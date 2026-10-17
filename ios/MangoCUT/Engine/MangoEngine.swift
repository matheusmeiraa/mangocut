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

    private func evaluate(_ script: String, sourceURL: URL? = nil) throws {
        lastException = nil
        if let sourceURL {
            context.evaluateScript(script, withSourceURL: sourceURL)
        } else {
            context.evaluateScript(script)
        }
        if let message = lastException { throw MangoEngineError.javascript(message) }
    }

    private func callBridge(_ method: String, _ argument: String) throws -> String {
        lastException = nil
        let result = context.objectForKeyedSubscript("MangoBridge")?.invokeMethod(method, withArguments: [argument])
        if let message = lastException { throw MangoEngineError.javascript(message) }
        guard let result, result.isString, let text = result.toString() else {
            throw MangoEngineError.javascript("resposta inesperada do motor em \(method)")
        }
        return text
    }

    private func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}
