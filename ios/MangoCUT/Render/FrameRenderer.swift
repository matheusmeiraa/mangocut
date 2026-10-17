import CoreImage

/// Monta um quadro do vídeo: encaixa cada clipe no canvas, aplica efeitos e filtro, faz a
/// transição entre dois clipes e desenha os textos por cima. O mesmo código serve ao player e à exportação.
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
            // Com quadros vindos do decodificador, o Core Image funde as etapas e repete a borda do
            // clipe com barras pretas por cima delas. Um intermediário por camada evita isso.
            frame = frames[0]
                .insertingIntermediate(cache: false)
                .applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: frames[1].insertingIntermediate(cache: false),
                    kCIInputTimeKey: progress,
                ])
                .cropped(to: canvas)
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
        if let filter = clip.filter {
            frame = MangoFilters.apply(filter.id, intensity: filter.intensity, to: frame)
        }
        if clip.effects.contains("blur") {
            frame = frame
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: canvas.height * 0.012])
                .cropped(to: canvas)
        }

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

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
