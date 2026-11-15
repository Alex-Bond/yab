// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "YabCoreClient", platforms: [.macOS(.v13)],
    products: [.library(name: "YabCoreClient", targets: ["YabCoreClient"]),
               .executable(name: "YabCoreProbe", targets: ["YabCoreProbe"])],
    targets: [.target(name: "YabCoreClient"),
              .executableTarget(name: "YabCoreProbe", dependencies: ["YabCoreClient"]),
              .testTarget(name: "YabCoreClientTests", dependencies: ["YabCoreClient"])])
