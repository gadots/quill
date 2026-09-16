import Foundation
import Testing

@testable import QuillCore

/// Words one second apart by default, so nothing trips the gap rule unless a
/// test asks for it.
private func words(_ specs: [(String, TimeInterval, TimeInterval)]) -> [TimedWord] {
    specs.map { TimedWord(text: $0.0, start: $0.1, end: $0.2) }
}

@Suite("segment grouping")
struct SegmentGroupingTests {
    @Test("no words yields no segments")
    func empty() {
        #expect(SegmentGrouping.segments(from: []).isEmpty)
    }

    @Test("a run with no break becomes one segment spanning first to last")
    func singleSegment() {
        let out = SegmentGrouping.segments(from: words([
            ("hello", 0.0, 0.4), ("there", 0.5, 0.9),
        ]))
        #expect(out.count == 1)
        #expect(out[0].text == "hello there")
        #expect(out[0].start == 0.0)
        #expect(out[0].end == 0.9)
    }

    @Test("sentence-ending punctuation closes a segment", arguments: [".", "?", "!"])
    func punctuationBreaks(mark: String) {
        let out = SegmentGrouping.segments(from: words([
            ("done\(mark)", 0.0, 0.4), ("next", 0.5, 0.9),
        ]))
        #expect(out.count == 2)
        #expect(out[0].text == "done\(mark)")
        #expect(out[1].text == "next")
    }

    @Test("a comma is not a sentence end")
    func commaDoesNotBreak() {
        let out = SegmentGrouping.segments(from: words([
            ("well,", 0.0, 0.4), ("anyway", 0.5, 0.9),
        ]))
        #expect(out.count == 1)
    }

    @Test("silence longer than the gap starts a new segment")
    func gapBreaks() {
        // 1.5s of silence, against the 1.0s default.
        let out = SegmentGrouping.segments(from: words([
            ("before", 0.0, 0.4), ("after", 1.9, 2.3),
        ]))
        #expect(out.count == 2)
        #expect(out[1].start == 1.9)
    }

    @Test("a gap exactly at the threshold does not break")
    func gapBoundaryIsExclusive() {
        let out = SegmentGrouping.segments(from: words([
            ("before", 0.0, 1.0), ("after", 2.0, 2.4),
        ]))
        #expect(out.count == 1)
    }

    @Test("a run-on speaker wraps at the word cap")
    func maxWordsCap() {
        // 130 unpunctuated words, tightly spaced so only the cap can break them.
        let specs = (0..<130).map { i in
            ("w\(i)", TimeInterval(i) * 0.1, TimeInterval(i) * 0.1 + 0.05)
        }
        let out = SegmentGrouping.segments(from: words(specs))
        #expect(out.count == 3)
        #expect(out[0].text.split(separator: " ").count == 60)
        #expect(out[1].text.split(separator: " ").count == 60)
        #expect(out[2].text.split(separator: " ").count == 10)
    }

    @Test("thresholds are configurable")
    func customThresholds() {
        let specs = (0..<5).map { i in
            ("w\(i)", TimeInterval(i) * 0.1, TimeInterval(i) * 0.1 + 0.05)
        }
        let out = SegmentGrouping.segments(from: words(specs), maxWords: 2)
        #expect(out.count == 3)
    }
}
