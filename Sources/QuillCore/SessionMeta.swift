import Foundation

/// The slice of meta.json the transcription pipeline needs: which files exist,
/// who they represent, and how far each track started after the earliest one.
public struct SessionMeta: Equatable {
    public struct Track: Equatable {
        public let file: String
        public let speaker: String
        public let offsetMs: Int

        public init(file: String, speaker: String, offsetMs: Int) {
            self.file = file
            self.speaker = speaker
            self.offsetMs = offsetMs
        }
    }

    public let tracks: [Track]

    public init(tracks: [Track]) {
        self.tracks = tracks
    }

    public enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        public var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    public static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { throw MetaError.unreadable(url) }
        return try parse(data, source: url)
    }

    /// Split out from `read` so the parsing rules can be tested against bytes
    /// rather than against a directory on disk.
    public static func parse(_ data: Data, source: URL) throws -> SessionMeta {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(source) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}
