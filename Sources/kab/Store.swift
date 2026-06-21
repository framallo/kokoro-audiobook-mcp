import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum JobStatus: String, Codable, Sendable {
    case queued, running, done, failed, cancelled
    static let terminal: Set<JobStatus> = [.done, .failed, .cancelled]
}

struct Spec: Codable, Sendable {
    var ebook: String
    var language: String
    var voice: String?
    var outputDir: String
    var outputFormat: String
}

struct Job: Codable, Sendable {
    var id: String
    var createdAt: Double
    var status: JobStatus
    var spec: Spec
    var sessionId: String
    var startedAt: Double?
    var finishedAt: Double?
    var returncode: Int32?
    var error: String?
    var pid: Int32?
    var cancelRequested: Bool
    var attempts: Int
    var priority: Double
}

/// File-based job store with an flock-guarded queue: one JSON file per job under
/// <home>/jobs/. All mutations take an exclusive flock on <home>/store.lock, so
/// claimNext() atomically moves a job queued -> running.
struct Store {
    let cfg: Config

    private func path(_ id: String) -> URL { cfg.jobsDir.appendingPathComponent("\(id).json") }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(cfg.storeLock.path, O_CREAT | O_RDWR, 0o644)
        defer { if fd >= 0 { close(fd) } }
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN) } }
        return try body()
    }

    private func write(_ job: Job) {
        guard let data = try? JSONEncoder().encode(job) else { return }
        let tmp = path(job.id).appendingPathExtension("tmp")
        try? data.write(to: tmp)
        try? FileManager.default.replaceItemAt(path(job.id), withItemAt: tmp)
        // replaceItemAt fails if the destination doesn't exist yet; fall back.
        if !FileManager.default.fileExists(atPath: path(job.id).path) {
            try? data.write(to: path(job.id))
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    func get(_ id: String) -> Job? {
        guard let data = try? Data(contentsOf: path(id)) else { return nil }
        return try? JSONDecoder().decode(Job.self, from: data)
    }

    func list() -> [Job] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: cfg.jobsDir, includingPropertiesForKeys: nil)) ?? []
        var jobs: [Job] = []
        for u in urls where u.lastPathComponent.hasPrefix("job_") && u.pathExtension == "json" {
            if let d = try? Data(contentsOf: u), let j = try? JSONDecoder().decode(Job.self, from: d) {
                jobs.append(j)
            }
        }
        return jobs.sorted { ($0.priority, $0.createdAt) < ($1.priority, $1.createdAt) }
    }

    @discardableResult
    func enqueue(_ spec: Spec) -> Job {
        let job = Job(
            id: "job_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)),
            createdAt: Date().timeIntervalSince1970, status: .queued, spec: spec,
            sessionId: UUID().uuidString, startedAt: nil, finishedAt: nil,
            returncode: nil, error: nil, pid: nil, cancelRequested: false,
            attempts: 0, priority: 0
        )
        withLock { write(job) }
        return job
    }

    @discardableResult
    func update(_ id: String, _ mutate: (inout Job) -> Void) -> Job? {
        withLock {
            guard var job = get(id) else { return nil }
            mutate(&job)
            write(job)
            return job
        }
    }

    @discardableResult
    func move(_ id: String, position: Int) -> Job? {
        withLock {
            var queued = list().filter { $0.status == .queued }
            guard let idx = queued.firstIndex(where: { $0.id == id }) else { return nil }
            let target = queued.remove(at: idx)
            let dest = max(0, min(queued.count, position - 1))
            queued.insert(target, at: dest)
            for (i, var j) in queued.enumerated() where j.priority != Double(i) {
                j.priority = Double(i); write(j)
            }
            return get(id)
        }
    }

    func claimNext() -> Job? {
        withLock {
            for var job in list() where job.status == .queued {
                if job.cancelRequested {
                    job.status = .cancelled; job.finishedAt = Date().timeIntervalSince1970
                    write(job); continue
                }
                job.status = .running; job.startedAt = Date().timeIntervalSince1970
                write(job); return job
            }
            return nil
        }
    }
}
