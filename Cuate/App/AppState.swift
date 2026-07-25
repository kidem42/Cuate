import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var pendingAttachment: ChatAttachment?

    /// Text captured from the frontmost app's selection when the panel was
    /// summoned (`SelectionGrabber`) — ChatWindow moves it into the input.
    @Published var pendingInputText: String?

    func setScreenshot(data: Data) {
        // File-backed (like every other attach path) so screenshots never bloat
        // the chat store with inline base64 — the store keeps only a reference.
        let timestamp = Int(Date().timeIntervalSince1970)
        pendingAttachment = ChatAttachment.fileBacked(
            data: data, mimeType: "image/png", filename: "screenshot-\(timestamp).png"
        )
    }

    func clearPendingAttachment() {
        pendingAttachment = nil
    }
}
