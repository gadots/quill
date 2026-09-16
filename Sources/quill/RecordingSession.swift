import Foundation
import QuillCore

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession {
    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
        } catch {
            system.stop()
            throw error
        }
        // Mark the session as live before any audio is captured. Until this
        // existed, meta.json was written only on a clean stop, so a session cut
        // short by a crash or power loss left audio on disk that resumePending
        // would never look at again.
        writeMeta(["status": SessionMeta.Status.recording.rawValue])
    }

    /// Stop both tracks and write meta.json.
    func stop() {
        mic.stop()
        system.stop()

        let ended = Date()

        var meta: [String: Any] = [
            "status": SessionMeta.Status.finished.rawValue,
            "ended": ISO8601DateFormatter().string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "start_offset_ms": startOffsetsMs(),
        ]
        // What the devices actually ran at. The mic engine and the tap's
        // aggregate keep separate clocks, and the difference accumulates
        // across a long meeting; the transcript merge scales by nominal ÷
        // measured to put both back on real time.
        var nominal: [String: Double] = [:]
        var measured: [String: Double] = [:]
        if mic.nominalSampleRate > 0 { nominal["mic"] = mic.nominalSampleRate }
        if system.nominalSampleRate > 0 { nominal["system"] = system.nominalSampleRate }
        if let rate = mic.measuredSampleRate { measured["mic"] = rate }
        if let rate = system.measuredSampleRate { measured["system"] = rate }
        if !nominal.isEmpty { meta["nominal_sample_rate"] = nominal }
        if !measured.isEmpty { meta["measured_sample_rate"] = measured }

        writeMeta(meta)
    }

    /// How far each track's first buffer lagged the earlier of the two, on the
    /// host clock both are stamped from. A track that never produced a buffer
    /// gets 0 — there is nothing to align.
    private func startOffsetsMs() -> [String: Int] {
        let stamps = [("mic", mic.firstHostTime), ("system", system.firstHostTime)]
        let present = stamps.compactMap(\.1)
        guard let earliest = present.min() else { return ["mic": 0, "system": 0] }

        var offsets: [String: Int] = [:]
        for (name, stamp) in stamps {
            guard let stamp else {
                offsets[name] = 0
                continue
            }
            offsets[name] = Int(
                (HostClock.seconds(from: earliest, to: stamp) * 1000).rounded()
            )
        }
        return offsets
    }

    // MARK: -

    /// Write meta.json with the fields every session always has, plus whatever
    /// the caller adds. Atomic, so a reader never sees a half-written file.
    private func writeMeta(_ extra: [String: Any]) {
        var meta: [String: Any] = [
            "started": ISO8601DateFormatter().string(from: startedAt),
            "files": ["mic": "mic.caf", "system": "system.caf"],
        ]
        meta.merge(extra) { _, new in new }

        guard let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }
}
