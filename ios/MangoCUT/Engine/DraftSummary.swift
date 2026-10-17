import Foundation

/// Espelho de `DraftSummary` em `src/summary.ts`. Tempos em microssegundos.
struct DraftSummary: Decodable {
    struct Canvas: Decodable {
        let width: Double?
        let height: Double?
        let ratio: String?
    }

    struct MaterialRef: Decodable {
        let category: String
        let label: String
    }

    struct TimeSpan: Decodable {
        let startUs: Double
        let durationUs: Double
    }

    struct KeyframeCount: Decodable {
        let property: String
        let count: Int
    }

    struct Segment: Decodable {
        let id: String
        let materialId: String
        let material: MaterialRef?
        let startUs: Double
        let durationUs: Double
        let endUs: Double
        let source: TimeSpan?
        let speed: Double
        let keyframes: [KeyframeCount]
        let keyframeRefs: Int
    }

    struct Track: Decodable {
        let index: Int
        let id: String
        let type: String
        let name: String
        let segments: [Segment]
    }

    struct Totals: Decodable {
        let tracks: Int
        let segments: Int
        let keyframes: Int
    }

    struct Issue: Decodable {
        let path: String
        let code: String
        let message: String
        let fatal: Bool
    }

    struct Validation: Decodable {
        let valid: Bool
        let fatalExceptionMessage: String?
        let errorMask: Int
        let issues: [Issue]
    }

    let name: String
    let id: String
    let version: Double?
    let newVersion: String?
    let canvas: Canvas?
    let fps: Double?
    let declaredDurationUs: Double
    let timelineEndUs: Double
    let tracks: [Track]
    let totals: Totals
    let validation: Validation
}

struct RepairOutcome: Decodable {
    let errorMask: Int
    let errorInfo: [String]
    let fixInfo: [String]
    let summary: DraftSummary
    let draftJSON: String
}

enum TimeFormat {
    /// `6.033s`
    static func seconds(_ us: Double) -> String {
        String(format: "%.3fs", us / 1_000_000)
    }

    /// `00:06.033`
    static func clock(_ us: Double) -> String {
        let totalMs = Int((us / 1000).rounded(.towardZero))
        return String(format: "%02d:%02d.%03d", totalMs / 60_000, (totalMs % 60_000) / 1000, totalMs % 1000)
    }
}
