import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import SwiftZarr
import Synchronization
import Testing

private final class RequestLog: Sendable {
    private let methods = Mutex<[String]>([])

    func append(_ method: String) { methods.withLock { $0.append(method) } }
    var snapshot: [String] { methods.withLock { $0 } }
}

private final class ChunkStatusHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let status: HTTPResponseStatus
    let requests: RequestLog

    init(status: HTTPResponseStatus, requests: RequestLog) {
        self.status = status
        self.requests = requests
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let request):
            requests.append(request.method.rawValue)
            #expect(request.method == .GET)
            #expect(request.uri == "/array/0")
        case .end:
            let body: [UInt8] = status.code == 200 ? [1, 0, 0, 0, 2, 0, 0, 0] : []
            let head = HTTPResponseHead(
                version: .http1_1,
                status: status,
                headers: HTTPHeaders([("Content-Length", String(body.count)), ("Connection", "close")])
            )
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            if !body.isEmpty {
                context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: body)))), promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        case .body:
            Issue.record("Unexpected request body")
        }
    }
}

@Test(arguments: [200, 400, 403, 404, 408, 429, 503])
func testS3ChunkHTTPStatus(code: Int) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let requests = RequestLog()
    do {
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ChunkStatusHandler(status: .init(statusCode: code), requests: requests))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        do {
            let port = try #require(server.localAddress?.port)
            let storage = try S3CompatibleStorage(baseURL: "http://127.0.0.1:\(port)")
            let array = try ZarrArray(
                metadata: V2ArrayMetadata(shape: [2], chunks: [2], dtype: "<i4", fillValue: .int(7)),
                storage: storage,
                path: "array"
            )
            if code == 200 {
                let values: [Int32] = try await array.retrieveChunk([0])
                #expect(values == [1, 2])
                #expect(requests.snapshot == ["GET"])
                let optional: [Int32]? = try await array.retrieveChunkIfExists([0])
                #expect(optional == [1, 2])
            } else if code == 404 {
                let values: [Int32] = try await array.retrieveChunk([0])
                #expect(values == [7, 7])
                let missing: [Int32]? = try await array.retrieveChunkIfExists([0])
                #expect(missing == nil)
            } else {
                do {
                    let values: [Int32] = try await array.retrieveChunk([0])
                    Issue.record("HTTP \(code) unexpectedly returned values: \(values)")
                } catch StorageError.httpError(let status, let path, _) {
                    #expect(status == code)
                    #expect(path == "array/0")
                }
                do {
                    let values: [Int32]? = try await array.retrieveChunkIfExists([0])
                    Issue.record("HTTP \(code) unexpectedly returned: \(String(describing: values))")
                } catch StorageError.httpError(let status, let path, _) {
                    #expect(status == code)
                    #expect(path == "array/0")
                }
            }
            let attempts = code == 408 || code == 429 || code >= 500 ? 3 : 1
            #expect(requests.snapshot == Array(repeating: "GET", count: 2 * attempts))
            let client = RetryingHTTPClient()
            let request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/array/0")
            do {
                let response = try await client.execute(request, path: "array/0")
                _ = try await response.body.collect(upTo: 1024)
                #expect(attempts == 1)
                #expect(Int(response.status.code) == code)
            } catch StorageError.httpError(let status, _, _) {
                #expect(attempts == 3)
                #expect(status == code)
            }
            #expect(requests.snapshot.count == 3 * attempts)
        } catch {
            try await server.close().get()
            throw error
        }
        try await server.close().get()
    } catch {
        try await group.shutdownGracefully()
        throw error
    }
    try await group.shutdownGracefully()
}
