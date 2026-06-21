import Foundation

/// Concatenate per-sentence WAVs into chapter audio, then into a single m4b with
/// embedded chapter markers (ffmpeg). mp3/wav fall out of the same path.
enum Assemble {
    /// Concat a list of WAVs into one file (stream copy) via the ffmpeg concat demuxer.
    static func concat(_ parts: [URL], to out: URL, work: URL) throws {
        let ff = Proc.which("ffmpeg")
        let list = work.appendingPathComponent("concat-" + UUID().uuidString + ".txt")
        let body = parts.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        try body.write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }
        try Proc.run(ff, ["-y", "-f", "concat", "-safe", "0", "-i", list.path, "-c", "copy", out.path])
    }

    static func duration(_ url: URL) -> Double {
        let ffprobe = Proc.which("ffprobe")
        guard let s = try? Proc.run(ffprobe, [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=nw=1:nk=1", url.path,
        ]) else { return 0 }
        return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Build the final audiobook with chapter markers. `chapters` is (title, wav).
    static func finalize(chapters: [(title: String, url: URL)], to out: URL,
                         format: String, work: URL) throws {
        let ff = Proc.which("ffmpeg")
        // Concat all chapter wavs.
        let joined = work.appendingPathComponent("joined-" + UUID().uuidString + ".wav")
        try concat(chapters.map { $0.url }, to: joined, work: work)
        defer { try? FileManager.default.removeItem(at: joined) }

        // ffmetadata with one [CHAPTER] per chapter (ms timebase).
        var meta = ";FFMETADATA1\n"
        var startMs = 0
        for ch in chapters {
            let durMs = Int(duration(ch.url) * 1000)
            let endMs = startMs + max(1, durMs)
            let title = ch.title.replacingOccurrences(of: "=", with: "\\=")
                .replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: "#", with: "\\#")
                .replacingOccurrences(of: "\n", with: " ")
            meta += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(startMs)\nEND=\(endMs)\ntitle=\(title)\n"
            startMs = endMs
        }
        let metaURL = work.appendingPathComponent("meta-" + UUID().uuidString + ".txt")
        try meta.write(to: metaURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: metaURL) }

        try? FileManager.default.removeItem(at: out)
        var args = ["-y", "-i", joined.path, "-i", metaURL.path, "-map_metadata", "1", "-map", "0:a"]
        switch format {
        case "mp3": args += ["-c:a", "libmp3lame", "-b:a", "96k"]
        case "wav": args += ["-c:a", "copy"]
        default:    args += ["-c:a", "aac", "-b:a", "80k"]   // m4b
        }
        args.append(out.path)
        try Proc.run(ff, args)
    }
}
