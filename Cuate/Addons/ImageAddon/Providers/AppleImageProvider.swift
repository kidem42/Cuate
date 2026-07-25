import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// Native, on-device image operations — no key, no network, no cost:
///   • Background removal via Vision (`VNGenerateForegroundInstanceMaskRequest`).
///   • Upscale via Core Image Lanczos resampling (`CILanczosScaleTransform`).
///
/// Both run on-device (macOS 14+ deployment target, no availability gate).
/// Honest scope: Lanczos is plain resampling — it sharpens interpolation but
/// invents NO new detail (unlike the cloud super-resolution models). Object
/// cleanup stays cloud-only: Apple ships no public inpainting API.
final class AppleImageProvider: ImageOperationProvider {
    static let shared = AppleImageProvider()
    private init() {}

    let id = ImageProviderID.apple

    /// Stable catalog ids, persisted in settings as the selected model.
    static let backgroundID = "apple/vision/background-removal"
    static let upscaleID = "apple/coreimage/lanczos-upscale"

    /// Hard ceiling on Lanczos output pixels — guards against OOM when a large
    /// input meets a high factor (the slash command doesn't clip by MP).
    private static let maxOutputPixels: CGFloat = 64_000_000

    func supports(_ function: ImageFunction) -> Bool {
        function == .removeBackground || function == .upscale
    }

    /// Built fresh per call so the localized price label follows the current
    /// app language (fal's catalog is a static `let`; ours is a translated word).
    func models(for function: ImageFunction) -> [ImageModelInfo] {
        switch function {
        case .removeBackground:
            return [ImageModelInfo(
                id: Self.backgroundID, name: "Apple Vision",
                function: .removeBackground, provider: .apple, tier: .onDevice,
                captionKey: "ia.model.appleBg.caption",
                priceUSD: 0, priceLabel: IAL("ia.price.free")
            )]
        case .upscale:
            return [ImageModelInfo(
                id: Self.upscaleID, name: "Apple (Lanczos)",
                function: .upscale, provider: .apple, tier: .onDevice,
                captionKey: "ia.model.appleUpscale.caption",
                priceUSD: 0, priceLabel: IAL("ia.price.free"),
                maxUpscaleFactor: 4,
                maxOutputMP: 48
            )]
        default:
            return []
        }
    }

    func run(_ request: ImageRequest) async throws -> ImageResult {
        guard let bytes = request.inputImage else { throw ImageAddonError.unreadableInput }
        // Vision/Core Image are synchronous and CPU/ANE-bound; the runner calls
        // providers from a main-actor Task, so hop off it to keep the panel live.
        switch request.function {
        case .removeBackground:
            let png = try await Task.detached(priority: .userInitiated) {
                try Self.removeBackground(imageData: bytes)
            }.value
            return ImageResult(image: png, mimeType: "image/png", costUSD: 0)
        case .upscale:
            let factor = request.params[ImageParam.factor] as? Int ?? 2
            let png = try await Task.detached(priority: .userInitiated) {
                try Self.upscale(imageData: bytes, factor: factor)
            }.value
            return ImageResult(image: png, mimeType: "image/png", costUSD: 0)
        default:
            throw ImageAddonError.badResponse
        }
    }

    // MARK: - Background removal (Vision, off the main actor)

    private static func removeBackground(imageData: Data) throws -> Data {
        // Bake in EXIF orientation so a rotated JPEG (input isn't forced to PNG
        // for this model) is segmented and written upright.
        guard let input = CIImage(data: imageData, options: [.applyOrientationProperty: true]) else {
            throw ImageAddonError.unreadableInput
        }

        let handler = VNImageRequestHandler(ciImage: input, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])

        // No foreground instance found — Vision returns an empty result rather
        // than throwing. Surface a clear hint to fall back to a cloud model.
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ImageAddonError.noSubjectFound
        }

        // The original pixels with everything outside the subject made
        // transparent (the alpha channel carries the soft mask).
        let masked = try observation.generateMaskedImage(
            ofInstances: observation.allInstances,
            from: handler,
            croppedToInstancesExtent: false
        )
        return try encodePNG(CIImage(cvPixelBuffer: masked))
    }

    // MARK: - Upscale (Core Image Lanczos, off the main actor)

    private static func upscale(imageData: Data, factor: Int) throws -> Data {
        guard let input = CIImage(data: imageData, options: [.applyOrientationProperty: true]) else {
            throw ImageAddonError.unreadableInput
        }

        // Clamp so a big input × high factor can't blow past the pixel ceiling.
        let inputPixels = input.extent.width * input.extent.height
        var scale = CGFloat(max(1, factor))
        if inputPixels > 0, inputPixels * scale * scale > maxOutputPixels {
            scale = max(1, (maxOutputPixels / inputPixels).squareRoot())
        }

        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = input
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        guard let output = filter.outputImage else { throw ImageAddonError.badResponse }
        return try encodePNG(output)
    }

    // MARK: - Shared PNG encode

    private static func encodePNG(_ image: CIImage) throws -> Data {
        let context = CIContext()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace) else {
            throw ImageAddonError.badResponse
        }
        return data
    }
}
