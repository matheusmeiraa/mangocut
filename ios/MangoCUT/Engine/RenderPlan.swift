import Foundation

/// Espelho de `RenderPlan` em `src/editor.ts`. Tempos em microssegundos.
struct RenderPlan: Decodable, Equatable {
    struct Canvas: Decodable, Equatable {
        let width: Double
        let height: Double
    }

    struct Filter: Decodable, Equatable {
        let id: String
        let intensity: Double
    }

    struct Transition: Decodable, Equatable {
        let kind: String
        let durationUs: Double
    }

    struct Clip: Decodable, Equatable {
        let segmentId: String
        let materialId: String
        let path: String
        let name: String
        let sourceStartUs: Double
        let sourceDurationUs: Double
        let speed: Double
        let volume: Double
        let timelineStartUs: Double
        let timelineDurationUs: Double
        let filter: Filter?
        let effects: [String]
        let transitionIn: Transition?
        let transitionOut: Transition?

        var timelineEndUs: Double { timelineStartUs + timelineDurationUs }
    }

    struct Text: Decodable, Equatable, Identifiable {
        let id: String
        let text: String
        let startUs: Double
        let durationUs: Double
        let font: String
        let size: Double
        let color: String
        let x: Double
        let y: Double
        let background: Bool

        var endUs: Double { startUs + durationUs }
    }

    let canvas: Canvas
    let fps: Double
    let durationUs: Double
    let clips: [Clip]
    let texts: [Text]
    let warnings: [String]

    func clip(at timeUs: Double) -> Clip? {
        clips.last { timeUs >= $0.timelineStartUs && timeUs < $0.timelineEndUs }
    }
}

/// Resposta de `MangoEngine.run` e `MangoEngine.create`.
struct EditOutcome: Decodable {
    let draftJSON: String
    let plan: RenderPlan
    let result: [String: String]
}
