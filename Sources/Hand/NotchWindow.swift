import AppKit
import SwiftUI

/// Size of the camera housing on the current screen. Falls back to a
/// notch-sized pill on displays without one (external monitors, older Macs).
struct NotchGeometry {
    var width: CGFloat
    var height: CGFloat

    static func of(_ screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return NotchGeometry(width: screen.frame.width - left.width - right.width, height: top)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(width: 190, height: max(menuBar, 24))
    }
}

/// Transparent, click-through panel pinned over the notch. The panel itself
/// never moves; the SwiftUI shape inside it grows out of the notch.
final class NotchPanel: NSPanel {
    static let canvas = NSSize(width: 620, height: 460)
    private let state: HandState
    /// True while an answer is showing; read by canBecomeKey without touching the actor.
    private var interactive = false

    init(state: HandState) {
        self.state = state
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        level = .statusBar + 1  // above the menu bar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let screen = Self.targetScreen()
        let host = NSHostingView(rootView: NotchView(state: state, notch: .of(screen)))
        host.frame = NSRect(origin: .zero, size: Self.canvas)
        contentView = host
        place(on: screen)
        followPhase()
    }

    /// Answers are interactive (scroll, select, copy, close); everything else is click-through.
    private func followPhase() {
        withObservationTracking {
            _ = state.phase
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let answering: Bool = { if case .answer = self.state.phase { return true }; return false }()
                self.ignoresMouseEvents = !answering
                self.interactive = answering
                // While interactive, the window is exactly the panel, so it can't swallow clicks around it.
                let screen = Self.targetScreen()
                if case .answer(let text) = self.state.phase {
                    let size = NSSize(width: NotchView.answerWidth + 24,
                                      height: NotchGeometry.of(screen).height + NotchView.answerHeight(text) + 6)
                    self.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                                         width: size.width, height: size.height), display: true)
                } else if self.frame.size != Self.canvas {
                    self.place(on: screen)
                }
                if answering { self.makeKeyAndOrderFront(nil) } else if self.isKeyWindow { self.resignKey() }
                self.followPhase()
            }
        }
    }

    /// Esc closes an answer.
    override func cancelOperation(_ sender: Any?) {
        DispatchQueue.main.async { [state] in state.dismiss() }
    }

    override var canBecomeKey: Bool {
        interactive
    }
    override var canBecomeMain: Bool { false }

    // Borderless windows get pushed below the menu bar by default; keep ours flush with the top edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func place(on screen: NSScreen) {
        let origin = NSPoint(
            x: screen.frame.midX - Self.canvas.width / 2,
            y: screen.frame.maxY - Self.canvas.height
        )
        setFrame(NSRect(origin: origin, size: Self.canvas), display: true)
    }

    /// Prefer the built-in display with a notch.
    static func targetScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
