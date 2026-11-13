import Foundation

package enum SavedSnapshot {
    package static let version = 1

    private struct Saved: Codable {
        var version: Int
        var snapshot: Snapshot
    }

    private struct Header: Decodable {
        var version: Int
    }

    package static func read(from file: URL) -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: file)
            guard try decoder.decode(Header.self, from: data).version == version else { return .empty }
            return try decoder.decode(Saved.self, from: data).snapshot
        } catch {
            return .empty  // the file only spares a wait at launch: the next refresh fills the picture again
        }
    }

    package static func write(_ snapshot: Snapshot, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Saved(version: version, snapshot: snapshot)).write(to: file, options: .atomic)
    }
}
