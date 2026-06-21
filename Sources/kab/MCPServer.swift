import Foundation
import MCP

/// MCP server (stdio) exposing the queue to Claude. Mirrors the ebook2audiobook
/// MCP tool surface: enqueue is non-blocking (returns a job id immediately); the
/// conversion runs in the background worker; clients poll queue_status / get_job.
enum MCPServer {
    static func serve() async throws {
        let cfg = Config.load()
        let store = Store(cfg: cfg)
        let server = Server(
            name: "kokoro-audiobook",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            let a = params.arguments ?? [:]
            func str(_ k: String) -> String? { a[k]?.stringValue }
            func num(_ k: String) -> Int? { a[k]?.intValue }

            switch params.name {
            case "enqueue_audiobook":
                guard let ebook = str("ebook") else { return errResult("ebook required") }
                let path = (ebook as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: path) else { return errResult("ebook not found: \(ebook)") }
                let out = str("output_dir") ?? (path as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
                let job = store.enqueue(Spec(
                    ebook: path, language: str("language") ?? "eng", voice: str("voice"),
                    outputDir: out, outputFormat: str("output_format") ?? "m4b"))
                let spawned = Worker.ensure(cfg)
                return ok(["job_id": job.id, "status": job.status.rawValue, "worker_spawned": spawned])
            case "queue_status":
                return ok(Views.queueView(cfg, store))
            case "get_job":
                guard let id = str("job_id"), let j = store.get(id) else { return errResult("job not found") }
                return ok(Views.jobView(cfg, j))
            case "list_jobs":
                return ok(["jobs": store.list().map { Views.jobView(cfg, $0) }])
            case "move_job":
                guard let id = str("job_id"), let pos = num("position"),
                      store.move(id, position: pos) != nil else { return errResult("not found or not queued") }
                return ok(["job_id": id, "position": pos])
            case "cancel_job":
                guard let id = str("job_id"), let j = store.get(id) else { return errResult("job not found") }
                if JobStatus.terminal.contains(j.status) {
                    return ok(["job_id": id, "status": j.status.rawValue, "note": "already finished"])
                }
                store.update(id) { $0.cancelRequested = true }
                return ok(["job_id": id, "status": "cancel_requested"])
            case "list_voices":
                return ok(["voices": KokoroVoices.all(language: str("language"))])
            default:
                return errResult("unknown tool: \(params.name)")
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        // Keep the process alive while the stdio transport serves requests.
        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }

    private static func ok(_ obj: Any) -> CallTool.Result {
        CallTool.Result(content: [.text(Views.json(obj))], isError: false)
    }
    private static func errResult(_ msg: String) -> CallTool.Result {
        CallTool.Result(content: [.text(Views.json(["error": msg]))], isError: true)
    }

    private static func schema(_ props: [String: String], required: [String]) -> Value {
        var properties: [String: Value] = [:]
        for (k, desc) in props {
            properties[k] = .object(["type": .string("string"), "description": .string(desc)])
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    private static var tools: [Tool] {
        [
            Tool(name: "enqueue_audiobook",
                 description: "Queue an EPUB → audiobook conversion (Kokoro). Returns a job id immediately; poll queue_status/get_job for live percent and ETA. Unchanged sentences are served from cache.",
                 inputSchema: schema([
                    "ebook": "Absolute path to the .epub",
                    "language": "ISO-639-3 code (eng, spa, por, fra, ita). Default eng.",
                    "voice": "Kokoro voice name (e.g. am_adam, em_alex) or WAV path. Optional.",
                    "output_dir": "Where to write the audiobook. Default: the ebook's folder.",
                    "output_format": "m4b (default), mp3, or wav.",
                 ], required: ["ebook"])),
            Tool(name: "queue_status",
                 description: "Whole-queue view: status counts, running job %/ETA, queued positions, overall ETA.",
                 inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
            Tool(name: "get_job", description: "Detailed status of one job (live %/ETA while running).",
                 inputSchema: schema(["job_id": "The job id"], required: ["job_id"])),
            Tool(name: "list_jobs", description: "List every job and its status.",
                 inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
            Tool(name: "move_job", description: "Move a queued job to a 1-based position (1 = next).",
                 inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "job_id": .object(["type": .string("string")]),
                        "position": .object(["type": .string("integer")]),
                    ]),
                    "required": .array([.string("job_id"), .string("position")]),
                 ])),
            Tool(name: "cancel_job", description: "Cancel a queued or running job.",
                 inputSchema: schema(["job_id": "The job id"], required: ["job_id"])),
            Tool(name: "list_voices", description: "List Kokoro voices, optionally filtered by ISO-639-3 language.",
                 inputSchema: schema(["language": "Optional ISO-639-3 filter (eng, spa, …)"], required: [])),
        ]
    }
}

/// Kokoro's fixed voicepacks. First letter encodes language (a/b English, e
/// Spanish, f French, i Italian, p Portuguese), second letter gender (f/m).
enum KokoroVoices {
    static let catalog: [String] = [
        "af_heart", "af_bella", "af_nicole", "af_sarah", "am_adam", "am_michael", "am_onyx",
        "bf_emma", "bf_isabella", "bm_george", "bm_lewis",
        "ef_dora", "em_alex", "em_santa",
        "ff_siwis", "if_sara", "im_nicola", "pf_dora", "pm_alex",
    ]
    static func all(language: String?) -> [String] {
        let prefixes: [String]? = {
            switch language {
            case "eng": return ["a", "b"]
            case "spa": return ["e"]
            case "fra": return ["f"]
            case "ita": return ["i"]
            case "por": return ["p"]
            default: return nil
            }
        }()
        guard let prefixes else { return catalog }
        return catalog.filter { v in prefixes.contains(where: { v.hasPrefix($0) }) }
    }
}
