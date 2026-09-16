import Foundation
import QuillCore

/// A speech-to-text engine quill can run locally. Engines are prepared lazily
/// (model download + load) when the transcription queue has work and released
/// when it drains, so quill never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment]
    func release() async
}
