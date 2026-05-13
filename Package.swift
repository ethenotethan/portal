// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "HermesNative",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(
            name: "HermesNative",
            targets: ["HermesNative"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-spm", from: "4.6.0"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.3.0"),
        .package(url: "https://github.com/lukilabs/beautiful-mermaid-swift", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "HermesNative",
            dependencies: [
                .product(name: "Lottie", package: "lottie-spm"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
            ],
            resources: [
                .process("Resources/Lottie"),
            ],
            linkerSettings: [
                .linkedFramework("SceneKit"),
                .linkedFramework("SpriteKit"),
            ]
        ),
        .testTarget(
            name: "HermesNativeTests",
            dependencies: ["HermesNative"]
        ),
    ]
)
