// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiteRTLMSwift",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "LiteRTLMSwift", targets: ["LiteRTLMSwift"])
    ],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM",
            path: "Frameworks/LiteRTLM-rewrapped.xcframework"
        ),
        .binaryTarget(
            name: "GemmaModelConstraintProvider",
            path: "Frameworks/GemmaModelConstraintProvider.xcframework"
        ),
        .target(
            name: "LiteRTLMSwift",
            dependencies: ["CLiteRTLM", "GemmaModelConstraintProvider"],
            path: "Sources/LiteRTLMSwift"
        ),
    ]
)
