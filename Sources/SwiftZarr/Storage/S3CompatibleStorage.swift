import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class S3CompatibleStorage: Storage {
    private let baseURL: URL
    private let session: URLSession
    private let additionalHeaders: [String: String]

    public init(
        baseURL: String,
        session: URLSession = .shared,
        additionalHeaders: [String: String] = [:]
    ) throws {
        guard let url = URL(string: baseURL) else {
            throw StorageError.invalidURL(baseURL)
        }
        self.baseURL = url
        self.session = session
        self.additionalHeaders = additionalHeaders
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        for (key, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func listingRequest(prefix: String) throws -> URLRequest {
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
        var request = URLRequest(url: listingURL)
        for (key, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func parseListingResponse(data: Data, prefix: String) throws -> (keys: [String], prefixes: [String]) {
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

    public func read(path: String) async throws -> Data {
        let request = request(path: path)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StorageError.httpError(statusCode: -1, path: path)
        }
        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 404:
            throw StorageError.noSuchFile(path)
        default:
            throw StorageError.httpError(statusCode: httpResponse.statusCode, path: path)
        }
    }

    public func write(path: String, data: Data) async throws {
        var request = request(path: path)
        request.httpMethod = "PUT"
        request.httpBody = data
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StorageError.httpError(statusCode: -1, path: path)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw StorageError.httpError(statusCode: httpResponse.statusCode, path: path)
        }
    }

    /// List all objects (files and sub-prefixes) under a prefix.
    public func list(prefix: String) async throws -> [String] {
        let request = try listingRequest(prefix: prefix)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StorageError.httpError(statusCode: -1, path: prefix)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw StorageError.httpError(statusCode: httpResponse.statusCode, path: prefix)
        }
        let (keys, prefixes) = try parseListingResponse(data: data, prefix: prefix)
        return keys + prefixes
    }

    /// List immediate sub-prefixes (directories) under a prefix.
    /// Returns names relative to the prefix, without trailing slashes.
    public func listDir(prefix: String) async throws -> [String] {
        let request = try listingRequest(prefix: prefix)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StorageError.httpError(statusCode: -1, path: prefix)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw StorageError.httpError(statusCode: httpResponse.statusCode, path: prefix)
        }
        let (_, prefixes) = try parseListingResponse(data: data, prefix: prefix)
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
        var request = request(path: path)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StorageError.httpError(statusCode: -1, path: path)
        }
        switch httpResponse.statusCode {
        case 200: return true
        case 404, 400: return false
        default:
            throw StorageError.httpError(statusCode: httpResponse.statusCode, path: path)
        }
    }

    public func delete(path: String) async throws {
        var request = request(path: path)
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StorageError.httpError(statusCode: -1, path: path)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw StorageError.httpError(statusCode: httpResponse.statusCode, path: path)
        }
    }
}

// MARK: - S3 ListBucket XML parser

private final class S3ListParserDelegate: NSObject, XMLParserDelegate {
    private enum State {
        case idle
        case inContents
        case inCommonPrefixes
    }

    private var state: State = .idle
    private var currentValue = ""
    var keys: [String] = []
    var prefixes: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "Contents":
            state = .inContents
            currentValue = ""
        case "CommonPrefixes":
            state = .inCommonPrefixes
            currentValue = ""
        case "Key", "Prefix":
            break
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch state {
        case .inContents, .inCommonPrefixes:
            currentValue += string
        case .idle:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Contents":
            if !value.isEmpty { keys.append(value) }
            state = .idle
        case "CommonPrefixes":
            if !value.isEmpty { prefixes.append(value) }
            state = .idle
        default:
            break
        }
    }
}
