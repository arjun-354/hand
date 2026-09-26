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
    static let canvas = NSSize(width: 560, height: 240)

    init(state: HandState) {
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
    }

    override var canBecomeKey: Bool { false }
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
