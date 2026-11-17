// swift-tools-version: 6.0
import PackageDescription

// The pure logic sits in its own library so that tests can reach it without
// starting the app: indent math, rule sentences, undo, palette matching.
let package = Package(
    name: "Reader",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ReaderLogic"),
        .executableTarget(name: "Reader", dependencies: ["ReaderLogic"]),
        .testTarget(name: "ReaderLogicTests", dependencies: ["ReaderLogic"]),
    ]
)
