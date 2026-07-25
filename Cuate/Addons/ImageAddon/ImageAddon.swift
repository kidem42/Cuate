import Foundation

/// ImageAddon — image operations (upscale, background/object removal — P1;
/// generation — P2) через облачные AI-API, встроенные в панель чата.
///
/// Self-contained: всё живёт в `Addons/ImageAddon/`. Host mount points:
/// 1. `ImageAddon.shared.start()` в `applicationDidFinishLaunching`.
/// 2. `SettingsView` — `case imageAddon` + вкладка + `ImageAddonEnableToggle`.
/// 3. `ChatWindow` — `ImageAttachmentActionsBar` под превью аттача.
/// 4. `MessageRow` — `ImageResultActionsBar` под картинками ассистента.
/// 5. `APIKeyStore.AuxKey.fal` — слот ключа.
@MainActor
final class ImageAddon {
    static let shared = ImageAddon()

    private init() {}

    /// Mount point #1 — call once from `applicationDidFinishLaunching`.
    /// Ничего не запускает в фоне; резервирует место под будущую
    /// инициализацию (миграции настроек, прогрев каталога).
    func start() {
        let settings = ImageAddonSettings.shared
        Diagnostics.log("imageaddon", "start enabled=\(settings.enabled) hasKey=\(APIKeyStore.hasKey(aux: .fal))")
    }
}
