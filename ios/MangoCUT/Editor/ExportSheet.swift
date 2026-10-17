import Photos
import SwiftUI

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @State private var shortSide = 1080
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
                Section("Resolução") {
                    Picker("Resolução", selection: $shortSide) {
                        Text("720p").tag(720)
                        Text("1080p").tag(1080)
                    }
                    .pickerStyle(.segmented)
                    .disabled(phase == .exporting)
                    let size = Exporter.renderSize(for: model.plan, shortSide: shortSide)
                    LabeledContent("Tamanho", value: "\(Int(size.width))×\(Int(size.height))")
                    LabeledContent("Duração", value: TimeFormat.clock(model.plan.durationUs))
                }

                Section {
                    switch phase {
                    case .idle:
                        Button {
                            start()
                        } label: {
                            Label("Exportar vídeo", systemImage: "film")
                        }
                    case .exporting:
                        ProgressView(value: progress) {
                            Text("Renderizando… \(Int(progress * 100))%")
                        }
                    case .done(let url):
                        Label("Vídeo pronto", systemImage: "checkmark.circle.fill")
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
            .navigationTitle("Exportar")
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
        let fileName = model.name.replacingOccurrences(of: "/", with: "-")
        Task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileName).mp4")
            do {
                try await Exporter.export(plan: plan, resolve: project.resolve, shortSide: side, to: url) { value in
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
