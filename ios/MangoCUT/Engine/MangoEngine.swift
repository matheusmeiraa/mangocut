import Foundation
import JavaScriptCore

enum MangoEngineError: LocalizedError {
    case bundleMissing
    case javascript(String)

    var errorDescription: String? {
        switch self {
        case .bundleMissing:
            return "mangocut-engine.js não foi incluído no app. Rode `npm run build:ios-engine` antes de compilar."
        case .javascript(let message):
            return message
        }
    }
}

/// Executa o motor do MangoCUT dentro do JavaScriptCore. É o mesmo código TypeScript da biblioteca e da CLI,
/// empacotado por `npm run build:ios-engine`. A troca com o Swift é feita só por strings JSON.
final class MangoEngine {
    private let context: JSContext
    private var lastException: String?

    /// APIs que o JavaScriptCore puro não oferece e que o motor usa.
    private static let prelude = """
    globalThis.crypto = globalThis.crypto || { randomUUID: () => __mangocutUUID() };
    globalThis.structuredClone = globalThis.structuredClone || ((value) => JSON.parse(JSON.stringify(value)));
    """

    private static let bridge = """
    globalThis.MangoBridge = {
      inspect(text) {
        const draft = JSON.parse(text);
        const validation = MangoCUT.validateDraftJson(draft);
        if (typeof draft !== "object" || draft === null || Array.isArray(draft)) {
          throw new Error(validation.fatalExceptionMessage || "o arquivo não é um projeto");
        }
        return JSON.stringify(MangoCUT.summarizeDraft(draft, validation));
      },
      repair(text) {
        const report = MangoCUT.repairDraft(JSON.parse(text));
        const fixed = report.repairedDraft;
        return JSON.stringify({
          errorMask: report.errorMask,
          errorInfo: report.errorInfo,
          fixInfo: report.fixInfo,
          summary: MangoCUT.summarizeDraft(fixed, MangoCUT.validateDraftJson(fixed)),
          draftJSON: JSON.stringify(fixed),
        });
      },
      plan(text) {
        return JSON.stringify(MangoCUT.buildRenderPlan(JSON.parse(text)));
      },
      run(text, commandId, params) {
        const out = MangoCUT.runEditorCommand(JSON.parse(text), commandId, JSON.parse(params));
        return JSON.stringify({ draftJSON: JSON.stringify(out.draft), plan: out.plan, result: out.result });
      },
      create(params) {
        const draft = MangoCUT.createEditorProject(JSON.parse(params));
        return JSON.stringify({ draftJSON: JSON.stringify(draft), plan: MangoCUT.buildRenderPlan(draft), result: {} });
      },
    };
    """

    convenience init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "mangocut-engine", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { throw MangoEngineError.bundleMissing }
        try self.init(engineSource: source, sourceURL: url)
    }

    init(engineSource: String, sourceURL: URL? = nil) throws {
        guard let context = JSContext() else {
            throw MangoEngineError.javascript("não foi possível criar o JSContext")
        }
        self.context = context
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "erro desconhecido no motor JavaScript"
        }
        let uuid: @convention(block) () -> String = { UUID().uuidString }
        context.setObject(uuid, forKeyedSubscript: "__mangocutUUID" as NSString)

        try evaluate(Self.prelude)
        try evaluate(engineSource, sourceURL: sourceURL)
        try evaluate(Self.bridge)
    }

    /// Valida e resume o projeto. Lança erro se o texto não for JSON ou não for um objeto.
    func inspect(json: String) throws -> DraftSummary {
        try decode(DraftSummary.self, from: callBridge("inspect", json))
    }

    /// Aplica o motor de reparo. O JSON original não é alterado.
    func repair(json: String) throws -> RepairOutcome {
        try decode(RepairOutcome.self, from: callBridge("repair", json))
    }

    /// Plano de render do draft: clipes na ordem, transições, filtros, efeitos e textos.
    func plan(json: String) throws -> RenderPlan {
        try decode(RenderPlan.self, from: callBridge("plan", json))
    }

    /// Executa um comando de edição de `src/editor.ts` sobre uma cópia do draft.
    func run(_ commandId: String, on json: String, params: [String: Any] = [:]) throws -> EditOutcome {
        try decode(EditOutcome.self, from: callBridge("run", json, commandId, try Self.json(params)))
    }

    /// Projeto novo do editor, já com a trilha principal.
    func createProject(name: String, width: Int, height: Int, fps: Int = 30) throws -> EditOutcome {
        let params: [String: Any] = ["name": name, "width": width, "height": height, "fps": fps]
        return try decode(EditOutcome.self, from: callBridge("create", try Self.json(params)))
    }

    private static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func evaluate(_ script: String, sourceURL: URL? = nil) throws {
        lastException = nil
        if let sourceURL {
            context.evaluateScript(script, withSourceURL: sourceURL)
        } else {
            context.evaluateScript(script)
        }
        if let message = lastException { throw MangoEngineError.javascript(message) }
    }

    private func callBridge(_ method: String, _ arguments: String...) throws -> String {
        lastException = nil
        let result = context.objectForKeyedSubscript("MangoBridge")?.invokeMethod(method, withArguments: arguments)
        if let message = lastException {
            // Erros de edição já vêm com a mensagem pronta para o usuário.
            let prefix = "EditorError: "
            throw MangoEngineError.javascript(message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message)
        }
        guard let result, result.isString, let text = result.toString() else {
            throw MangoEngineError.javascript("resposta inesperada do motor em \(method)")
        }
        return text
    }

    private func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}
