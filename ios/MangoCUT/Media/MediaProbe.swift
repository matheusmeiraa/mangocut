import AVFoundation

struct MediaInfo {
    let durationUs: Double
    /// Largura e altura de exibição, já considerando a rotação gravada pela câmera.
    let width: Int
    let height: Int
    let hasAudio: Bool
}

enum MediaProbe {
    static func probe(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideo(url.lastPathComponent)
        }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let display = CGRect(origin: .zero, size: size).applying(transform)
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        return MediaInfo(
            durationUs: (duration.seconds * 1_000_000).rounded(),
            width: Int(abs(display.width).rounded()),
            height: Int(abs(display.height).rounded()),
            hasAudio: hasAudio
        )
    }
}
