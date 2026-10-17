import AVFoundation
import CoreImage
import SwiftUI

private extension View {
    /// Botão "OK" comum às folhas do editor.
    @MainActor
    func sheetDoneButton(_ model: EditorModel) -> some View {
        toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") { model.sheet = nil }
            }
        }
    }
}

// MARK: Filtros

/// Quadro do meio do clipe com cada filtro aplicado, para escolher vendo o resultado.
enum FilterPreviews {
    private static let context = CIContext()

    static func make(for clip: RenderPlan.Clip, url: URL) async -> [String: CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let time = CMTime(microseconds: clip.sourceStartUs + clip.sourceDurationUs / 2)
        guard let frame = try? await generator.image(at: time).image else { return [:] }
        let source = CIImage(cgImage: frame)
        var result: [String: CGImage] = ["": frame]
        for filter in MangoFilters.all {
            let filtered = MangoFilters.apply(filter.id, intensity: 1, to: source)
            if let image = context.createCGImage(filtered, from: source.extent) {
                result[filter.id] = image
            }
        }
        return result
    }
}

struct FilterSheet: View {
    @ObservedObject var model: EditorModel
    @State private var previews: [String: CGImage] = [:]
    @State private var intensity: Double = 1

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if let clip = model.selectedClip {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            tile(id: nil, name: "Nenhum", current: clip.filter?.id)
                            ForEach(MangoFilters.all) { filter in
                                tile(id: filter.id, name: filter.name, current: clip.filter?.id)
                            }
                        }
                        .padding(.horizontal)
                    }
                    if let filter = clip.filter {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Intensidade: \(Int((intensity * 100).rounded()))%")
                                .font(.subheadline)
                            Slider(value: $intensity, in: 0...1) { editing in
                                if !editing { model.setFilter(filter.id, intensity: intensity) }
                            }
                        }
                        .padding(.horizontal)
                    }
                } else {
                    Text("Selecione um clipe na timeline.").foregroundStyle(.secondary).padding()
                }
                Spacer()
            }
            .padding(.top, 8)
            .navigationTitle("Filtros")
            .sheetDoneButton(model)
            .task(id: model.selectedClip?.segmentId) {
                guard let clip = model.selectedClip else { return }
                intensity = clip.filter?.intensity ?? 1
                if let url = model.project.resolve(clip) {
                    previews = await FilterPreviews.make(for: clip, url: url)
                }
            }
        }
    }

    private func tile(id: String?, name: String, current: String?) -> some View {
        let selected = id == current
        return Button {
            intensity = 1
            model.setFilter(id)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.2))
                    if let image = previews[id ?? ""] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: 76, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.mango : Color.clear, lineWidth: 3)
                }
                Text(name)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.mango : Color.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Efeitos

struct EffectsSheet: View {
    @ObservedObject var model: EditorModel

    private struct Effect: Identifiable {
        let id: String
        let name: String
        let systemImage: String
    }

    private static let motionEffects = [
        Effect(id: "zoomIn", name: "Zoom de aproximação", systemImage: "plus.magnifyingglass"),
        Effect(id: "zoomOut", name: "Zoom de afastamento", systemImage: "minus.magnifyingglass"),
        Effect(id: "fadeIn", name: "Surgir do preto", systemImage: "sunrise"),
        Effect(id: "fadeOut", name: "Sumir no preto", systemImage: "sunset"),
    ]

    private static let shaderEffects = [
        Effect(id: "blur", name: "Desfoque gaussiano", systemImage: "drop"),
        Effect(id: "vignette", name: "Vinheta cinematográfica", systemImage: "circle.dashed"),
        Effect(id: "filmGrain", name: "Granulação de película 35mm", systemImage: "circle.grid.cross"),
        Effect(id: "glitch", name: "Glitch RGB / Aberração", systemImage: "waveform.path.badge.plus"),
        Effect(id: "bloom", name: "Glow / Brilho suave", systemImage: "sun.max"),
        Effect(id: "comic", name: "Estilo Quadrinhos", systemImage: "paintpalette"),
    ]

    private static let aiEffects = [
        Effect(id: "aiCutout", name: "Recorte de Pessoa (IA Vision)", systemImage: "person.crop.rectangle.stack"),
        Effect(id: "portraitBlur", name: "Desfoque de Retrato (IA Vision)", systemImage: "camera.macro"),
        Effect(id: "chromaKey", name: "Chroma Key (Tela Verde)", systemImage: "square.inset.filled"),
    ]

