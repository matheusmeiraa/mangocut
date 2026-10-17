import AVFoundation
import CoreGraphics
import CoreVideo

/// Vídeos sintéticos para o projeto de demonstração e para os testes de render.
/// São desenhados por código: nenhum asset de terceiros.
enum DemoMedia {
    enum DemoError: Error {
        case writer(String)
    }

    /// Gradiente na cor `hue`, faixas de cor embaixo, um círculo branco que atravessa a tela
    /// e um quadrado branco no canto superior esquerdo (útil para conferir a orientação).
    static func makeClip(
        at url: URL,
        width: Int,
        height: Int,
        seconds: Double,
        hue: CGFloat,
        transform: CGAffineTransform = .identity,
        fps: Int32 = 30
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? DemoError.writer("não foi possível iniciar a gravação")
        }
        writer.startSession(atSourceTime: .zero)

        let frames = max(1, Int(seconds * Double(fps)))
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw DemoError.writer("sem pool de pixel buffers") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw DemoError.writer("sem pixel buffer") }
            draw(into: buffer, width: width, height: height, progress: Double(index) / Double(frames), hue: hue)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? DemoError.writer("gravação incompleta")
        }
    }

    private static func draw(into buffer: CVPixelBuffer, width: Int, height: Int, progress: Double, hue: CGFloat) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        let w = CGFloat(width)
        let h = CGFloat(height)
        let colors = [color(hue: hue, saturation: 0.75, brightness: 0.95), color(hue: hue + 0.1, saturation: 0.9, brightness: 0.45)]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        }

        // Faixas de cor no rodapé
        let stripe = w / 6
        for (i, stripeHue) in [0.0, 0.08, 0.16, 0.33, 0.55, 0.75].enumerated() {
            context.setFillColor(color(hue: CGFloat(stripeHue), saturation: 0.9, brightness: 0.9))
            context.fill(CGRect(x: CGFloat(i) * stripe, y: 0, width: stripe, height: h * 0.12))
        }

        // Círculo branco atravessando a tela
        let radius = min(w, h) * 0.12
        let x = radius + (w - 2 * radius) * CGFloat(progress)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: x - radius, y: h * 0.5 - radius, width: radius * 2, height: radius * 2))

        // Marcador de orientação no canto superior esquerdo
        let marker = min(w, h) * 0.08
        context.fill(CGRect(x: marker * 0.3, y: h - marker * 1.3, width: marker, height: marker))
    }

    static func color(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGColor {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return CGColor(red: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}
