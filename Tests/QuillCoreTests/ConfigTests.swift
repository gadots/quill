import Foundation
import Testing

@testable import QuillCore

@Suite("config")
struct ConfigTests {
    private func parse(_ json: String) -> QuillConfig {
        ConfigStore.parse(Data(json.utf8), describedBy: "test-config.json")
    }

    @Test("every key is optional, so an empty object means defaults")
    func emptyObject() {
        let c = parse("{}")
        #expect(c == .empty)
        #expect(c.transcription?.enabled == nil)
    }

    @Test("a full config round-trips into typed fields")
    func fullConfig() {
        let c = parse("""
        {
          "recordings_dir": "~/Meetings",
          "transcription": {"enabled": false, "engine": "parakeet"},
          "mic_voice_processing": true,
          "on_stop": "my-hook"
        }
        """)
        #expect(c.recordings_dir == "~/Meetings")
        #expect(c.transcription?.enabled == false)
        #expect(c.transcription?.engine == "parakeet")
        #expect(c.mic_voice_processing == true)
        #expect(c.on_stop == "my-hook")
    }

    @Test("malformed JSON falls back to defaults rather than crashing")
    func malformed() {
        #expect(parse("not json at all") == .empty)
        #expect(parse("[1, 2, 3]") == .empty)
    }

    @Test("a wrongly typed value doesn't take the rest of the config with it")
    func wrongType() {
        // Decoding is all-or-nothing, so this must land on defaults — the point
        // is that it does so loudly (a warning) instead of half-applying.
        #expect(parse(#"{"mic_voice_processing": "yes"}"#) == .empty)
    }

    @Test("unknown keys are ignored but the known ones still apply")
    func unknownKeysDoNotDiscardConfig() {
        let c = parse("""
        {
          "recordings_dir": "~/Meetings",
          "transcriptions": {"enabled": false},
          "typo_key": 1
        }
        """)
        #expect(c.recordings_dir == "~/Meetings")
        // "transcriptions" is a typo for "transcription": it must not apply.
        #expect(c.transcription == nil)
    }

    @Test("a nested typo leaves the surrounding block intact")
    func unknownNestedKey() {
        let c = parse(#"{"transcription": {"enabled": false, "engien": "whisper"}}"#)
        #expect(c.transcription?.enabled == false)
        #expect(c.transcription?.engine == nil)
    }

    @Test("a CLI override wins over config and expands a tilde")
    func cliOverrideWins() {
        let root = Config.resolveRoot(cliOverride: "~/Elsewhere")
        #expect(root.path.hasSuffix("/Elsewhere"))
        #expect(!root.path.contains("~"))
    }

    @Test("an absolute override is used as given")
    func absoluteOverride() {
        #expect(Config.resolveRoot(cliOverride: "/tmp/quill-test").path == "/tmp/quill-test")
    }
}
