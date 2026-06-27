import Foundation

// MARK: - Checkpoint

/// Identifies a position in a specific incarnation of an append-only file.
/// `fileId` encodes inode+device so rotation (new inode) is detected.
/// `offset` is the byte position of the next unread byte.
public struct Checkpoint: Codable, Equatable {
    public var fileId: String
    public var offset: UInt64

    public init(fileId: String, offset: UInt64) {
        self.fileId = fileId
        self.offset = offset
    }
}

// MARK: - EventTailReader

/// Stateless incremental tail-reader for an append-only NDJSON file.
///
/// - Detects rotation/truncation via inode mismatch or offset > file size.
/// - Partial lines (no trailing `\n`) are NOT returned; offset stays at last `\n`.
/// - `\r` before `\n` is stripped.
/// - Missing file returns ([], zeroCheckpoint) without throwing.
public struct EventTailReader {

    public init() {}

    /// Read all complete new lines since `checkpoint`.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the NDJSON file.
    ///   - checkpoint: Previous read position, or `nil` to start from the beginning.
    /// - Returns: Complete lines (stripped of `\r`) and the next checkpoint to pass on the next call.
    public func readNewLines(path: String, from checkpoint: Checkpoint?) throws -> (lines: [String], next: Checkpoint) {
        // ── 1. Stat the file ─────────────────────────────────────────────────
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            // File missing: return empty, preserve checkpoint offset at 0
            let zero = Checkpoint(fileId: "", offset: 0)
            return ([], checkpoint ?? zero)
        }

        let currentSize = (attrs[.size] as? UInt64) ?? 0
        let inode = (attrs[.systemFileNumber] as? UInt) ?? 0
        let device = (attrs[.systemNumber] as? UInt) ?? 0
        let currentFileId = "\(device):\(inode)"

        // ── 2. Decide read offset ─────────────────────────────────────────────
        var readOffset: UInt64 = 0
        if let cp = checkpoint,
           !cp.fileId.isEmpty,
           cp.fileId == currentFileId,
           cp.offset <= currentSize {
            readOffset = cp.offset
        }
        // else: rotation, truncation, first read, or missing-file checkpoint → read from 0

        // ── 3. Read bytes from offset to EOF ──────────────────────────────────
        guard currentSize > readOffset else {
            // Nothing new to read
            return ([], Checkpoint(fileId: currentFileId, offset: readOffset))
        }

        let fh: FileHandle
        do {
            fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            return ([], Checkpoint(fileId: currentFileId, offset: readOffset))
        }
        defer { try? fh.close() }

        if readOffset > 0 {
            fh.seek(toFileOffset: readOffset)
        }

        let data = fh.readDataToEndOfFile()

        // ── 4. Split into complete lines ──────────────────────────────────────
        // Only advance offset to the last `\n`; trailing partial content is left pending.
        guard !data.isEmpty else {
            return ([], Checkpoint(fileId: currentFileId, offset: readOffset))
        }

        // Find the position of the last newline byte in the data chunk
        var lastNewlineIndex: Int? = nil
        for i in stride(from: data.count - 1, through: 0, by: -1) {
            if data[i] == UInt8(ascii: "\n") {
                lastNewlineIndex = i
                break
            }
        }

        guard let lastNL = lastNewlineIndex else {
            // No complete line yet — don't advance offset
            return ([], Checkpoint(fileId: currentFileId, offset: readOffset))
        }

        // Bytes up to and including the last `\n`
        let consumedData = data[data.startIndex ..< data.index(data.startIndex, offsetBy: lastNL + 1)]
        let advancedOffset = readOffset + UInt64(lastNL + 1)

        // Decode and split on `\n`
        guard let text = String(bytes: consumedData, encoding: .utf8) else {
            return ([], Checkpoint(fileId: currentFileId, offset: readOffset))
        }

        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if !trimmed.isEmpty {
                lines.append(trimmed)
            }
        }

        return (lines, Checkpoint(fileId: currentFileId, offset: advancedOffset))
    }
}
