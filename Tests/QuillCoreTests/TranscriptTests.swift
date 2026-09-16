import Foundation
import Testing

@testable import QuillCore

@Suite("transcript rendering")
struct TranscriptTests {
    @Test("clock stays m:ss below an hour")
    func clockUnderAnHour() {
        #expect(Transcript.clock(0) == "0:00")
        #expect(Transcript.clock(9_000) == "0:09")
        #expect(Transcript.clock(61_000) == "1:01")
        #expect(Transcript.clock(3_599_000) == "59:59")
    }

    @Test("clock grows to h:mm:ss at the hour mark")
    func clockOverAnHour() {
        #expect(Transcript.clock(3_600_000) == "1:00:00")
        #expect(Transcript.clock(3_661_000) == "1:01:01")
        #expect(Transcript.clock(45_296_000) == "12:34:56")
    }

    @Test("sub-second values truncate rather than round")
    func clockTruncates() {
        #expect(Transcript.clock(1_999) == "0:01")
    }

    @Test("markdown carries the timestamp, speaker and provenance")
    func rendering() {
        let t = Transcript(
            engine: "parakeet",
            model: "parakeet-tdt-0.6b-v2-coreml",
            created_at: "2026-09-16T12:00:00Z",
            segments: [
                .init(speaker: "me", start_ms: 0, end_ms: 1_000, text: "hello"),
                .init(speaker: "them", start_ms: 65_000, end_ms: 66_000, text: "hi back"),
            ]
        )
        let md = t.rendered(title: "2026.09.16-1200")

        #expect(md.hasPrefix("# 2026.09.16-1200"))
        #expect(md.contains("engine: parakeet (parakeet-tdt-0.6b-v2-coreml)"))
        #expect(md.contains("**[0:00] me:** hello"))
        #expect(md.contains("**[1:05] them:** hi back"))
    }

    @Test("an empty transcript still renders a usable header")
    func renderingEmpty() {
        let t = Transcript(engine: "parakeet", model: "m", created_at: "x", segments: [])
        let md = t.rendered(title: "session")
        #expect(md.contains("# session"))
    }

    @Test("json round-trips through the on-disk schema")
    func roundTrip() throws {
        let t = Transcript(
            engine: "parakeet",
            model: "m",
            created_at: "2026-09-16T12:00:00Z",
            segments: [.init(speaker: "me", start_ms: 10, end_ms: 20, text: "x")]
        )
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(Transcript.self, from: data) == t)

        // The key names are the published schema — guard them explicitly.
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let seg = try #require((json["segments"] as? [[String: Any]])?.first)
        #expect(seg["start_ms"] as? Int == 10)
        #expect(seg["end_ms"] as? Int == 20)
        #expect(seg["speaker"] as? String == "me")
    }
}
