import SwiftUI

/// Timeline horizontal: régua (arraste para navegar), clipes da trilha principal, transições,
/// textos e a agulha de reprodução. Toque num bloco para selecionar.
struct TimelineView: View {
    let plan: RenderPlan
    let currentUs: Double
    let selection: EditorSelection?
    let pointsPerSecond: Double
    let onSeek: (Double) -> Void
    let onSelect: (EditorSelection?) -> Void

    static let palette: [Color] = [.mango, .pink, .teal, .indigo, .purple, .green, .orange, .cyan]
    private let rulerHeight: CGFloat = 22
    private let clipHeight: CGFloat = 56
    private let textHeight: CGFloat = 24
    private let gap: CGFloat = 6

    private var pps: CGFloat { CGFloat(pointsPerSecond) }
    private var clipTop: CGFloat { rulerHeight + gap }
    private var textTop: CGFloat { clipTop + clipHeight + gap }
    private var totalHeight: CGFloat { textTop + textHeight }

    private var contentWidth: CGFloat {
        let end = max(plan.durationUs, plan.texts.map(\.endUs).max() ?? 0)
        return max(x(end), 1)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(nil) }
                ruler
                ForEach(Array(plan.clips.enumerated()), id: \.offset) { index, clip in
                    clipBlock(clip, index: index)
                }
                ForEach(Array(plan.clips.enumerated()), id: \.offset) { _, clip in
                    if let transition = clip.transitionIn {
                        transitionMarker(atUs: clip.timelineStartUs + transition.durationUs / 2)
                    }
                }
                ForEach(plan.texts) { text in
                    textBlock(text)
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: totalHeight)
                    .offset(x: x(currentUs) - 1)
                    .allowsHitTesting(false)
            }
            .frame(width: contentWidth + 24, height: totalHeight, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(white: 0.1))
    }

    private func x(_ us: Double) -> CGFloat {
        CGFloat(us / 1_000_000) * pps
    }

    private var ruler: some View {
        let step: Double = pps >= 40 ? 1 : (pps >= 15 ? 5 : 10)
        let ticks = Array(stride(from: 0.0, through: Double(contentWidth / pps), by: step))
        return ZStack(alignment: .topLeading) {
            Color(white: 0.14)
            ForEach(ticks, id: \.self) { second in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.tickLabel(second))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Rectangle()
                        .fill(Color.gray)
                        .frame(width: 1, height: 6)
                }
                .offset(x: CGFloat(second) * pps)
            }
        }
        .frame(width: contentWidth, height: rulerHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            onSeek(Double(max(0, value.location.x) / pps) * 1_000_000)
        })
    }

    private func clipBlock(_ clip: RenderPlan.Clip, index: Int) -> some View {
        let selected = selection == .clip(clip.segmentId)
        return RoundedRectangle(cornerRadius: 6)
            .fill(Self.palette[index % Self.palette.count].gradient)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.name)
                        .font(.caption2.bold())
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if clip.filter != nil { Image(systemName: "camera.filters") }
                        if !clip.effects.isEmpty { Image(systemName: "sparkles") }
                        if clip.speed != 1 { Text(Self.speedLabel(clip.speed)) }
                    }
                    .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.yellow : Color.black.opacity(0.35), lineWidth: selected ? 3 : 1)
            }
            .frame(width: max(x(clip.timelineDurationUs), 6), height: clipHeight)
            .clipped()
            .offset(x: x(clip.timelineStartUs), y: clipTop)
            .onTapGesture { onSelect(.clip(clip.segmentId)) }
    }

    private func transitionMarker(atUs: Double) -> some View {
        Image(systemName: "square.on.square")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Color.black.opacity(0.7), in: Circle())
            .offset(x: x(atUs) - 11, y: clipTop + clipHeight / 2 - 11)
            .allowsHitTesting(false)
    }

    private func textBlock(_ text: RenderPlan.Text) -> some View {
        let selected = selection == .text(text.id)
        return RoundedRectangle(cornerRadius: 4)
            .fill(Color.yellow.opacity(0.85))
            .overlay(alignment: .leading) {
                Label(text.text, systemImage: "textformat")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Color.white : Color.clear, lineWidth: 2)
            }
            .frame(width: max(x(text.durationUs), 6), height: textHeight)
            .clipped()
            .offset(x: x(text.startUs), y: textTop)
            .onTapGesture { onSelect(.text(text.id)) }
    }

    static func tickLabel(_ second: Double) -> String {
        let total = Int(second)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func speedLabel(_ speed: Double) -> String {
        "\(speed.decimalText())x"
    }
}
