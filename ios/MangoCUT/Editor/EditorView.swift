import PhotosUI
import SwiftUI

struct EditorView: View {
    @StateObject private var model: EditorModel
    let store: ProjectStore
    let demo: DemoRequest?
    @Environment(\.dismiss) private var dismiss
    @State private var pointsPerSecond: Double = 40
    @State private var timelineWidth: CGFloat = 0
    @State private var mediaItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var isRenaming = false
    @State private var newName = ""

    init(project: ProjectInfo, store: ProjectStore, demo: DemoRequest? = nil) {
        _model = StateObject(wrappedValue: EditorModel(project: project))
        self.store = store
        self.demo = demo
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
            transportBar
            GeometryReader { geometry in
                TimelineView(
                    plan: model.plan,
                    currentUs: model.currentUs,
                    selection: model.selection,
                    pointsPerSecond: pointsPerSecond,
                    onSeek: { model.seek(to: $0) },
                    onSelect: { model.selection = $0 },
                    onTransitionTap: { clip in
                        model.selection = .clip(clip.segmentId)
                        model.sheet = .transition
                    }
                )
                .onAppear { timelineWidth = geometry.size.width }
            }
            .frame(height: 148)
            tools
        }
        .background(Color.capcutDark.ignoresSafeArea())
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(item: $model.sheet) { sheet in
            sheetContent(sheet)
                .presentationDetents(sheet == .export || sheet == .text ? [.large] : [.medium, .large])
        }
        .alert("Renomear Projeto", isPresented: $isRenaming) {
            TextField("Nome", text: $newName)
            Button("Cancelar", role: .cancel) {}
            Button("Salvar") { model.rename(newName) }
        }
        .alert(
            "Aviso",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay {
            if isImporting {
                ProgressView("Importando vídeos…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .task(id: mediaItems) { await importPicked() }
        .task { await prepare() }
        .onDisappear {
            model.close()
            store.reload()
        }
    }

    // MARK: Top Bar (Estilo CapCut com Exportar destacado)

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.capcutCard, in: Circle())
            }

            Button {
                newName = model.name
                isRenaming = true
            } label: {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Badge de proporção do canvas
            Text(canvasRatio)
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.capcutCard)
                .foregroundStyle(Color.capcutCyan)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.capcutBorder, lineWidth: 1))

            // Botão Exportar destacado (estilo CapCut)
            Button {
                model.sheet = .export
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up")
                        .font(.caption.bold())
                    Text("Exportar")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    LinearGradient(
                        colors: [Color.mango, Color.capcutCyan],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundStyle(.black)
                .clipShape(Capsule())
                .shadow(color: Color.mango.opacity(0.3), radius: 6, x: 0, y: 2)
            }
            .disabled(model.plan.clips.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.capcutBar)
    }

    private var canvasRatio: String {
        let w = model.plan.canvas.width
        let h = model.plan.canvas.height
        if w == h { return "1:1" }
        return w > h ? "16:9" : "9:16"
    }

    // MARK: Player Preview

    private var preview: some View {
        ZStack {
            Color.black
            if model.plan.clips.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.gray.opacity(0.5))
                    Text("Adicione vídeos para começar a editar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                PlayerView(player: model.player)
                    .aspectRatio(model.plan.canvas.width / model.plan.canvas.height, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.capcutBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.8), radius: 10, x: 0, y: 4)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlay() }
    }

    // MARK: Transport Bar

    private var transportBar: some View {
        HStack(spacing: 16) {
            Button {
                model.togglePlay()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.capcutCardHover)
                        .frame(width: 34, height: 34)
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .disabled(model.plan.clips.isEmpty)

            HStack(spacing: 4) {
                Text(TimeFormat.clock(model.currentUs))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.white)
                Text("/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(TimeFormat.clock(model.plan.durationUs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Color.capcutCard, in: Circle())
            }
            .disabled(!model.canUndo)

            Button { zoom(by: 0.7) } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 14))
                    .frame(width: 32, height: 32)
                    .background(Color.capcutCard, in: Circle())
            }

            Button { zoom(by: 1.4) } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 14))
                    .frame(width: 32, height: 32)
                    .background(Color.capcutCard, in: Circle())
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.capcutBar)
    }

    // MARK: Bottom Toolbar (Sistema de 2 Níveis do CapCut)

    private var tools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if let clip = model.selectedClip {
                    // Modo de Edição de Clipe Selecionado (CapCut Level 2)
                    ToolButton(title: "Voltar", systemImage: "chevron.backward", accentColor: .secondary) {
                        model.selection = nil
                    }

                    Group {
                        ToolButton(title: "Dividir", systemImage: "scissors", accentColor: .white) { model.split() }
                        ToolButton(title: "Aparar Início", systemImage: "arrow.right.to.line") { model.trim("start") }
                        ToolButton(title: "Aparar Fim", systemImage: "arrow.left.to.line") { model.trim("end") }
                        ToolButton(title: "Estúdio IA", systemImage: "wand.and.stars", accentColor: Color.capcutCyan) {
                            model.sheet = .aiStudio
                        }
                        ToolButton(title: "Velocidade", systemImage: "speedometer", accentColor: Color.capcutYellow) {
                            model.sheet = .speed
                        }
                        ToolButton(title: "Filtros", systemImage: "camera.filters") { model.sheet = .filters }
                    }

                    Group {
                        ToolButton(title: "Efeitos", systemImage: "sparkles", accentColor: Color.capcutPurple) {
                            model.sheet = .effects
                        }
                        ToolButton(
                            title: "Transição",
                            systemImage: "square.on.square",
                            disabled: clip.segmentId == model.plan.clips.last?.segmentId
                        ) { model.sheet = .transition }
                        ToolButton(title: "Para Trás", systemImage: "arrow.left", disabled: model.selectedClipIndex == 0) {
                            model.move(by: -1)
                        }
                        ToolButton(
                            title: "Para Frente",
                            systemImage: "arrow.right",
                            disabled: model.selectedClipIndex == model.plan.clips.count - 1
                        ) { model.move(by: 1) }
                        ToolButton(title: "Excluir", systemImage: "trash", accentColor: Color.red) {
                            model.deleteSelection()
                        }
                    }
                } else if model.selectedText != nil {
                    ToolButton(title: "Voltar", systemImage: "chevron.backward") { model.selection = nil }
                    ToolButton(title: "Editar Texto", systemImage: "pencil", accentColor: Color.mango) { model.sheet = .text }
                    ToolButton(title: "Excluir", systemImage: "trash", accentColor: Color.red) { model.deleteSelection() }
                } else {
                    // Modo Principal (CapCut Level 1)
                    ToolButton(title: "Editar", systemImage: "scissors", accentColor: .white) {
                        if let first = model.plan.clips.first { model.selection = .clip(first.segmentId) }
                    }
                    ToolButton(title: "Estúdio IA", systemImage: "wand.and.stars", accentColor: Color.capcutCyan) {
                        model.sheet = .aiStudio
                    }
                    ToolButton(title: "Templates", systemImage: "rectangle.3.group", accentColor: Color.mango) {
                        model.sheet = .templates
                    }
                    ToolButton(title: "Texto", systemImage: "textformat", accentColor: Color.capcutYellow) {
                        model.addText()
                    }
                    ToolButton(title: "Filtros", systemImage: "camera.filters") { model.sheet = .filters }
                    ToolButton(title: "Efeitos", systemImage: "sparkles", accentColor: Color.capcutPurple) { model.sheet = .effects }

                    PhotosPicker(selection: $mediaItems, matching: .videos) {
                        ToolLabel(title: "Mídia", systemImage: "plus.rectangle.on.rectangle", accentColor: Color.capcutCyan)
                    }
                    .buttonStyle(.plain)

                    ToolButton(title: "Ajustar", systemImage: "arrow.left.and.right") { fitTimeline() }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(height: 84)
        .background(Color.capcutBar)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: EditorSheet) -> some View {
        switch sheet {
        case .filters: FilterSheet(model: model)
        case .effects: EffectsSheet(model: model)
        case .speed: SpeedSheet(model: model)
        case .transition: TransitionSheet(model: model)
        case .text: TextSheet(model: model)
        case .export: ExportSheet(model: model)
        case .aiStudio: AIStudioSheet(model: model)
        case .templates: TemplatesSheet(model: model)
        }
    }

    // MARK: Ações

    private func zoom(by factor: Double) {
        pointsPerSecond = min(max(pointsPerSecond * factor, 6), 400)
    }

    private func fitTimeline() {
        let seconds = model.plan.durationUs / 1_000_000
        guard seconds > 0 else { return }
        let width = timelineWidth > 0 ? timelineWidth : 360
        pointsPerSecond = min(max(Double(width - 64) / seconds, 6), 400)
    }

    private func importPicked() async {
        guard !mediaItems.isEmpty else { return }
        isImporting = true
        defer {
            isImporting = false
            mediaItems = []
        }
        var urls: [URL] = []
        for item in mediaItems {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                urls.append(movie.url)
            }
        }
        await model.addMedia(urls)
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
        fitTimeline()
    }

    private func prepare() async {
        fitTimeline()
        guard let demo else { return }
        try? await Task.sleep(nanoseconds: 800_000_000)
        demo.apply(to: model)
    }
}

struct ToolLabel: View {
    let title: String
    let systemImage: String
    var accentColor: Color? = nil
    var disabled = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.capcutCardHover)
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.capcutBorder.opacity(0.8), lineWidth: 1)
                    )

                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(disabled ? Color.gray.opacity(0.5) : (accentColor ?? .white))
            }

            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(disabled ? Color.gray.opacity(0.5) : Color.white.opacity(0.9))
        }
        .frame(width: 62)
        .padding(.vertical, 2)
    }
}

struct ToolButton: View {
    let title: String
    let systemImage: String
    var accentColor: Color? = nil
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolLabel(title: title, systemImage: systemImage, accentColor: accentColor, disabled: disabled)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
