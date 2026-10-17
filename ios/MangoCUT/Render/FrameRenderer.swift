import CoreImage

/// Monta um quadro do vídeo: encaixa cada clipe no canvas, aplica efeitos avançados e filtros,
/// faz a transição entre dois clipes (dissolve, slide, zoom, flash) e desenha os textos por cima.
/// O mesmo código serve ao player e à exportação.
enum FrameRenderer {
    struct Layer {
        let clip: RenderPlan.Clip
        let image: CIImage?
        let orientation: CGImagePropertyOrientation
    }

    /// Duração do fade de entrada e de saída.
    static let fadeUs = 500_000.0

    static func render(
        layers: [Layer],
        timeUs: Double,
        texts: [RenderPlan.Text],
        rasterizer: TextRasterizer,
        size: CGSize
    ) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
        let frames = layers.map { clipFrame($0, timeUs: timeUs, canvas: canvas, background: black) }

        var frame = black
        if frames.count == 1 {
            frame = frames[0]
        } else if frames.count >= 2 {
            let incoming = layers[1].clip
            let length = max(incoming.transitionIn?.durationUs ?? 1, 1)
            let progress = clamp((timeUs - incoming.timelineStartUs) / length)
            let kind = incoming.transitionIn?.kind ?? "dissolve"
            frame = renderTransition(kind: kind, progress: progress, from: frames[0], to: frames[1], canvas: canvas)
        }

