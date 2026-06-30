import ArgumentParser
import Foundation

@main
struct KAB: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kab",
        abstract: "EPUB → audiobook with Kokoro (Apple Silicon): queue, live progress, CLI + MCP.",
        subcommands: [Serve.self, WorkerCmd.self, ConvertCmd.self, ConvertJobCmd.self,
                      AneEnqueue.self, AneQueueRun.self, AneQueueStatus.self, Enqueue.self,
                      Status.self, ListCmd.self, Cancel.self, Move.self, ConfigCmd.self, Setup.self],
        defaultSubcommand: Status.self
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", abstract: "Run the MCP server over stdio.")
    func run() async throws { try await MCPServer.serve() }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Install synthesis deps: download the Kokoro model + voices and wire the synthesizer.")
    @Option(name: .customLong("synth-cmd"), help: "Path to the built kokoro-say binary; wires it as synthCmd.")
    var synthCmd: String?

    func run() throws {
        var cfg = Config.load()
        let models = cfg.home.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let items: [(String, URL, String)] = [
            ("Kokoro model (~600MB)", models.appendingPathComponent("kokoro.safetensors"),
             "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors"),
            ("voices", models.appendingPathComponent("voices.npz"),
             "https://github.com/mlalma/KokoroTestApp/raw/main/Resources/voices.npz"),
        ]
        for (name, dest, url) in items {
            if FileManager.default.fileExists(atPath: dest.path) { print("\(name): present"); continue }
            print("Downloading \(name)…")
            try Proc.run("/usr/bin/curl", ["-fL", "--progress-bar", "-o", dest.path, url])
        }
        if let s = synthCmd {
            cfg.synthCmd = (s as NSString).expandingTildeInPath
            cfg.save()
            print("synthCmd = \(cfg.synthCmd ?? "")")
        }
        print("Model + voices in \(models.path).")
        print("Build the synthesizer with `make synth`, then: kab setup --synth-cmd <path-to-kokoro-say>")
    }
}

struct WorkerCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "worker", abstract: "Run the queue worker (internal).")
    func run() throws { Worker.run(Config.load()) }
}

/// Internal worker step: render one queued EPUB job (the legacy MLX/cache path).
/// Invoked by the queue Worker as `kab convert-job --job <id>`.
struct ConvertJobCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "convert-job", abstract: "Render one queued EPUB job (internal).")
    @Option var job: String
    func run() throws {
        let cfg = Config.load()
        guard let j = Store(cfg: cfg).get(job) else { throw ValidationError("job not found: \(job)") }
        try Convert.run(cfg: cfg, job: j)
    }
}

