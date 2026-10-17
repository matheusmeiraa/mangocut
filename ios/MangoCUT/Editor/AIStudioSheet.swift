import SwiftUI

/// Estúdio de Inteligência Artificial do MangoCUT.
/// Substitui os ~180 MB de modelos proprietários do ByteNN com pipelines 100% limpas,
/// nativas e aceleradas pelo Apple Neural Engine (ANE) via Vision e Speech frameworks.
struct AIStudioSheet: View {
    @ObservedObject var model: EditorModel
    @State private var isTranscribing = false
    @State private var transcriptionResult: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "wand.and.stars")
                                .font(.title2)
                                .foregroundStyle(Color.mango)
                            Text("IA Nativa no Dispositivo")
                                .font(.headline)
                        }
                        Text("Processamento neural acelerado pelo hardware do iPhone (Apple Neural Engine). Totalmente privado e offline.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Legendas Automáticas (IA Speech)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transcreve a fala do vídeo e cria legendas sincronizadas palavra por palavra na timeline automaticamente.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if isTranscribing {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Ouvindo e transcrevendo fala com IA…")
                                    .font(.subheadline)
                            }
                            .padding(.vertical, 4)
                        } else {
                            Button {
                                generateCaptions()
                            } label: {
                                Label("Gerar legendas automáticas agora", systemImage: "captions.bubble.fill")
                                    .font(.subheadline.bold())
                            }
                            .disabled(model.plan.clips.isEmpty)
                        }

                        if let result = transcriptionResult {
                            Label(result, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section("Recorte de Fundo e Câmera (IA Vision)") {
                    if let clip = model.selectedClip {
                        Toggle(isOn: Binding(
                            get: { clip.effects.contains("aiCutout") },
                            set: { model.toggleEffect("aiCutout", on: $0) }
                        )) {
                            Label("Recorte de Pessoa (Sem Fundo Verde)", systemImage: "person.crop.rectangle.stack")
                        }

                        Toggle(isOn: Binding(
                            get: { clip.effects.contains("portraitBlur") },
                            set: { model.toggleEffect("portraitBlur", on: $0) }
                        )) {
                            Label("Desfoque de Retrato Cinemático", systemImage: "camera.macro")
                        }

                        Toggle(isOn: Binding(
                            get: { clip.effects.contains("chromaKey") },
                            set: { model.toggleEffect("chromaKey", on: $0) }
                        )) {
                            Label("Chroma Key (Tela Verde)", systemImage: "square.inset.filled")
                        }
                    } else {
                        Text("Selecione um clipe na timeline para aplicar efeitos de IA.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Diferencial do MangoCUT")
                            .font(.footnote.bold())
                        Text("Diferente de editores comerciais que incluem rastreadores e modelos pesados de mais de 500 MB, o MangoCUT utiliza as redes neurais já integradas no iOS, proporcionando consumo zero de dados e alta performance.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Estúdio IA")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fechar") { model.sheet = nil }
                }
            }
        }
    }

    private func generateCaptions() {
        guard let firstClip = model.selectedClip ?? model.plan.clips.first,
              let url = model.project.resolve(firstClip) else {
            errorMessage = "Nenhum arquivo de mídia encontrado para transcrever."
            return
        }

        isTranscribing = true
        errorMessage = nil
        transcriptionResult = nil

        Task {
            do {
                let captions = try await AISpeechCaptioner.transcribe(url: url)
                model.setCaptions(captions)
                transcriptionResult = "\(captions.count) legendas criadas e sincronizadas na timeline!"
                isTranscribing = false
            } catch {
                errorMessage = error.localizedDescription
                isTranscribing = false
            }
        }
    }
}
