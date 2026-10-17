import CoreImage

/// Filtros do MangoCUT, montados com filtros embutidos do Core Image e ajustes próprios.
enum MangoFilters {
    struct Info: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static let all: [Info] = [
        Info(id: "noir", name: "P&B"),
        Info(id: "vintage", name: "Vintage"),
        Info(id: "warm", name: "Quente"),
        Info(id: "cool", name: "Frio"),
        Info(id: "vivid", name: "Vívido"),
        Info(id: "contrast", name: "Contraste"),
    ]

    static func name(of id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }

    /// Aplica o filtro com intensidade de 0 a 1. Um id desconhecido devolve a imagem intacta.
    static func apply(_ id: String, intensity: Double, to image: CIImage) -> CIImage {
        let extent = image.extent
        let filtered: CIImage
        switch id {
        case "noir":
            filtered = image.applyingFilter("CIPhotoEffectNoir")
        case "vintage":
            filtered = image
                .applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.55])
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.9, kCIInputRadiusKey: 1.6])
        case "warm":
            filtered = channelGains(image, red: 1.10, green: 1.02, blue: 0.84)
        case "cool":
            filtered = channelGains(image, red: 0.86, green: 1.0, blue: 1.12)
        case "vivid":
            filtered = image
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.9])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25])
        case "contrast":
            filtered = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.35])
        default:
            return image
        }
        let result = filtered.cropped(to: extent)
        let amount = min(max(intensity, 0), 1)
        if amount >= 0.999 { return result }
        return image
            .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: result, kCIInputTimeKey: amount])
            .cropped(to: extent)
    }

    private static func channelGains(_ image: CIImage, red: CGFloat, green: CGFloat, blue: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: red, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: green, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: blue, w: 0),
        ])
    }
}
