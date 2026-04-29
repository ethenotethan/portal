// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "HermesNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "HermesNative",
            targets: ["HermesNative"]
        ),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "HermesNative",
            dependencies: []
        ),
        .testTarget(
            name: "HermesNativeTests",
            dependencies: ["HermesNative"]
        ),
    ]
)
