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
        case .working: CGSize(width: 400, height: notch.height + rowHeight)
        case .done, .failed: CGSize(width: 360, height: notch.height + rowHeight)
        case .answer(let text): CGSize(width: answerWidth, height: notch.height + answerHeight(text))
        }
    }

    private var isOpen: Bool { state.phase != .idle }
    private var isAnswer: Bool { if case .answer = state.phase { return true }; return false }

    static let answerWidth: CGFloat = 540
    private var answerWidth: CGFloat { Self.answerWidth }
    private func answerHeight(_ text: String) -> CGFloat { Self.answerHeight(text) }
    /// Grows with the answer, up to a readable panel; longer answers scroll.
    static func answerHeight(_ text: String) -> CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 62))) }
        return min(380, 64 + CGFloat(lines) * 20)
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(topRadius: flare, bottomRadius: isOpen ? 22 : 10)
                .fill(.black)
                .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 18, y: 8)

            if case .answer(let text) = state.phase {
                AnswerPanel(question: state.transcript, text: text, dismiss: state.dismiss)
                    .padding(.horizontal, flare + 16)
                    .padding(.bottom, 14)
                    .offset(y: notch.height)
                    .frame(height: size.height - notch.height, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            } else if isOpen {
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
        case .thinking: state.transcript.isEmpty ? "Thinking…" : state.transcript
        case .working(let step): step
        case .done(let message), .failed(let message), .answer(let message): message
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state.phase {
        case .listening:
            Waveform(level: state.level).frame(width: 64, height: 22)
        case .thinking, .working:
            ProgressView().controlSize(.small).tint(.white)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18)).foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18)).foregroundStyle(.red)
        case .idle, .answer:
            EmptyView()
        }
    }
}

/// Reading view for Brain answers: scrollable, selectable, stays until closed.
private struct AnswerPanel: View {
    let question: String
    let text: String
    let dismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Orb(phase: .answer(text)).frame(width: 18, height: 18)
                Text(question.isEmpty ? "Answer" : question)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(PanelButton())
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(PanelButton())
                .help("Close (Esc)")
            }
            .padding(.top, 10)

            ScrollView {
                Text(Self.render(text))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.92))
                    .tint(.cyan)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 6)
            }
            .scrollIndicators(.automatic)
        }
    }

    /// Bold, italics and links from Brain's markdown; keeps its line breaks and bullets.
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let bulleted = text.replacingOccurrences(of: #"(?m)^\s*[-*] "#, with: "•  ", options: .regularExpression)
        return (try? AttributedString(markdown: bulleted, options: options)) ?? AttributedString(text)
    }
}

private struct PanelButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.9))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.2 : 0.12)))
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
        case .working: [.blue, .purple, .cyan, .blue]
        case .done: [.green, .mint, .teal, .green]
        case .failed: [.red, .orange, .pink, .red]
        case .answer: [.purple, .blue, .cyan, .purple]
        case .idle: [.gray, .gray]
        }
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let busy: Bool = { if case .working = phase { return true }; return phase == .thinking }()
            let speed: Double = busy ? 3 : 1.2
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
