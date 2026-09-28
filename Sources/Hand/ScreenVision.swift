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

    /// Screenshots the whole display (always 1:1 with screen coordinates, unlike
    /// per-app or per-window captures, which crop and rescale) and keeps the text
    /// that falls inside `pid`'s windows. What's on top is what's clickable.
    static func readText(pid: pid_t) async -> [TextBox] {
        guard hasPermission else { return [] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let appWindows = content.windows
                .filter { $0.owningApplication?.processID == pid && $0.frame.width > 40 && $0.frame.height > 20 }
                .map(\.frame)
            guard let anchor = appWindows.max(by: { $0.width * $0.height < $1.width * $1.height }),
                  let display = content.displays.first(where: { $0.frame.intersects(anchor) }) ?? content.displays.first
            else {
                log("vision: no visible windows for \(pid)"); return []
            }

            // Leave Hand's own notch out of the picture.
            let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingWindows: own)
            let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.width = Int(display.frame.width * scale)
            config.height = Int(display.frame.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            saveForDebugging(image)

            let boxes = try recognize(image, covering: display.frame).filter { box in
                let center = CGPoint(x: box.frame.midX, y: box.frame.midY)
                return appWindows.contains { $0.contains(center) }
            }
            log("vision: display \(display.frame), \(appWindows.count) app window(s) -> \(boxes.count) text boxes")
            return boxes
        } catch {
            log("vision error: \(error)")
            return []
        }
    }

    /// JPEG of `pid`'s main window, scaled to at most 1280px, for Gemini to look at.
    /// Never for windows that look like secret files.
    static func windowImageJPEG(pid: pid_t) async -> Data? {
        guard hasPermission else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows
                .filter({ $0.owningApplication?.processID == pid && $0.frame.width > 100 && $0.frame.height > 100 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
                  !Redact.isSecretWindow(window.title ?? "") else { return nil }
            // Capture the display (reliable, 1:1 with screen points) and crop to the window.
            guard let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) ?? content.displays.first
            else { return nil }
            let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
            let config = SCStreamConfiguration()
            config.width = Int(display.frame.width)
            config.height = Int(display.frame.height)
            config.showsCursor = false
            var shot: CGImage?
            for attempt in 0..<3 where shot == nil {
                if attempt > 0 { try? await Task.sleep(for: .seconds(0.3)) }  // another capture may be running
                shot = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: config)
            }
            let crop = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                .intersection(CGRect(origin: .zero, size: display.frame.size))
            guard let full = shot, !crop.isNull, let image = full.cropping(to: crop) else {
                log("window image: capture failed"); return nil
            }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return data as Data
        } catch {
            log("window image error: \(error)")
            return nil
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
