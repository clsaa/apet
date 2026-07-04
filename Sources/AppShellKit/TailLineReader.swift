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

    /// 读文件开头至多 maxLines 行 / maxBytes(拿开场用户指令用)。
    public static func firstLines(path: String, maxLines: Int, maxBytes: Int = 262_144) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        fh.seek(toFileOffset: 0)
        let data = fh.readData(ofLength: maxBytes)
        let text = String(decoding: data, as: UTF8.self)
        return Array(text.components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(maxLines))
    }

    public static func firstLine(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }

        fh.seek(toFileOffset: 0)
        // Read up to 64KB to find the first line（计划指定 65536；jsonl 首行远小于此）
        let data = fh.readData(ofLength: 65_536)
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "\n").first
    }
}
