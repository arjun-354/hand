import AppKit
import ScreenCaptureKit
import Vision

/// Sees what an app draws: screenshots its windows (dialogs and dropdowns
/// included) and turns every visible word into a clickable element. Covers apps
/// that expose little to Accessibility, like CapCut (Qt) or games.
/// Needs the Screen Recording permission.
enum ScreenVision {
    struct TextBox {
        let text: String
        /// Global screen coordinates, top-left origin.
        let frame: CGRect
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Screenshots only `pid`'s windows on the display it's using and reads the text.
    static func readText(pid: pid_t) async -> [TextBox] {
        guard hasPermission else { return [] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let app = content.applications.first(where: { $0.processID == pid }) else { return [] }
            let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.frame.width > 40 }
            guard let biggest = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
                  let display = content.displays.first(where: { $0.frame.intersects(biggest.frame) }) ?? content.displays.first
            else { return [] }

            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
            config.width = Int(display.frame.width * scale)
            config.height = Int(display.frame.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return try recognize(image, in: display.frame)
        } catch {
            log("vision error: \(error)")
            return []
        }
    }

    private static func recognize(_ image: CGImage, in displayFrame: CGRect) throws -> [TextBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false  // UI labels like "4K", "60fps", "H.264" aren't dictionary words
        try VNImageRequestHandler(cgImage: image).perform([request])

        return (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                  text.count <= 48, text.contains(where: \.isLetter) || text.contains(where: \.isNumber)
            else { return nil }
            // Vision boxes are normalized with a bottom-left origin.
            let box = obs.boundingBox
            let frame = CGRect(
                x: displayFrame.minX + box.minX * displayFrame.width,
                y: displayFrame.minY + (1 - box.maxY) * displayFrame.height,
                width: box.width * displayFrame.width,
                height: box.height * displayFrame.height
            )
            return TextBox(text: text, frame: frame)
        }
    }

    /// Loads the text model at launch so the first real read is fast.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            guard let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0),
                  let image = ctx.makeImage() else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: image).perform([request])
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
