import Foundation

enum CliExec {
    struct Options: Equatable {
        var file: String?
        var code: String?
        var json = false
        var timeout: TimeInterval = 60
        var outputLimit = 8000
        var socket: String?
        var help = false
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ args: [String]) throws -> Options {
        var options = Options()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw Failure(message: "\(flag) needs a value.") }
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help": options.help = true
            case "--json": options.json = true
            case "-f", "--file":
                guard options.file == nil else { throw Failure(message: "Choose one script file.") }
                options.file = try value(arg)
            case "--socket":
                guard options.socket == nil else { throw Failure(message: "Choose one socket.") }
                options.socket = try value(arg)
            case "--timeout":
                guard let seconds = Double(try value(arg)), seconds.isFinite, (0.1...600).contains(seconds) else {
                    throw Failure(message: "--timeout must be 0.1 to 600 seconds.")
                }
                options.timeout = seconds
            case "--output-limit":
                guard let limit = Int(try value(arg)), (256...32000).contains(limit) else {
                    throw Failure(message: "--output-limit must be 256 to 32000 characters.")
                }
                options.outputLimit = limit
            case "--":
                i += 1
                guard i == args.count - 1, options.code == nil else { throw Failure(message: "Pass JavaScript as one argument, a file, or stdin (-).") }
                options.code = args[i]
            default:
                guard arg == "-" || !arg.hasPrefix("-"), options.code == nil else {
                    throw Failure(message: "Unknown or extra argument: \(arg).")
                }
                options.code = arg
            }
            i += 1
        }
        guard options.file == nil || options.code == nil else { throw Failure(message: "Choose JavaScript, a file, or stdin (-), not several.") }
        return options
    }

    static func source(_ options: Options, stdin: () throws -> Data) throws -> String {
        let data: Data
        if let file = options.file, file != "-" {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
            defer { try? handle.close() }
            data = try handle.read(upToCount: 1_048_577) ?? Data()
        } else if options.file == "-" || options.code == "-" {
            data = try stdin()
        } else if let code = options.code {
            data = Data(code.utf8)
        } else {
            throw Failure(message: "Pass JavaScript, -f FILE, or - for stdin.")
        }
        guard data.count <= 1_048_576 else { throw Failure(message: "The script is larger than 1 MiB.") }
        guard let code = String(data: data, encoding: .utf8), !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "The script must be nonempty UTF-8 JavaScript.")
        }
        return code
    }

    static func status(_ result: [String: Any]) -> Int32 {
        guard result["isError"] as? Bool == true else { return 0 }
        let text = words(result)
        return text.contains("status: needs_user") ? 3 : 1
    }

    static func words(_ result: [String: Any]) -> String {
        (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private let json: Bool
        init(json: Bool) { self.json = json }

        func finish(_ result: [String: Any], code: Int32) -> Never {
            lock.lock()
            let text: String
            if json, let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let encoded = String(data: data, encoding: .utf8) {
                text = encoded
            } else {
                text = CliExec.words(result)
            }
            let handle = json || code == 0 ? FileHandle.standardOutput : FileHandle.standardError
            try? handle.write(contentsOf: Data((text + "\n").utf8))
            exit(code)
        }
    }

    static func run(_ args: [String]) -> Never {
        let options: Options
        let code: String
        do {
            options = try parse(args)
            if options.help { print(usage); exit(0) }
            code = try source(options) {
                var data = Data()
                while data.count <= 1_048_576, let part = try FileHandle.standardInput.read(upToCount: min(65536, 1_048_577 - data.count)), !part.isEmpty {
                    data.append(part)
                }
                return data
            }
        } catch {
            let output = Output(json: args.contains("--json"))
            output.finish(Mcp.text(error.localizedDescription, error: true), code: 2)
        }
        let output = Output(json: options.json)
        let deadline = DispatchSource.makeTimerSource(queue: .global())
        deadline.schedule(deadline: .now() + options.timeout)
        deadline.setEventHandler {
            output.finish(Mcp.text("Script timed out after \(options.timeout)s. Further steps were stopped. An action already sent may have completed; read its actual state before retrying.", error: true), code: 124)
        }
        deadline.resume()
        var signals: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                output.finish(Mcp.text("Script stopped. An action already sent may have completed; read its actual state before retrying.", error: true), code: 128 + number)
            }
            source.resume()
            signals.append(source)
        }
        let connection = options.socket.map { ["--socket", $0] } ?? []
        let result = Mcp.once("run", ["code": code, "outputLimit": options.outputLimit], args: connection)
        deadline.cancel()
        withExtendedLifetime(signals) { output.finish(result, code: status(result)) }
    }

    static var usage: String {
        """
        usage: \(AgentSetup.command) exec 'return 2 + 2' [--json]
               \(AgentSetup.command) exec -f FILE.js [--json] [--timeout SECONDS] [--output-limit CHARS]
               \(AgentSetup.command) exec - [--json]     read JavaScript from stdin
        Runs the existing MCP run tool directly, with the same browser permissions and approvals; no model is started.
        Each exec has its own keep object. MCP run keeps it for its MCP connection.
        timeout: 60 seconds by default, 0.1–600; output: 8000 characters by default, 256–32000.
        exit: 0 done · 1 script/tool error · 2 usage · 3 needs you · 124 timeout · 130 interrupted · 143 terminated
        """
    }
}
