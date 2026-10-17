import SwiftUI

/// Folha de Templates Criativos do MangoCUT.
/// Aplica estilos pré-configurados de aspect ratio, filtros cinemáticos, transições e efeitos
/// dinâmicos com apenas 1 toque.
struct TemplatesSheet: View {
    @ObservedObject var model: EditorModel
    @State private var appliedTemplate: String?

    struct TemplateInfo: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let ratio: String
    }

    private static let templates: [TemplateInfo] = [
        TemplateInfo(
            id: "tiktok",
            title: "TikTok & Reels Dinâmico",
            subtitle: "Formato 9:16 vertical, cores vívidas, cortes dinâmicos com aproximação e transições suaves.",
            icon: "play.rectangle.on.rectangle",
            ratio: "9:16"
        ),
        TemplateInfo(
            id: "cinematic",
            title: "Cinema Blockbuster",
            subtitle: "Formato 16:9 widescreen, color grading Teal & Orange Hollywoodiano, fades dramáticos e dissolução.",
            icon: "film",
            ratio: "16:9"
        ),
        TemplateInfo(
            id: "retro",
            title: "Retrô VHS Anos 90",
            subtitle: "Estilo fita analógica, granulação de película 35mm cinematográfica e vinheta nostálgica.",
            icon: "tv",
            ratio: "Original"
        ),
        TemplateInfo(
            id: "cyberpunk",
            title: "Cyberpunk Futurista",
            subtitle: "Duo-tone neon ciano/magenta, distorção cromática glitch e transições de flash de impacto.",
            icon: "bolt.horizontal.circle",
            ratio: "Original"
        ),
        TemplateInfo(
            id: "aesthetic",
            title: "Estético & Retrato",
            subtitle: "Tons quentes aconchegantes, vinheta suave e desfoque óptico de retrato.",
            icon: "heart.circle",
            ratio: "Original"
        ),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Escolha um template para transformar o estilo visual, formato e ritmo de todos os clipes do seu vídeo com 1 toque.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Modelos Prontos") {
                    ForEach(Self.templates) { t in
                        Button {
                            apply(t.id)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: t.icon)
                                    .font(.title2)
                                    .foregroundStyle(Color.mango)
                                    .frame(width: 36)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(t.title)
                                            .font(.headline)
                                            .foregroundStyle(Color.primary)
                                        Spacer()
                                        Text(t.ratio)
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.mango.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                    Text(t.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if let applied = appliedTemplate {
                    Section {
                        Label("Template \"\(applied)\" aplicado com sucesso!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Templates")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Concluir") { model.sheet = nil }
                }
            }
        }
    }

    private func apply(_ id: String) {
        model.applyTemplate(id: id)
        if let found = Self.templates.first(where: { $0.id == id }) {
            appliedTemplate = found.title
        }
    }
}
