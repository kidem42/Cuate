import Foundation

/// ImageAddon — image operations (upscale, background/object removal — P1;
/// generation — P2) over cloud AI APIs, built into the chat panel.
///
/// Self-contained: everything lives in `Addons/ImageAddon/`. Host mount points:
/// 1. `ImageAddon.shared.start()` in `applicationDidFinishLaunching`.
/// 2. `SettingsView` — `case imageAddon` + tab + `ImageAddonEnableToggle`.
/// 3. `ChatWindow` — `ImageAttachmentActionsBar` under the attachment preview.
/// 4. `MessageRow` — `ImageResultActionsBar` under assistant images.
/// 5. `APIKeyStore.AuxKey.fal` — the key slot.
@MainActor
final class ImageAddon {
    static let shared = ImageAddon()

    private init() {}

    /// Mount point #1 — call once from `applicationDidFinishLaunching`.
    /// Starts nothing in the background; it reserves the spot for future
    /// initialization (settings migrations, catalog warm-up).
    func start() {
        let settings = ImageAddonSettings.shared
        Diagnostics.log("imageaddon", "start enabled=\(settings.enabled) hasKey=\(APIKeyStore.hasKey(aux: .fal))")
    }
}
