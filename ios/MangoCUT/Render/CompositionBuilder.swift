import AVFoundation
import CoreImage

enum RenderError: LocalizedError {
    case missingMedia(String)
    case noVideo(String)
    case emptyProject
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingMedia(let name):
            return "A mídia do clipe \"\(name)\" não foi encontrada."
        case .noVideo(let name):
            return "\(name) não tem trilha de vídeo."
        case .emptyProject:
            return "O projeto ainda não tem clipes."
        case .exportFailed(let reason):
            return "A exportação falhou: \(reason)"
        }
    }
}

extension CMTime {
    init(microseconds: Double) {
        self.init(value: CMTimeValue(microseconds.rounded()), timescale: 1_000_000)
    }

    var microseconds: Double { seconds * 1_000_000 }
}

/// Transforma o plano de render numa composição do AVFoundation. Os clipes se alternam entre
/// duas trilhas (A e B) para que, numa transição, os dois quadros estejam disponíveis ao mesmo tempo.
enum CompositionBuilder {
    struct Built {
        let composition: AVComposition
        let videoComposition: AVVideoComposition
        let audioMix: AVAudioMix?
    }

    static func build(
        plan: RenderPlan,
        resolve: (RenderPlan.Clip) -> URL?,
        renderSize: CGSize? = nil
    ) async throws -> Built {
        guard !plan.clips.isEmpty else { throw RenderError.emptyProject }
        let composition = AVMutableComposition()
        guard let videoA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let videoB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioB = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw RenderError.exportFailed("não foi possível criar as trilhas da composição") }

        var orientations: [String: CGImagePropertyOrientation] = [:]
        var videoTrackOfClip: [Int: CMPersistentTrackID] = [:]
        let audioParameters = [
            audioA.trackID: AVMutableAudioMixInputParameters(track: audioA),
            audioB.trackID: AVMutableAudioMixInputParameters(track: audioB),
        ]

        for (index, clip) in plan.clips.enumerated() {
            guard let url = resolve(clip) else { throw RenderError.missingMedia(clip.name) }
            let asset = AVURLAsset(url: url)
            let videoTrack = index.isMultiple(of: 2) ? videoA : videoB
            let audioTrack = index.isMultiple(of: 2) ? audioA : audioB
            let start = CMTime(microseconds: clip.timelineStartUs)
            let source = CMTimeRange(
                start: CMTime(microseconds: clip.sourceStartUs),
                duration: CMTime(microseconds: clip.sourceDurationUs)
            )
            let target = CMTime(microseconds: clip.timelineDurationUs)

            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw RenderError.noVideo(clip.name)
            }
            try await insert(sourceVideo, range: source, into: videoTrack, at: start, duration: target)
            orientations[clip.segmentId] = orientation(of: try await sourceVideo.load(.preferredTransform))
            videoTrackOfClip[index] = videoTrack.trackID

            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try await insert(sourceAudio, range: source, into: audioTrack, at: start, duration: target)
                if let parameters = audioParameters[audioTrack.trackID] {
                    applyVolume(of: clip, to: parameters, start: start)
                }
            }
        }

        for track in [videoB, audioA, audioB] where track.segments.isEmpty {
            composition.removeTrack(track)
        }

        let context = RenderContext(plan: plan, orientations: orientations)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = MangoCompositor.self
        videoComposition.renderSize = renderSize ?? CGSize(width: plan.canvas.width, height: plan.canvas.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, plan.fps.rounded())))
        videoComposition.instructions = instructions(
            plan: plan,
            tracks: videoTrackOfClip,
            context: context,
            end: composition.duration
        )

        let usedAudio = audioParameters.values.filter { parameters in
            composition.tracks.contains { $0.trackID == parameters.trackID }
        }
        let audioMix: AVMutableAudioMix?
        if usedAudio.isEmpty {
            audioMix = nil
        } else {
            let mix = AVMutableAudioMix()
            mix.inputParameters = usedAudio
            audioMix = mix
        }
        return Built(composition: composition, videoComposition: videoComposition, audioMix: audioMix)
    }

    /// Corta a timeline nos pontos onde algum clipe começa ou termina; cada trecho vira uma instrução.
    static func instructions(
        plan: RenderPlan,
        tracks: [Int: CMPersistentTrackID],
        context: RenderContext,
        end: CMTime
    ) -> [MangoInstruction] {
        let endUs = end.microseconds
        var cuts = Set<Double>([0, endUs])
        for clip in plan.clips {
            cuts.insert(clip.timelineStartUs)
            cuts.insert(clip.timelineEndUs)
        }
        let points = cuts.filter { $0 >= 0 && $0 <= endUs }.sorted()
        var result: [MangoInstruction] = []
        for (from, to) in zip(points, points.dropFirst()) where to > from {
            let layers = plan.clips.enumerated().compactMap { index, clip -> MangoInstruction.Layer? in
                guard clip.timelineStartUs < to, clip.timelineEndUs > from, let track = tracks[index] else { return nil }
                return MangoInstruction.Layer(trackID: track, clipIndex: index)
            }
            let start = result.last?.timeRange.end ?? .zero
            let stop = to >= endUs ? end : CMTime(microseconds: to)
            guard stop > start else { continue }
            result.append(MangoInstruction(
                timeRange: CMTimeRange(start: start, end: stop),
                layers: layers,
                context: context
            ))
        }
        return result
    }

    private static func insert(
        _ source: AVAssetTrack,
        range: CMTimeRange,
        into track: AVMutableCompositionTrack,
        at start: CMTime,
        duration: CMTime
    ) async throws {
        let available = range.intersection(try await source.load(.timeRange))
        guard available.duration > .zero else { return }
        let trackEnd = track.timeRange.end
        if start > trackEnd {
            track.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: start))
        }
        try track.insertTimeRange(available, of: source, at: start)
        if available.duration != duration {
            track.scaleTimeRange(CMTimeRange(start: start, duration: available.duration), toDuration: duration)
        }
    }

    private static func applyVolume(
        of clip: RenderPlan.Clip,
        to parameters: AVMutableAudioMixInputParameters,
        start: CMTime
    ) {
        let volume = Float(max(0, clip.volume))
        let fade = FrameRenderer.fadeUs
        if let transition = clip.transitionIn {
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: volume,
                timeRange: CMTimeRange(start: start, duration: CMTime(microseconds: transition.durationUs))
            )
        } else if clip.effects.contains("fadeIn") {
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: volume,
                timeRange: CMTimeRange(start: start, duration: CMTime(microseconds: min(fade, clip.timelineDurationUs)))
            )
        } else {
            parameters.setVolume(volume, at: start)
        }
        let outLength = clip.transitionOut?.durationUs ?? (clip.effects.contains("fadeOut") ? min(fade, clip.timelineDurationUs) : 0)
        if outLength > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: volume,
                toEndVolume: 0,
                timeRange: CMTimeRange(
                    start: CMTime(microseconds: clip.timelineEndUs - outLength),
                    duration: CMTime(microseconds: outLength)
                )
            )
        }
    }

    /// Converte a rotação gravada pela câmera (`preferredTransform`) numa orientação do Core Image.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }
}
