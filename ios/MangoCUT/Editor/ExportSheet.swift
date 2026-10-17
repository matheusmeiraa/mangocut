import Photos
import SwiftUI

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @State private var shortSide = 1080
    @State private var codec = Exporter.Codec.hevc
    @State private var progress = 0.0
    @State private var phase = Phase.idle
    @State private var savedToPhotos = false
    @State private var photosMessage: String?

    enum Phase: Equatable {
        case idle
        case exporting
        case done(URL)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Qualidade e Resolução") {
                    Picker("Resolução", selection: $shortSide) {
                        Text("720p (HD)").tag(720)
                        Text("1080p (Full HD)").tag(1080)
                        Text("4K (Ultra HD)").tag(2160)
                    }
                    .pickerStyle(.segmented)
                    .disabled(phase == .exporting)

                    let size = Exporter.renderSize(for: model.plan, shortSide: shortSide)
                    LabeledContent("Dimensões", value: "\(Int(size.width))×\(Int(size.height))")
                    LabeledContent("Duração", value: TimeFormat.clock(model.plan.durationUs))
                }

                Section("Codec de Vídeo") {
                    Picker("Formato", selection: $codec) {
                        ForEach(Exporter.Codec.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(phase == .exporting)
                } footer: {
                    Text(codec == .hevc ? "HEVC economiza até 50% de espaço com alta fidelidade visual no iPhone." : "H.264 tem compatibilidade máxima com computadores e navegadores antigos.")
                }

                Section {
                    switch phase {
                    case .idle:
                        Button {
                            start()
                        } label: {
                            Label("Exportar vídeo agora", systemImage: "film")
                                .font(.headline)
                        }
                    case .exporting:
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress) {
                                HStack {
                                    Text("Renderizando…")
                                    Spacer()
                                    Text("\(Int(progress * 100))%")
                                        .font(.caption.monospacedDigit())
                                }
                            }
                            Text("Processando efeitos, shaders e IA nativa…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    case .done(let url):
                        Label("Vídeo exportado com sucesso!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button {
                            saveToPhotos(url)
                        } label: {
                            Label(savedToPhotos ? "Salvo na Fototeca" : "Salvar na Fototeca", systemImage: "photo.on.rectangle")
                        }
                        .disabled(savedToPhotos)
                        ShareLink(item: url) {
                            Label("Compartilhar", systemImage: "square.and.arrow.up")
                        }
                        if let photosMessage {
                            Text(photosMessage).font(.footnote).foregroundStyle(.secondary)
                        }
                    case .failed(let message):
                        Text(message).foregroundStyle(.red)
                        Button("Tentar de novo") { start() }
                    }
                }

                if !model.plan.warnings.isEmpty {
                    Section("Avisos") {
                        ForEach(model.plan.warnings, id: \.self) { Text($0).font(.footnote) }
                    }
                }
            }
            .navigationTitle("Exportar Vídeo")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fechar") { model.sheet = nil }
                        .disabled(phase == .exporting)
                }
            }
        }
    }

    private func start() {
        phase = .exporting
        progress = 0
        savedToPhotos = false
        photosMessage = nil
        let plan = model.plan
        let project = model.project
        let side = shortSide
        let selectedCodec = codec
        let fileName = model.name.replacingOccurrences(of: "/", with: "-")
        Task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileName).mp4")
            do {
                try await Exporter.export(
                    plan: plan,
                    resolve: project.resolve,
                    shortSide: side,
                    codec: selectedCodec,
                    to: url
                ) { value in
                    Task { @MainActor in progress = value }
                }
                phase = .done(url)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in photosMessage = "Sem permissão para salvar na Fototeca. Libere em Ajustes > MangoCUT." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }) { success, error in
                Task { @MainActor in
                    if success {
                        savedToPhotos = true
                    } else {
                        photosMessage = error?.localizedDescription ?? "Não foi possível salvar."
                    }
                }
            }
        }
    }
}
