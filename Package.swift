// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MusicCraftCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MusicCraftCore", targets: ["MusicCraftCore"])],
    dependencies: [],
    targets: [
        .target(name: "MusicCraftCore", resources: [.process("Resources")]),
        .testTarget(name: "MusicCraftCoreTests", dependencies: ["MusicCraftCore"])
    ]
)
