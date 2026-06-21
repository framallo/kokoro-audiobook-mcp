// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kokoro-audiobook-mcp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kab", targets: ["kab"]),
    ],
    dependencies: [
        // Official Swift MCP SDK (server over stdio) — exposes the queue to Claude.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "kab",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/kab"
        ),
    ]
)

// The acoustic synthesis runs on Apple Silicon via Kokoro. To keep the core
// (queue + MCP + EPUB + m4b) building fast, the synthesizer is invoked as an
// external command (cfg.synthCmd) rather than linking MLX/CoreML here. Wire it to
// the kokoro-coreml `kokoro-bench` (ANE) or a KokoroSwift CLI — see README.
