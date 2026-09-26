import SwiftUI

struct NotchView: View {
    let state: HandState
    let notch: NotchGeometry

    private let rowHeight: CGFloat = 54
    private let flare: CGFloat = 10  // outward curve where the shape meets the screen edge

    private var size: CGSize {
        switch state.phase {
        case .idle: CGSize(width: notch.width + flare * 2, height: notch.height)
        case .listening: CGSize(width: 380, height: notch.height + rowHeight)
        case .thinking: CGSize(width: 320, height: notch.height + rowHeight)
        case .done, .failed: CGSize(width: 360, height: notch.height + rowHeight)
        }
    }

    private var isOpen: Bool { state.phase != .idle }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(topRadius: flare, bottomRadius: isOpen ? 22 : 10)
                .fill(.black)
                .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 18, y: 8)

            if isOpen {
                content
                    .frame(height: rowHeight)
                    .padding(.horizontal, flare + 18)
                    .offset(y: notch.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .opacity(isOpen ? 1 : 0)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: state.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: 12) {
            Orb(phase: state.phase)
                .frame(width: 26, height: 26)

            Text(label)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.head)
                .contentTransition(.opacity)

            Spacer(minLength: 8)

            trailing
        }
    }

    private var label: String {
        switch state.phase {
        case .idle: ""
        case .listening: state.transcript.isEmpty ? "Listening…" : state.transcript
        case .thinking: "Thinking…"
        case .done(let message), .failed(let message): message
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state.phase {
        case .listening:
            Waveform(level: state.level).frame(width: 64, height: 22)
        case .thinking:
            ProgressView().controlSize(.small).tint(.white)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18)).foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18)).foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }
}

/// Notch silhouette: flush with the top edge, flared top corners, rounded bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius
        let b = min(bottomRadius, (rect.height - t) / 2, (rect.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Glowing orb whose colors track what Hand is doing.
struct Orb: View {
    let phase: Phase

    private var colors: [Color] {
        switch phase {
        case .listening: [.cyan, .blue, .mint, .cyan]
        case .thinking: [.purple, .pink, .indigo, .purple]
        case .done: [.green, .mint, .teal, .green]
        case .failed: [.red, .orange, .pink, .red]
        case .idle: [.gray, .gray]
        }
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let speed: Double = phase == .thinking ? 3 : 1.2
            let pulse = phase == .listening ? 1 + 0.08 * sin(t * 5) : 1
            Circle()
                .fill(AngularGradient(colors: colors, center: .center,
                                      angle: .radians(t * speed)))
                .blur(radius: 1.5)
                .overlay(Circle().fill(.white.opacity(0.25)).scaleEffect(0.35).blur(radius: 3))
                .scaleEffect(pulse)
                .shadow(color: colors[0].opacity(0.7), radius: 8)
        }
    }
}

/// Bars that bounce with the mic level. Uses a fake signal until audio input exists.
struct Waveform: View {
    let level: Double
    private let bars = 7

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    let wobble = (sin(t * 7 + Double(i) * 0.9) + sin(t * 4.3 + Double(i) * 1.7)) / 4 + 0.5
                    let amp = level > 0 ? level : 0.55
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: 3, height: max(4, 22 * wobble * amp + 3))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
