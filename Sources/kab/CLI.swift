import ArgumentParser
import Foundation

@main
struct KAB: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kab",
        abstract: "EPUB → audiobook with Kokoro (Apple Silicon): queue, live progress, CLI + MCP.",
        subcommands: [Serve.self, WorkerCmd.self, ConvertCmd.self, Enqueue.self,
                      Status.self, ListCmd.self, Cancel.self, Move.self, ConfigCmd.self],
        defaultSubcommand: Status.self
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", abstract: "Run the MCP server over stdio.")
    func run() async throws { try await MCPServer.serve() }
}

struct WorkerCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "worker", abstract: "Run the queue worker (internal).")
    func run() throws { Worker.run(Config.load()) }
}

struct ConvertCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "convert", abstract: "Convert one job (internal).")
    @Option var job: String
    func run() throws {
        let cfg = Config.load()
        guard let j = Store(cfg: cfg).get(job) else { throw ValidationError("job not found: \(job)") }
        try Convert.run(cfg: cfg, job: j)
    }
}

struct Enqueue: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enqueue", abstract: "Queue an EPUB → audiobook conversion.")
    @Argument(help: "Path to the .epub") var ebook: String
    @Option(help: "ISO-639-3 language (eng, spa, …)") var language: String = "eng"
    @Option(help: "Kokoro voice name or WAV path") var voice: String?
    @Option(help: "Output directory (default: the ebook's folder)") var outputDir: String?
    @Option(help: "m4b | mp3 | wav") var format: String = "m4b"
    func run() throws {
        let cfg = Config.load()
        let store = Store(cfg: cfg)
        let path = (ebook as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw ValidationError("ebook not found: \(ebook)") }
        let out = outputDir ?? (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let job = store.enqueue(Spec(ebook: path, language: language, voice: voice,
                                     outputDir: out, outputFormat: format))
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
            default: throw ValidationError("unknown key \(k)")
            }
            cfg.save(); print("set \(k)=\(v)")
        case "voice" where args.count == 2:
            cfg.voices[args[0]] = args[1]; cfg.save(); print("voice \(args[0])=\(args[1])")
        default:
            print(Views.json([
                "home": cfg.home.path, "synthCmd": cfg.synthCmd ?? "(none — silent dry-run)",
                "voices": cfg.voices, "speed": cfg.speed, "concurrency": cfg.concurrency,
            ]))
        }
    }
}
