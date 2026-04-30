// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "HermesNative",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(
            name: "HermesNative",
            targets: ["HermesNative"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-spm", from: "4.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "HermesNative",
            dependencies: [
                .product(name: "Lottie", package: "lottie-spm"),
            ],
            resources: [
                .process("Resources/Lottie"),
            ],
            linkerSettings: [
                .linkedFramework("SceneKit"),
                .linkedFramework("SpriteKit"),
            ]
        ),
    ]
)
