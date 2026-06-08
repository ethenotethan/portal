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
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "HermesNative",
            dependencies: [
                .product(name: "Lottie", package: "lottie-spm"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
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
