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
        let base64 = data.base64EncodedString()
        let timestamp = Int(Date().timeIntervalSince1970)
        let attachment = ChatAttachment(
            filename: "screenshot-\(timestamp).png",
            mimeType: "image/png",
            base64: base64
        )
        pendingAttachment = attachment
    }

    func clearPendingAttachment() {
        pendingAttachment = nil
    }
}
