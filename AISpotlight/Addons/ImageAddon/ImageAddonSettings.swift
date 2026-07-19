import Foundation
import Combine

extension Notification.Name {
    /// Posted when the addon's enable flag changes (the host refreshes UI
    /// that gates on it). Kept separate from app-wide notifications.
    static let imageAddonDidChange = Notification.Name("imageAddonDidChange")
}

/// Persisted settings for the ImageAddon. Own `UserDefaults` keys (prefix
/// `imageAddon.`), nothing stored in the app's `AppSettings` — the addon
/// stays fully self-contained (pattern: `LayoutFixSettings`).
@MainActor
final class ImageAddonSettings: ObservableObject {
    static let shared = ImageAddonSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Master switch

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "imageAddon.enabled")
            NotificationCenter.default.post(name: .imageAddonDidChange, object: nil)
        }
    }

    // MARK: - Model choice (per function, ТЗ §3.1)

    @Published var upscaleModel: String {
        didSet { defaults.set(upscaleModel, forKey: "imageAddon.upscaleModel") }
    }

    @Published var backgroundModel: String {
        didSet { defaults.set(backgroundModel, forKey: "imageAddon.backgroundModel") }
    }

    /// Mask-based object cleanup model (кисть).
    @Published var cleanupModel: String {
        didSet { defaults.set(cleanupModel, forKey: "imageAddon.cleanupModel") }
    }

    /// Catalog entry for the selected model of a function, falling back to
    /// the first available one if the saved id vanished from the catalog.
    private func modelInfo(_ id: String, function: ImageFunction) -> ImageModelInfo? {
        if let info = ImageProviderRegistry.model(id: id), info.function == function {
            return info
        }
        return ImageProviderRegistry.models(for: function).first
    }

    var upscaleModelInfo: ImageModelInfo? { modelInfo(upscaleModel, function: .upscale) }
    var backgroundModelInfo: ImageModelInfo? { modelInfo(backgroundModel, function: .removeBackground) }
    var cleanupModelInfo: ImageModelInfo? { modelInfo(cleanupModel, function: .objectCleanup) }

    /// The text-mode cleanup model (fixed: the catalog's by-text entry).
    var cleanupTextModelInfo: ImageModelInfo? {
        ImageProviderRegistry.models(for: .objectCleanup).first { $0.cleanupByText }
    }

    // MARK: - Output & input options (ТЗ §4.4b / §4.5)

    /// Result format. Background removal always keeps PNG (alpha).
    @Published var outputFormat: ImageOutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: "imageAddon.outputFormat") }
    }

    /// Copy every result to the clipboard automatically (off by default).
    @Published var autoCopyResult: Bool {
        didSet { defaults.set(autoCopyResult, forKey: "imageAddon.autoCopyResult") }
    }

    /// Input ceiling in megapixels; bigger inputs are downscaled with a
    /// warning. The byte ceiling is fixed.
    @Published var maxInputMegapixels: Double {
        didSet { defaults.set(maxInputMegapixels, forKey: "imageAddon.maxInputMegapixels") }
    }

    static let maxInputBytes = 20 * 1024 * 1024 // 20 MB (ТЗ §4.4b)

    // MARK: - Save folder (nil = Downloads)

    @Published var saveFolderPath: String? {
        didSet { defaults.set(saveFolderPath, forKey: "imageAddon.saveFolderPath") }
    }

    /// Where the one-click Save button writes results.
    var saveFolderURL: URL {
        if let path = saveFolderPath, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    // MARK: - Spend counters (estimates from catalog prices, local only)

    /// Accumulated cost for the current calendar month.
    @Published private(set) var spentMonthUSD: Double
    /// Accumulated cost since app launch (not persisted).
    @Published private(set) var sessionSpentUSD: Double = 0

    func addSpent(_ cost: Double) {
        guard cost > 0 else { return }
        rolloverMonthIfNeeded()
        sessionSpentUSD += cost
        spentMonthUSD += cost
        defaults.set(spentMonthUSD, forKey: "imageAddon.spentMonthUSD")
    }

    private static func currentMonthKey() -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return "\(comps.year ?? 0)-\(comps.month ?? 0)"
    }

    /// Resets the month counter when a new calendar month starts.
    private func rolloverMonthIfNeeded() {
        let key = Self.currentMonthKey()
        guard defaults.string(forKey: "imageAddon.spentMonthKey") != key else { return }
        defaults.set(key, forKey: "imageAddon.spentMonthKey")
        spentMonthUSD = 0
        defaults.set(0.0, forKey: "imageAddon.spentMonthUSD")
    }

    // MARK: - Init

    private init() {
        // Enabled by default: background removal works out of the box on-device
        // (no key). Existing users who explicitly toggled it keep their choice
        // (the key is only present once they've flipped the switch).
        enabled = defaults.object(forKey: "imageAddon.enabled") as? Bool ?? true
        // Default models are the free on-device ones; cloud models stay
        // available for anyone who picks them (needs a fal.ai key).
        upscaleModel = defaults.string(forKey: "imageAddon.upscaleModel") ?? AppleImageProvider.upscaleID
        backgroundModel = defaults.string(forKey: "imageAddon.backgroundModel") ?? AppleImageProvider.backgroundID
        cleanupModel = defaults.string(forKey: "imageAddon.cleanupModel") ?? FalImageProvider.briaEraserID
        outputFormat = defaults.string(forKey: "imageAddon.outputFormat")
            .flatMap(ImageOutputFormat.init(rawValue:)) ?? .png
        autoCopyResult = defaults.bool(forKey: "imageAddon.autoCopyResult")
        let storedMP = defaults.double(forKey: "imageAddon.maxInputMegapixels")
        maxInputMegapixels = storedMP > 0 ? storedMP : 25
        saveFolderPath = defaults.string(forKey: "imageAddon.saveFolderPath")
        if defaults.string(forKey: "imageAddon.spentMonthKey") == Self.currentMonthKey() {
            spentMonthUSD = defaults.double(forKey: "imageAddon.spentMonthUSD")
        } else {
            spentMonthUSD = 0
        }
    }
}