/// User-facing converter: chapters dir -> chaptered .m4b, via the proven ANE
/// engine (kokoro-coreml/scripts/ane_book.py book). Streams progress/ETA live
/// and leaves no kokoro-bench process behind.
struct ConvertCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert a chapters directory to a chaptered .m4b (ANE engine).")
    @Option(name: .customLong("chapters-dir"), help: "Directory of chapter markdown/text files.")
    var chaptersDir: String
    @Option(help: "Filename glob for chapters (default: capitulo-*.md).")
    var glob: String = "capitulo-*.md"
    @Option(help: "Front-matter file spoken first (repeatable).")
    var prepend: [String] = []
    @Option(help: "Kokoro voice (e.g. ef_dora, af_heart).")
    var voice: String = "af_heart"
    @Option(help: "ane_book language code: a=English, e=Spanish, f=French, i=Italian, p=Portuguese.")
    var lang: String = "a"
    @Option(help: "Album/title metadata.")
    var title: String = "Audiobook"
    @Option(help: "Artist metadata.")
    var artist: String = ""
    @Option(help: "Output .m4b path.")
    var out: String
    @Option(help: "Speech speed.")
    var speed: Double = 1.0
    @Flag(name: .customLong("drop-title"), help: "Do not speak the chapter heading (markers only).")
    var dropTitle: Bool = false
    @Option(name: .customLong("cache-dir"),
            help: "Persistent per-chapter audio cache dir; reuses unchanged chapters across runs.")
    var cacheDir: String?

    func run() throws {
        let cfg = Config.load()
        let chapters = (chaptersDir as NSString).expandingTildeInPath
        let outPath = (out as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: chapters) else {
            throw ValidationError("chapters dir not found: \(chaptersDir)")
        }
        try? FileManager.default.createDirectory(
            atPath: (outPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        var args = [
            "--chapters-dir", chapters,
            "--glob", glob,
            "--voice", voice,
            "--lang", lang,
            "--title", title,
            "--artist", artist,
            "--out", outPath,
            "--speed", String(speed),
        ]
        if dropTitle { args.append("--drop-title") }
        if let cacheDir {
            args += ["--cache-dir", (cacheDir as NSString).expandingTildeInPath]
        }
        for p in prepend { args += ["--prepend", (p as NSString).expandingTildeInPath] }

        FileHandle.standardError.write(Data("kab convert -> ane_book.py book (\(cfg.kokoroRepo))\n".utf8))
        let code = try AneRunner.run(cfg: cfg, subcommand: "book", args: args)
        if code != 0 { throw KabError.proc("ane_book.py book exited \(code)") }
        guard FileManager.default.fileExists(atPath: outPath) else {
            throw KabError.proc("ane_book.py reported success but no file at \(outPath)")
        }
        print("OK: \(outPath)")
    }
}

/// Enqueue a chapters->m4b job onto ane_book.py's own queue (`enqueue`).
struct AneEnqueue: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ane-enqueue",
        abstract: "Queue a chapters->m4b conversion on the ANE engine queue.")
    @Option(name: .customLong("chapters-dir")) var chaptersDir: String
    @Option var glob: String = "capitulo-*.md"
    @Option var prepend: [String] = []
    @Option var voice: String = "af_heart"
    @Option var lang: String = "a"
    @Option var title: String = "Audiobook"
    @Option var artist: String = ""
    @Option var out: String
    @Option var speed: Double = 1.0
    @Flag(name: .customLong("drop-title")) var dropTitle: Bool = false
    @Option(name: .customLong("cache-dir"),
            help: "Persistent per-chapter audio cache dir (see `convert`).") var cacheDir: String?
    @Option(help: "Queue JSON file (default: ane_book.py's default).") var queue: String?

    func run() throws {
        let cfg = Config.load()
        var args = [
            "--chapters-dir", (chaptersDir as NSString).expandingTildeInPath,
            "--glob", glob,
            "--voice", voice, "--lang", lang,
            "--title", title, "--artist", artist,
            "--out", (out as NSString).expandingTildeInPath,
            "--speed", String(speed),
        ]
        if dropTitle { args.append("--drop-title") }
        if let cacheDir { args += ["--cache-dir", (cacheDir as NSString).expandingTildeInPath] }
        for p in prepend { args += ["--prepend", (p as NSString).expandingTildeInPath] }
        if let queue { args += ["--queue", (queue as NSString).expandingTildeInPath] }
        let code = try AneRunner.run(cfg: cfg, subcommand: "enqueue", args: args)
        if code != 0 { throw KabError.proc("ane_book.py enqueue exited \(code)") }
    }
}

/// Drain the ANE engine queue (`queue-run`), streaming progress.
struct AneQueueRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ane-queue-run",
        abstract: "Drain the ANE engine queue (serial by default).")
    @Option var concurrency: Int = 1
    @Option(help: "Queue JSON file (default: ane_book.py's default).") var queue: String?
    func run() throws {
        let cfg = Config.load()
        var args = ["--concurrency", String(concurrency)]
        if let queue { args += ["--queue", (queue as NSString).expandingTildeInPath] }
        let code = try AneRunner.run(cfg: cfg, subcommand: "queue-run", args: args)
        if code != 0 { throw KabError.proc("ane_book.py queue-run exited \(code)") }
    }
}

/// Show the ANE engine queue (`queue-status`).
struct AneQueueStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ane-queue-status",
        abstract: "Show the ANE engine queue.")
    @Option(help: "Queue JSON file (default: ane_book.py's default).") var queue: String?
    func run() throws {
        let cfg = Config.load()
        var args: [String] = []
        if let queue { args += ["--queue", (queue as NSString).expandingTildeInPath] }
        _ = try AneRunner.run(cfg: cfg, subcommand: "queue-status", args: args)
    }
}

