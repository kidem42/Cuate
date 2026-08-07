import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Local, lossless-where-possible input preparation: PNG conversion for
/// models that require it (and for HEIC/TIFF, which no API accepts), plus
/// the base64 data-URI encoding the fal endpoints take as `image_url`.
enum ImageInputPreparer {
    /// Formats the cloud endpoints accept as-is (spec §4.4b).
    static func isDirectlySendable(mime: String) -> Bool {
        ["image/png", "image/jpeg", "image/webp"].contains(mime.lowercased())
    }

    /// Re-encodes arbitrary image bytes to PNG via ImageIO. Returns nil when
    /// the bytes are not a decodable image.
    static func pngData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// (bytes, mime) ready for upload: converts to PNG when the model demands
    /// it or when the source format isn't directly sendable. Throws
    /// `unreadableInput` when the data can't be decoded.
    static func prepare(data: Data, mime: String, forcePNG: Bool) throws -> (data: Data, mime: String) {
        if !forcePNG, isDirectlySendable(mime: mime) {
            return (data, mime)
        }
        if mime.lowercased() == "image/png" {
            return (data, mime)
        }
        guard let png = pngData(from: data) else {
            throw ImageAddonError.unreadableInput
        }
        return (png, "image/png")
    }

    /// Base64 data URI accepted by fal `image_url` fields.
    static func dataURI(_ data: Data, mime: String) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// Pixel dimensions without decoding the full bitmap (for megapixel
    /// limits; cheap — reads the header only).
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    // MARK: - Operation-time normalization (spec §4.4b)

    /// What happened to the input on the way in — the UI surfaces these as
    /// system-message warnings (banners).
    enum InputNote {
        case gifFirstFrame
        case downscaled(fromMP: Double, toMP: Double)
    }

    /// Applies the input rules before an operation: GIF → first frame,
    /// input over the limit → auto-downscale. Returns the normalized bytes,
    /// mime, and the notes to show.
    static func normalizeForOperation(
        data: Data,
        mime: String,
        maxMegapixels: Double,
        maxBytes: Int
    ) throws -> (data: Data, mime: String, notes: [InputNote]) {
        var notes: [InputNote] = []
        var outData = data
        var outMime = mime

        // GIF: first frame only (animation makes no sense for these APIs).
        if mime.lowercased() == "image/gif" {
            guard let png = pngData(from: data) else { throw ImageAddonError.unreadableInput }
            outData = png
            outMime = "image/png"
            notes.append(.gifFirstFrame)
        }

        // Megapixel / byte ceiling → proportional downscale.
        let size = pixelSize(of: outData)
        let mp = size.map { ($0.width * $0.height) / 1_000_000 } ?? 0
        if mp > maxMegapixels || outData.count > maxBytes {
            let targetMP = min(maxMegapixels, mp > 0 ? mp : maxMegapixels)
            guard let size,
                  let downscaled = downscale(outData, toMaxMegapixels: targetMP,
                                             currentSize: size) else {
                throw ImageAddonError.unreadableInput
            }
            outData = downscaled
            outMime = "image/png"
            let newMP = pixelSize(of: outData).map { ($0.width * $0.height) / 1_000_000 } ?? targetMP
            notes.append(.downscaled(fromMP: mp, toMP: newMP))
        }

        return (outData, outMime, notes)
    }

    /// Proportional downscale via ImageIO thumbnailing (memory-friendly).
    private static func downscale(_ data: Data, toMaxMegapixels maxMP: Double, currentSize: CGSize) -> Data? {
        let currentMP = (currentSize.width * currentSize.height) / 1_000_000
        guard currentMP > 0 else { return nil }
        let scale = (maxMP / currentMP).squareRoot()
        let maxDimension = Swift.max(currentSize.width, currentSize.height) * Swift.min(scale, 1)

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Exact-size resize (used to keep a cleanup mask pixel-aligned with the
    /// normalized image — mask APIs require identical dimensions).
    static func resizeImage(_ data: Data, to targetSize: CGSize) -> Data? {
        guard targetSize.width >= 1, targetSize.height >= 1,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                data: nil,
                width: Int(targetSize.width), height: Int(targetSize.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))
        guard let resized = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, resized, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Alpha handling (the "resurrected background" fix)
    //
    // Background-removal models (Bria RMBG, BiRefNet) return a PNG whose RGB
    // still holds the UNTOUCHED original — the cutout lives in the alpha
    // channel alone. Viewers honor alpha, so the image looks cut out; fal
    // models (upscale, eraser) ignore alpha and process RGB — the "removed"
    // background came back to life in the result. It is also a leak: any
    // editor can pull the background out of the saved file.

    /// Decodes the first frame (shared by the alpha helpers below).
    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// RGBA8 premultiplied bitmap — drawing into a premultiplied context
    /// multiplies RGB by alpha on its own, so pixels hidden under
    /// transparency die at this very step.
    private static func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest), out.length > 0 else { return nil }
        return out as Data
    }

