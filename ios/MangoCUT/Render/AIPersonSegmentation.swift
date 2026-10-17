import CoreImage
import Foundation
import Vision

/// Motor de IA para Recorte de Corpo Humano e Desfoque de Retrato Cinemático.
/// Inspirado nos modelos neurais do CapCut (ByteNN ~180 MB), mas implementado de forma 100% limpa,
/// nativa e acelerada diretamente pelo Apple Neural Engine (ANE) via Vision framework.
/// Sem pesos proprietários, sem internet e com consumo mínimo de bateria.
final class AIPersonSegmentation: @unchecked Sendable {
    static let shared = AIPersonSegmentation()

    private let request: VNGeneratePersonSegmentationRequest
    private let context = CIContext(options: [.cacheIntermediates: false])

    private init() {
        request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// Gera a máscara em escala de cinza da pessoa no quadro (branco = pessoa, preto = fundo).
    func generateMask(for image: CIImage) -> CIImage? {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
            let scaleX = image.extent.width / mask.extent.width
            let scaleY = image.extent.height / mask.extent.height
            return mask
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .cropped(to: image.extent)
        } catch {
            return nil
        }
    }

    /// Recorta a pessoa mantendo-a em destaque e substituindo o fundo por um fundo sólido ou personalizado.
    func cutout(image: CIImage, background: CIImage? = nil) -> CIImage {
        guard let mask = generateMask(for: image) else { return image }
        let bg = background ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: image.extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bg,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: image.extent)
    }

    /// Modo Retrato Cinemático: mantém o sujeito focado e nítido enquanto desfoca o cenário de fundo.
    func portraitBlur(image: CIImage, blurRadius: CGFloat = 20) -> CIImage {
        guard let mask = generateMask(for: image) else { return image }
        let blurred = image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: image.extent)

        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: blurred,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: image.extent)
    }
}
