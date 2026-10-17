import CoreImage

/// Filtros e Shaders de Cor do MangoCUT.
/// Inspirado no EffectSDK do CapCut (~120 MB de shaders pré-compilados), implementado
/// de forma elegante e limpa através de pipelines Metal do Core Image com interpolação de intensidade.
enum MangoFilters {
    struct Info: Identifiable, Hashable {
        let id: String
        let name: String
        let category: String
    }

    static let all: [Info] = [
        Info(id: "noir", name: "P&B", category: "Monocromático"),
        Info(id: "vintage", name: "Vintage", category: "Retrô"),
        Info(id: "warm", name: "Quente", category: "Tons Naturais"),
        Info(id: "cool", name: "Frio", category: "Tons Naturais"),
        Info(id: "vivid", name: "Vívido", category: "Cores"),
        Info(id: "contrast", name: "Contraste", category: "Cores"),
        Info(id: "tealOrange", name: "Teal & Orange", category: "Cinematográfico"),
        Info(id: "cyberpunk", name: "Cyberpunk", category: "Criativo"),
        Info(id: "vhsRetro", name: "VHS 90s", category: "Retrô"),
        Info(id: "monochromeRed", name: "Noir Drama", category: "Cinematográfico"),
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
        case "tealOrange":
            // Estilo blockbuster: sombras frias (ciano) e realces quentes (laranja)
            filtered = image
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.2,
                    kCIInputSaturationKey: 1.25,
                ])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.15, y: 0, z: -0.05, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.98, z: 0.05, w: 0),
                    "inputBVector": CIVector(x: -0.1, y: 0.05, z: 1.15, w: 0),
                ])
        case "cyberpunk":
            // Duo-tone neon ciano e magenta com alto contraste
            filtered = image
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.35,
                    kCIInputSaturationKey: 1.45,
                ])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.25, y: 0, z: 0.20, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.70, z: 0.10, w: 0),
                    "inputBVector": CIVector(x: 0.20, y: 0.10, z: 1.35, w: 0),
                ])
        case "vhsRetro":
            // Visual analógico VHS anos 90 com leve saturação e aberração térmica
            filtered = image
                .applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.30])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.8])
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.7, kCIInputRadiusKey: 1.8])
        case "monochromeRed":
            // P&B com curvas profundas e sombras dramáticas
            filtered = image
                .applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.4])
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 1.0, kCIInputRadiusKey: 1.4])
        default:
            return image
        }

        let result = filtered.cropped(to: extent)
        let amount = min(max(intensity, 0), 1)
        if amount >= 0.999 { return result }
        return image
            .applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: result,
                kCIInputTimeKey: amount,
            ])
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
