import Foundation
import CryptoKit

enum RecordError: Error { case full, closed, encoding, missedWindow }

// A diagnostic writes local evidence only. A stopped test keeps its partial files.
final class ProofRecord {
    let directory: URL
    private let handle: FileHandle
    private let limit: Int
    private var bytes = 0
    private var photoBytes = 0
    private var closed = false
    private(set) var snapshots = 0

    init(parent: URL, metadata: [String: Any], limit: Int = 16_000_000) throws {
        self.limit = limit
        directory = parent.appendingPathComponent("camera-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var localDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try localDirectory.setResourceValues(values)
        let file = directory.appendingPathComponent("events.jsonl")
        try Data().write(to: file, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: file)
        try append(["type": "header", "schema": 1, "metadata": metadata])
    }

    func append(_ record: [String: Any]) throws {
        guard !closed else { throw RecordError.closed }
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10)
        guard bytes + data.count < limit - 2_048 else { throw RecordError.full }
        try handle.write(contentsOf: data)
        bytes += data.count
        if record["type"] as? String == "snapshot" { snapshots += 1 }
    }

    func photo(_ data: Data, index: Int) throws -> [String: Any] {
        guard !closed else { throw RecordError.closed }
        guard index >= 0, data.count < 16_000_000, photoBytes + data.count < 64_000_000 else { throw RecordError.full }
        let name = "photo-\(index).jpg"
        try data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
        photoBytes += data.count
        return ["file": name, "bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }

    func finish(complete: Bool, reason: String) throws {
        guard !closed else { return }
        // The footer has reserved space even when a normal record reaches its bound.
        var footer = try JSONSerialization.data(withJSONObject: ["type": "footer", "complete": complete,
            "reason": String(reason.prefix(256)), "snapshots": snapshots, "photoBytes": photoBytes], options: [.sortedKeys])
        footer.append(10)
        guard footer.count < 2_048, bytes + footer.count < limit else { throw RecordError.full }
        try handle.write(contentsOf: footer)
        try handle.synchronize()
        try handle.close()
        closed = true
    }

    deinit { try? handle.close() }
}

#if RECORD_SELF_TEST
@main struct RecordChecks {
    static func main() throws {
        let parent = FileManager.default.temporaryDirectory
        let record = try ProofRecord(parent: parent, metadata: ["generated": true], limit: 4_096)
        try record.append(["type": "snapshot", "text": "£2.50 日本語"])
        do { try record.append(["type": "snapshot", "text": String(repeating: "x", count: 4_096)]); fatalError("Oversize accepted") }
        catch RecordError.full { }
        _ = try record.photo(Data([0xff, 0xd8, 0xff, 0xd9]), index: 0)
        do { _ = try record.photo(Data([1]), index: 0); fatalError("Overwrote a saved file") } catch { }
        try record.finish(complete: false, reason: "Generated boundary check; no camera image")
        let lines = try String(contentsOf: record.directory.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n")
        precondition(lines.count == 3)
        let footer = try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as! [String: Any]
        precondition(footer["complete"] as? Bool == false && footer["snapshots"] as? Int == 1)
        do { try record.append(["type": "snapshot"]); fatalError("Wrote after footer") } catch RecordError.closed { }
        print("Local record bounds, Unicode, retained partial output and no-overwrite checks PASS; no camera test")
    }
}
#endif
