import Foundation

/// fal.ai backend: REST Queue API (`https://queue.fal.run/{model_id}`,
/// submit → poll → fetch), auth `Authorization: Key <FAL_KEY>`.
/// Изображения передаются base64 data-URI прямо в `image_url`/`mask_url`
/// (официально поддерживается fal; storage-upload — при необходимости позже).
///
/// Каталог моделей статический и обновляется релизами приложения (ТЗ §5).
/// Схемы входов каждой модели сверены с официальными API-доками fal.
final class FalImageProvider: ImageOperationProvider {
    static let shared = FalImageProvider()
    private init() {}

    let id = ImageProviderID.fal

    // MARK: - Catalog (ТЗ §3.1 / §3.1a)

    static let recraftCrispID = "fal-ai/recraft/upscale/crisp"
    static let topazID = "fal-ai/topaz/upscale/image"
    static let seedvrID = "fal-ai/seedvr/upscale/image"
    static let esrganID = "fal-ai/esrgan"
    static let briaRMBGID = "fal-ai/bria/background/remove"
    static let birefnetID = "fal-ai/birefnet/v2"
    static let briaEraserID = "fal-ai/bria/eraser"
    static let objectRemovalID = "fal-ai/object-removal"

    /// Static catalog: id эндпоинта, имя, функция, бейдж, подпись, цена.
    static let catalog: [ImageModelInfo] = [
        // --- Апскейл ---
        ImageModelInfo(
            id: recraftCrispID, name: "Recraft Crisp",
            function: .upscale, provider: .fal, tier: .standard,
            captionKey: "ia.model.recraftCrisp.caption",
            priceUSD: 0.004, priceLabel: "$0.004",
            requiresPNGInput: true, // API: "Must be in PNG format"
            maxUpscaleFactor: nil,  // фиксированный «crisp» проход без фактора
            maxOutputMP: 16
        ),
        ImageModelInfo(
            id: topazID, name: "Topaz Upscale",
            function: .upscale, provider: .fal, tier: .premium,
            captionKey: "ia.model.topaz.caption",
            priceUSD: 0.08, priceLabel: "~$0.08–0.15",
            maxUpscaleFactor: 4,
            supportsFaceEnhance: true,
            maxOutputMP: 512
        ),
        ImageModelInfo(
            id: seedvrID, name: "SeedVR2",
            function: .upscale, provider: .fal, tier: .quality,
            captionKey: "ia.model.seedvr.caption",
            priceUSD: 0.03, priceLabel: "~$0.02–0.05",
            maxUpscaleFactor: 4,
            maxOutputMP: 33 // ~8K
        ),
        ImageModelInfo(
            id: esrganID, name: "Real-ESRGAN",
            function: .upscale, provider: .fal, tier: .budget,
            captionKey: "ia.model.esrgan.caption",
            priceUSD: 0.0025, priceLabel: "~$0.0025",
            maxUpscaleFactor: 8,
            supportsFaceEnhance: true,
            maxOutputMP: 32
        ),

        // --- Удаление фона ---
        ImageModelInfo(
            id: briaRMBGID, name: "Bria RMBG-2.0",
            function: .removeBackground, provider: .fal, tier: .standard,
            captionKey: "ia.model.rmbg.caption",
            priceUSD: 0.018, priceLabel: "$0.018"
        ),
        ImageModelInfo(
            id: birefnetID, name: "BiRefNet v2",
            function: .removeBackground, provider: .fal, tier: .budget,
            captionKey: "ia.model.birefnet.caption",
            priceUSD: 0.002, priceLabel: "~$0.002"
        ),

        // --- Удаление объектов ---
        ImageModelInfo(
            id: briaEraserID, name: "Bria Eraser",
            function: .objectCleanup, provider: .fal, tier: .standard,
            captionKey: "ia.model.briaEraser.caption",
            priceUSD: 0.04, priceLabel: "~$0.04"
        ),
        ImageModelInfo(
            id: objectRemovalID, name: "Object Removal",
            function: .objectCleanup, provider: .fal, tier: .smart,
            captionKey: "ia.model.objectRemoval.caption",
            priceUSD: 0.024, priceLabel: "~$0.024",
            cleanupByText: true
        ),
    ]

