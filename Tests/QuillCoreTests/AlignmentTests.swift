import Foundation
import Testing

@testable import QuillCore

@Suite("track clock")
struct TrackClockTests {
    @Test("a clock with no observations has no span and no rate")
    func empty() {
        let c = TrackClock()
        #expect(c.firstHostTime == nil)
        #expect(c.span == nil)
        #expect(c.measuredRate(elapsed: 1) == nil)
    }

    @Test("one buffer fixes the start but can't measure a rate yet")
    func singleObservation() {
        var c = TrackClock()
        c.record(hostTime: 1_000, frames: 512)
        #expect(c.firstHostTime == 1_000)
        #expect(c.framesWritten == 512)
        #expect(c.span == nil)
        #expect(c.measuredRate(elapsed: 1) == nil)
    }

    @Test("the rate pairs a stamp with the frames that elapsed before it")
    func measuredRateExcludesTheUnelapsedBuffer() {
        // Three buffers of 480 frames. At the third stamp, 960 frames have
        // actually elapsed — not 1440; the third buffer's frames are only
        // starting at that instant.
        var c = TrackClock()
        c.record(hostTime: 0, frames: 480)
        c.record(hostTime: 10, frames: 480)
        c.record(hostTime: 20, frames: 480)

        #expect(c.framesWritten == 1_440)
        #expect(c.framesBeforeLastHostTime == 960)
        #expect(c.measuredRate(elapsed: 0.02) == 48_000)
    }

    @Test("an out-of-order stamp doesn't move the span backwards")
    func ignoresRegression() {
        var c = TrackClock()
        c.record(hostTime: 0, frames: 480)
        c.record(hostTime: 100, frames: 480)
        c.record(hostTime: 50, frames: 480)
        #expect(c.span?.last == 100)
    }
}

@Suite("track alignment")
struct TrackAlignmentTests {
    @Test("with no offset and no drift, track time is session time")
    func identity() {
        let a = TrackAlignment(offsetMs: 0)
        #expect(a.sessionTime(12.5) == 12.5)
        #expect(a.sessionMilliseconds(12.5) == 12_500)
    }

    @Test("a start offset shifts the whole track")
    func offsetShifts() {
        let a = TrackAlignment(offsetMs: 250)
        #expect(a.sessionMilliseconds(0) == 250)
        #expect(a.sessionMilliseconds(10) == 10_250)
    }

    @Test("a nominal rate with no measurement applies no correction")
    func noMeasurement() {
        #expect(TrackAlignment.rateScale(nominal: 48_000, measured: nil) == 1)
        #expect(TrackAlignment.rateScale(nominal: 0, measured: 48_000) == 1)
    }

    @Test("an implausible ratio is refused rather than stretching the transcript")
    func rejectsBadMeasurement() {
        // Half the expected rate is a broken measurement, not a crystal.
        #expect(TrackAlignment.rateScale(nominal: 48_000, measured: 24_000) == 1)
        #expect(TrackAlignment.rateScale(nominal: 48_000, measured: 0) == 1)
        #expect(TrackAlignment.rateScale(nominal: 48_000, measured: .nan) == 1)
    }

    @Test("a non-finite scale never reaches the timeline")
    func sanitisesScale() {
        #expect(TrackAlignment(offsetMs: 0, rateScale: .infinity).rateScale == 1)
        #expect(TrackAlignment(offsetMs: 0, rateScale: -1).rateScale == 1)
    }

    @Test("drift that would cost ~72 ms across an hour is corrected to under 10 ms")
    func hourLongDrift() {
        // 20 ppm fast: the device delivers 48_000.96 frames per real second,
        // so an hour of audio is timestamped ~72 ms long.
        let nominal = 48_000.0
        let measured = nominal * 1.000_02
        let scale = TrackAlignment.rateScale(nominal: nominal, measured: measured)

        let uncorrected = TrackAlignment(offsetMs: 0)
        let corrected = TrackAlignment(offsetMs: 0, rateScale: scale)

        let anHourOfFrames = 3_600.0
        let trueElapsed = anHourOfFrames * nominal / measured

        let errorBefore = abs(uncorrected.sessionTime(anHourOfFrames) - trueElapsed)
        let errorAfter = abs(corrected.sessionTime(anHourOfFrames) - trueElapsed)

        #expect(errorBefore > 0.070)
        #expect(errorAfter < 0.010)
    }

    @Test("two tracks drifting apart stay aligned at the end of a long session")
    func twoTrackDriftAtTheHour() {
        // The mic device runs 20 ppm fast, the tap's aggregate 15 ppm slow.
        let nominal = 48_000.0
        let mic = TrackAlignment(
            offsetMs: 0,
            rateScale: TrackAlignment.rateScale(nominal: nominal, measured: nominal * 1.000_02)
        )
        let system = TrackAlignment(
            offsetMs: 0,
            rateScale: TrackAlignment.rateScale(nominal: nominal, measured: nominal * 0.999_985)
        )

        // One real instant, an hour in, as each track timestamps it.
        let instant = 3_600.0
        let micTrackTime = instant * 1.000_02
        let systemTrackTime = instant * 0.999_985

        let gapBefore = abs(micTrackTime - systemTrackTime)
        let gapAfter = abs(mic.sessionTime(micTrackTime) - system.sessionTime(systemTrackTime))

        #expect(gapBefore > 0.100)
        #expect(gapAfter < 0.010)
    }
}
