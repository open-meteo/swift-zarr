import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

#if canImport(FoundationXML)
import FoundationXML
#endif

public final class S3CompatibleStorage: Storage {
    private let baseURL: URL
    private let retryingClient: RetryingHTTPClient
    private let additionalHeaders: [String: String]

    /// - Parameters:
    ///   - baseURL: Base URL of the S3-compatible endpoint, e.g. `"https://s3.amazonaws.com/my-bucket"`.
    ///   - retryingClient: A `RetryingHTTPClient` instance wrapping an `AsyncHTTPClient.HTTPClient`.
    ///   - additionalHeaders: Extra HTTP headers added to every request (e.g. auth tokens).
    public init(
        baseURL: String,
        retryingClient: RetryingHTTPClient = RetryingHTTPClient(),
        additionalHeaders: [String: String] = [:]
    ) throws {
        guard let url = URL(string: baseURL) else {
            throw StorageError.invalidURL(baseURL)
        }
        self.baseURL = url
        self.retryingClient = retryingClient
        self.additionalHeaders = additionalHeaders
    }

    // MARK: - Request builders

    private func makeRequest(url: URL, method: HTTPMethod = .GET) -> HTTPClientRequest {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = method
        for (key, value) in additionalHeaders {
            request.headers.add(name: key, value: value)
        }
        return request
    }

    private func listingRequest(prefix: String) throws -> HTTPClientRequest {
        let normalizedPrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw StorageError.invalidURL(baseURL.absoluteString)
        }
        components.queryItems = [
            URLQueryItem(name: "prefix", value: normalizedPrefix),
            URLQueryItem(name: "delimiter", value: "/"),
        ]
        guard let listingURL = components.url else {
            throw StorageError.invalidURL(baseURL.absoluteString)
        }
        return makeRequest(url: listingURL)
    }

    private func parseListingResponse(data: Data) throws -> (keys: [String], prefixes: [String]) {
        let parser = XMLParser(data: data)
        let delegate = S3ListParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw StorageError.listFailed(
                parser.parserError.map { "\($0)" } ?? "unknown XML parse error"
            )
        }
        return (delegate.keys, delegate.prefixes)
    }

    // MARK: - Storage protocol

    public func read(path: String) async throws -> Data {
        let request = makeRequest(url: baseURL.appending(path: path))
        let response = try await retryingClient.execute(request, path: path)
        switch response.status.code {
        case 200...299:
            let buffer = try await response.body.collect(upTo: 512 * 1024 * 1024)
            return Data(buffer.readableBytesView)
        case 404:
            throw StorageError.noSuchFile(path)
        default:
            throw StorageError.httpError(statusCode: Int(response.status.code), path: path)
        }
    }

    public func write(path: String, data: Data) async throws {
        var request = makeRequest(url: baseURL.appending(path: path), method: .PUT)
        request.body = .bytes(data)
        let response = try await retryingClient.execute(request, path: path)
        _ = try? await response.body.collect(upTo: 1024 * 1024)
        guard (200...299).contains(Int(response.status.code)) else {
            throw StorageError.httpError(statusCode: Int(response.status.code), path: path)
        }
    }

    /// List all objects (files and sub-prefixes) under a prefix.
    public func list(prefix: String) async throws -> [String] {
        let request = try listingRequest(prefix: prefix)
        let response = try await retryingClient.execute(request, path: prefix)
        guard (200...299).contains(Int(response.status.code)) else {
            throw StorageError.httpError(statusCode: Int(response.status.code), path: prefix)
        }
        let buffer = try await response.body.collect(upTo: 16 * 1024 * 1024)
        let data = Data(buffer.readableBytesView)
        let (keys, prefixes) = try parseListingResponse(data: data)
        return keys + prefixes
    }

    /// List immediate sub-prefixes (directories) under a prefix.
    /// Returns names relative to the prefix, without trailing slashes.
    public func listDir(prefix: String) async throws -> [String] {
        let request = try listingRequest(prefix: prefix)
        let response = try await retryingClient.execute(request, path: prefix)
        guard (200...299).contains(Int(response.status.code)) else {
            throw StorageError.httpError(statusCode: Int(response.status.code), path: prefix)
        }
        let buffer = try await response.body.collect(upTo: 16 * 1024 * 1024)
        let data = Data(buffer.readableBytesView)
        let (_, prefixes) = try parseListingResponse(data: data)
        let normalizedPrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return prefixes.map {
            var name = $0
            if name.hasPrefix(normalizedPrefix) {
                name = String(name.dropFirst(normalizedPrefix.count))
            }
            return name.hasSuffix("/") ? String(name.dropLast()) : name
        }
    }

    public func exists(path: String) async throws -> Bool {
        let request = makeRequest(url: baseURL.appending(path: path), method: .HEAD)
        let response = try await retryingClient.execute(request, path: path)
        _ = try? await response.body.collect(upTo: 1024)
        switch response.status.code {
        case 200: return true
        case 400, 404: return false
        default:
            throw StorageError.httpError(statusCode: Int(response.status.code), path: path)
        }
    }

    public func delete(path: String) async throws {
        let request = makeRequest(url: baseURL.appending(path: path), method: .DELETE)
        let response = try await retryingClient.execute(request, path: path)
        _ = try? await response.body.collect(upTo: 1024 * 1024)
        guard (200...299).contains(Int(response.status.code)) else {
            throw StorageError.httpError(statusCode: Int(response.status.code), path: path)
        }
    }
}

// MARK: - S3 ListBucket XML parser

internal final class S3ListParserDelegate: NSObject, XMLParserDelegate {
    private enum State {
        case idle
        case inContents
        case inCommonPrefixes
    }

    private var state: State = .idle
    private var currentElement = ""
    private var currentValue = ""
    private var currentKey = ""
    private var currentPrefix = ""
    var keys: [String] = []
    var prefixes: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        switch elementName {
        case "Contents":
            state = .inContents
            currentValue = ""
        case "CommonPrefixes":
            state = .inCommonPrefixes
            currentValue = ""
        case "Key", "Prefix":
            currentValue = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard state != .idle, currentElement == "Key" || currentElement == "Prefix" else { return }
        currentValue += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key":
            currentKey = value
            currentValue = ""
        case "Prefix":
            currentPrefix = value
            currentValue = ""
        case "Contents":
            if !currentKey.isEmpty { keys.append(currentKey) }
            currentKey = ""
            state = .idle
            currentElement = ""
        case "CommonPrefixes":
            if !currentPrefix.isEmpty { prefixes.append(currentPrefix) }
            currentPrefix = ""
            state = .idle
            currentElement = ""
        default:
            break
        }
    }
}
