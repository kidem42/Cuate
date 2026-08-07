import Foundation

// MARK: - Functions & providers

/// The image operations the addon can perform. `generate` is P2 — the case
/// exists so the catalog/protocol shape is final, but nothing wires it yet.
enum ImageFunction: String, CaseIterable, Codable {
    case upscale
    case removeBackground
    case objectCleanup
    case generate
}

/// Backends that can run image operations. `apple` is native and on-device
/// (background removal only); `fal` is the cloud API for everything else.
/// Declared apple-first so it leads the background-removal picker.
enum ImageProviderID: String, CaseIterable, Codable, Identifiable {
    case apple
    case fal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .fal: return "fal.ai"
        }
    }

    /// Whether this backend needs an API key in the Keychain. On-device
    /// providers run without one, so the UI must not gate them behind a key.
    var requiresKey: Bool {
        switch self {
        case .apple: return false
        case .fal: return true
        }
    }
}

// MARK: - Model catalog entries

/// Fixed model-class badge shown next to each model in pickers (spec §3.1a).
enum ImageModelTier: String, Codable {
    case onDevice, budget, standard, quality, premium, smart, freedom

    /// Localized badge label.
    var label: String { IAL("ia.tier.\(rawValue)") }
}

/// One catalog entry: a concrete model behind a function, with everything the
/// UI needs (badge, one-line caption, price). The catalog is static and ships
/// with app releases (spec §5).
struct ImageModelInfo: Identifiable, Equatable {
    /// Provider-side endpoint id, e.g. "fal-ai/recraft/upscale/crisp".
    let id: String
    let name: String
    let function: ImageFunction
    let provider: ImageProviderID
    let tier: ImageModelTier
    /// IAL key of the one-line UI caption.
    let captionKey: String
    /// Fixed price per operation in USD (nil when metered, e.g. per-MP).
    let priceUSD: Double?
    /// Human price label for the picker ("$0.004", "~$0.08–0.15").
    let priceLabel: String
    /// The model's input must be PNG — the request layer converts beforehand.
    var requiresPNGInput: Bool = false
    /// Highest upscale factor the model accepts; nil = the model has no
    /// factor parameter (e.g. Recraft Crisp decides on its own).
    var maxUpscaleFactor: Int? = nil
    /// The model exposes a face-enhancement switch (spec §4.4a).
    var supportsFaceEnhance: Bool = false
    /// Estimated output ceiling in megapixels — factors that would exceed it
    /// are disabled in the UI (spec §4.4a).
    var maxOutputMP: Double? = nil
    /// For `objectCleanup`: the model works from a text prompt instead of a mask.
    var cleanupByText: Bool = false

    var caption: String { IAL(captionKey) }

    /// Factor choices to offer in the ▾ menu (×2 / ×4 / ×8 clipped to max).
    var factorOptions: [Int] {
        guard let maxUpscaleFactor else { return [] }
        return [2, 4, 8].filter { $0 <= maxUpscaleFactor }
    }
}

/// Output format for results (spec §4.5). Background removal always keeps PNG
/// (alpha channel); other functions convert locally after download.
enum ImageOutputFormat: String, CaseIterable, Codable, Identifiable {
    case png, jpeg, webp

    var id: String { rawValue }
    var displayName: String { rawValue.uppercased() }

    var mime: String {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        case .webp: return "image/webp"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .webp: return "webp"
        }
    }
}

/// Well-known `ImageRequest.params` keys.
enum ImageParam {
    static let factor = "factor"        // Int — upscale factor
    static let faceEnhance = "face"     // Bool — Topaz/ESRGAN face switch
}

// MARK: - Requests & results

/// A single image operation. `params` carries model-specific knobs
/// (scale factor, output format, …) — see each provider's mapping.
struct ImageRequest {
    let function: ImageFunction
    /// Catalog model id (`ImageModelInfo.id`).
    let model: String
    /// Source image bytes; nil for `generate`.
    var inputImage: Data?
    /// MIME type of `inputImage` ("image/png", …).
    var inputMime: String?
    /// Mask for `objectCleanup` (white = remove).
    var maskImage: Data?
    /// Prompt for `generate` / text-guided object removal.
    var prompt: String?
    var params: [String: Any] = [:]
}

struct ImageResult {
    let image: Data
    let mimeType: String
    /// Known fixed cost of the operation (from the catalog), for the spend counter.
    let costUSD: Double?
}

// MARK: - Provider protocol

protocol ImageOperationProvider {
    var id: ImageProviderID { get }
    func supports(_ function: ImageFunction) -> Bool
    func models(for function: ImageFunction) -> [ImageModelInfo]
    /// Runs one operation to completion. Long-running; must honor task
    /// cancellation at its await points.
    func run(_ request: ImageRequest) async throws -> ImageResult
}

/// Static lookup of the addon's provider instances.
enum ImageProviderRegistry {
    static func provider(for id: ImageProviderID) -> ImageOperationProvider {
        switch id {
        case .apple: return AppleImageProvider.shared
        case .fal: return FalImageProvider.shared
        }
    }

    /// All models for a function across providers (P1: fal only).
    static func models(for function: ImageFunction) -> [ImageModelInfo] {
        ImageProviderID.allCases.flatMap { provider(for: $0).models(for: function) }
    }

    static func model(id: String) -> ImageModelInfo? {
        ImageFunction.allCases
            .flatMap { models(for: $0) }
            .first { $0.id == id }
    }
}
