import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Desenha os textos do projeto com CoreText e guarda o resultado já posicionado no canvas.
/// Usa só fontes do sistema, que não vêm empacotadas no app.
final class TextRasterizer: @unchecked Sendable {
    private var cache: [String: CIImage] = [:]
    private let lock = NSLock()

    func image(for text: RenderPlan.Text, canvas: CGSize) -> CIImage? {
        let key = "\(text.id)|\(text.text)|\(text.font)|\(text.size)|\(text.color)|\(text.x)|\(text.y)|\(text.background)|\(canvas.width)x\(canvas.height)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let image = Self.draw(text, canvas: canvas) else { return nil }
        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }

    static func font(named name: String, size: CGFloat) -> CTFont {
        switch name {
        case "serif":
            return CTFontCreateWithName("Georgia-Bold" as CFString, size, nil)
        case "mono":
            return CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        case "rounded":
            return CTFontCreateWithName("ArialRoundedMTBold" as CFString, size, nil)
        default:
            let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
        }
    }

    static func cgColor(hex: String) -> CGColor {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
        return CGColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func draw(_ text: RenderPlan.Text, canvas: CGSize) -> CIImage? {
        let fontSize = max(4, CGFloat(text.size) * canvas.height)
        var alignment = CTTextAlignment.center
        let paragraph: CTParagraphStyle = withUnsafeBytes(of: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: pointer.baseAddress!
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font(named: text.font, size: fontSize),
            kCTForegroundColorAttributeName: cgColor(hex: text.color),
            kCTParagraphStyleAttributeName: paragraph,
        ]
        guard let attributed = CFAttributedStringCreate(nil, text.text as CFString, attributes as CFDictionary) else {
            return nil
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: canvas.width * 0.9, height: .greatestFiniteMagnitude),
            nil
        )
        let padding = text.background ? fontSize * 0.35 : fontSize * 0.25
        let textSize = CGSize(width: ceil(fit.width) + 2, height: ceil(fit.height) + 2)
        let size = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding * 2)
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        if text.background {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
            context.addPath(CGPath(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerWidth: padding,
                cornerHeight: padding,
                transform: nil
            ))
            context.fillPath()
        } else {
            context.setShadow(
                offset: CGSize(width: 0, height: -fontSize * 0.04),
                blur: fontSize * 0.15,
                color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.65)
            )
        }
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(origin: CGPoint(x: padding, y: padding), size: textSize), transform: nil),
            nil
        )
        CTFrameDraw(frame, context)
        guard let rendered = context.makeImage() else { return nil }

        // x e y são o centro do texto medido a partir do topo; o Core Image conta y de baixo para cima.
        let centerX = CGFloat(text.x) * canvas.width
        let centerY = canvas.height - CGFloat(text.y) * canvas.height
        return CIImage(cgImage: rendered).transformed(by: CGAffineTransform(
            translationX: (centerX - size.width / 2).rounded(),
            y: (centerY - size.height / 2).rounded()
        ))
    }
}
