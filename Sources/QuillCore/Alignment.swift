import Foundation

/// Observations of a capture clock, accumulated as buffers arrive.
///
/// Tracks were aligned by `Date()` taken inside the capture callback, which is
/// not when the audio was captured: it trails by the buffer's own duration plus
/// whatever the scheduler added. Both callbacks already receive a host-time
/// stamp — the same clock for both tracks — so that is what gets recorded here.
///
/// Host ticks are stored raw; converting them to seconds needs the machine's
/// timebase, which is the caller's job. That keeps this type portable and
/// testable.
public struct TrackClock: Sendable, Equatable {
    public private(set) var firstHostTime: UInt64?
    public private(set) var lastHostTime: UInt64 = 0
    /// Frames delivered strictly *before* `lastHostTime`. A buffer's stamp
    /// marks its first sample, so pairing it with the running total would
    /// count one buffer's worth of frames that hadn't elapsed yet.
    public private(set) var framesBeforeLastHostTime: Int64 = 0
    public private(set) var framesWritten: Int64 = 0

    public init() {}

    public mutating func record(hostTime: UInt64, frames: Int64) {
        if firstHostTime == nil {
            firstHostTime = hostTime
        } else if hostTime > lastHostTime {
            lastHostTime = hostTime
            framesBeforeLastHostTime = framesWritten
        }
        framesWritten += frames
    }

    /// Host-tick span between the first and last observation, if there are two.
    public var span: (first: UInt64, last: UInt64)? {
        guard let firstHostTime, lastHostTime > firstHostTime else { return nil }
        return (firstHostTime, lastHostTime)
    }

    /// Frames per second this device actually delivered, given the wall-clock
    /// seconds the caller measured across `span`. Nil when too little has been
    /// observed to say anything.
    public func measuredRate(elapsed: TimeInterval) -> Double? {
        guard framesBeforeLastHostTime > 0, elapsed > 0 else { return nil }
        return Double(framesBeforeLastHostTime) / elapsed
    }
}

/// Maps one track's own timeline onto the session's shared timeline.
///
/// Two corrections, and the second is the one that grows with meeting length:
/// the tracks don't start on the same buffer (`offsetMs`), and the mic engine
/// and the tap's aggregate run off different hardware clocks with nothing
/// reconciling them (`rateScale`). The sub-tap's drift compensation only
/// applies inside the aggregate. A 20 ppm difference is ~72 ms per hour, all of
/// it landing at the end of the meeting.
public struct TrackAlignment: Sendable, Equatable {
    public let offsetMs: Int
    /// nominal ÷ measured. 1.0 means no correction — either the clock was
    /// exact or there was no measurement to make.
    public let rateScale: Double

    public init(offsetMs: Int, rateScale: Double = 1) {
        self.offsetMs = offsetMs
        self.rateScale = TrackAlignment.isUsable(rateScale) ? rateScale : 1
    }

    /// Track-relative seconds → session-relative seconds.
    public func sessionTime(_ trackTime: TimeInterval) -> TimeInterval {
        TimeInterval(offsetMs) / 1000 + trackTime * rateScale
    }

    public func sessionMilliseconds(_ trackTime: TimeInterval) -> Int {
        Int((sessionTime(trackTime) * 1000).rounded())
    }

    /// A file's timestamps are laid out at the nominal rate, but the frames in
    /// it took `frames / measured` seconds to arrive. Scaling by nominal ÷
    /// measured puts them back on real time.
    public static func rateScale(nominal: Double, measured: Double?) -> Double {
        guard let measured, nominal > 0, measured > 0 else { return 1 }
        let scale = nominal / measured
        // A wildly off ratio means the measurement is wrong, not that the
        // crystal is: refuse to stretch the transcript on bad data.
        guard isUsable(scale), abs(scale - 1) < 0.05 else { return 1 }
        return scale
    }

    private static func isUsable(_ scale: Double) -> Bool {
        scale.isFinite && scale > 0
    }
}
