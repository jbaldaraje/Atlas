// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "VaultCore", platforms: [.macOS(.v14)], products: [.library(name: "VaultCore", targets: ["VaultCore"])], targets: [.target(name: "VaultCore"), .testTarget(name: "VaultCoreTests", dependencies: ["VaultCore"])])
