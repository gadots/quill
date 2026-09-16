import Foundation

/// One timed span of recognized speech from a single track, relative to that
/// track's own start.
public struct TranscriptSegment: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A single recognized word with its timing, decoupled from any one engine's
/// word type. Engines map their own output into this so the grouping rules
/// below can be tested without a model — or a Mac.
public struct TimedWord: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}
