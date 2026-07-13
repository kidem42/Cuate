import AppKit
import Foundation
import ScreenCaptureKit
import CoreVideo

enum ScreenshotError: LocalizedError {
    case displayUnavailable
    case captureFailed
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            return "Failed to determine the active screen. Please try again."
        case .captureFailed:
            return "Failed to take screenshot. Check Screen Recording permissions in System Settings."
        case .notAuthorized:
            return "The app needs Screen Recording permission. Enable it in System Settings → Privacy & Security → Screen Recording."
        }
    }
}

@available(macOS 14.0, *)
struct ScreenshotCapturer {

    /// Interactive area selection using the system tool (`screencapture -i`) —
    /// the native crosshair UI (drag an area, or press Space to pick a window).
    /// Returns `nil` if the user cancels with Esc.
    static func captureInteractiveArea() async throws -> Data? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("area_capture_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", tempURL.path] // interactive, no shutter sound

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        // Esc during selection → no file written → treat as cancel.
        guard FileManager.default.fileExists(atPath: tempURL.path) else { return nil }
        return try Data(contentsOf: tempURL)
    }

    static func captureActiveDisplay() async throws -> Data {
        guard let screen = activeScreen() else {
            throw ScreenshotError.displayUnavailable
        }

        guard let displayID = displayIdentifier(for: screen) else {
            throw ScreenshotError.displayUnavailable
        }

        guard ensureScreenCaptureAccess() else {
            throw ScreenshotError.notAuthorized
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw ScreenshotError.notAuthorized
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotError.displayUnavailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [] as [SCWindow])
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.width = size_t(display.width)
        config.height = size_t(display.height)
        config.showsCursor = true
        config.capturesAudio = false

        let cgImage = try await captureImage(filter: filter, configuration: config)

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotError.captureFailed
        }

        return pngData
    }

    private static func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { cgImage, error in
                if let error = error as NSError? {
                    if error.domain == SCStreamErrorDomain && error.code == Int(SCStreamError.userDeclined.rawValue) {
                        continuation.resume(throwing: ScreenshotError.notAuthorized)
                    } else {
                        continuation.resume(throwing: ScreenshotError.captureFailed)
                    }
                    return
                }

                if let cgImage {
                    continuation.resume(returning: cgImage)
                } else {
                    continuation.resume(throwing: ScreenshotError.captureFailed)
                }
            }
        }
    }

    private static func ensureScreenCaptureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    private static func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screenUnderCursor = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screenUnderCursor
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static func displayIdentifier(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(truncating: screenNumber)
    }
}
