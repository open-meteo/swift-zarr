import AsyncHTTPClient
import Foundation
import NIOCore

public struct RetryConfiguration: Sendable {
    let maxAttempts: Int
    let baseDelay: Duration
    let maxDelay: Duration
    let jitter: Double
    let timeout: TimeAmount

    public static let `default` = RetryConfiguration(
        maxAttempts: 3,
        baseDelay: .milliseconds(200),
        maxDelay: .seconds(10),
        jitter: 0.2,
        timeout: .seconds(60)
    )

    public init(maxAttempts: Int, baseDelay: Duration, maxDelay: Duration, jitter: Double, timeout: TimeAmount) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.timeout = timeout
    }
}

public struct RetryingHTTPClient: Sendable {
    private let httpClient: HTTPClient
    private let config: RetryConfiguration

    public init(httpClient: HTTPClient = .shared, config: RetryConfiguration = .default) {
        self.httpClient = httpClient
        self.config = config
    }

    public func execute(_ request: HTTPClientRequest, path: String) async throws -> HTTPClientResponse {
        try await retry(path: path) {
            let response = try await httpClient.execute(request, timeout: config.timeout)
            if response.status.code >= 500 {
                let buffer = try? await response.body.collect(upTo: 1024 * 1024)
                let responseString = buffer?.getString(at: 0, length: buffer?.readableBytes ?? 0)
                throw StorageError.httpError(statusCode: Int(response.status.code), path: path, reason: responseString)
            }
            return response
        }
    }

    /// Executes a request and collects the full response body within the retry boundary.
    /// This ensures that connection drops during body transfer are retried from scratch,
    /// not just connection drops during the initial request handshake.
    public func executeAndCollect(
        _ request: HTTPClientRequest,
        path: String,
        maxBytes: Int
    ) async throws -> (response: HTTPClientResponse, buffer: ByteBuffer) {
        try await retry(path: path) {
            let response = try await httpClient.execute(request, timeout: config.timeout)
            let buffer = try await response.body.collect(upTo: maxBytes)
            if response.status.code >= 500 {
                let responseString = buffer.getString(at: 0, length: buffer.readableBytes)
                throw StorageError.httpError(statusCode: Int(response.status.code), path: path, reason: responseString)
            }
            return (response, buffer)
        }
    }

    // MARK: - Retry helpers

    private func retry<T>(path: String, body: () async throws -> T) async throws -> T {
        for attempt in 1...config.maxAttempts {
            do {
                return try await body()
            } catch {
                if !isRetryable(error) || attempt == config.maxAttempts {
                    throw mapHTTPError(error, path: path)
                }
                try await Task.sleep(for: backoffDuration(attempt: attempt))
            }
        }
        throw StorageError.connectionFailed(path: path, underlying: NSError(domain: "", code: -1))
    }

    private func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError:
            return false
        case is HTTPClientError:
            return true
        case let se as StorageError:
            switch se {
            case .connectionFailed, .timeout:
                return true
            case .httpError(let statusCode, _, _):
                return statusCode >= 500
            case .invalidURL, .noSuchFile, .listFailed, .readFailed, .writeFailed, .deleteFailed:
                return false
            }
        default:
            return false
        }
    }

    private func backoffDuration(attempt: Int) -> Duration {
        let multiplier = Int64(1 << (attempt - 1))
        let base = config.baseDelay * multiplier
        let clamped = min(config.maxDelay, base)
        let jitterFraction = config.jitter * Double.random(in: -1...1)
        let jitterPercent = Int64(jitterFraction * 100)
        let adjustment = clamped * jitterPercent / 100
        return clamped + adjustment
    }

    private func mapHTTPError(_ error: any Error, path: String) -> any Error {
        if let storageError = error as? StorageError {
            return storageError
        }
        if let httpClientError = error as? HTTPClientError {
            switch httpClientError {
            case .connectTimeout, .readTimeout:
                return StorageError.timeout(path: path)
            default:
                return StorageError.connectionFailed(path: path, underlying: httpClientError)
            }
        }
        return StorageError.connectionFailed(path: path, underlying: error)
    }
}
