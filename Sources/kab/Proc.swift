import Foundation

/// Thin subprocess helper.
enum Proc {
    @discardableResult
    static func run(_ launch: String, _ args: [String], cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw KabError.proc("\(launch) exited \(p.terminationStatus): \(out.suffix(600))")
        }
        return out
    }

    static func which(_ name: String) -> String {
        for base in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            if FileManager.default.isExecutableFile(atPath: base + name) { return base + name }
        }
        return name
    }
}
