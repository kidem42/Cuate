import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Local, lossless-where-possible input preparation: PNG conversion for
/// models that require it (and for HEIC/TIFF, which no API accepts), plus
/// the base64 data-URI encoding the fal endpoints take as `image_url`.
enum ImageInputPreparer {
    /// Formats the cloud endpoints accept as-is (ТЗ §4.4b).
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

    // MARK: - Operation-time normalization (ТЗ §4.4b)

    /// What happened to the input on the way in — the UI surfaces these as
    /// system-message warnings ("плашки").
    enum InputNote {
        case gifFirstFrame
        case downscaled(fromMP: Double, toMP: Double)
    }

    /// Applies the input rules before an operation: GIF → первый кадр,
    /// вход больше лимита → автодаунскейл. Returns the normalized bytes,
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

    // MARK: - Output conversion (ТЗ §4.5: формат вывода)

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
