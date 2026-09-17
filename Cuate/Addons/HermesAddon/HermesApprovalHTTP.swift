import Foundation

/// Approval POSTs cannot be redirected or supplied another body for replay.
/// A lost answer must be reconciled with GET run status and another human choice.
nonisolated final class HermesApprovalHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let delegate = HermesApprovalHTTP()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    static func oneShot(_ original: URLRequest) -> URLRequest {
        var request = original
        if let data = request.httpBody {
            request.httpBody = nil
            request.httpBodyStream = InputStream(data: data)
            request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(nil)
    }
}