    var body: some View {
        NavigationStack {
            List {
                if let clip = model.selectedClip {
                    Section("Inteligência Artificial (Apple Neural Engine)") {
                        ForEach(Self.aiEffects) { effect in
                            toggleRow(clip: clip, effect: effect)
                        }
                    }

                    Section("Shaders Gráficos e Texturas (EffectSDK)") {
                        ForEach(Self.shaderEffects) { effect in
                            toggleRow(clip: clip, effect: effect)
                        }
                    }

                    Section("Movimento e Fades") {
                        ForEach(Self.motionEffects) { effect in
                            toggleRow(clip: clip, effect: effect)
                        }
                    }
                } else {
                    Text("Selecione um clipe na timeline.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Efeitos e Shaders")
            .sheetDoneButton(model)
        }
    }

    private func toggleRow(clip: RenderPlan.Clip, effect: Effect) -> some View {
        Toggle(isOn: Binding(
            get: { clip.effects.contains(effect.id) },
            set: { model.toggleEffect(effect.id, on: $0) }
        )) {
            Label(effect.name, systemImage: effect.systemImage)
        }
    }
}

// MARK: Velocidade

struct SpeedSheet: View {
    @ObservedObject var model: EditorModel
    private static let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 4]

    var body: some View {
        NavigationStack {
            Form {
                if let clip = model.selectedClip {
                    Section {
                        Picker("Velocidade", selection: Binding(get: { clip.speed }, set: { model.setSpeed($0) })) {
                            ForEach(Self.speeds, id: \.self) { speed in
                                Text(TimelineView.speedLabel(speed)).tag(speed)
                            }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text("Duração no projeto: \(TimeFormat.clock(clip.timelineDurationUs)). O áudio acompanha a velocidade.")
                    }
                }
            }
            .navigationTitle("Velocidade")
            .sheetDoneButton(model)
        }
    }
}

// MARK: Transição

struct TransitionSheet: View {
    @ObservedObject var model: EditorModel
    private static let durations: [Double] = [300_000, 500_000, 1_000_000]

    private struct KindOption: Identifiable {
        let id: String
        let name: String
    }

    private static let kinds = [
        KindOption(id: "none", name: "Nenhuma"),
        KindOption(id: "dissolve", name: "Dissolver"),
        KindOption(id: "slideLeft", name: "Deslizar Esq."),
        KindOption(id: "slideRight", name: "Deslizar Dir."),
        KindOption(id: "zoomIn", name: "Zoom In"),
        KindOption(id: "flashWhite", name: "Flash Branco"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                if let clip = model.selectedClip {
                    let current = clip.transitionOut
                    Section("Transição para o próximo clipe") {
                        Picker("Tipo", selection: Binding(
                            get: { current?.kind ?? "none" },
                            set: { model.setTransition(kind: $0 == "none" ? nil : $0, durationUs: current?.durationUs ?? 500_000) }
                        )) {
                            ForEach(Self.kinds) { option in
                                Text(option.name).tag(option.id)
                            }
                        }
                    }
                    if let current {
                        Section {
                            Picker("Duração", selection: Binding(
                                get: { Self.durations.min { abs($0 - current.durationUs) < abs($1 - current.durationUs) } ?? 500_000 },
                                set: { model.setTransition(kind: current.kind, durationUs: $0) }
                            )) {
                                ForEach(Self.durations, id: \.self) { duration in
                                    Text("\((duration / 1_000_000).decimalText(1)) s").tag(duration)
                                }
                            }
                            .pickerStyle(.segmented)
                        } footer: {
                            Text("A transição sobrepõe o fim deste clipe e o começo do próximo de forma contínua.")
                        }
                    }
                }
            }
            .navigationTitle("Transições")
            .sheetDoneButton(model)
        }
    }
}

// MARK: Texto

struct TextSheet: View {
    @ObservedObject var model: EditorModel
    @State private var text = ""
    @State private var font = "system"
    @State private var size = 0.07
    @State private var color = "#FFFFFF"
    @State private var y = 0.8
    @State private var background = false
    @State private var durationSeconds = 3.0
    @State private var loadedId: String?

    private static let colors = ["#FFFFFF", "#FFD60A", "#FF8A00", "#FF375F", "#64D2FF", "#30D158", "#BF5AF2", "#000000"]
    private static let fonts = [("system", "Sistema"), ("rounded", "Arredondada"), ("serif", "Serifada"), ("mono", "Mono")]

    var body: some View {
        NavigationStack {
            Form {
                if let overlay = model.selectedText {
                    Section("Texto") {
                        TextField("Digite o texto", text: $text, axis: .vertical)
                            .lineLimit(1...4)
                    }
                    Section("Estilo") {
                        Picker("Fonte", selection: $font) {
                            ForEach(Self.fonts, id: \.0) { id, name in
                                Text(name).tag(id)
                            }
                        }
                        VStack(alignment: .leading) {
                            Text("Tamanho")
                            Slider(value: $size, in: 0.03...0.15)
                        }
                        HStack(spacing: 10) {
                            ForEach(Self.colors, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        Circle().stroke(color == hex ? Color.mango : Color.gray.opacity(0.5), lineWidth: color == hex ? 3 : 1)
                                    }
                                    .onTapGesture { color = hex }
                            }
                        }
                        Toggle("Fundo escuro", isOn: $background)
                    }
                    Section("Posição") {
                        Picker("Posição", selection: $y) {
                            Text("Topo").tag(0.15)
                            Text("Centro").tag(0.5)
                            Text("Base").tag(0.8)
                        }
                        .pickerStyle(.segmented)
                    }
                    Section("Tempo") {
                        Stepper(value: $durationSeconds, in: 0.5...60, step: 0.5) {
                            Text("Duração: \(durationSeconds.decimalText(1)) s")
                        }
                        Text("Começa em \(TimeFormat.clock(overlay.startUs))")
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Excluir texto", role: .destructive) {
                            model.deleteSelection()
                            model.sheet = nil
                        }
                    }
                }
            }
            .navigationTitle("Texto")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { model.sheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar") { apply() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let overlay = model.selectedText, loadedId != overlay.id else { return }
        loadedId = overlay.id
        text = overlay.text
        font = overlay.font
        size = overlay.size
        color = overlay.color
        y = [0.15, 0.5, 0.8].min { abs($0 - overlay.y) < abs($1 - overlay.y) } ?? 0.8
        background = overlay.background
        durationSeconds = overlay.durationUs / 1_000_000
    }

    private func apply() {
        guard let overlay = model.selectedText else { return }
        model.updateText(id: overlay.id, fields: [
            "text": text,
            "font": font,
            "size": size,
            "color": color,
            "y": y,
            "background": background,
            "durationUs": durationSeconds * 1_000_000,
        ])
        model.sheet = nil
    }
}
