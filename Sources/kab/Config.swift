import Foundation

/// Configuration + path resolution. State lives under $KAB_HOME
/// (default ~/.kokoro-audiobook-mcp). The tool owns its whole pipeline, so it
/// writes its own progress to <home>/progress/<session>.json and caches
/// per-sentence audio under <home>/cache/ (keyed by text+voice+speed+lang).
struct Config: Sendable {
    var home: URL
    /// External synthesizer command. Receives:
    ///   <cmd> --text-file F --voice V --language L --speed S --out OUT.wav
    /// and must write a 24 kHz mono WAV to OUT. Wire it to kokoro-bench (ANE) or
    /// a KokoroSwift CLI (see README). When nil, convert runs in dry-run (silent).
    var synthCmd: String?
    var voices: [String: String]      // per-language override: ["spa": "em_santa"]
    var speed: Double
    var sampleRate: Int
    var concurrency: Int
    var maxRetries: Int
    var idleExitSeconds: Int

    static let defaultVoice: [String: String] = [
        "eng": "am_adam", "spa": "em_alex", "por": "pm_alex",
        "fra": "ff_siwis", "ita": "im_nicola",
    ]
    /// ISO-639-3 -> Kokoro/espeak language label used by the synth backend.
    static let langName: [String: String] = [
        "eng": "en-us", "spa": "es", "por": "pt-br", "fra": "fr", "ita": "it",
    ]

    func voiceFor(_ language: String?) -> String? {
        guard let language else { return nil }
        return voices[language] ?? Config.defaultVoice[language]
    }
    func langName(_ language: String?) -> String {
        Config.langName[language ?? ""] ?? "en-us"
    }

    var jobsDir: URL { home.appendingPathComponent("jobs") }
    var logsDir: URL { home.appendingPathComponent("logs") }
    var progressDir: URL { home.appendingPathComponent("progress") }
    var cacheDir: URL { home.appendingPathComponent("cache") }
    var workDir: URL { home.appendingPathComponent("work") }
    var workerLock: URL { home.appendingPathComponent("worker.lock") }
    var workerLog: URL { home.appendingPathComponent("worker.log") }
    var storeLock: URL { home.appendingPathComponent("store.lock") }
    var configFile: URL { home.appendingPathComponent("config.json") }

    func progressPath(session: String) -> URL {
        progressDir.appendingPathComponent("\(session).json")
    }

    private struct File: Codable {
        var synthCmd: String?
        var voices: [String: String]?
        var speed: Double?
        var sampleRate: Int?
        var concurrency: Int?
        var maxRetries: Int?
        var idleExitSeconds: Int?
    }

    static func load() -> Config {
        let home: URL = {
            if let env = ProcessInfo.processInfo.environment["KAB_HOME"] {
                return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".kokoro-audiobook-mcp")
        }()
        var f = File(synthCmd: nil, voices: [:], speed: 1.0, sampleRate: 24000,
                     concurrency: 1, maxRetries: 2, idleExitSeconds: 30)
        let cfgPath = home.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: cfgPath),
           let parsed = try? JSONDecoder().decode(File.self, from: data) {
            f = parsed
        }
        var cfg = Config(
            home: home,
            synthCmd: f.synthCmd,
            voices: f.voices ?? [:],
            speed: f.speed ?? 1.0,
            sampleRate: f.sampleRate ?? 24000,
            concurrency: max(1, f.concurrency ?? 1),
            maxRetries: max(0, f.maxRetries ?? 2),
            idleExitSeconds: f.idleExitSeconds ?? 30
        )
        cfg.ensureDirs()
        return cfg
    }

    func ensureDirs() {
        let fm = FileManager.default
        for d in [home, jobsDir, logsDir, progressDir, cacheDir, workDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    func save() {
        let f = File(synthCmd: synthCmd, voices: voices, speed: speed,
                     sampleRate: sampleRate, concurrency: concurrency,
                     maxRetries: maxRetries, idleExitSeconds: idleExitSeconds)
        if let data = try? JSONEncoder().encode(f) {
            try? data.write(to: configFile)
        }
    }
}
