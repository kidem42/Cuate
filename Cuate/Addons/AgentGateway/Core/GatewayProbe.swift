import Foundation

/// Unified gateway diagnostics (AGENT-ADDONS-NOTES.md §7): every failure a
/// user can hit while connecting maps onto one structured status with a
/// localized, actionable message — never a raw URLSession error string.
/// The addon supplies the endpoints; the probe logic and the message table
/// are shared so OpenClaw reuses them unchanged.
enum GatewayProbe {

    enum Status: Equatable {
        /// The gateway answered and the authorized call succeeded.
        case ok
        /// TCP-level failure: nothing listening / host unreachable / timeout.
        case unreachable
        /// The server answered but the API endpoint is missing (404) — the
        /// API server feature is disabled in the gateway's config.
        case endpointDisabled
        /// 401/403 — missing or wrong token (or missing scope, OpenClaw).
        case unauthorized
        /// TLS handshake failed (self-signed without trust, pin mismatch).
        case tlsFailure
        /// Reachable and authorized, but no agents/profiles configured.
        case noAgents
        /// Anything else, with the sanitized detail.
        case failed(String)

        /// Localized, actionable user-facing message (§7 table).
        var message: String {
            switch self {
            case .ok: return AGL("agent.probe.ok")
            case .unreachable: return AGL("agent.probe.unreachable")
            case .endpointDisabled: return AGL("agent.probe.endpointDisabled")
            case .unauthorized: return AGL("agent.probe.unauthorized")
            case .tlsFailure: return AGL("agent.probe.tls")
            case .noAgents: return AGL("agent.probe.noAgents")
            case .failed(let detail):
                return String(format: AGL("agent.probe.failed"), detail)
            }
        }
    }

    struct Result: Equatable {
        let status: Status
        /// Gateway platform/version when it identified itself (health body).
        var serverInfo: String?
    }

    /// Classifies a transport error into a probe status. Shared by the probe
    /// and by mid-chat failure paths, so both speak the same language.
    static func status(forTransportError error: Error) -> Status {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                 NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed:
                return .unreachable
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
                return .tlsFailure
            default:
                break
            }
        }
        return .failed(String(error.localizedDescription.prefix(200)))
    }

    /// Classifies an HTTP status from the authorized probe call.
    static func status(forHTTPStatus code: Int) -> Status {
        switch code {
        case 200...299: return .ok
        case 401, 403: return .unauthorized
        case 404: return .endpointDisabled
        default: return .failed("HTTP \(code)")
        }
    }
}
