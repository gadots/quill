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
