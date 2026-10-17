import Foundation

// MARK: - Music library (persistent cache of analysis + stems)
//
// <root>/index.json
// <root>/<id>/info.json            (copy of the record)
// <root>/<id>/drums.wav ... vocals.wav
// The original mix is NOT stored: it is re-decoded from the source file on load.

public struct SongRecord: Codable, Identifiable, Sendable {
    public var id: String
    /// Filename of the source copy inside the song folder (e.g. "source.mp3").
    /// Everything the app needs lives under the song folder; the outside file
    /// is never referenced after import.
    public var audioFile: String
    /// Original filename at import time (display + duplicate detection).
    public var sourceName: String
    public var sourceSize: Int
    public var sourceMtime: Double
    /// Legacy: outside path from before the copy-on-import change. Display only.
    public var sourcePath: String
    public var title: String
    public var duration: Double
    public var bpm: Double?
    public var beats: [Double]
    public var createdAt: Double

    public init(id: String = UUID().uuidString, audioFile: String = "", sourceName: String = "",
                sourceSize: Int = 0, sourceMtime: Double = 0, sourcePath: String = "",
                title: String, duration: Double,
                bpm: Double?, beats: [Double], createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.audioFile = audioFile
        self.sourceName = sourceName
        self.sourceSize = sourceSize
        self.sourceMtime = sourceMtime
        self.sourcePath = sourcePath
        self.title = title
        self.duration = duration
        self.bpm = bpm
        self.beats = beats
        self.createdAt = createdAt
    }

    // Old index.json files lack the newer keys; decode tolerantly.
    enum CodingKeys: String, CodingKey {
        case id, audioFile, sourceName, sourceSize, sourceMtime, sourcePath
        case title, duration, bpm, beats, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        audioFile = try c.decodeIfPresent(String.self, forKey: .audioFile) ?? ""
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        sourceSize = try c.decodeIfPresent(Int.self, forKey: .sourceSize) ?? 0
        sourceMtime = try c.decodeIfPresent(Double.self, forKey: .sourceMtime) ?? 0
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath) ?? ""
        title = try c.decode(String.self, forKey: .title)
        duration = try c.decode(Double.self, forKey: .duration)
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm)
        beats = try c.decodeIfPresent([Double].self, forKey: .beats) ?? []
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
    }
    // encode() stays synthesized.
}

public final class LibraryStore {
    public static let rootDefaultsKey = "libraryRoot"

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/StemsCraft", isDirectory: true)
    }

    public static func savedRoot() -> URL {
        if let s = UserDefaults.standard.string(forKey: rootDefaultsKey) {
            return URL(fileURLWithPath: s, isDirectory: true)
        }
        return defaultRoot
    }

    public private(set) var root: URL
    public private(set) var records: [SongRecord] = []

    public init(root: URL = LibraryStore.savedRoot()) {
        self.root = root
        load()
    }

    public var indexURL: URL { root.appendingPathComponent("index.json", isDirectory: false) }
    public func songDir(id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    public func stemURL(id: String, stem: String) -> URL {
        songDir(id: id).appendingPathComponent("\(stem).wav", isDirectory: false)
    }

    /// Decoded copy of the original mix, written at import so the library never
    /// depends on the source file still being where it was.
    public func originalURL(id: String) -> URL {
        songDir(id: id).appendingPathComponent("original.wav", isDirectory: false)
    }

    private func load() {
        records = []
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([SongRecord].self, from: data) else { return }
        // Oldest first; new songs always land at the end and re-saves never jump.
        records = list.sorted { $0.createdAt < $1.createdAt }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// Fresh record for this exact file (path + size + mtime must match), if any.
    /// Legacy helper; new code identifies songs by their in-library copy.
    public func match(sourcePath: String) -> SongRecord? {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: sourcePath),
              let size = attr[.size] as? Int,
              let date = attr[.modificationDate] as? Date else { return nil }
        return records.first {
            $0.sourcePath == sourcePath && $0.sourceSize == size && $0.sourceMtime == date.timeIntervalSince1970
        }
    }

    /// Record holding a previous import of this same outside file
    /// (same name + size + mtime), if any. Used to skip re-importing drops.
    public func matchImport(name: String, size: Int, mtime: Double) -> SongRecord? {
        records.first { $0.sourceName == name && $0.sourceSize == size && $0.sourceMtime == mtime }
    }

    public static func fileIdentity(path: String) -> (size: Int, modDate: Double)? {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attr[.size] as? Int,
              let date = attr[.modificationDate] as? Date else { return nil }
        return (size, date.timeIntervalSince1970)
    }

    public func stemsPresent(_ r: SongRecord) -> Bool {
        ["drums", "bass", "other", "vocals"].allSatisfy {
            FileManager.default.fileExists(atPath: stemURL(id: r.id, stem: $0).path)
        }
    }

    /// Insert or replace by id; persists index + info.json.
    /// New songs append at the end; re-saves keep their position (never jump).
    public func upsert(_ record: SongRecord) {
        if let i = records.firstIndex(where: { $0.id == record.id }) {
            records[i] = record
        } else {
            records.append(record)
        }
        let dir = songDir(id: record.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: dir.appendingPathComponent("info.json"), options: .atomic)
        }
        persist()
    }

    public func remove(id: String) {
        records.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: songDir(id: id))
        persist()
    }

    public func moveRoot(to url: URL) {
        root = url
        UserDefaults.standard.set(url.path, forKey: Self.rootDefaultsKey)
        load()
    }
}
