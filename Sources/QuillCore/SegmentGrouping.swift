import Foundation

/// Groups word timings into readable transcript segments.
///
/// Extracted from ParakeetEngine so the rules are testable on their own: they
/// decide how a transcript reads, and until now the only way to check them was
/// to record a meeting.
public enum SegmentGrouping {
    /// Silence longer than this between two words starts a new segment.
    public static let defaultGapSeconds: TimeInterval = 1.0
    /// Hard cap so a run-on speaker still wraps.
    public static let defaultMaxWords = 60

    /// Break on sentence-ending punctuation (parakeet v2 emits punctuation), a
    /// silence gap, or the length cap.
    public static func segments(
        from words: [TimedWord],
        gapSeconds: TimeInterval = defaultGapSeconds,
        maxWords: Int = defaultMaxWords
    ) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptSegment(
                start: first.start,
                end: last.end,
                text: current.map(\.text).joined(separator: " ")
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.start - last.end > gapSeconds {
                flush()
            }
            current.append(word)
            if endsSentence(word.text) || current.count >= maxWords {
                flush()
            }
        }
        flush()
        return out
    }

    private static func endsSentence(_ word: String) -> Bool {
        word.hasSuffix(".") || word.hasSuffix("?") || word.hasSuffix("!")
    }
}
