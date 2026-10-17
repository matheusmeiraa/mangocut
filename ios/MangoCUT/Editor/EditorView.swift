import PhotosUI
import SwiftUI

struct EditorView: View {
    @StateObject private var model: EditorModel
    let store: ProjectStore
    let demo: DemoRequest?
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
            preview
            transportBar
            GeometryReader { geometry in
                TimelineView(
                    plan: model.plan,
                    currentUs: model.currentUs,
                    selection: model.selection,
                    pointsPerSecond: pointsPerSecond,
                    onSeek: { model.seek(to: $0) },
                    onSelect: { model.selection = $0 }
                )
                .onAppear { timelineWidth = geometry.size.width }
            }
            .frame(height: 140)
            tools
        }
        .background(Color.black)
        .navigationTitle(model.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.sheet = .export
                } label: {
                    Label("Exportar", systemImage: "square.and.arrow.up")
                }
                .disabled(model.plan.clips.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newName = model.name
                    isRenaming = true
                } label: {
                    Label("Renomear", systemImage: "pencil")
                }
            }
        }
        .sheet(item: $model.sheet) { sheet in
            sheetContent(sheet)
                .presentationDetents(sheet == .export || sheet == .text ? [.large] : [.medium, .large])
        }
        .alert("Renomear projeto", isPresented: $isRenaming) {
            TextField("Nome", text: $newName)
            Button("Cancelar", role: .cancel) {}
            Button("Salvar") { model.rename(newName) }
        }
        .alert(
            "Não deu certo",
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

    // MARK: Partes da tela

    private var preview: some View {
        ZStack {
            Color.black
            if model.plan.clips.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 40))
                    Text("Adicione vídeos em Mídia para começar")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            } else {
                PlayerView(player: model.player)
                    .aspectRatio(model.plan.canvas.width / model.plan.canvas.height, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlay() }
    }

    private var transportBar: some View {
        HStack(spacing: 18) {
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 28)
            }
            .disabled(model.plan.clips.isEmpty)
            Text("\(TimeFormat.clock(model.currentUs)) / \(TimeFormat.clock(model.plan.durationUs))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
            Button { zoom(by: 0.7) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoom(by: 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.06))
    }

    private var tools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if let clip = model.selectedClip {
                    ToolButton(title: "Dividir", systemImage: "scissors") { model.split() }
                    ToolButton(title: "Aparar início", systemImage: "arrow.right.to.line") { model.trim("start") }
                    ToolButton(title: "Aparar fim", systemImage: "arrow.left.to.line") { model.trim("end") }
                    ToolButton(title: "Velocidade", systemImage: "speedometer") { model.sheet = .speed }
                    ToolButton(title: "Filtros", systemImage: "camera.filters") { model.sheet = .filters }
                    ToolButton(title: "Efeitos", systemImage: "sparkles") { model.sheet = .effects }
                    ToolButton(
                        title: "Transição",
                        systemImage: "square.on.square",
                        disabled: clip.segmentId == model.plan.clips.last?.segmentId
                    ) { model.sheet = .transition }
                    ToolButton(title: "Para trás", systemImage: "arrow.left", disabled: model.selectedClipIndex == 0) {
                        model.move(by: -1)
                    }
                    ToolButton(
                        title: "Para frente",
                        systemImage: "arrow.right",
                        disabled: model.selectedClipIndex == model.plan.clips.count - 1
                    ) { model.move(by: 1) }
                    ToolButton(title: "Excluir", systemImage: "trash") { model.deleteSelection() }
                } else if model.selectedText != nil {
                    ToolButton(title: "Editar", systemImage: "pencil") { model.sheet = .text }
                    ToolButton(title: "Excluir", systemImage: "trash") { model.deleteSelection() }
                } else {
                    PhotosPicker(selection: $mediaItems, matching: .videos) {
                        ToolLabel(title: "Mídia", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .buttonStyle(.plain)
                    ToolButton(title: "Texto", systemImage: "textformat") { model.addText() }
                    ToolButton(title: "Ajustar", systemImage: "arrow.left.and.right") { fitTimeline() }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 74)
        .background(Color(white: 0.06))
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
    var disabled = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
            Text(title)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .frame(width: 70, height: 58)
        .foregroundStyle(disabled ? Color.gray : Color.white)
    }
}

struct ToolButton: View {
    let title: String
    let systemImage: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolLabel(title: title, systemImage: systemImage, disabled: disabled)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
