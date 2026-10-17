import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DraftViewModel: ObservableObject {
    @Published private(set) var fileName: String?
    @Published private(set) var summary: DraftSummary?
    @Published private(set) var fixes: [String] = []
    @Published private(set) var isRepaired = false
    @Published private(set) var engineError: String?
    @Published var errorMessage: String?

    private var draftJSON: String?
    private let engine: MangoEngine?

    init() {
        switch Result(catching: { try AppEngine.get() }) {
        case .success(let engine):
            self.engine = engine
        case .failure(let error):
            self.engine = nil
            self.engineError = error.localizedDescription
        }
    }

    var canRepair: Bool {
        guard let validation = summary?.validation else { return false }
        return validation.errorMask != 0 && validation.fatalExceptionMessage == nil
    }

    var title: String {
        guard let summary else { return "MangoCUT" }
        return summary.name.isEmpty ? (fileName ?? "Projeto") : summary.name
    }

    var exportDocument: JSONFile? {
        draftJSON.map(JSONFile.init(text:))
    }

    var exportFileName: String {
        let base = ((fileName ?? "draft_content") as NSString).deletingPathExtension
        return isRepaired ? "\(base).repaired.json" : "\(base).json"
    }

    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            var text = try String(contentsOf: url, encoding: .utf8)
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            let summary = try requireEngine().inspect(json: text)
            draftJSON = text
            fileName = url.lastPathComponent
            self.summary = summary
            fixes = []
            isRepaired = false
        } catch {
            errorMessage = "Não foi possível abrir \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func repair() {
        guard let draftJSON else { return }
        do {
            let outcome = try requireEngine().repair(json: draftJSON)
            self.draftJSON = outcome.draftJSON
            summary = outcome.summary
            fixes = outcome.fixInfo
            isRepaired = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requireEngine() throws -> MangoEngine {
        guard let engine else { throw MangoEngineError.bundleMissing }
        return engine
    }
}

struct JSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadCorruptFile) }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