    private static func hasAlphaChannel(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Flattens a transparent image onto WHITE (what the user actually sees
    /// in the chat) and extracts the alpha mask as a grayscale PNG. Returns nil
    /// for images without actual transparency — the caller keeps the
    /// original bytes and skips the restore step.
    static func flattenIfTransparent(_ data: Data) -> (flattened: Data, alphaMask: Data)? {
        guard let image = decodeImage(data), hasAlphaChannel(image) else { return nil }
        let w = image.width, h = image.height
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        guard let ctx = rgbaContext(width: w, height: h) else { return nil }
        ctx.draw(image, in: rect)
        guard let buf = ctx.data else { return nil }
        let px = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var mask = [UInt8](repeating: 255, count: w * h)
        var transparent = false
        for i in 0..<(w * h) {
            let a = px[i * 4 + 3]
            mask[i] = a
            if a < 255 { transparent = true }
        }
        guard transparent else { return nil }

        let maskPNG: Data? = mask.withUnsafeMutableBytes { raw in
            guard let maskCtx = CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ), let maskImage = maskCtx.makeImage() else { return nil }
            return encodePNG(maskImage)
        }

        guard let flatCtx = rgbaContext(width: w, height: h) else { return nil }
        flatCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        flatCtx.fill(rect)
        flatCtx.draw(image, in: rect)
        guard let maskPNG,
              let flatImage = flatCtx.makeImage(),
              let flatPNG = encodePNG(flatImage) else { return nil }
        return (flatPNG, maskPNG)
    }

    /// Re-encodes an image so pixels under transparency hold no leftover RGB
    /// (premultiply round-trip: RGB×0 → 0). Returns nil when the image has
    /// no alpha channel — nothing to sanitize.
    static func sanitizedTransparency(_ data: Data) -> Data? {
        guard let image = decodeImage(data), hasAlphaChannel(image) else { return nil }
        guard let ctx = rgbaContext(width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cleaned = ctx.makeImage() else { return nil }
        return encodePNG(cleaned)
    }

    /// Scales the remembered alpha mask to the result's size and writes it
    /// into the alpha channel — upscalers return opaque RGB, so the cutout's
    /// transparency is restored locally (for free).
    static func applyingAlphaMask(_ maskPNG: Data, to resultData: Data) -> Data? {
        guard let result = decodeImage(resultData), let mask = decodeImage(maskPNG) else { return nil }
        let w = result.width, h = result.height
        let rect = CGRect(x: 0, y: 0, width: w, height: h)

        var scaled = [UInt8](repeating: 255, count: w * h)
        let scaledOK = scaled.withUnsafeMutableBytes { raw -> Bool in
            guard let maskCtx = CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            maskCtx.interpolationQuality = .high
            maskCtx.draw(mask, in: rect)
            return true
        }
        guard scaledOK, let ctx = rgbaContext(width: w, height: h) else { return nil }

        ctx.draw(result, in: rect)
        guard let buf = ctx.data else { return nil }
        let px = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in 0..<(w * h) {
            let a = Int(scaled[i])
            guard a < 255 else { continue }
            // The context is premultiplied — multiply by hand; the PNG encoder
            // undoes the premultiplication on write (straight alpha).
            px[i * 4]     = UInt8(Int(px[i * 4]) * a / 255)
            px[i * 4 + 1] = UInt8(Int(px[i * 4 + 1]) * a / 255)
            px[i * 4 + 2] = UInt8(Int(px[i * 4 + 2]) * a / 255)
            px[i * 4 + 3] = UInt8(a)
        }
        guard let combined = ctx.makeImage() else { return nil }
        return encodePNG(combined)
    }

    // MARK: - Output conversion (spec §4.5: output format)

    /// Re-encodes a result into the requested format. Returns the input
    /// unchanged when it already matches or when encoding fails (a valid
    /// image beats a failed conversion).
    static func convert(_ data: Data, from mime: String, to format: ImageOutputFormat) -> (data: Data, mime: String) {
        guard mime.lowercased() != format.mime else { return (data, mime) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return (data, mime)
        }
        let type: UTType
        switch format {
        case .png: type = .png
        case .jpeg: type = .jpeg
        case .webp: type = .webP
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            return (data, mime)
        }
        let props: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.9]
            : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length > 0 else { return (data, mime) }
        return (out as Data, format.mime)
    }
}
