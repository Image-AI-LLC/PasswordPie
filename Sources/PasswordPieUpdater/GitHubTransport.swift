import Foundation
import PasswordPieUpdate

/// The only file in PasswordPie that opens a network connection (docs/CHANNELS.md, "Network"): two kinds of request,
/// the latest release from api.github.com and a release's disk image from GitHub. HTTPS only, GitHub's hosts only, no
/// cookies, no cache, nothing in the request but the name `PasswordPie-Updater`.
final class GitHubTransport: NSObject, UpdateTransport, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    private static let maxFeedBytes = 1024 * 1024
    private var maxBytes = 0
    private var destination: URL?
    private var moved = false
    private var tooLarge = false

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.httpAdditionalHeaders = ["User-Agent": "PasswordPie-Updater", "Accept": "application/vnd.github+json"]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// GitHub, or where GitHub keeps release files.
    static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "api.github.com" || host.hasSuffix(".githubusercontent.com")
    }

    func fetch(_ url: URL) throws -> Data {
        guard Self.allowed(url) else { throw UpdateError("The update check failed.") }
        let session = session()
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, UpdateError> = .failure(UpdateError("GitHub did not answer."))
        session.dataTask(with: url) { data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200, data.count <= Self.maxFeedBytes {
                result = .success(data)
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    func download(_ url: URL, to file: URL, maxBytes: Int) throws {
        guard Self.allowed(url) else { throw UpdateError("The download failed.") }
        self.maxBytes = maxBytes
        destination = file
        moved = false
        tooLarge = false
        let session = session()
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        var status = 0
        let task = session.downloadTask(with: url)
        completion = { response in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }
        task.resume()
        done.wait()
        guard status == 200, moved, !tooLarge else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateError(tooLarge ? "The download is larger than GitHub said." : "The download failed.")
        }
    }

    private var completion: ((URLResponse?) -> Void)?

    /// A redirect is followed only to GitHub over HTTPS: release files are served from another GitHub host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allowed(request.url) ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Int64(maxBytes) {
            tooLarge = true
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination, !tooLarge else { return }
        try? FileManager.default.removeItem(at: destination)
        moved = (try? FileManager.default.moveItem(at: location, to: destination)) != nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task is URLSessionDownloadTask else { return }
        completion?(error == nil ? task.response : nil)
        completion = nil
    }
}
