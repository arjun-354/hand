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

    /// Screenshots each of `pid`'s visible windows (main window, dialogs, dropdowns)
    /// and reads the text on them.
    static func readText(pid: pid_t) async -> [TextBox] {
        guard hasPermission else { return [] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows
                .filter { $0.owningApplication?.processID == pid && $0.frame.width > 40 && $0.frame.height > 20 }
                .sorted { $0.windowLayer > $1.windowLayer }
                .prefix(4)
            guard !windows.isEmpty else {
                log("vision: no visible windows for \(pid)"); return []
            }

            var boxes: [TextBox] = []
            for window in windows {
                // A single-window capture shows exactly `window.frame` (global points, top-left origin).
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = CGFloat(filter.pointPixelScale)
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                if window == windows.first { saveForDebugging(image) }
                boxes += try recognize(image, covering: window.frame)
            }
            log("vision: \(windows.count) window(s) \(windows.map { "\($0.frame)" }.joined(separator: " ")) -> \(boxes.count) text boxes")
            return boxes
        } catch {
            log("vision error: \(error)")
            return []
        }
    }

    /// `area` is the on-screen rectangle (global points) the image shows.
    private static func recognize(_ image: CGImage, covering area: CGRect) throws -> [TextBox] {
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
                x: area.minX + box.minX * area.width,
                y: area.minY + (1 - box.maxY) * area.height,
                width: box.width * area.width,
                height: box.height * area.height
            )
            return TextBox(text: text, frame: frame)
        }
    }

    /// Keeps the latest capture at ~/Library/Logs/Hand/last-capture.png for debugging.
    private static func saveForDebugging(_ image: CGImage) {
        let url = Log.dir.appendingPathComponent("last-capture.png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
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
