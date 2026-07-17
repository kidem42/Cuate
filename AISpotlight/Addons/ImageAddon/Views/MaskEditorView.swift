import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Inline object-cleanup editor shown inside the panel (ТЗ §4.2): paint a
/// mask with a brush (slider 10–100 px, undo, reset) OR describe the object
/// in text. «Применить» hands the mask/prompt back to the caller.
struct MaskEditorView: View {
    let attachment: ChatAttachment
    /// Called with the mask (white = remove, image resolution) — brush mode.
    let applyMask: (Data) -> Void
    /// Called with the description — text mode.
    let applyPrompt: (String) -> Void
    let close: () -> Void

    private enum Mode: Hashable { case brush, text }

    private struct Stroke {
        var points: [CGPoint] // in displayed-image coordinates
        var radius: CGFloat   // in displayed-image points
    }

    @State private var mode: Mode = .brush
    @State private var strokes: [Stroke] = []
    @State private var currentStroke: Stroke?
    @State private var brushSize: Double = 40 // ТЗ §4.4a: 10–100, дефолт 40
    @State private var promptText = ""

    private var image: NSImage? {
        attachment.data.flatMap(NSImage.init(data:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $mode) {
                Text(IAL("ia.cleanup.brush")).tag(Mode.brush)
                    .help(IAL("ia.help.brushMode"))
                Text(IAL("ia.cleanup.text")).tag(Mode.text)
                    .help(IAL("ia.help.textMode"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .help(mode == .brush ? IAL("ia.help.brushMode") : IAL("ia.help.textMode"))

            if mode == .brush {
                brushEditor
            } else {
                textEditor
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
    }

    // MARK: - Brush mode

    @ViewBuilder
    private var brushEditor: some View {
        if let image {
            Text(IAL("ia.cleanup.hint"))
                .font(.caption)
                .foregroundColor(.secondary)

            GeometryReader { geo in
                let fitted = fittedRect(imageSize: image.size, in: geo.size)
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()

                    Canvas { context, _ in
                        for stroke in strokes + (currentStroke.map { [$0] } ?? []) {
                            var path = Path()
                            if let first = stroke.points.first {
                                path.move(to: first)
                                for point in stroke.points.dropFirst() {
                                    path.addLine(to: point)
                                }
                            }
                            context.stroke(
                                path,
                                with: .color(.red.opacity(0.45)),
                                style: StrokeStyle(lineWidth: stroke.radius * 2, lineCap: .round, lineJoin: .round)
                            )
                            // A single tap must still leave a dot.
                            if stroke.points.count == 1, let point = stroke.points.first {
                                let dot = CGRect(x: point.x - stroke.radius, y: point.y - stroke.radius,
                                                 width: stroke.radius * 2, height: stroke.radius * 2)
                                context.fill(Path(ellipseIn: dot), with: .color(.red.opacity(0.45)))
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // The gesture is attached to the ZStack that is
                            // ALREADY framed to the fitted image rect, so
                            // value.location is in fitted-local coordinates —
                            // no centering offset to subtract. Clamp inside
                            // the image so edge strokes stay on the mask.
                            let point = CGPoint(
                                x: min(max(value.location.x, 0), fitted.width),
                                y: min(max(value.location.y, 0), fitted.height)
                            )
                            let radius = displayRadius(fitted: fitted, imageSize: image.size)
                            if currentStroke == nil {
                                currentStroke = Stroke(points: [point], radius: radius)
                            } else {
                                currentStroke?.points.append(point)
                            }
                        }
                        .onEnded { _ in
                            if let stroke = currentStroke {
                                strokes.append(stroke)
                            }
                            currentStroke = nil
                        }
                )
                // Draw only inside the fitted image area.
                .frame(width: fitted.width, height: fitted.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .clipped()
                .onAppear { rememberFitted(fitted) }
                .onChange(of: geo.size) {
                    rememberFitted(fittedRect(imageSize: image.size, in: geo.size))
                }
            }
            .frame(height: 230)

            HStack(spacing: 10) {
                Text(IAL("ia.cleanup.brushSize"))
                    .font(.caption)
                Slider(value: $brushSize, in: 10...100)
                    .frame(width: 130)
                    .help(IAL("ia.help.brushSize"))
                Text("\(Int(brushSize)) px")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .leading)

                Spacer()

                Button(IAL("ia.cleanup.undo")) {
                    _ = strokes.popLast()
                }
                .disabled(strokes.isEmpty)
                .help(IAL("ia.help.undo"))
                Button(IAL("ia.cleanup.clear")) {
                    strokes.removeAll()
                }
                .disabled(strokes.isEmpty)
                .help(IAL("ia.help.clear"))
            }
            .controlSize(.small)

            HStack {
                Button(IAL("ia.cleanup.close")) { close() }
                Spacer()
                Button(IAL("ia.cleanup.apply")) {
                    if let mask = exportMask(image: image) {
                        applyMask(mask)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(strokes.isEmpty)
                .help(IAL("ia.help.applyMask"))
            }
            .controlSize(.small)
        }
    }

    // MARK: - Text mode

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(IAL("ia.cleanup.prompt.placeholder"), text: $promptText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(IAL("ia.cleanup.close")) { close() }
                Spacer()
                Button(IAL("ia.cleanup.apply")) {
                    applyPrompt(promptText)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(promptText.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(IAL("ia.help.applyText"))
            }
            .controlSize(.small)
        }
    }

    // MARK: - Geometry & mask export

    /// The rect the scaledToFit image actually occupies inside the container.
    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Brush size is specified in IMAGE pixels (ТЗ) — convert to view points.
    private func displayRadius(fitted: CGRect, imageSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, fitted.width > 0 else { return brushSize / 2 }
        let scale = fitted.width / imageSize.width
        return max(1.5, (brushSize / 2) * scale)
    }

    /// Renders the strokes into an image-resolution mask: white = remove,
    /// black = keep (Bria Eraser, mask_type "manual").
    private func exportMask(image: NSImage) -> Data? {
        // True pixel size (points × backing scale of the source bitmap).
        guard let source = attachment.data,
              let pixelSize = ImageInputPreparer.pixelSize(of: source),
              pixelSize.width > 0, pixelSize.height > 0 else {
            return nil
        }
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Strokes were captured in displayed-image coords with the brush
        // radius already scaled for display — recover image-pixel geometry.
        // Display height maps to pixel height top-down; CG is bottom-up.
        let displaySize = displayedSizeForExport(imageSize: image.size)
        guard displaySize.width > 0 else { return nil }
        let scale = CGFloat(width) / displaySize.width

        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes {
            let lineWidth = stroke.radius * 2 * scale
            let points = stroke.points.map { point in
                CGPoint(x: point.x * scale, y: CGFloat(height) - point.y * scale)
            }
            if points.count == 1, let point = points.first {
                let radius = stroke.radius * scale
                context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                               width: radius * 2, height: radius * 2))
                continue
            }
            context.setLineWidth(lineWidth)
            context.beginPath()
            context.addLines(between: points)
            context.strokePath()
        }

        guard let cgImage = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// The size strokes were recorded against — captured from the live
    /// layout (`rememberFitted`), so the export math matches exactly what
    /// the user painted on.
    private func displayedSizeForExport(imageSize: CGSize) -> CGSize {
        lastFittedSize
    }

    @State private var lastFittedSize: CGSize = .zero

    private func rememberFitted(_ rect: CGRect) {
        if lastFittedSize != rect.size {
            lastFittedSize = rect.size
        }
    }
}
