import AppKit
import SwiftUI

@MainActor
@Observable
final class PointerModel {
    var label = ""
    var visible = false
    var clicks = 0
}

/// Hand's own on-screen pointer: glides to whatever it's about to use and
/// ripples when it clicks. Separate from the real mouse cursor.
@MainActor
final class Pointer {
    private let model = PointerModel()
    private let panel: NSPanel
    private static let size = NSSize(width: 320, height: 90)
    /// Where the arrow tip sits inside the panel (from the top-left corner).
    private static let tip = CGPoint(x: 20, y: 20)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: PointerView(model: model, tip: Self.tip))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
    }

    /// Animates the pointer to a global top-left-origin point.
    func move(to point: CGPoint, label: String) async {
        model.label = label
        let origin = Self.panelOrigin(for: point)
        if !model.visible {
            // Enter from the notch.
            let screen = NotchPanel.targetScreen().frame
            panel.setFrameOrigin(NSPoint(x: screen.midX - Self.tip.x, y: screen.maxY - Self.size.height))
            panel.orderFrontRegardless()
            model.visible = true
        }
        await withCheckedContinuation { cont in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.45
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrameOrigin(origin)
            }, completionHandler: { cont.resume() })
        }
    }

    func clickPulse() { model.clicks += 1 }

    func hide() {
        model.visible = false
        Task {
            try? await Task.sleep(for: .seconds(0.3))
            if !model.visible { panel.orderOut(nil) }
        }
    }

    private static func panelOrigin(for point: CGPoint) -> NSPoint {
        // AX/CGEvent space has y growing down from the top of the primary screen; AppKit grows up.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = primaryHeight - point.y
        return NSPoint(x: point.x - tip.x, y: cocoaY - size.height + tip.y)
    }
}

private struct PointerView: View {
    let model: PointerModel
    let tip: CGPoint
    @State private var ripple = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .stroke(Color.cyan, lineWidth: 2)
                .frame(width: 36, height: 36)
                .scaleEffect(ripple ? 1.6 : 0.2)
                .opacity(ripple ? 0 : 0.9)
                .offset(x: tip.x - 18, y: tip.y - 18)

            ArrowShape()
                .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                .overlay(ArrowShape().stroke(.white, lineWidth: 1.5))
                .frame(width: 20, height: 26)
                .shadow(color: .cyan.opacity(0.8), radius: 8)
                .offset(x: tip.x, y: tip.y)

            if !model.label.isEmpty {
                Text(model.label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.85)))
                    .overlay(Capsule().stroke(.cyan.opacity(0.6), lineWidth: 1))
                    .offset(x: tip.x + 20, y: tip.y + 22)
                    .frame(maxWidth: 280, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(model.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: model.visible)
        .onChange(of: model.clicks) {
            ripple = false
            withAnimation(.easeOut(duration: 0.5)) { ripple = true }
        }
    }
}

private struct ArrowShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY * 0.82))
        p.addLine(to: CGPoint(x: r.width * 0.3, y: r.height * 0.62))
        p.addLine(to: CGPoint(x: r.width * 0.55, y: r.maxY))
        p.addLine(to: CGPoint(x: r.width * 0.72, y: r.height * 0.92))
        p.addLine(to: CGPoint(x: r.width * 0.47, y: r.height * 0.56))
        p.addLine(to: CGPoint(x: r.maxX, y: r.height * 0.56))
        p.closeSubpath()
        return p
    }
}
