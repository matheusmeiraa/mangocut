import SwiftUI

/// Timeline horizontal no estilo CapCut: régua de tempo, trilha principal com visual de película de cinema,
/// borda branca de seleção com alças amarelas de corte, transições interativas, trilha de legendas/textos
/// e agulha de reprodução com indicador superior.
struct TimelineView: View {
    let plan: RenderPlan
    let currentUs: Double
    let selection: EditorSelection?
    let pointsPerSecond: Double
    let onSeek: (Double) -> Void
    let onSelect: (EditorSelection?) -> Void
    var onTransitionTap: ((RenderPlan.Clip) -> Void)? = nil

    private let rulerHeight: CGFloat = 24
    private let clipHeight: CGFloat = 60
    private let textHeight: CGFloat = 26
    private let gap: CGFloat = 8

    private var pps: CGFloat { CGFloat(pointsPerSecond) }
    private var clipTop: CGFloat { rulerHeight + gap }
    private var textTop: CGFloat { clipTop + clipHeight + gap }
    private var totalHeight: CGFloat { textTop + textHeight + 8 }

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

                // Trilhas guias de fundo
                Rectangle()
                    .fill(Color.capcutBar)
                    .frame(width: contentWidth + 60, height: clipHeight)
                    .offset(y: clipTop)

                ForEach(Array(plan.clips.enumerated()), id: \.offset) { index, clip in
                    clipBlock(clip, index: index)
                }

                ForEach(Array(plan.clips.enumerated()), id: \.offset) { _, clip in
                    if let transition = clip.transitionIn {
                        transitionMarker(clip: clip, atUs: clip.timelineStartUs + transition.durationUs / 2)
                    }
                }

                ForEach(plan.texts) { text in
                    textBlock(text)
                }

                // Agulha de reprodução estilo CapCut (linha branca com cápsula no topo)
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: totalHeight)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: 10, height: 16)
                        .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                }
                .offset(x: x(currentUs) - 5)
                .allowsHitTesting(false)
            }
            .frame(width: contentWidth + 80, height: totalHeight, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
        .background(Color.capcutDark)
    }

    private func x(_ us: Double) -> CGFloat {
        CGFloat(us / 1_000_000) * pps
    }

    private var ruler: some View {
        let step: Double = pps >= 40 ? 1 : (pps >= 15 ? 5 : 10)
        let ticks = Array(stride(from: 0.0, through: Double(contentWidth / pps) + 5, by: step))
        return ZStack(alignment: .topLeading) {
            Color.capcutBar
            ForEach(ticks, id: \.self) { second in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.tickLabel(second))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.gray.opacity(0.8))
                    Rectangle()
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 1, height: 6)
                }
                .offset(x: CGFloat(second) * pps)
            }
        }
        .frame(width: contentWidth + 60, height: rulerHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            onSeek(Double(max(0, value.location.x) / pps) * 1_000_000)
        })
    }

    private func clipBlock(_ clip: RenderPlan.Clip, index: Int) -> some View {
        let selected = selection == .clip(clip.segmentId)
        let clipWidth = max(x(clip.timelineDurationUs), 10)

        return ZStack(alignment: .leading) {
            // Fundo escuro de película
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#262634"), Color(hex: "#1C1C24")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Linhas de perfuração de filme sutis
            VStack {
                HStack(spacing: 6) {
                    ForEach(0..<max(Int(clipWidth / 12), 1), id: \.self) { _ in
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 5, height: 3)
                    }
                }
                .padding(.top, 3)

                Spacer()

                HStack(spacing: 6) {
                    ForEach(0..<max(Int(clipWidth / 12), 1), id: \.self) { _ in
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 5, height: 3)
                    }
                }
                .padding(.bottom, 3)
            }
            .allowsHitTesting(false)

            // Conteúdo e badges do clipe
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.name)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if clip.filter != nil {
                        Image(systemName: "camera.filters")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.capcutCyan)
                    }
                    if !clip.effects.isEmpty {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.capcutPurple)
                    }
                    if clip.speed != 1 {
                        Text(Self.speedLabel(clip.speed))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.capcutYellow)
                    }
                }
            }
            .padding(.horizontal, selected ? 10 : 8)
            .padding(.vertical, 8)

            // Borda de seleção clássica do CapCut (borda branca grossa com alças amarelas de recorte)
            if selected {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white, lineWidth: 2.5)

                // Alça esquerda de trim
                Capsule()
                    .fill(Color.capcutYellow)
                    .frame(width: 4, height: 28)
                    .padding(.leading, 3)

                // Alça direita de trim
                HStack {
                    Spacer()
                    Capsule()
                        .fill(Color.capcutYellow)
                        .frame(width: 4, height: 28)
                        .padding(.trailing, 3)
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.capcutBorder, lineWidth: 1)
            }
        }
        .frame(width: clipWidth, height: clipHeight)
        .clipped()
        .offset(x: x(clip.timelineStartUs), y: clipTop)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(.clip(clip.segmentId)) }
    }

    private func transitionMarker(clip: RenderPlan.Clip, atUs: Double) -> some View {
        Button {
            onTransitionTap?(clip)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.capcutCardHover)
                    .frame(width: 20, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.5), radius: 2)

                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.capcutCyan)
            }
        }
        .buttonStyle(.plain)
        .offset(x: x(atUs) - 10, y: clipTop + clipHeight / 2 - 10)
    }

    private func textBlock(_ text: RenderPlan.Text) -> some View {
        let selected = selection == .text(text.id)
        let textWidth = max(x(text.durationUs), 12)

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [Color.mango, Color(hex: "#FF5500")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            HStack(spacing: 4) {
                Image(systemName: "textformat")
                    .font(.system(size: 9, weight: .bold))
                Text(text.text)
                    .font(.caption2.bold())
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)

            if selected {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white, lineWidth: 2)
            }
        }
        .frame(width: textWidth, height: textHeight)
        .clipped()
        .offset(x: x(text.startUs), y: textTop)
        .contentShape(Rectangle())
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
