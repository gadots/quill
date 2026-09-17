import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
public enum Config {
    public static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    public static func recordingsDir() -> URL? {
        guard let dir = store.current().recordings_dir, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    public static func onStop() -> String? {
        guard let cmd = store.current().on_stop, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    public static func transcriptionEnabled() -> Bool {
        store.current().transcription?.enabled ?? true
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    public static func transcriptionEngine() -> String {
        store.current().transcription?.engine ?? "parakeet"
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    public static func micVoiceProcessing() -> Bool {
        store.current().mic_voice_processing ?? false
    }

    /// Resolve the recordings root from an optional CLI override.
    public static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }

    static let store = ConfigStore(path: path)
}

/// The config file as written, with every key optional so absence means
/// "default" rather than "invalid". Property names are the JSON schema.
struct QuillConfig: Codable, Sendable, Equatable {
    struct Transcription: Codable, Sendable, Equatable {
        var enabled: Bool?
        var engine: String?

        static let knownKeys: Set<String> = ["enabled", "engine"]
    }

    var recordings_dir: String?
    var transcription: Transcription?
    var mic_voice_processing: Bool?
    var on_stop: String?

    static let knownKeys: Set<String> = [
        "recordings_dir", "transcription", "mic_voice_processing", "on_stop",
    ]

    static let empty = QuillConfig()
}

/// Parses the config file once and re-parses only when it changes on disk.
///
/// Every accessor used to re-read and re-parse the file, which meant a disk
/// read per recording start, per enqueue and per doctor check. Caching on
/// modification date keeps that down to one `stat` while preserving the
/// previous behaviour of picking up an edit without a restart.
final class ConfigStore: @unchecked Sendable {
    private let path: URL
    // Guards the two cached fields below, which are read and written from
    // whichever thread happens to ask for config.
    private let lock = NSLock()
    private var cached: QuillConfig?
    private var cachedStamp: Date?

    init(path: URL) {
        self.path = path
    }

    func current() -> QuillConfig {
        lock.lock()
        defer { lock.unlock() }

        let stamp = modificationDate()
        if let cached, cachedStamp == stamp {
            return cached
        }
        let parsed = Self.parse(contentsOf: path)
        cached = parsed
        cachedStamp = stamp
        return parsed
    }

    private func modificationDate() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
        return attrs?[.modificationDate] as? Date
    }

    private static func parse(contentsOf path: URL) -> QuillConfig {
        guard FileManager.default.fileExists(atPath: path.path) else { return .empty }
        guard let data = try? Data(contentsOf: path) else { return .empty }
        return parse(data, describedBy: path.path)
    }

    /// A malformed config is reported on stderr rather than silently ignored —
    /// recordings landing in an unexpected place is worse than a warning. So is
    /// a misspelled key, which used to be indistinguishable from a key that was
    /// never set.
    static func parse(_ data: Data, describedBy source: String) -> QuillConfig {
        guard let config = try? JSONDecoder().decode(QuillConfig.self, from: data) else {
            warn("\(source) is not valid quill config JSON — ignoring config")
            return .empty
        }
        reportUnknownKeys(in: data, source: source)
        return config
    }

    private static func reportUnknownKeys(in data: Data, source: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        for key in json.keys.sorted() where !QuillConfig.knownKeys.contains(key) {
            warn("\(source): unknown key \"\(key)\" — ignored")
        }
        guard let nested = json["transcription"] as? [String: Any] else { return }
        for key in nested.keys.sorted()
        where !QuillConfig.Transcription.knownKeys.contains(key) {
            warn("\(source): unknown key \"transcription.\(key)\" — ignored")
        }
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }
}
