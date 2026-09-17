import Foundation

/// The slice of meta.json the transcription pipeline needs: which files exist,
/// who they represent, and how far each track started after the earliest one.
public struct SessionMeta: Equatable {
    /// Whether the session reached a clean stop. Written at start as
    /// `.recording` and rewritten at stop, so a session interrupted by a
    /// crash, a forced quit or power loss is still identifiable as one that
    /// has audio worth transcribing.
    public enum Status: String, Sendable, Equatable {
        case recording
        case finished
    }

    public struct Track: Equatable {
        public let file: String
        public let speaker: String
        public let offsetMs: Int
        /// nominal ÷ measured sample rate for the device that captured this
        /// track. 1.0 when the session predates the measurement.
        public let rateScale: Double

        public init(file: String, speaker: String, offsetMs: Int, rateScale: Double = 1) {
            self.file = file
            self.speaker = speaker
            self.offsetMs = offsetMs
            self.rateScale = rateScale
        }

        public var alignment: TrackAlignment {
            TrackAlignment(offsetMs: offsetMs, rateScale: rateScale)
        }
    }

    public let tracks: [Track]
    public let status: Status

    public init(tracks: [Track], status: Status = .finished) {
        self.tracks = tracks
        self.status = status
    }

    /// The track files a session is expected to hold, in merge order.
    public static let knownTracks: [(file: String, speaker: String)] = [
        (file: "mic.caf", speaker: "me"),
        (file: "system.caf", speaker: "them"),
    ]

    /// What a session looks like when meta.json is missing or unparseable:
    /// derived from whichever known track files are actually present. Takes a
    /// predicate rather than touching disk so the rule stays testable.
    public static func recovered(fileExists: (String) -> Bool) -> SessionMeta {
        SessionMeta(
            tracks: knownTracks
                .filter { fileExists($0.file) }
                .map { Track(file: $0.file, speaker: $0.speaker, offsetMs: 0) },
            status: .recording
        )
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
        // Sessions written before `status` existed only ever got a meta.json
        // on a clean stop, so absence means finished.
        let status = (json["status"] as? String).flatMap(Status.init(rawValue:)) ?? .finished

        // Absent for sessions recorded before the clocks were measured, which
        // is exactly what a 1.0 scale means.
        let nominal = json["nominal_sample_rate"] as? [String: Double] ?? [:]
        let measured = json["measured_sample_rate"] as? [String: Double] ?? [:]
        func scale(_ key: String) -> Double {
            TrackAlignment.rateScale(nominal: nominal[key] ?? 0, measured: measured[key])
        }

        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(
                file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0, rateScale: scale("mic")
            ))
        }
        if let system = files["system"] {
            tracks.append(Track(
                file: system,
                speaker: "them",
                offsetMs: offsets["system"] ?? 0,
                rateScale: scale("system")
            ))
        }
        return SessionMeta(tracks: tracks, status: status)
    }
}
