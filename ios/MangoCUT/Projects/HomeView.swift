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

struct HomeView: View {
    let demo: DemoRequest?
    @StateObject private var store = ProjectStore()
    @State private var path: [ProjectInfo] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isCreating = false
    @State private var isInspecting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: 30,
                        selectionBehavior: .ordered,
                        matching: .videos
                    ) {
                        Label("Novo projeto com vídeos", systemImage: "plus.rectangle.on.rectangle")
                    }
                    Button {
                        isInspecting = true
                    } label: {
                        Label("Inspecionar um draft do CapCut", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section("Projetos") {
                    if store.projects.isEmpty {
                        Text("Nenhum projeto ainda. Escolha vídeos para começar.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.projects) { project in
                        NavigationLink(value: project) {
                            ProjectRow(project: project)
                        }
                    }
                    .onDelete { offsets in
                        for project in offsets.map({ store.projects[$0] }) {
                            store.delete(project)
                        }
                    }
                }

                if let error = AppEngine.loadError {
                    Section("Motor indisponível") {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("MangoCUT")
            .navigationDestination(for: ProjectInfo.self) { project in
                EditorView(project: project, store: store, demo: demo)
            }
            .overlay {
                if isCreating {
                    ProgressView("Preparando o projeto…")
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
        .alert(
            "Não deu certo",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
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

private struct ProjectRow: View {
    let project: ProjectInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.headline)
            Text("\(project.clipCount) clipe\(project.clipCount == 1 ? "" : "s") · \(TimeFormat.clock(project.durationUs)) · \(project.modified.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
