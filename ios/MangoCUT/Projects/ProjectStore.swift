import Foundation

struct ProjectInfo: Identifiable, Hashable {
    let id: String
    let folder: URL
    var name: String
    var durationUs: Double
    var clipCount: Int
    var modified: Date

    var draftURL: URL { folder.appendingPathComponent("draft_content.json") }
    var mediaFolder: URL { folder.appendingPathComponent("media", isDirectory: true) }

    /// Caminho absoluto (drafts vindos de outro editor) ou relativo à pasta do projeto (projetos do MangoCUT).
    func resolve(_ clip: RenderPlan.Clip) -> URL? {
        guard !clip.path.isEmpty else { return nil }
        let url = clip.path.hasPrefix("/") ? URL(fileURLWithPath: clip.path) : folder.appendingPathComponent(clip.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

struct ImportedMedia {
    let relativePath: String
    let name: String
    let info: MediaInfo

    var appendParams: [String: Any] {
        ["path": relativePath, "name": name, "durationUs": info.durationUs, "width": info.width, "height": info.height]
    }
}

/// Projetos ficam em Documentos/Projetos/<id>/ com o draft_content.json e a pasta media/.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ProjectInfo] = []
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projetos", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        projects = folders.compactMap(Self.load(folder:)).sorted { $0.modified > $1.modified }
    }

    nonisolated static func load(folder: URL) -> ProjectInfo? {
        let draftURL = folder.appendingPathComponent("draft_content.json")
        guard let data = try? Data(contentsOf: draftURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let modified = (try? draftURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let tracks = json["tracks"] as? [[String: Any]] ?? []
        let main = tracks.first { $0["type"] as? String == "video" }
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Sem nome"
        return ProjectInfo(
            id: folder.lastPathComponent,
            folder: folder,
            name: name,
            durationUs: json["duration"] as? Double ?? 0,
            clipCount: (main?["segments"] as? [Any])?.count ?? 0,
            modified: modified ?? .distantPast
        )
    }

    /// Copia os vídeos para a pasta de mídia do projeto e lê duração e tamanho de cada um.
    nonisolated static func importMedia(_ urls: [URL], into project: ProjectInfo) async throws -> [ImportedMedia] {
        try FileManager.default.createDirectory(at: project.mediaFolder, withIntermediateDirectories: true)
        var result: [ImportedMedia] = []
        for url in urls {
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
            let fileName = "\(UUID().uuidString).\(ext)"
            let destination = project.mediaFolder.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: url, to: destination)
            let info = try await MediaProbe.probe(destination)
            result.append(ImportedMedia(relativePath: "media/\(fileName)", name: url.lastPathComponent, info: info))
        }
        return result
    }

    func createProject(name: String, media urls: [URL]) async throws -> ProjectInfo {
        let engine = try AppEngine.get()
        let id = UUID().uuidString
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = ProjectInfo(id: id, folder: folder, name: name, durationUs: 0, clipCount: 0, modified: Date())
        do {
            let imported = try await Self.importMedia(urls, into: project)
            let (width, height) = Self.canvas(for: imported.first?.info)
            var outcome = try engine.createProject(name: name, width: width, height: height)
            for media in imported {
                outcome = try engine.run("clip.append", on: outcome.draftJSON, params: media.appendParams)
            }
            try outcome.draftJSON.write(to: project.draftURL, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        reload()
        return projects.first { $0.id == id } ?? project
    }

    func delete(_ project: ProjectInfo) {
        try? FileManager.default.removeItem(at: project.folder)
        reload()
    }

    /// Canvas do projeto a partir do primeiro vídeo: retrato, paisagem ou quadrado.
    nonisolated static func canvas(for info: MediaInfo?) -> (Int, Int) {
        guard let info, info.width > 0, info.height > 0 else { return (1080, 1920) }
        if info.width == info.height { return (1080, 1080) }
        return info.width > info.height ? (1920, 1080) : (1080, 1920)
    }
}
