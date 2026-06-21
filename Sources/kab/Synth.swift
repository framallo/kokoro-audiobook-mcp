import Foundation

/// One sentence -> a 24 kHz mono WAV. The acoustic work happens here; everything
/// else in the tool is orchestration.
protocol Synthesizer: Sendable {
    func synthesize(text: String, voice: String, language: String, speed: Double, to out: URL) throws
}

/// Shells out to the configured Kokoro synthesizer (kokoro-bench on ANE, or a
/// KokoroSwift CLI). Contract:
///   <cmd> --text-file F --voice V --language L --speed S --out OUT.wav
struct CommandSynth: Synthesizer {
    let cmd: String

    func synthesize(text: String, voice: String, language: String, speed: Double, to out: URL) throws {
        let tf = FileManager.default.temporaryDirectory
            .appendingPathComponent("kab-txt-" + UUID().uuidString + ".txt")
        try text.write(to: tf, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tf) }
        try Proc.run(cmd, [
            "--text-file", tf.path,
            "--voice", voice,
            "--language", language,
            "--speed", String(format: "%.3f", speed),
            "--out", out.path,
        ])
    }
}

/// Dry-run backend: writes silence sized to the text length so the whole
/// pipeline (cache, progress, chapter concat, m4b + markers) can be exercised
/// end to end before the Kokoro models are set up.
struct SilentSynth: Synthesizer {
    let sampleRate: Int

    func synthesize(text: String, voice: String, language: String, speed: Double, to out: URL) throws {
        // ~14 chars/sec of speech is a rough but fine placeholder.
        let seconds = max(0.4, Double(text.count) / 14.0 / max(0.5, speed))
        try Wav.writeSilence(to: out, seconds: seconds, sampleRate: sampleRate)
    }
}

enum Wav {
    /// Minimal 16-bit PCM mono WAV of silence.
    static func writeSilence(to url: URL, seconds: Double, sampleRate: Int) throws {
        let n = max(1, Int(seconds * Double(sampleRate)))
        let dataSize = UInt32(n * 2)
        let byteRate = UInt32(sampleRate * 2)
        var d = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
        le(UInt32(sampleRate)); le(byteRate); le(UInt16(2)); le(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); le(dataSize)
        d.append(Data(count: n * 2))  // zeros = silence
        try d.write(to: url)
    }
}
