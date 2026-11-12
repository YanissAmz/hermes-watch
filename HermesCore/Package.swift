// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesCore",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HermesCore", targets: ["HermesCore"])],
    targets: [
        .target(name: "HermesCore"),
        .testTarget(name: "HermesCoreTests", dependencies: ["HermesCore"]),
    ]
)
