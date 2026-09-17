import Foundation
import Testing

@testable import QuillCore

@Suite("session metadata")
struct SessionMetaTests {
    private let source = URL(fileURLWithPath: "/tmp/session/meta.json")

    private func parse(_ json: String) throws -> SessionMeta {
        try SessionMeta.parse(Data(json.utf8), source: source)
    }

    @Test("both tracks are read with their speakers and offsets")
    func bothTracks() throws {
        let meta = try parse("""
        {
          "files": {"mic": "mic.caf", "system": "system.caf"},
          "start_offset_ms": {"mic": 40, "system": 0}
        }
        """)
        #expect(meta.tracks.count == 2)
        #expect(meta.tracks[0] == .init(file: "mic.caf", speaker: "me", offsetMs: 40))
        #expect(meta.tracks[1] == .init(file: "system.caf", speaker: "them", offsetMs: 0))
    }

    @Test("sessions recorded before offsets existed default to zero")
    func missingOffsets() throws {
        let meta = try parse(#"{"files": {"mic": "mic.caf", "system": "system.caf"}}"#)
        #expect(meta.tracks.allSatisfy { $0.offsetMs == 0 })
    }

    @Test("a partially recorded session yields only the track it has")
    func singleTrack() throws {
        let meta = try parse(#"{"files": {"system": "system.caf"}}"#)
        #expect(meta.tracks.count == 1)
        #expect(meta.tracks[0].speaker == "them")
    }

    @Test("mic is always ordered before system so the merge is deterministic")
    func trackOrder() throws {
        let meta = try parse(#"{"files": {"system": "system.caf", "mic": "mic.caf"}}"#)
        #expect(meta.tracks.map(\.speaker) == ["me", "them"])
    }

    @Test("malformed or fileless metadata is rejected, not silently empty")
    func rejectsGarbage() {
        #expect(throws: SessionMeta.MetaError.self) { try parse("not json") }
        #expect(throws: SessionMeta.MetaError.self) { try parse(#"{"started": "x"}"#) }
    }
}

@Suite("interrupted session recovery")
struct SessionRecoveryTests {
    private let source = URL(fileURLWithPath: "/tmp/session/meta.json")

    private func parse(_ json: String) throws -> SessionMeta {
        try SessionMeta.parse(Data(json.utf8), source: source)
    }

    @Test("a session that never stopped cleanly is marked as recording")
    func liveStatus() throws {
        let meta = try parse("""
        {"status": "recording", "files": {"mic": "mic.caf", "system": "system.caf"}}
        """)
        #expect(meta.status == .recording)
        #expect(meta.tracks.count == 2)
    }

    @Test("a clean stop is marked finished")
    func finishedStatus() throws {
        let meta = try parse(#"{"status": "finished", "files": {"mic": "mic.caf"}}"#)
        #expect(meta.status == .finished)
    }

    @Test("metadata written before status existed only ever meant a clean stop")
    func legacyMetaDefaultsToFinished() throws {
        let meta = try parse(#"{"files": {"mic": "mic.caf"}}"#)
        #expect(meta.status == .finished)
    }

    @Test("an unrecognised status is treated as finished rather than rejected")
    func unknownStatus() throws {
        let meta = try parse(#"{"status": "wat", "files": {"mic": "mic.caf"}}"#)
        #expect(meta.status == .finished)
    }

    @Test("with no metadata at all, tracks come from the audio on disk")
    func recoverBothTracks() {
        let meta = SessionMeta.recovered { _ in true }
        #expect(meta.status == .recording)
        #expect(meta.tracks.map(\.file) == ["mic.caf", "system.caf"])
        #expect(meta.tracks.map(\.speaker) == ["me", "them"])
        #expect(meta.tracks.allSatisfy { $0.offsetMs == 0 })
    }

    @Test("recovery keeps whichever track actually exists")
    func recoverOneTrack() {
        let meta = SessionMeta.recovered { $0 == "system.caf" }
        #expect(meta.tracks.map(\.file) == ["system.caf"])
    }

    @Test("an empty session folder recovers nothing to transcribe")
    func recoverNothing() {
        #expect(SessionMeta.recovered { _ in false }.tracks.isEmpty)
    }
}
