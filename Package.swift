// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SamsungMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SamsungMac",
            path: "Sources/SamsungMac"
        )
    ]
)