struct Enqueue: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enqueue", abstract: "Queue an EPUB → audiobook conversion.")
    @Argument(help: "Path to the .epub") var ebook: String
    @Option(help: "ISO-639-3 language (eng, spa, …)") var language: String = "eng"
    @Option(help: "Kokoro voice name or WAV path") var voice: String?
    @Option(help: "Output directory (default: the ebook's folder)") var outputDir: String?
    @Option(help: "m4b | mp3 | wav") var format: String = "m4b"
    @Option(help: "Book title (audiobook metadata)") var title: String = "Audiobook"
    @Option(help: "Author/artist (audiobook metadata)") var artist: String = ""
    func run() throws {
        let cfg = Config.load()
        let store = Store(cfg: cfg)
        let path = (ebook as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw ValidationError("ebook not found: \(ebook)") }
        let out = outputDir ?? (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let job = store.enqueue(Spec(ebook: path, language: language, voice: voice,
                                     outputDir: out, outputFormat: format,
                                     title: title, artist: artist))
        let spawned = Worker.ensure(cfg)
        print(Views.json(["job_id": job.id, "status": job.status.rawValue, "worker_spawned": spawned]))
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the whole queue (counts, running %/ETA, positions).")
    func run() throws {
        let cfg = Config.load()
        print(Views.json(Views.queueView(cfg, Store(cfg: cfg))))
    }
}

struct ListCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List every job.")
    func run() throws {
        let cfg = Config.load()
        print(Views.json(["jobs": Store(cfg: cfg).list().map { Views.jobView(cfg, $0) }]))
    }
}

struct Cancel: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cancel", abstract: "Cancel a queued or running job.")
    @Argument var jobId: String
    func run() throws {
        let store = Store(cfg: Config.load())
        guard let j = store.get(jobId) else { throw ValidationError("job not found: \(jobId)") }
        if JobStatus.terminal.contains(j.status) { print("already \(j.status.rawValue)"); return }
        store.update(jobId) { $0.cancelRequested = true }
        print("cancel_requested \(jobId)")
    }
}

struct Move: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Move a queued job to a 1-based position.")
    @Argument var jobId: String
    @Argument var position: Int
    func run() throws {
        let store = Store(cfg: Config.load())
        guard store.move(jobId, position: position) != nil else { throw ValidationError("job not found or not queued") }
        print("moved \(jobId) -> \(position)")
    }
}

struct ConfigCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Get/set config (synthCmd, voices, concurrency).")
    @Argument(help: "set <key> <value> | voice <lang> <voice> | show") var action: String = "show"
    @Argument var args: [String] = []
    func run() throws {
        var cfg = Config.load()
        switch action {
        case "set" where args.count == 2:
            let (k, v) = (args[0], args[1])
            switch k {
            case "synthCmd": cfg.synthCmd = (v as NSString).expandingTildeInPath
            case "speed": cfg.speed = Double(v) ?? cfg.speed
            case "concurrency": cfg.concurrency = max(1, Int(v) ?? cfg.concurrency)
            case "maxRetries": cfg.maxRetries = max(0, Int(v) ?? cfg.maxRetries)
            case "kokoroRepo": cfg.kokoroRepo = (v as NSString).expandingTildeInPath
            case "runner": cfg.runner = v.split(separator: " ").map(String.init)
            default: throw ValidationError("unknown key \(k)")
            }
            cfg.save(); print("set \(k)=\(v)")
        case "voice" where args.count == 2:
            cfg.voices[args[0]] = args[1]; cfg.save(); print("voice \(args[0])=\(args[1])")
        default:
            print(Views.json([
                "home": cfg.home.path, "synthCmd": cfg.synthCmd ?? "(none — silent dry-run)",
                "voices": cfg.voices, "speed": cfg.speed, "concurrency": cfg.concurrency,
                "kokoroRepo": cfg.kokoroRepo, "runner": cfg.runner.joined(separator: " "),
                "aneBookScript": cfg.aneBookScript,
            ]))
        }
    }
}
