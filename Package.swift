// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Portal",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(
            name: "Portal",
            targets: ["Portal"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/raspu/Highlightr", from: "2.3.0"),
        .package(url: "https://github.com/lukilabs/beautiful-mermaid-swift", from: "1.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.0"),
    ],
    targets: [
        .target(
            name: "Portal",
            dependencies: [
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("SceneKit"),
                .linkedFramework("SpriteKit"),
            ]
        ),
        .testTarget(
            name: "PortalTests",
            dependencies: ["Portal"],
            // Golden PNGs for the View-snapshot gate. ViewSnapshot reads them by
            // absolute source path (#filePath-resolved), never via Bundle, so
            // they must NOT be bundled — left in, SwiftPM flags them as unhandled
            // resources, a build warning the metric ratchet would then catch.
            exclude: ["__Snapshots__"]
        ),
    ]
)
