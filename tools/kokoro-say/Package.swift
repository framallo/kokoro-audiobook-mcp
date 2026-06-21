// swift-tools-version: 6.0
import PackageDescription

// Thin Kokoro synthesizer CLI used as `kab`'s synthCmd backend.
// Wraps KokoroSwift (kokoro-ios, MLX/Metal): text -> 24 kHz WAV.
//   kokoro-say --text-file F --voice V --language L --speed S --out O.wav
// Model + voices come from env KOKORO_MODEL / KOKORO_VOICES.
//
// NOTE: KokoroSwift currently ships English G2P only (Misaki; eSpeakNGSwift is
// commented out in its package). Spanish needs that enabled — see the project TODO.
let package = Package(
    name: "kokoro-say",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "kokoro-say", targets: ["kokoro-say"])],
    dependencies: [
        .package(path: "../../../kokoro-coreml/ios-bench/Vendor/kokoro-ios"),
    ],
    targets: [
        .executableTarget(
            name: "kokoro-say",
            dependencies: [.product(name: "KokoroSwift", package: "kokoro-ios")],
            path: "Sources/kokoro-say"
        ),
    ]
)
