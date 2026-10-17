import Foundation

/// Modo de demonstração usado pelos screenshots do CI:
/// `xcrun simctl launch <device> com.mangocut.MangoCUT --demo-screen editor`
struct DemoRequest {
    /// home, editor, filters, effects, speed, transition, text ou export
    let screen: String

    static func fromArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> DemoRequest? {
        guard let index = arguments.firstIndex(of: "--demo-screen"), index + 1 < arguments.count else { return nil }
        return DemoRequest(screen: arguments[index + 1])
    }

    @MainActor
    func apply(to model: EditorModel) {
        let clips = model.plan.clips
        guard clips.count >= 3 else { return }
        switch screen {
        case "filters":
            model.selection = .clip(clips[1].segmentId)
            model.seek(to: clips[1].timelineStartUs + clips[1].timelineDurationUs / 2)
            model.sheet = .filters
        case "effects":
            model.selection = .clip(clips[0].segmentId)
            model.seek(to: 2_500_000)
            model.sheet = .effects
        case "speed":
            model.selection = .clip(clips[2].segmentId)
            model.seek(to: clips[2].timelineStartUs + 500_000)
            model.sheet = .speed
        case "transition":
            model.selection = .clip(clips[0].segmentId)
            model.seek(to: clips[1].timelineStartUs + (clips[1].transitionIn?.durationUs ?? 0) / 2)
            model.sheet = .transition
        case "text":
            if let text = model.plan.texts.first {
                model.selection = .text(text.id)
                model.seek(to: text.startUs + 1_000_000)
                model.sheet = .text
            }
        case "export":
            model.sheet = .export
        default:
            model.selection = .clip(clips[1].segmentId)
            model.seek(to: 1_500_000)
        }
    }
}

extension ProjectStore {
    static let demoName = "Demonstração"

    /// Projeto com três vídeos sintéticos, zoom, transição, filtro, fade e um texto.
    func demoProject() async throws -> ProjectInfo {
        if let existing = projects.first(where: { $0.name == Self.demoName }) { return existing }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mangocut-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clips = [("praia.mov", 0.07, 4.0), ("cidade.mov", 0.58, 3.0), ("campo.mov", 0.3, 3.5)]
        var urls: [URL] = []
        for (name, hue, seconds) in clips {
            let url = folder.appendingPathComponent(name)
            try await DemoMedia.makeClip(at: url, width: 720, height: 1280, seconds: seconds, hue: hue)
            urls.append(url)
        }
        let project = try await createProject(name: Self.demoName, media: urls)
        urls.forEach { try? FileManager.default.removeItem(at: $0) }

        let engine = try AppEngine.get()
        var json = try String(contentsOf: project.draftURL, encoding: .utf8)
        let ids = try engine.plan(json: json).clips.map(\.segmentId)
        let steps: [(String, [String: Any])] = [
            ("clip.effects", ["segmentId": ids[0], "effects": ["zoomIn"]]),
            ("clip.transition", ["segmentId": ids[0], "kind": "dissolve", "durationUs": 600_000]),
            ("clip.filter", ["segmentId": ids[1], "filter": "vintage"]),
            ("clip.effects", ["segmentId": ids[2], "effects": ["fadeOut"]]),
            ("text.add", ["text": "Férias 2026", "startUs": 300_000, "durationUs": 3_000_000, "y": 0.18, "font": "rounded", "size": 0.08]),
        ]
        for (command, params) in steps {
            json = try engine.run(command, on: json, params: params).draftJSON
        }
        try json.write(to: project.draftURL, atomically: true, encoding: .utf8)
        reload()
        return projects.first { $0.id == project.id } ?? project
    }
}
