import Foundation
import Combine

/// Single-flight executor for image operations. Owns the "is something
/// running" state the UI observes, supports cancellation (the × on the
/// thinking pill), retries once on timeout/5xx (spec §6), records spend,
/// and logs through Diagnostics.
@MainActor
final class ImageTaskRunner: ObservableObject {
    static let shared = ImageTaskRunner()

    @Published private(set) var isRunning = false

    private var currentTask: Task<ImageResult, Error>?

    private init() {}

    /// Runs one operation to completion. Throws `.busy` when another one is
    /// in flight, `CancellationError` on `cancel()`.
    func perform(_ request: ImageRequest) async throws -> ImageResult {
        guard !isRunning else { throw ImageAddonError.busy }
        isRunning = true
        defer {
            isRunning = false
            currentTask = nil
        }

        let provider = ImageProviderRegistry.provider(for: providerID(for: request))
        let start = ContinuousClock.now
        Diagnostics.log("imageaddon", "op.begin fn=\(request.function.rawValue) model=\(request.model) inBytes=\(request.inputImage?.count ?? 0)")

        let task = Task { () throws -> ImageResult in
            do {
                return try await provider.run(request)
            } catch let error as ImageAddonError {
                // One automatic retry on flaky failures (timeout / 5xx).
                guard Self.isRetryable(error), !Task.isCancelled else { throw error }
                Diagnostics.log("imageaddon", "op.retry after: \(error.localizedDescription)")
                return try await provider.run(request)
            }
        }
        currentTask = task

        do {
            let result = try await task.value
            let elapsed = start.duration(to: .now).components
            let ms = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
            Diagnostics.log("imageaddon", "op.done fn=\(request.function.rawValue) model=\(request.model) outBytes=\(result.image.count) ms=\(ms) cost=\(result.costUSD.map { String($0) } ?? "?")")
            if let cost = result.costUSD {
                ImageAddonSettings.shared.addSpent(cost)
                // Mirror into the unified spend ledger so the Costs tab's
                // charts include image operations (addon counters stay
                // untouched — their own UI keeps working as before).
                SpendStore.shared.record(
                    kind: .image, provider: "fal", model: request.model,
                    units: 1, costUSD: cost
                )
            }
            return result
        } catch {
            Diagnostics.log("imageaddon", "op.fail fn=\(request.function.rawValue) model=\(request.model) error=\(error.localizedDescription)")
            throw error
        }
    }

    /// Cancels the operation in flight (also cancels the remote fal job —
    /// see `FalImageProvider.awaitResult`).
    func cancel() {
        currentTask?.cancel()
    }

    private static func isRetryable(_ error: ImageAddonError) -> Bool {
        switch error {
        case .timeout: return true
        case .http(let status, _): return (500..<600).contains(status)
        default: return false
        }
    }

    /// P1: everything runs through fal. When direct providers arrive (P2)
    /// this resolves from the model catalog instead.
    private func providerID(for request: ImageRequest) -> ImageProviderID {
        ImageProviderRegistry.model(id: request.model)?.provider ?? .fal
    }
}
