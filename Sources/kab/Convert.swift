import Foundation

/// Live progress written to <home>/progress/<session>.json after every sentence.
struct Progress: Codable, Sendable {
    var percent: Double
    var rendered: Int
    var reused: Int
    var total: Int
    var etaSeconds: Double?
    var avgRenderSeconds: Double?
    var chapter: Int
    var index: Int
    var text: String
}

/// The conversion pipeline, run as a subprocess by the worker:
///   kab convert --job <id>
/// EPUB -> chapters -> per-sentence synth (cached) -> chapter concat -> m4b.
/// Killable at any point; a re-run resumes for free because rendered sentences
/// are served from the content cache.
enum Convert {
    static func main(_ args: [String]) {
        var jobId: String?
        var i = 0
        while i < args.count {
            if args[i] == "--job", i + 1 < args.count { jobId = args[i + 1]; i += 1 }
            i += 1
        }
        let cfg = Config.load()
        let store = Store(cfg: cfg)
        guard let jobId, let job = store.get(jobId) else {
            FileHandle.standardError.write(Data("convert: job not found\n".utf8)); exit(2)
        }
        do { try run(cfg: cfg, job: job); exit(0) }
        catch {
            FileHandle.standardError.write(Data("convert error: \(error)\n".utf8)); exit(1)
        }
    }

    static func run(cfg: Config, job: Job) throws {
        let spec = job.spec
        let chapters = try Epub.parse(spec.ebook)
        let voice = spec.voice ?? cfg.voiceFor(spec.language) ?? "am_adam"
        let lang = cfg.langName(spec.language)
        let total = max(1, chapters.reduce(0) { $0 + $1.sentences.count })
        let synth: Synthesizer = cfg.synthCmd.map { CommandSynth(cmd: $0) }
            ?? SilentSynth(sampleRate: cfg.sampleRate)

        let work = cfg.workDir.appendingPathComponent(job.sessionId)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        var rendered = 0, reused = 0, idx = 0
        let t0 = Date()
        var chapterFiles: [(String, URL)] = []

        for (ci, ch) in chapters.enumerated() {
            var sentenceFiles: [URL] = []
            for sentence in ch.sentences {
                idx += 1
                let key = fnv1a("\(voice)|\(lang)|\(cfg.speed)|\(sentence)")
                let cached = cfg.cacheDir.appendingPathComponent("\(key).wav")
                if FileManager.default.fileExists(atPath: cached.path) {
                    reused += 1
                } else {
                    let tmp = cached.appendingPathExtension("part")
                    try synth.synthesize(text: sentence, voice: voice, language: lang,
                                         speed: cfg.speed, to: tmp)
                    try? FileManager.default.removeItem(at: cached)
                    try FileManager.default.moveItem(at: tmp, to: cached)
                    rendered += 1
                }
                sentenceFiles.append(cached)
                writeProgress(cfg, session: job.sessionId, total: total, idx: idx,
                              rendered: rendered, reused: reused, t0: t0,
                              chapter: ci + 1, text: sentence)
            }
            let chWav = work.appendingPathComponent("ch\(String(format: "%03d", ci + 1)).wav")
            try Assemble.concat(sentenceFiles, to: chWav, work: work)
            chapterFiles.append((ch.title, chWav))
        }

        let stem = ((spec.ebook as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = spec.outputFormat == "wav" ? "wav" : (spec.outputFormat == "mp3" ? "mp3" : "m4b")
        let out = URL(fileURLWithPath: spec.outputDir).appendingPathComponent("\(stem).\(ext)")
        try Assemble.finalize(chapters: chapterFiles, to: out, format: spec.outputFormat, work: work)
        try? FileManager.default.removeItem(at: work)
    }

    static func writeProgress(_ cfg: Config, session: String, total: Int, idx: Int,
                              rendered: Int, reused: Int, t0: Date, chapter: Int, text: String) {
        let elapsed = Date().timeIntervalSince(t0)
        let perItem = idx > 0 ? elapsed / Double(idx) : 0
        let remaining = max(0, total - idx)
        let prog = Progress(
            percent: Double(idx) / Double(total) * 100,
            rendered: rendered, reused: reused, total: total,
            etaSeconds: perItem > 0 ? perItem * Double(remaining) : nil,
            avgRenderSeconds: rendered > 0 ? elapsed / Double(rendered) : nil,
            chapter: chapter, index: idx, text: String(text.prefix(160))
        )
        if let data = try? JSONEncoder().encode(prog) {
            try? data.write(to: cfg.progressPath(session: session))
        }
    }

    /// 64-bit FNV-1a as hex — stable cache key for (voice|lang|speed|sentence).
    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return String(h, radix: 16)
    }
}
