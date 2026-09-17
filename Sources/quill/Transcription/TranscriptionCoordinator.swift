import Foundation
import QuillCore

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    /// Queued plus currently transcribing. `queue` alone isn't enough: the
    /// session being worked on has already been removed from it, so a second
    /// scan would hand it out again.
    private var claimed: Set<URL> = []
    /// The session being recorded right now, if any. It has a meta.json and
    /// audio but no transcript, so it matches every "pending" test — and its
    /// tracks are still open for writing.
    private var activeSession: URL?
    private var draining = false
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Tell the coordinator which session is live, so a scan never picks up a
    /// file that is still being written. Pass nil when recording stops.
    func setActiveSession(_ dir: URL?) {
        activeSession = dir
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        claim(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that hold audio but no
    /// transcript. Folder names sort chronologically, so oldest-first is a
    /// name sort.
    ///
    /// A session is a candidate on the strength of its audio, not its
    /// bookkeeping: a crash mid-meeting leaves a readable CAF behind (that is
    /// the whole reason quill records CAF), and it should be transcribed on the
    /// next launch even if meta.json is missing or truncated.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter { dir in
                guard !fm.fileExists(
                    atPath: dir.appendingPathComponent("transcript.json").path
                ) else { return false }
                return fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path)
                    || SessionMeta.knownTracks.contains {
                        fm.fileExists(atPath: dir.appendingPathComponent($0.file).path)
                    }
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var resumed = 0
        for dir in pending where dir != activeSession {
            if claim(dir) { resumed += 1 }
        }
        if resumed > 0 {
            FileHandle.standardError.write(Data(
                "resuming \(resumed) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    /// Add a session to the queue unless it is already queued or in
    /// progress. Returns whether it was newly claimed.
    @discardableResult
    private func claim(_ dir: URL) -> Bool {
        guard claimed.insert(dir).inserted else { return false }
        queue.append(dir)
        return true
    }

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            defer { claimed.remove(dir) }
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                notifyUser(title: "quill — transcript ready", body: dir.lastPathComponent)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "quill — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try readMeta(dir)
        if meta.status == .recording {
            log(dir, "recovering an interrupted session — transcribing what was written")
        }
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let alignment = track.alignment
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: alignment.sessionMilliseconds($0.start),
                    end_ms: alignment.sessionMilliseconds($0.end),
                    text: $0.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    /// meta.json, or — when it is missing or unparseable because the session
    /// was cut short — whatever tracks are actually on disk.
    private func readMeta(_ dir: URL) throws -> SessionMeta {
        if let meta = try? SessionMeta.read(from: dir), !meta.tracks.isEmpty {
            return meta
        }
        let fm = FileManager.default
        let recovered = SessionMeta.recovered { file in
            fm.fileExists(atPath: dir.appendingPathComponent(file).path)
        }
        guard !recovered.tracks.isEmpty else { throw SessionMeta.MetaError.unreadable(dir) }
        log(dir, "meta.json missing or unreadable — recovered \(recovered.tracks.count) track(s)")
        return recovered
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
            ))
        }
        let engine = ParakeetEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}
