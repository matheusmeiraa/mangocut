import AVFoundation

/// Exporta o projeto em MP4 com codecs acelerados por hardware (HEVC / H.264).
/// Inspirado no ByteVC1 e encoders customizados do CapCut (~60 MB), implementado nativamente
/// via VideoToolbox e AVFoundation sem dependências externas estáticas.
enum Exporter {
    enum Codec: String, CaseIterable, Identifiable {
        case hevc = "hevc"
        case h264 = "h264"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .hevc: return "HEVC (H.265) • Mais leve"
            case .h264: return "H.264 (AVC) • Compatível"
            }
        }

        var presetName: String {
            switch self {
            case .hevc:
                return AVAssetExportPresetHEVCHighestQuality
            case .h264:
                return AVAssetExportPresetHighestQuality
            }
        }
    }

    /// Tamanho de saída com o lado menor igual a `shortSide`, mantendo a proporção do canvas.
    static func renderSize(for plan: RenderPlan, shortSide: Int) -> CGSize {
        let width = plan.canvas.width
        let height = plan.canvas.height
        let scale = Double(shortSide) / max(1, min(width, height))
        func even(_ value: Double) -> Double { max(2, (value / 2).rounded() * 2) }
        return CGSize(width: even(width * scale), height: even(height * scale))
    }

    static func export(
        plan: RenderPlan,
        resolve: (RenderPlan.Clip) -> URL?,
        shortSide: Int,
        codec: Codec = .hevc,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let built = try await CompositionBuilder.build(
            plan: plan,
            resolve: resolve,
            renderSize: renderSize(for: plan, shortSide: shortSide)
        )

        let chosenPreset: String
        let compatible = AVAssetExportSession.exportPresets(compatibleWith: built.composition)
        if compatible.contains(codec.presetName) {
            chosenPreset = codec.presetName
        } else {
            chosenPreset = AVAssetExportPresetHighestQuality
        }

        guard let session = AVAssetExportSession(asset: built.composition, presetName: chosenPreset) else {
            throw RenderError.exportFailed("o iPhone não conseguiu preparar a exportação")
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.outputFileType = .mp4
        session.outputURL = url
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: url)

        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        poller.cancel()
        guard session.status == .completed else {
            throw RenderError.exportFailed(session.error?.localizedDescription ?? "a exportação não terminou")
        }
        progress(1)
    }
}
