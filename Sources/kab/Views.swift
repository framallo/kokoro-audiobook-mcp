import Foundation

/// Serializable views over the queue, merging a job's stored state with the live
/// progress.json of a running conversion. Returned as JSON (MCP tool text / CLI).
enum Views {
    static func readProgress(_ cfg: Config, _ session: String) -> Progress? {
        guard let d = try? Data(contentsOf: cfg.progressPath(session: session)) else { return nil }
        return try? JSONDecoder().decode(Progress.self, from: d)
    }

    static func jobView(_ cfg: Config, _ job: Job) -> [String: Any] {
        var d: [String: Any] = [
            "id": job.id, "status": job.status.rawValue,
            "ebook": job.spec.ebook, "language": job.spec.language,
            "voice": job.spec.voice ?? cfg.voiceFor(job.spec.language) ?? "",
            "output_dir": job.spec.outputDir, "session_id": job.sessionId,
            "created_at": job.createdAt,
        ]
        if let v = job.startedAt { d["started_at"] = v }
        if let v = job.finishedAt { d["finished_at"] = v }
        if let v = job.error { d["error"] = v }
        if job.status == .running {
            if let p = readProgress(cfg, job.sessionId) {
                d["percent"] = round(p.percent * 10) / 10
                d["rendered"] = p.rendered; d["reused"] = p.reused; d["total"] = p.total
                if let e = p.etaSeconds { d["eta_seconds"] = round(e); d["eta_human"] = human(e) }
                if let a = p.avgRenderSeconds { d["avg_render_seconds"] = round(a * 100) / 100 }
                d["current"] = ["chapter": p.chapter, "index": p.index, "text": p.text]
            } else {
                d["percent"] = 0.0; d["note"] = "starting (parsing / model load)…"
            }
        }
        if job.status == .done, let s = job.startedAt, let f = job.finishedAt {
            d["duration_seconds"] = round(f - s); d["duration_human"] = human(f - s)
        }
        return d
    }

    static func queueView(_ cfg: Config, _ store: Store) -> [String: Any] {
        let jobs = store.list()
        var counts: [String: Int] = [:]
        for j in jobs { counts[j.status.rawValue, default: 0] += 1 }
        let running = jobs.filter { $0.status == .running }.map { jobView(cfg, $0) }
        let queued = jobs.filter { $0.status == .queued }
            .sorted { ($0.priority, $0.createdAt) < ($1.priority, $1.createdAt) }
        let done = jobs.filter { $0.status == .done && $0.startedAt != nil && $0.finishedAt != nil }
            .map { $0.finishedAt! - $0.startedAt! }.sorted()
        let perJob = done.isEmpty ? nil : done[done.count / 2]
        let runningEtas = running.compactMap { $0["eta_seconds"] as? Double }
        var overall: Double? = nil
        if !runningEtas.isEmpty || (perJob != nil && !queued.isEmpty) {
            let waves = Int(ceil(Double(queued.count) / Double(max(1, cfg.concurrency))))
            overall = (runningEtas.max() ?? 0) + (perJob ?? 0) * Double(waves)
        }
        var out: [String: Any] = [
            "concurrency": cfg.concurrency,
            "counts": counts,
            "running": running,
            "queued": queued.enumerated().map { i, j in
                ["id": j.id, "ebook": (j.spec.ebook as NSString).lastPathComponent,
                 "language": j.spec.language, "position": i + 1]
            },
        ]
        if let p = perJob { out["per_job_estimate_seconds"] = round(p) }
        if let o = overall { out["overall_eta_seconds"] = round(o); out["overall_eta_human"] = human(o) }
        return out
    }

    static func human(_ seconds: Double) -> String {
        let s = Int(max(0, seconds)); let h = s / 3600; let m = (s % 3600) / 60; let sec = s % 60
        if h > 0 { return "\(h)h \(m)m \(sec)s" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}
