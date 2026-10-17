import CoreImage
import Foundation

/// Filtro de Chroma Key (remoção de tela verde ou tela azul) de alta velocidade usando `CIColorCube`.
/// Roda acelerado por Metal com supressão de borda e zero lag.
enum ChromaKeyFilter {
    private static let cubeSize = 32
    private static let greenCubeData: Data = makeCubeData(targetHue: 120, hueTolerance: 45)
    private static let blueCubeData: Data = makeCubeData(targetHue: 220, hueTolerance: 40)

    /// Aplica o efeito de Chroma Key removendo a cor de fundo (verde ou azul).
    static func apply(to image: CIImage, color: KeyColor = .green, background: CIImage? = nil) -> CIImage {
        let cubeData = color == .green ? greenCubeData : blueCubeData
        let keyed = image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": cubeSize,
            "inputCubeData": cubeData,
        ])
        guard let background else { return keyed }
        return keyed.composited(over: background).cropped(to: image.extent)
    }

    enum KeyColor {
        case green
        case blue
    }

    private static func makeCubeData(targetHue: Float, hueTolerance: Float) -> Data {
        let size = cubeSize
        var cube = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0

        for z in 0..<size {
            let blue = Float(z) / Float(size - 1)
            for y in 0..<size {
                let green = Float(y) / Float(size - 1)
                for x in 0..<size {
                    let red = Float(x) / Float(size - 1)

                    let (h, s, _) = rgbToHsv(r: red, g: green, b: blue)
                    let hueDiff = min(abs(h - targetHue), 360 - abs(h - targetHue))

                    var alpha: Float = 1.0
                    let outR = red
                    var outG = green
                    let outB = blue

                    if hueDiff < hueTolerance && s > 0.25 {
                        let factor = hueDiff / hueTolerance
                        alpha = factor * factor
                        // Supressão de vazamento de verde (spill suppression) nas bordas
                        outG = min(green, max(red, blue) * 1.05)
                    }

                    cube[offset] = outR * alpha
                    cube[offset + 1] = outG * alpha
                    cube[offset + 2] = outB * alpha
                    cube[offset + 3] = alpha
                    offset += 4
                }
            }
        }

        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func rgbToHsv(r: Float, g: Float, b: Float) -> (h: Float, s: Float, v: Float) {
        let maxVal = max(r, max(g, b))
        let minVal = min(r, min(g, b))
        let delta = maxVal - minVal

        var h: Float = 0
        if delta > 0.0001 {
            if maxVal == r {
                h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxVal == greenVal(g) {
                h = 60 * ((b - r) / delta + 2)
            } else {
                h = 60 * ((r - g) / delta + 4)
            }
            if h < 0 { h += 360 }
        }
        let s = maxVal > 0 ? delta / maxVal : 0
        return (h, s, maxVal)
    }

    private static func greenVal(_ g: Float) -> Float { g }
}
