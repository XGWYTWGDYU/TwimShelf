// swift-tools-version: 5.9

import PackageDescription

/// The on-device MLX engine, shared by the native Apple apps and the Flutter app's Apple runner
/// (through `flutter/tl_native`). It knows nothing of the library: it is given a model folder,
/// a prompt and a picture, and answers with text or vectors.
let package = Package(
    name: "TLLocalAI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TLLocalAI", targets: ["TLLocalAI"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(name: "TLLocalAI", dependencies: [
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
    ]
)