    func supports(_ function: ImageFunction) -> Bool {
        Self.catalog.contains { $0.function == function }
    }

    func models(for function: ImageFunction) -> [ImageModelInfo] {
        Self.catalog.filter { $0.function == function }
    }

    // MARK: - Key validation (no-cost probe)

    /// Checks the key WITHOUT spending money: a status request for a
    /// nonexistent job answers 401/403 for a bad key and 404/422 for a good
    /// one (the auth layer runs before the request lookup).
    static func validateKey(_ apiKey: String) async throws {
        let url = URL(string: "https://queue.fal.run/fal-ai/recraft/requests/00000000-0000-0000-0000-000000000000/status")!
        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImageAddonError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ImageAddonError.fromHTTP(status: http.statusCode, body: data)
        }
        // 404 / 422 / 200 — the key passed authentication.
    }

    // MARK: - Execution

    private static let pollInterval: Duration = .seconds(1)
    private static let deadline: Duration = .seconds(120)

    func run(_ request: ImageRequest) async throws -> ImageResult {
        guard let apiKey = APIKeyStore.key(aux: .fal) else {
            throw ImageAddonError.missingKey
        }
        guard let model = Self.catalog.first(where: { $0.id == request.model }) else {
            throw ImageAddonError.badResponse
        }

        let input = try buildInput(for: request, model: model)
        let submitted = try await submit(modelID: model.id, input: input, apiKey: apiKey)
        let response = try await awaitResult(submitted, apiKey: apiKey)
        let (data, mime) = try await downloadOutputImage(from: response, apiKey: apiKey)
        return ImageResult(image: data, mimeType: mime, costUSD: model.priceUSD)
    }

    /// Maps an `ImageRequest` onto the model's input JSON (schemas verified
    /// against the fal API docs per endpoint).
    private func buildInput(for request: ImageRequest, model: ImageModelInfo) throws -> [String: Any] {
        guard let bytes = request.inputImage else { throw ImageAddonError.unreadableInput }
        let prepared = try ImageInputPreparer.prepare(
            data: bytes,
            mime: request.inputMime ?? "image/png",
            forcePNG: model.requiresPNGInput
        )
        let imageURI = ImageInputPreparer.dataURI(prepared.data, mime: prepared.mime)
        let factor = request.params[ImageParam.factor] as? Int ?? 2
        let face = request.params[ImageParam.faceEnhance] as? Bool ?? false

        switch model.id {
        case Self.recraftCrispID:
            return ["image_url": imageURI]

        case Self.topazID:
            var input: [String: Any] = ["image_url": imageURI, "upscale_factor": factor]
            input["face_enhancement"] = face
            return input

        case Self.seedvrID:
            return ["image_url": imageURI, "upscale_mode": "factor", "upscale_factor": factor]

        case Self.esrganID:
            return ["image_url": imageURI, "scale": factor, "face": face, "output_format": "png"]

        case Self.briaRMBGID:
            return ["image_url": imageURI]

        case Self.birefnetID:
            return ["image_url": imageURI, "output_format": "png", "refine_foreground": true]

        case Self.briaEraserID:
            guard let mask = request.maskImage else { throw ImageAddonError.unreadableInput }
            return [
                "image_url": imageURI,
                "mask_url": ImageInputPreparer.dataURI(mask, mime: "image/png"),
                "mask_type": "manual"
            ]

        case Self.objectRemovalID:
            guard let prompt = request.prompt, !prompt.isEmpty else { throw ImageAddonError.unreadableInput }
            return ["image_url": imageURI, "prompt": prompt]

        default:
            throw ImageAddonError.badResponse
        }
    }

    // MARK: - Queue API

    private struct SubmitResponse: Decodable {
        let request_id: String
        let status_url: String
        let response_url: String
        let cancel_url: String?
    }

    private struct StatusResponse: Decodable {
        let status: String
    }

    private func authorizedRequest(url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func submit(modelID: String, input: [String: Any], apiKey: String) async throws -> SubmitResponse {
        guard let url = URL(string: "https://queue.fal.run/\(modelID)") else {
            throw ImageAddonError.badResponse
        }
        var request = authorizedRequest(url: url, apiKey: apiKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: input)

        let data = try await performHTTP(request)
        guard let submitted = try? JSONDecoder().decode(SubmitResponse.self, from: data) else {
            throw ImageAddonError.badResponse
        }
        return submitted
    }

    /// Polls the status URL until COMPLETED, then fetches the result JSON.
    /// The submit response carries канонические URL-ы (у моделей с subpath
    /// они отличаются от адреса сабмита) — используем их, не собираем сами.
    /// On task cancellation the queued fal job is cancelled too (cancel_url).
    private func awaitResult(_ submitted: SubmitResponse, apiKey: String) async throws -> [String: Any] {
        guard let statusURL = URL(string: submitted.status_url),
              let responseURL = URL(string: submitted.response_url) else {
            throw ImageAddonError.badResponse
        }

        let start = ContinuousClock.now
        while true {
            if Task.isCancelled {
                cancelRemoteJob(submitted, apiKey: apiKey)
                throw CancellationError()
            }
            if start.duration(to: .now) > Self.deadline {
                cancelRemoteJob(submitted, apiKey: apiKey)
                throw ImageAddonError.timeout
            }

            let data = try await performHTTP(authorizedRequest(url: statusURL, apiKey: apiKey))
            let status = (try? JSONDecoder().decode(StatusResponse.self, from: data))?.status ?? ""
            switch status {
            case "COMPLETED":
                let body = try await performHTTP(authorizedRequest(url: responseURL, apiKey: apiKey))
                guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    throw ImageAddonError.badResponse
                }
                return json
            case "IN_QUEUE", "IN_PROGRESS":
                try await Task.sleep(for: Self.pollInterval)
            default:
                throw ImageAddonError.badResponse
            }
        }
    }

    /// Fire-and-forget PUT to the job's cancel URL (best effort — the job
    /// may already be running; nothing to handle either way).
    private func cancelRemoteJob(_ submitted: SubmitResponse, apiKey: String) {
        guard let cancelString = submitted.cancel_url, let url = URL(string: cancelString) else { return }
        var request = authorizedRequest(url: url, apiKey: apiKey)
        request.httpMethod = "PUT"
        Task.detached {
            _ = try? await HTTPClient.session.data(for: request)
        }
        Diagnostics.log("imageaddon", "op.cancel request=\(submitted.request_id)")
    }

    /// Pulls the first output image out of a result JSON. Модели fal отдают
    /// либо `{"image": {...}}`, либо `{"images": [{...}]}` — принимаем оба.
    private func downloadOutputImage(from json: [String: Any], apiKey: String) async throws -> (Data, String) {
        let file: [String: Any]?
        if let image = json["image"] as? [String: Any] {
            file = image
        } else if let images = json["images"] as? [[String: Any]] {
            file = images.first
        } else {
            file = nil
        }
        guard let file, let urlString = file["url"] as? String else {
            throw ImageAddonError.badResponse
        }

        // Data-URI результат (sync_mode) — декодируем без сети.
        if urlString.hasPrefix("data:") {
            guard let comma = urlString.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])) else {
                throw ImageAddonError.badResponse
            }
            let mime = urlString.dropFirst(5).prefix { $0 != ";" && $0 != "," }
            return (data, mime.isEmpty ? "image/png" : String(mime))
        }

        guard let url = URL(string: urlString) else { throw ImageAddonError.badResponse }
        let data = try await performHTTP(URLRequest(url: url)) // fal.media — без авторизации
        let mime = (file["content_type"] as? String) ?? "image/png"
        return (data, mime)
    }

    /// Shared-session HTTP with sanitized errors (reuses the host's session).
    /// Maps provider content-policy rejections onto `.contentFiltered`.
    private func performHTTP(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImageAddonError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let error = ImageAddonError.fromHTTP(status: http.statusCode, body: data)
            if case .http(let status, let message) = error, status == 422 || status == 400 {
                let lowered = message.lowercased()
                if ["nsfw", "safety", "content policy", "policy violation", "flagged"]
                    .contains(where: lowered.contains) {
                    throw ImageAddonError.contentFiltered
                }
            }
            throw error
        }
        return data
    }
}
