import Foundation

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
public struct Transcript: Codable, Equatable {
    public struct Segment: Codable, Equatable {
        public let speaker: String
        public let start_ms: Int
        public let end_ms: Int
        public let text: String

        public init(speaker: String, start_ms: Int, end_ms: Int, text: String) {
            self.speaker = speaker
            self.start_ms = start_ms
            self.end_ms = end_ms
            self.text = text
        }
    }

    public let engine: String
    public let model: String
    public let created_at: String
    public let segments: [Segment]

    public init(engine: String, model: String, created_at: String, segments: [Segment]) {
        self.engine = engine
        self.model = model
        self.created_at = created_at
        self.segments = segments
    }

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    public func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    public func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Milliseconds as m:ss, or h:mm:ss once the hour mark is passed.
    public static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
