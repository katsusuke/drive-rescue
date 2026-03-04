// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "drive-rescue",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "drive-rescue",
            path: "Sources"
        ),
    ]
)
