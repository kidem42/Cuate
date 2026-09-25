// Pre-request-receipt schema retained solely for migration contracts.
@Model
final class SDSpendRecord {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var kindRaw: String
    var provider: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var reasoningTokens: Int
    /// Non-token quantity: OCR pages, STT minutes, search queries, images.
    var units: Double
    /// nil = tokens recorded but no price known for the model at write time.
    var costUSD: Double?
    /// true when the stream ended without provider usage (cancel/error) and
    /// the tokens are a script-aware estimate, not an API-reported count.
    var isEstimate: Bool

    init(id: UUID = UUID(), timestamp: Date = Date(), kindRaw: String,
         provider: String, model: String,
         inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0,
         cacheWriteTokens: Int = 0, reasoningTokens: Int = 0,
         units: Double = 0, costUSD: Double? = nil, isEstimate: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.kindRaw = kindRaw
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.units = units
        self.costUSD = costUSD
        self.isEstimate = isEstimate
    }
}

