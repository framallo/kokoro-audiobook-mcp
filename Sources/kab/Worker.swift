import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Background worker: an flock singleton that drains the queue. Runs up to
/// cfg.concurrency `kab convert` subprocesses at once; retries non-zero exits;
/// honors cancellation; requeues orphans from a dead worker; exits when idle.
enum Worker {
    private struct Running { var proc: Process; var log: FileHandle }

    static func isRunning(_ cfg: Config) -> Bool {
        let fd = open(cfg.workerLock.path, O_CREAT | O_RDWR, 0o644)
        if fd < 0 { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }

    /// Spawn a detached worker if none holds the lock. Returns true if spawned.
    @discardableResult
    static func ensure(_ cfg: Config) -> Bool {
        if isRunning(cfg) { return false }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let log = cfg.workerLog.path
        let cmd = "nohup '\(exe)' worker >> '\(log)' 2>&1 &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try? p.run()
        p.waitUntilExit()  // sh returns immediately after backgrounding
        return true
    }

    static func run(_ cfg: Config) {
        let lockFd = open(cfg.workerLock.path, O_CREAT | O_RDWR, 0o644)
        if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
            FileHandle.standardError.write(Data("worker already running; exiting\n".utf8)); return
        }
        defer { flock(lockFd, LOCK_UN); close(lockFd) }
        let store = Store(cfg: cfg)
        reconcileOrphans(store)
        log("worker \(getpid()) started (concurrency=\(cfg.concurrency))")

        var running: [String: Running] = [:]
        var idleSince: Date? = nil
        while true {
            reap(cfg, store, &running)
            while running.count < cfg.concurrency, let job = store.claimNext() {
                if let r = launch(cfg, store, job) { running[job.id] = r }
            }
            if running.isEmpty {
                if idleSince == nil { idleSince = Date() }
                if Date().timeIntervalSince(idleSince!) > Double(cfg.idleExitSeconds) {
                    log("idle; worker exiting"); break
                }
            } else { idleSince = nil }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private static func launch(_ cfg: Config, _ store: Store, _ job: Job) -> Running? {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let logURL = cfg.logsDir.appendingPathComponent("\(job.id).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["convert", "--job", job.id]
        p.standardOutput = log
        p.standardError = log
        do { try p.run() } catch {
            store.update(job.id) { $0.status = .failed; $0.error = "launch: \(error)"
                $0.finishedAt = Date().timeIntervalSince1970 }
            return nil
        }
        store.update(job.id) { $0.pid = p.processIdentifier; $0.attempts += 1 }
        log.seekToEndOfFile()
        return Running(proc: p, log: log)
    }

    private static func reap(_ cfg: Config, _ store: Store, _ running: inout [String: Running]) {
        for (id, r) in running {
            if r.proc.isRunning {
                if let cur = store.get(id), cur.cancelRequested {
                    r.proc.terminate()
                    try? r.log.close()
                    store.update(id) { $0.status = .cancelled; $0.error = "cancelled"
                        $0.finishedAt = Date().timeIntervalSince1970 }
                    running[id] = nil
                }
                continue
            }
            try? r.log.close()
            let rc = r.proc.terminationStatus
            let cur = store.get(id)
            if rc == 0 {
                store.update(id) { $0.status = .done; $0.returncode = 0
                    $0.finishedAt = Date().timeIntervalSince1970 }
                log("done \(id)")
            } else if cur?.cancelRequested == true {
                store.update(id) { $0.status = .cancelled
                    $0.finishedAt = Date().timeIntervalSince1970 }
            } else if (cur?.attempts ?? 99) <= cfg.maxRetries {
                store.update(id) { $0.status = .queued; $0.returncode = rc; $0.pid = nil
                    $0.startedAt = nil }
                log("retry \(id) (rc=\(rc))")
            } else {
                store.update(id) { $0.status = .failed; $0.returncode = rc
                    $0.finishedAt = Date().timeIntervalSince1970 }
                log("failed \(id) (rc=\(rc))")
            }
            running[id] = nil
        }
    }

    private static func reconcileOrphans(_ store: Store) {
        for job in store.list() where job.status == .running {
            if let pid = job.pid, kill(pid, 0) == 0 { kill(pid, SIGTERM) }
            store.update(job.id) { $0.status = .queued; $0.pid = nil; $0.startedAt = nil }
        }
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(Data("[worker] \(s)\n".utf8))
    }
}