        for text in texts where timeUs >= text.startUs && timeUs < text.endUs {
            if let overlay = rasterizer.image(for: text, canvas: size) {
                frame = overlay.composited(over: frame)
            }
        }
        return frame.cropped(to: canvas)
    }

    static func clipFrame(_ layer: Layer, timeUs: Double, canvas: CGRect, background: CIImage) -> CIImage {
        guard let source = layer.image else { return background }
        let clip = layer.clip
        var image = source.oriented(layer.orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let width = image.extent.width
        let height = image.extent.height
        guard width > 0, height > 0 else { return background }

        // Encaixa sem cortar, centralizado (barras pretas quando a proporção é outra)
        let scale = min(canvas.width / width, canvas.height / height)
        var transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(
                translationX: (canvas.width - width * scale) / 2,
                y: (canvas.height - height * scale) / 2
            ))

        let local = timeUs - clip.timelineStartUs
        let progress = clamp(local / max(clip.timelineDurationUs, 1))
        let eased = CGFloat(progress * progress * (3 - 2 * progress))
        var zoom: CGFloat = 1
        if clip.effects.contains("zoomIn") {
            zoom = 1 + 0.15 * eased
        } else if clip.effects.contains("zoomOut") {
            zoom = 1.15 - 0.15 * eased
        }
        if zoom != 1 {
            transform = transform
                .concatenating(CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY))
                .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                .concatenating(CGAffineTransform(translationX: canvas.midX, y: canvas.midY))
        }

        var frame = image.transformed(by: transform).composited(over: background).cropped(to: canvas)

        // 1. Recorte Inteligente de IA (Vision) ou Chroma Key
        if clip.effects.contains("aiCutout") {
            frame = AIPersonSegmentation.shared.cutout(image: frame, background: background)
        } else if clip.effects.contains("portraitBlur") {
            frame = AIPersonSegmentation.shared.portraitBlur(image: frame, blurRadius: canvas.height * 0.02)
        } else if clip.effects.contains("chromaKey") {
            frame = ChromaKeyFilter.apply(to: frame, color: .green, background: background)
        }

        // 2. Filtro de Cor / LUT
        if let filter = clip.filter {
            frame = MangoFilters.apply(filter.id, intensity: filter.intensity, to: frame)
        }

        // 3. Efeitos de Shaders e Textura (EffectSDK clean-room)
        if clip.effects.contains("blur") {
            frame = frame
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: canvas.height * 0.015])
                .cropped(to: canvas)
        }

        if clip.effects.contains("bloom") {
            frame = frame
                .applyingFilter("CIBloom", parameters: [
                    "inputRadius": canvas.height * 0.02,
                    "inputIntensity": 0.8,
                ])
                .cropped(to: canvas)
        }

        if clip.effects.contains("vignette") {
            frame = frame
                .applyingFilter("CIVignette", parameters: [
                    kCIInputIntensityKey: 1.4,
                    kCIInputRadiusKey: 1.6,
                ])
                .cropped(to: canvas)
        }

        if clip.effects.contains("glitch") {
            frame = applyGlitch(frame, canvas: canvas, progress: progress)
        }

        if clip.effects.contains("filmGrain") {
            frame = applyFilmGrain(frame, canvas: canvas)
        }

        if clip.effects.contains("comic") {
            frame = frame.applyingFilter("CIComicEffect").cropped(to: canvas)
        }

        // 4. Fade de entrada e saída
        var brightness = 1.0
        if clip.effects.contains("fadeIn") { brightness = min(brightness, local / fadeUs) }
        if clip.effects.contains("fadeOut") { brightness = min(brightness, (clip.timelineDurationUs - local) / fadeUs) }
        brightness = clamp(brightness)
        if brightness < 0.999 {
            // O Core Image trabalha em luz linear; elevar a 2,2 faz o fade parecer uniforme na tela.
            let b = CGFloat(pow(brightness, 2.2))
            frame = frame.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: b, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: b, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            ])
        }
        return frame
    }

    /// Renderizador de transições cinematográficas entre dois quadros.
    private static func renderTransition(
        kind: String,
        progress: Double,
        from frameA: CIImage,
        to frameB: CIImage,
        canvas: CGRect
    ) -> CIImage {
        let t = CGFloat(progress)
        switch kind {
        case "slideLeft":
            let offsetA = -canvas.width * t
            let offsetB = canvas.width * (1 - t)
            let movedA = frameA.transformed(by: CGAffineTransform(translationX: offsetA, y: 0))
            let movedB = frameB.transformed(by: CGAffineTransform(translationX: offsetB, y: 0))
            return movedB.composited(over: movedA).cropped(to: canvas)

        case "slideRight":
            let offsetA = canvas.width * t
            let offsetB = -canvas.width * (1 - t)
            let movedA = frameA.transformed(by: CGAffineTransform(translationX: offsetA, y: 0))
            let movedB = frameB.transformed(by: CGAffineTransform(translationX: offsetB, y: 0))
            return movedB.composited(over: movedA).cropped(to: canvas)

        case "zoomIn":
            let scaleB = 0.5 + 0.5 * t
            let scaledB = frameB
                .transformed(by: CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY))
                .transformed(by: CGAffineTransform(scaleX: scaleB, y: scaleB))
                .transformed(by: CGAffineTransform(translationX: canvas.midX, y: canvas.midY))
            return frameA
                .applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: scaledB,
                    kCIInputTimeKey: t,
                ])
                .cropped(to: canvas)

        case "flashWhite":
            let peak = 1 - abs(t - 0.5) * 2 // 0 no início, 1 no meio, 0 no fim
            let base = t < 0.5 ? frameA : frameB
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: canvas)
            return base
                .applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: white,
                    kCIInputTimeKey: peak,
                ])
                .cropped(to: canvas)

        case "dissolve":
            fallthrough
        default:
            return frameA
                .insertingIntermediate(cache: false)
                .applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: frameB.insertingIntermediate(cache: false),
                    kCIInputTimeKey: progress,
                ])
                .cropped(to: canvas)
        }
    }

    /// Efeito Glitch / Aberração cromática com separação suave de canais RGB.
    private static func applyGlitch(_ image: CIImage, canvas: CGRect, progress: Double) -> CIImage {
        let shift: CGFloat = 8.0 * (1 + CGFloat(sin(progress * 20)))
        let redShifted = image.transformed(by: CGAffineTransform(translationX: shift, y: 0))
        let blueShifted = image.transformed(by: CGAffineTransform(translationX: -shift, y: 0))

        let redChannel = redShifted.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        let greenChannel = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        let blueChannel = blueShifted.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
        ])

        return redChannel
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: greenChannel])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blueChannel])
            .cropped(to: canvas)
    }

    /// Granulação de película analógica 35mm cinematográfica.
    private static func applyFilmGrain(_ image: CIImage, canvas: CGRect) -> CIImage {
        let noise = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: canvas)
            .applyingFilter("CIRandomGenerator")
            .cropped(to: canvas)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.5,
            ])

        return image
            .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: noise])
            .cropped(to: canvas)
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
