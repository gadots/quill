import AVFoundation
import CoreAudio
import Foundation

/// The mach absolute-time clock, shared by both capture paths.
///
/// This is the one clock both tracks can be expressed in: the mic tap's
/// `AVAudioTime` and the system tap's `AudioTimeStamp` are stamped from it, so
/// aligning on it needs no correlation between two unrelated time bases.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func now() -> UInt64 { mach_absolute_time() }

    /// Seconds between two host-time stamps. Only ever applied to a
    /// difference — the absolute value is far too large to survive conversion
    /// to Double with the precision this needs.
    static func seconds(from: UInt64, to: UInt64) -> TimeInterval {
        guard to > from else { return 0 }
        let nanos = (to - from) * UInt64(timebase.numer) / UInt64(timebase.denom)
        return TimeInterval(nanos) / 1_000_000_000
    }

    /// When the buffer's first sample was captured. Falls back to reading the
    /// clock now if the stamp isn't usable — worse, but still the same clock as
    /// the other track, which is what alignment depends on.
    static func hostTime(of time: AVAudioTime?) -> UInt64 {
        guard let time, time.isHostTimeValid else { return now() }
        return time.hostTime
    }

    static func hostTime(of stamp: UnsafePointer<AudioTimeStamp>) -> UInt64 {
        let value = stamp.pointee
        guard value.mFlags.contains(.hostTimeValid) else { return now() }
        return value.mHostTime
    }
}
