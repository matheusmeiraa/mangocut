import AVFoundation
import CoreImage

/// Dados compartilhados por todas as instruções de uma composição.
final class RenderContext: @unchecked Sendable {
    let plan: RenderPlan
    let orientations: [String: CGImagePropertyOrientation]
    let texts = TextRasterizer()

    init(plan: RenderPlan, orientations: [String: CGImagePropertyOrientation]) {
        self.plan = plan
        self.orientations = orientations
    }

    func orientation(for segmentId: String) -> CGImagePropertyOrientation {
        orientations[segmentId] ?? .up
    }
}

/// Um trecho da timeline em que os mesmos clipes estão visíveis (um, ou dois durante uma transição).
final class MangoInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    struct Layer {
        let trackID: CMPersistentTrackID
        let clipIndex: Int
    }

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [Layer]
    let context: RenderContext

    init(timeRange: CMTimeRange, layers: [Layer], context: RenderContext) {
        self.timeRange = timeRange
        self.layers = layers
        self.context = context
        self.requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
        super.init()
    }
}

/// Compositor de vídeo do MangoCUT: o AVFoundation entrega os quadros dos clipes e o
/// `FrameRenderer` monta o quadro final com Core Image.
final class MangoCompositor: NSObject, AVVideoCompositing {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "com.mangocut.render", qos: .userInitiated)
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    #if compiler(>=6.0)
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    #else
    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    #endif

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            render(request)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? MangoInstruction,
              let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: NSError(
                domain: "MangoCUT",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "instrução de render inválida"]
            ))
            return
        }
        let context = instruction.context
        let layers = instruction.layers.map { layer in
            let clip = context.plan.clips[layer.clipIndex]
            return FrameRenderer.Layer(
                clip: clip,
                image: request.sourceFrame(byTrackID: layer.trackID).map { CIImage(cvPixelBuffer: $0) },
                orientation: context.orientation(for: clip.segmentId)
            )
        }
        let size = request.renderContext.size
        let frame = FrameRenderer.render(
            layers: layers,
            timeUs: request.compositionTime.seconds * 1_000_000,
            texts: context.plan.texts,
            rasterizer: context.texts,
            size: size
        )
        ciContext.render(frame, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }
}
