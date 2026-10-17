import AVFoundation
import SwiftUI

enum EditorSelection: Hashable {
    case clip(String)
    case text(String)
}

enum EditorSheet: String, Identifiable {
    case filters, effects, speed, transition, text, export
    var id: String { rawValue }
}

extension RenderPlan {
    static let empty = RenderPlan(
        canvas: Canvas(width: 1080, height: 1920),
        fps: 30,
        durationUs: 0,
        clips: [],
        texts: [],
        warnings: []
    )
}

/// Estado do editor. Toda edição passa pelo motor (`AppEngine`); o resultado é salvo no
/// draft_content.json do projeto e o player é remontado a partir do novo plano.
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var plan: RenderPlan = .empty
    @Published private(set) var name: String
    @Published var selection: EditorSelection?
    @Published private(set) var currentUs: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var canUndo = false
    @Published var errorMessage: String?
    @Published var sheet: EditorSheet?

    let project: ProjectInfo
    let player = AVPlayer()
    private var draftJSON = ""
    private var undoStack: [String] = []
    private var timeObserver: Any?
    private var buildTask: Task<Void, Never>?

    init(project: ProjectInfo) {
        self.project = project
        name = project.name
        player.actionAtItemEnd = .pause
        do {
            draftJSON = try String(contentsOf: project.draftURL, encoding: .utf8)
            plan = try AppEngine.get().plan(json: draftJSON)
        } catch {
            errorMessage = "Não foi possível abrir o projeto: \(error.localizedDescription)"
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.playerTick(time) }
        }
        rebuild()
    }

    // MARK: Seleção

    var selectedClip: RenderPlan.Clip? {
        guard case .clip(let id) = selection else { return nil }
        return plan.clips.first { $0.segmentId == id }
    }

    var selectedText: RenderPlan.Text? {
        guard case .text(let id) = selection else { return nil }
        return plan.texts.first { $0.id == id }
    }

    var selectedClipIndex: Int? {
        guard let clip = selectedClip else { return nil }
        return plan.clips.firstIndex { $0.segmentId == clip.segmentId }
    }

    // MARK: Comandos

    @discardableResult
    func run(_ command: String, _ params: [String: Any] = [:]) -> [String: String]? {
        do {
            let outcome = try AppEngine.get().run(command, on: draftJSON, params: params)
            pushUndo()
            apply(json: outcome.draftJSON, plan: outcome.plan)
            return outcome.result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        do {
            apply(json: previous, plan: try AppEngine.get().plan(json: previous))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func split() {
        if let result = run("clip.split", ["atUs": currentUs]), let id = result["segmentId"] {
            selection = .clip(id)
        }
    }

    func trim(_ edge: String) {
        guard let clip = selectedClip else { return }
        run("clip.trim", ["segmentId": clip.segmentId, "edge": edge, "atUs": currentUs])
        if edge == "start", let trimmed = selectedClip {
            seek(to: trimmed.timelineStartUs)
        }
    }

    func move(by offset: Int) {
        guard let clip = selectedClip, let index = selectedClipIndex else { return }
        run("clip.move", ["segmentId": clip.segmentId, "toIndex": max(0, index + offset)])
    }

    func deleteSelection() {
        switch selection {
        case .clip(let id):
            if run("clip.delete", ["segmentId": id]) != nil { selection = nil }
        case .text(let id):
            if run("text.delete", ["id": id]) != nil { selection = nil }
        case nil:
            break
        }
    }

    func setSpeed(_ speed: Double) {
        guard let clip = selectedClip, clip.speed != speed else { return }
        run("clip.speed", ["segmentId": clip.segmentId, "speed": speed])
    }

    func setFilter(_ id: String?, intensity: Double = 1) {
        guard let clip = selectedClip else { return }
        var params: [String: Any] = ["segmentId": clip.segmentId, "intensity": intensity]
        params["filter"] = id ?? NSNull()
        run("clip.filter", params)
    }

    func toggleEffect(_ effect: String, on: Bool) {
        guard let clip = selectedClip else { return }
        var effects = clip.effects.filter { $0 != effect }
        if on {
            if effect == "zoomIn" { effects.removeAll { $0 == "zoomOut" } }
            if effect == "zoomOut" { effects.removeAll { $0 == "zoomIn" } }
            effects.append(effect)
        }
        run("clip.effects", ["segmentId": clip.segmentId, "effects": effects])
    }

    func setTransition(kind: String?, durationUs: Double) {
        guard let clip = selectedClip else { return }
        var params: [String: Any] = ["segmentId": clip.segmentId, "durationUs": durationUs]
        params["kind"] = kind ?? NSNull()
        run("clip.transition", params)
    }

    func addText() {
        let start = min(currentUs, max(0, plan.durationUs - 500_000))
        if let result = run("text.add", ["text": "Seu texto", "startUs": start]), let id = result["textId"] {
            selection = .text(id)
            sheet = .text
        }
    }

    func updateText(id: String, fields: [String: Any]) {
        var params = fields
        params["id"] = id
        run("text.update", params)
    }

    func rename(_ newName: String) {
        run("project.rename", ["name": newName])
    }

    func addMedia(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        do {
            let imported = try await ProjectStore.importMedia(urls, into: project)
            var json = draftJSON
            var lastPlan = plan
            for media in imported {
                let outcome = try AppEngine.get().run("clip.append", on: json, params: media.appendParams)
                json = outcome.draftJSON
                lastPlan = outcome.plan
            }
            pushUndo()
            apply(json: json, plan: lastPlan)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Player

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            guard !plan.clips.isEmpty else { return }
            if currentUs >= plan.durationUs - 50_000 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to timeUs: Double) {
        let clamped = min(max(0, timeUs), plan.durationUs)
        currentUs = clamped
        player.seek(to: CMTime(microseconds: clamped), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func close() {
        player.pause()
        isPlaying = false
        buildTask?.cancel()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    // MARK: Interno

    private func pushUndo() {
        undoStack.append(draftJSON)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    private func apply(json: String, plan newPlan: RenderPlan) {
        draftJSON = json
        plan = newPlan
        canUndo = !undoStack.isEmpty
        if let data = json.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let newName = root["name"] as? String, !newName.isEmpty {
            name = newName
        }
        switch selection {
        case .clip(let id) where !newPlan.clips.contains { $0.segmentId == id }:
            selection = nil
        case .text(let id) where !newPlan.texts.contains { $0.id == id }:
            selection = nil
        default:
            break
        }
        if currentUs > newPlan.durationUs { currentUs = newPlan.durationUs }
        try? json.write(to: project.draftURL, atomically: true, encoding: .utf8)
        rebuild()
    }

    private func rebuild() {
        buildTask?.cancel()
        let plan = self.plan
        let project = self.project
        buildTask = Task {
            guard !plan.clips.isEmpty else {
                player.replaceCurrentItem(with: nil)
                return
            }
            do {
                let built = try await CompositionBuilder.build(plan: plan, resolve: project.resolve)
                if Task.isCancelled { return }
                let item = AVPlayerItem(asset: built.composition)
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
                player.replaceCurrentItem(with: item)
                let target = min(currentUs, max(0, plan.durationUs - 1))
                _ = await player.seek(to: CMTime(microseconds: target), toleranceBefore: .zero, toleranceAfter: .zero)
                if isPlaying { player.play() }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    private func playerTick(_ time: CMTime) {
        guard isPlaying else { return }
        currentUs = min(time.microseconds, plan.durationUs)
        if player.rate == 0 && currentUs >= plan.durationUs - 50_000 {
            isPlaying = false
        }
    }
}
