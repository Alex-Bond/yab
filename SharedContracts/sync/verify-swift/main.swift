// Compile with the actual Swift wire sources, so the fixture oracle cannot drift silently.
// swiftc Sources/SyncKit/{Value,Clock,Record,Seal}.swift SharedContracts/sync/verify-swift/main.swift -o "$YAB_FARM_OUT/verify-sync"
import CryptoKit
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("Contract mismatch: \(label)") }
}
func bytes(_ hex: String) -> Data {
    Data(stride(from: 0, to: hex.count, by: 2).map { index in
        let start = hex.index(hex.startIndex, offsetBy: index)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    })
}
let path = CommandLine.arguments.dropFirst().first ?? "SharedContracts/sync/vectors-v1.json"
let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
let key = root["root"] as! [String: String], record = root["record"] as! [String: String]
let seal = Seal(raw: bytes(key["hex"]!))!
require(seal.account == key["account"]!, "account")
require(seal.secret == key["auth"]!, "auth")
require(seal.recovery == key["recovery"]!, "recovery")
let decoded = try JSONDecoder().decode(Record.self, from: Data(record["json"]!.utf8))
require(seal.name(decoded.key) == record["name"]!, "record name")
let opened = try seal.open(Data(base64Encoded: record["sealed"]!)!, name: record["name"]!)
require(opened == decoded, "AES-GCM record")
let hidden = root["secret"] as! [String: String]
let secretKey = hidden["key"]!.split(separator: "/", maxSplits: 1).map(String.init)
require(seal.reveal(hidden["sealed"]!, in: .init(collection: secretKey[0], id: secretKey[1])) == Data(hidden["text"]!.utf8), "secret")
let pairing = root["pairing"] as! [String: String]
require(Joining.box(pairing["code"]!) == pairing["box"]!, "pairing PBKDF2")
require(Joining.verified(pairing["posted"]!, code: pairing["code"]!) == bytes(pairing["receiverPublic"]!), "pairing tag")
let receiver = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(pairing["receiverPrivate"]!))
let envelope = Data(base64Encoded: pairing["envelope"]!)!
let shared = try receiver.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.prefix(32)))
let envelopeKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Stretch.of(pairing["code"]!).salt,
    sharedInfo: Data("yab sync join v2".utf8), outputByteCount: 32)
let recovered = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.dropFirst(32)), using: envelopeKey)
require(recovered == seal.raw, "X25519 envelope")
print("Swift SyncKit matches shared crypto vectors")

let approvalPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "SharedContracts/sync/approval-vectors-v1.json"
let approvalVectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: approvalPath))) as! [String: Any]
var actualCases = [[String: String]]()
for item in approvalVectors["cases"] as! [[String: String]] {
    let input = Data(item["input"]!.utf8)
    let canonical: String, digest: String
    if item["type"] == "request" {
        var request = try JSONDecoder().decode(AssistantApprovalRecords.Request.self, from: input)
        try request.validate()
        digest = try request.digest()
        request.seen = nil
        canonical = try AssistantApprovalRecords.encodeBody(request)
    } else {
        let detail = try JSONDecoder().decode(AssistantApprovalRecords.Detail.self, from: input)
        canonical = try AssistantApprovalRecords.encodeBody(detail)
        digest = try detail.digest()
    }
    actualCases.append(["name": item["name"]!, "canonical": canonical, "digest": digest])
}
// Always retain the actual oracle bytes before comparing, including on mismatch.
if CommandLine.arguments.count > 3 {
    try JSONSerialization.data(withJSONObject: actualCases, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
}
for (input, actual) in zip(approvalVectors["cases"] as! [[String: String]], actualCases) {
    require(actual["canonical"] == input["canonical"], "\(input["name"]!) canonical JSON: \(actual["canonical"]!)")
    require(actual["digest"] == input["digest"], "\(input["name"]!) digest")
}
print("Swift approval Request/Detail models match \(actualCases.count) shared canonical digest vectors")

let taskPath = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "SharedContracts/sync/task-vectors-v1.json"
let taskVectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: taskPath))) as! [String: Any]
var actualTasks = [[String: String]]()
for item in taskVectors["cases"] as! [[String: String]] {
    let request = try JSONDecoder().decode(TaskRecords.Request.self, from: Data(item["input"]!.utf8))
    try request.validate()
    let body = try request.fields()["body"]!.string!
    let observation = try JSONDecoder().decode(TaskRecords.Observation.self, from: Data(item["observation"]!.utf8))
    try observation.validate(request: request)
    actualTasks.append(["name": item["name"]!, "canonical": body, "digest": try request.digest(), "observation": try observation.fields()["body"]!.string!])
}
if CommandLine.arguments.count > 5 {
    try JSONSerialization.data(withJSONObject: actualTasks, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: URL(fileURLWithPath: CommandLine.arguments[5]))
}
for (input, actual) in zip(taskVectors["cases"] as! [[String: String]], actualTasks) {
    for key in ["canonical", "digest", "observation"] { require(actual[key] == input[key], "\(input["name"]!) task \(key)") }
}
print("Swift TaskRecords Request/Observation models match \(actualTasks.count) shared vectors")
