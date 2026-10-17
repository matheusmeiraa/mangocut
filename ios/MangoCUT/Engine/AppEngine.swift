import Foundation

/// Uma única instância do motor para o app inteiro (o JSContext não é thread-safe: use só na main actor).
@MainActor
enum AppEngine {
    private static let loaded = Result { try MangoEngine() }

    static func get() throws -> MangoEngine {
        try loaded.get()
    }

    static var loadError: String? {
        if case .failure(let error) = loaded { return error.localizedDescription }
        return nil
    }
}
