import Foundation

public enum TailReadResult: Equatable {
    case ok(lines: [String])
    case unreadable(path: String)
}

public enum TailLineReader {
    public static func lastLines(path: String, maxLines: Int, maxBytes: Int) -> TailReadResult {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            return .unreadable(path: path)
        }
        defer { try? fh.close() }

        let fileSize = Int(fh.seekToEndOfFile())
        let readSize = min(maxBytes, fileSize)
        let start = fileSize - readSize

        fh.seek(toFileOffset: UInt64(start))
        let data = fh.readData(ofLength: readSize)

        var text = String(decoding: data, as: UTF8.self)

        // If we didn't start at beginning, drop the first (potentially partial) line
        if start > 0 {
            if let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            } else {
                text = ""
            }
        }

        // Split into lines, dropping trailing empty string from trailing newline
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        // Take last maxLines
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }

        return .ok(lines: lines)
    }

    public static func firstLine(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }

        fh.seek(toFileOffset: 0)
        // Read up to 4KB to find the first line
        let data = fh.readData(ofLength: 4096)
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "\n").first
    }
}
