import Foundation
import MLX
import KokoroSwift

// kokoro-say --text-file F --voice V --language L --speed S --out O.wav
func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}

let env = ProcessInfo.processInfo.environment
guard let textFile = arg("--text-file"), let outPath = arg("--out") else {
    FileHandle.standardError.write(Data("usage: kokoro-say --text-file F --voice V --language L --speed S --out O.wav\n".utf8))
    exit(2)
}
let text = (try? String(contentsOfFile: textFile, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
let voiceName = arg("--voice") ?? "af_heart"
let langArg = arg("--language") ?? "en-us"
let speed = Float(arg("--speed") ?? "1.0") ?? 1.0
let home = NSHomeDirectory() + "/.kokoro-audiobook-mcp/models"
let modelPath = env["KOKORO_MODEL"] ?? "\(home)/kokoro.safetensors"
let voicesPath = env["KOKORO_VOICES"] ?? "\(home)/voices.npz"

// KokoroSwift currently supports English only.
let lang: Language
switch langArg {
case "en-gb": lang = .enGB
case "en-us", "eng", "en": lang = .enUS
default:
    FileHandle.standardError.write(Data("kokoro-say: '\(langArg)' not supported by KokoroSwift (English only); see TODO. Falling back to en-us.\n".utf8))
    lang = .enUS
}

do {
    let tts = KokoroTTS(modelPath: URL(fileURLWithPath: modelPath))
    let voices = try MLX.loadArrays(url: URL(fileURLWithPath: voicesPath))
    let key = voices[voiceName] != nil ? voiceName : "\(voiceName).npy"
    guard let voiceArr = voices[key] else {
        FileHandle.standardError.write(Data("kokoro-say: voice '\(voiceName)' not in \(voicesPath)\n".utf8))
        exit(3)
    }
    let (audio, _) = try tts.generateAudio(voice: voiceArr, language: lang, text: text, speed: speed)
    try writeWavMono16(samples: audio, sampleRate: 24000, to: outPath)
} catch {
    FileHandle.standardError.write(Data("kokoro-say error: \(error)\n".utf8))
    exit(1)
}

/// Peak-normalized 16-bit PCM mono WAV.
func writeWavMono16(samples: [Float], sampleRate: Int, to path: String) throws {
    let n = samples.count
    var peak: Float = 1e-7
    for s in samples { peak = max(peak, abs(s)) }
    var pcm = [Int16](repeating: 0, count: n)
    for i in 0..<n { pcm[i] = Int16(max(-1, min(1, samples[i] / peak)) * 32767) }
    let dataSize = UInt32(n * 2)
    var d = Data()
    func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36) + dataSize)
    d.append(contentsOf: Array("WAVE".utf8)); d.append(contentsOf: Array("fmt ".utf8))
    le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(sampleRate))
    le(UInt32(sampleRate * 2)); le(UInt16(2)); le(UInt16(16))
    d.append(contentsOf: Array("data".utf8)); le(dataSize)
    pcm.withUnsafeBytes { d.append(contentsOf: $0) }
    try d.write(to: URL(fileURLWithPath: path))
}
