import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = DraftViewModel()
    @State private var isImporting = false
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isImporting = true
                        } label: {
                            Label("Abrir", systemImage: "folder")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isExporting = true
                        } label: {
                            Label("Exportar", systemImage: "square.and.arrow.up")
                        }
                        .disabled(model.summary == nil)
                    }
                }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                model.open(url)
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: model.exportDocument,
            contentType: .json,
            defaultFilename: model.exportFileName
        ) { result in
            if case .failure(let error) = result {
                model.errorMessage = error.localizedDescription
            }
        }
        .alert(
            "Erro",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let engineError = model.engineError {
            MessageView(systemImage: "exclamationmark.triangle", title: "Motor indisponível", message: engineError)
        } else if let summary = model.summary {
            DraftDetailView(summary: summary, fixes: model.fixes, canRepair: model.canRepair, repair: model.repair)
        } else {
            VStack(spacing: 20) {
                MessageView(
                    systemImage: "film.stack",
                    title: "Nenhum projeto aberto",
                    message: "Abra um draft_content.json ou draft_info.json para ver a timeline, validar e reparar."
                )
                Button("Abrir projeto") { isImporting = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct DraftDetailView: View {
    let summary: DraftSummary
    let fixes: [String]
    let canRepair: Bool
    let repair: () -> Void

    var body: some View {
        List {
            Section("Projeto") {
                LabeledContent("Duração real", value: TimeFormat.clock(summary.timelineEndUs))
                if summary.declaredDurationUs != summary.timelineEndUs {
                    LabeledContent("Duração declarada", value: TimeFormat.clock(summary.declaredDurationUs))
                }
                if let canvas = summary.canvas {
                    LabeledContent("Canvas", value: "\(number(canvas.width))x\(number(canvas.height)) (\(canvas.ratio ?? "?"))")
                }
                if let fps = summary.fps {
                    LabeledContent("FPS", value: number(fps))
                }
                LabeledContent(
                    "Conteúdo",
                    value: "\(summary.totals.tracks) trilhas · \(summary.totals.segments) clipes · \(summary.totals.keyframes) keyframes"
                )
                if let newVersion = summary.newVersion {
                    LabeledContent("Versão do formato", value: newVersion)
                }
            }

            Section("Validação") {
                if summary.validation.valid {
                    Label("Sem problemas", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Color.green)
                } else {
                    ForEach(Array(summary.validation.issues.enumerated()), id: \.offset) { _, issue in
                        IssueRow(issue: issue)
                    }
                    if canRepair {
                        Button(action: repair) {
                            Label("Reparar projeto", systemImage: "wrench.and.screwdriver")
                        }
                    }
                }
            }

            if !fixes.isEmpty {
                Section("Correções aplicadas") {
                    ForEach(Array(fixes.enumerated()), id: \.offset) { _, fix in
                        Label(fix, systemImage: "checkmark")
                            .font(.callout)
                    }
                }
            }

            ForEach(summary.tracks, id: \.index) { track in
                Section {
                    ForEach(Array(track.segments.enumerated()), id: \.offset) { position, segment in
                        SegmentRow(number: position + 1, segment: segment)
                    }
                } header: {
                    Text("#\(track.index + 1) \(track.type)\(track.name.isEmpty ? "" : " · \(track.name)")")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func number(_ value: Double?) -> String {
        guard let value else { return "?" }
        return value.rounded() == value ? String(Int(value)) : String(value)
    }
}

struct IssueRow: View {
    let issue: DraftSummary.Issue

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.message)
                    .font(.callout)
                Text(issue.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: issue.fatal ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.fatal ? Color.red : Color.orange)
        }
    }
}

struct SegmentRow: View {
    let number: Int
    let segment: DraftSummary.Segment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timing)
                .font(.callout.monospacedDigit())
            Text(segment.material?.label ?? "material \(segment.materialId) ausente")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !keyframes.isEmpty {
                Text(keyframes)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timing: String {
        var text = "[\(number)] \(TimeFormat.seconds(segment.startUs)) → \(TimeFormat.seconds(segment.endUs))"
        text += " (\(TimeFormat.seconds(segment.durationUs)))"
        if segment.speed != 1 { text += " · \(segment.speed)x" }
        return text
    }

    private var keyframes: String {
        var parts = segment.keyframes.filter { $0.count > 0 }.map { "\($0.property) ×\($0.count)" }
        if segment.keyframeRefs > 0 { parts.append("keyframe_refs ×\(segment.keyframeRefs)") }
        return parts.joined(separator: ", ")
    }
}

struct MessageView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
