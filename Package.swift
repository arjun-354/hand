// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Hand",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Hand",
            path: "Sources/Hand"
        )
    ]
)
