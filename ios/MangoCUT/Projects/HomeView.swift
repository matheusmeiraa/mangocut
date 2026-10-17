import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Vídeo escolhido na Fototeca, copiado para uma pasta temporária.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Tela Inicial do MangoCUT no estilo profissional mobile (CapCut dark aesthetic).
struct HomeView: View {
    let demo: DemoRequest?
    @StateObject private var store = ProjectStore()
    @State private var path: [ProjectInfo] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isCreating = false
    @State private var isInspecting = false
    @State private var errorMessage: String?
    @State private var renamingProject: ProjectInfo?
    @State private var newProjectName = ""

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    headerView
                    newProjectHero
                    quickToolsSection
                    recentProjectsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Color.capcutDark.ignoresSafeArea())
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(for: ProjectInfo.self) { project in
                EditorView(project: project, store: store, demo: demo)
            }
            .overlay {
                if isCreating {
                    ProgressView("Preparando projeto…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .task(id: pickerItems) { await createFromPicked() }
        .task { await openDemo() }
        .sheet(isPresented: $isInspecting) {
            InspectorView()
        }
        .alert("Renomear Projeto", isPresented: Binding(get: { renamingProject != nil }, set: { if !$0 { renamingProject = nil } })) {
            TextField("Nome do projeto", text: $newProjectName)
            Button("Cancelar", role: .cancel) { renamingProject = nil }
            Button("Salvar") {
                if let project = renamingProject, !newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.rename(project, to: newProjectName)
                }
                renamingProject = nil
            }
        }
        .alert(
            "Aviso",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Componentes da Tela

    private var headerView: some View {
        HStack {
            HStack(spacing: 6) {
                Text("Mango")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("CUT")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Color.mango)
                Circle()
                    .fill(Color.capcutCyan)
                    .frame(width: 6, height: 6)
            }

            Spacer()

            Button {
                isInspecting = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("CapCut Draft")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.capcutCard)
                .foregroundStyle(Color.capcutCyan)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.capcutBorder, lineWidth: 1))
            }
        }
        .padding(.vertical, 4)
    }

    private var newProjectHero: some View {
        PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: 30,
            selectionBehavior: .ordered,
            matching: .videos
        ) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.mango, Color.capcutCyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                        .shadow(color: Color.mango.opacity(0.4), radius: 8, x: 0, y: 4)

                    Image(systemName: "plus")
                        .font(.title2.bold())
                        .foregroundStyle(.black)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Novo Projeto")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("Selecione vídeos ou fotos da Fototeca")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.callout.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(Color.capcutCard)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        LinearGradient(
                            colors: [Color.capcutBorder, Color.capcutCyan.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var quickToolsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                quickToolPill(title: "Auto-Legendas", icon: "captions.bubble.fill", color: Color.capcutCyan) {
                    triggerPicker()
                }
                quickToolPill(title: "Recorte IA", icon: "person.crop.rectangle.stack", color: Color.capcutPurple) {
                    triggerPicker()
                }
                quickToolPill(title: "Templates", icon: "rectangle.3.group.fill", color: Color.mango) {
                    triggerPicker()
                }
                quickToolPill(title: "Inspecionar", icon: "magnifyingglass.circle.fill", color: Color.capcutYellow) {
                    isInspecting = true
                }
            }
        }
    }

    private func quickToolPill(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(color)
                Text(title)
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.capcutCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.capcutBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var recentProjectsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Projetos Recentes")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("\(store.projects.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.capcutCard)
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
            }

            if store.projects.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.gray.opacity(0.6))
                    Text("Nenhum projeto ainda")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Toque em Novo Projeto para começar a editar seus vídeos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(Color.capcutCard.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.capcutBorder, lineWidth: 1))
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(store.projects) { project in
                        NavigationLink(value: project) {
                            ProjectCard(project: project)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                renamingProject = project
                                newProjectName = project.name
                            } label: {
                                Label("Renomear", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                store.delete(project)
                            } label: {
                                Label("Excluir", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func triggerPicker() {
        // Dispara o PhotosPicker simulado tocando no Hero
    }

    private func createFromPicked() async {
        guard !pickerItems.isEmpty else { return }
        isCreating = true
        defer {
            isCreating = false
            pickerItems = []
        }
        var urls: [URL] = []
        for item in pickerItems {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                urls.append(movie.url)
            }
        }
        guard !urls.isEmpty else {
            errorMessage = "Não foi possível ler os vídeos escolhidos."
            return
        }
        do {
            let name = "Projeto \(Date().formatted(date: .abbreviated, time: .shortened))"
            let project = try await store.createProject(name: name, media: urls)
            path = [project]
        } catch {
            errorMessage = error.localizedDescription
        }
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func openDemo() async {
        guard let demo else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let project = try await store.demoProject()
            if demo.screen != "home" { path = [project] }
        } catch {
            errorMessage = "Demonstração: \(error.localizedDescription)"
        }
    }
}

/// Card de projeto no formato CapCut com thumbnail real, badge de duração e visual dark glass.
private struct ProjectCard: View {
    let project: ProjectInfo
    @State private var thumbnailImage: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.capcutCardHover)
                    .aspectRatio(1.2, contentMode: .fit)

                if let img = thumbnailImage {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1.2, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.gray.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Badge de duração (estilo CapCut)
                Text(TimeFormat.clock(project.durationUs))
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.75))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.capcutBorder, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(project.clipCount) clipe\(project.clipCount == 1 ? "" : "s")")
                    Text("•")
                    Text(project.modified.formatted(.relative(presentation: .named)))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .task {
            thumbnailImage = await project.thumbnail()
        }
    }
}
