#!/usr/bin/env python3
"""Exercise real STT services with synthetic HTTP/key/settings/spend dependencies.

Compiles only isolated contract sources; no application build, network or mic.
Provider value declarations are extracted from current production sources.
"""
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
source=(root/'Cuate/Providers/ProviderCore.swift').read_text()
def declaration(start):
    pos=source.index(start)
    return source[pos:source.index('\n}',pos)+2]
with tempfile.TemporaryDirectory(prefix="cuate-ollama-stt-") as tmp:
    out = Path(tmp) / "IntegrationMocks.swift"
    out.write_text('import Foundation\nimport AVFoundation\n'+declaration('struct ModelInfo:')+'\n'+declaration('enum STTProviderID:')+r'''
    func L(_ key: String) -> String { key }
    enum ProviderID { case mistral, openai, ollama
        var apiKeyURL: URL { URL(string: "https://example.invalid")! }
    }
    enum ProviderError: Error {
        case decoding(String), badResponse, transcriptionUnavailable, http(status: Int, message: String)
        static func fromHTTP(status: Int, body: Data) -> ProviderError { .http(status: status, message: "synthetic") }
    }
    @MainActor final class AppSettings {
        static let shared = AppSettings()
        var sttProvider = STTProviderID.ollama
        var localEndpointURL = "http://localhost:11434/v1"
        var localModelsEnabled = true
        var models = [STTProviderID.ollama: "audio-model", .mistral: "cloud-model"]
        func sttModel(for provider: STTProviderID) -> String { models[provider] ?? provider.defaultModel }
    }
    enum APIKeyStore {
        enum AuxKey { case deepgram }
        static var warms = 0
        static func warmIfNeeded() async { warms += 1 }
        static func hasKey(for provider: ProviderID) -> Bool { true }
        static func hasKey(aux: AuxKey) -> Bool { true }
        static func key(for provider: ProviderID) -> String? { "synthetic-key" }
        static func key(aux: AuxKey) -> String? { "synthetic-key" }
    }
    enum PricingCatalog { static let sttPerMinute: [STTProviderID: Double] = [.mistral: 0.001] }
    final class SpendStore {
        enum Kind { case stt }
        static let shared = SpendStore()
        var providers: [String] = []
        var costs: [Double?] = []
        func record(kind: Kind, provider: String, model: String, units: Double, costUSD: Double?) {
            providers.append(provider); costs.append(costUSD)
        }
    }
    enum HTTPClient {
        static let session = URLSession(configuration: .ephemeral)
        static var requests: [URLRequest] = []
        static var remote = false
        static var caps = ["completion", "audio", "thinking"]
        static var failChat = false
        static var changeEndpointOnChat = false
        static func json(_ request: URLRequest) async throws -> Data {
            requests.append(request)
            if request.url!.path.hasSuffix("/show") {
                return try JSONSerialization.data(withJSONObject: ["capabilities": caps, "remote_model": remote ? "cloud-alias" : ""])
            }
            if failChat { throw ProviderError.http(status: 503, message: "synthetic") }
            if changeEndpointOnChat { AppSettings.shared.localEndpointURL = "http://localhost:11435/v1" }
            if request.url!.path.hasSuffix("chat/completions") {
                return Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"Synthetic transcript."}}]}"#.utf8)
            }
            return Data(#"{"text":"Cloud transcript."}"#.utf8)
        }
    }
    @main struct IntegrationContract {
        @MainActor static func main() async throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).wav")
            try OllamaTranscriptionWire.wav(samples: [Int16](repeating: 1000, count: 16000)[...]).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            var checks = 0
            func expect(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
            let selection = TranscriptionService.Selection()
            AppSettings.shared.sttProvider = .openai
            AppSettings.shared.models[.ollama] = "changed-model"
            let transcript = try await TranscriptionService.transcribe(audioURL: url, selection: selection)
            expect(transcript == "Synthetic transcript.", "snapshot keeps local provider")
            expect(APIKeyStore.warms == 0, "local recognition never warms cloud keys")
            let chat = HTTPClient.requests.last!
            let body = try JSONSerialization.jsonObject(with: chat.httpBody!) as! [String: Any]
            expect(body["model"] as? String == "audio-model", "snapshot keeps selected model")
            expect(chat.value(forHTTPHeaderField: "Authorization") == nil, "no cloud authorization")
            expect(SpendStore.shared.providers == ["ollama"] && SpendStore.shared.costs == [0], "local STT accounting")
            HTTPClient.requests = []; HTTPClient.remote = true
            do { _ = try await TranscriptionService.transcribe(audioURL: url, selection: selection); fatalError("remote alias accepted") }
            catch { expect(HTTPClient.requests.count == 1, "cloud alias rejected before audio upload") }
            HTTPClient.remote = false; HTTPClient.requests = []; HTTPClient.caps = ["completion"]
            do { _ = try await TranscriptionService.transcribe(audioURL: url, selection: selection); fatalError("non-audio accepted") }
            catch { expect(HTTPClient.requests.count == 1, "non-audio rejected before upload") }
            HTTPClient.caps = ["completion", "audio"]; HTTPClient.requests = []; HTTPClient.failChat = true
            do { _ = try await TranscriptionService.transcribe(audioURL: url, selection: selection); fatalError("network error ignored") }
            catch { expect(HTTPClient.requests.count == 2 && APIKeyStore.warms == 0, "local failure has no cloud fallback") }
            HTTPClient.failChat = false; HTTPClient.requests = []; HTTPClient.changeEndpointOnChat = true
            do { _ = try await TranscriptionService.transcribe(audioURL: url, selection: selection); fatalError("endpoint change ignored") }
            catch { expect(HTTPClient.requests.count == 2, "changed endpoint invalidates in-flight result") }
            HTTPClient.requests = []
            do { _ = try await TranscriptionService.transcribe(audioURL: url, selection: selection); fatalError("stale endpoint accepted") }
            catch { expect(HTTPClient.requests.isEmpty, "old endpoint not contacted on retry") }
            HTTPClient.changeEndpointOnChat = false; HTTPClient.requests = []
            let cloud = try await TranscriptionService.transcribe(audioURL: url)
            expect(cloud == "Cloud transcript." && HTTPClient.requests.last?.url?.host == "api.openai.com", "explicit cloud provider still works")
            print("Ollama transcription integration: \(checks) checks passed")
        }
    }
    ''')

    executable = Path(tmp) / "integration-test"
    sources = [root / "Cuate/Providers" / name for name in ['OllamaCompatibility.swift', 'OllamaTranscriptionWire.swift', 'OllamaAudioReader.swift', 'OllamaTranscriptionQueue.swift', 'OllamaAdminService.swift', 'OllamaTranscriptionService.swift', 'TranscriptionService.swift']]
    subprocess.run([
        "xcrun", "swiftc", "-default-isolation", "MainActor",
        "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", "-warnings-as-errors",
        "-module-cache-path", str(Path(tmp) / "module-cache"),
        "-o", str(executable), *map(str, sources), str(out)
    ], check=True, timeout=120)
    subprocess.run([str(executable)], check=True, timeout=30)
