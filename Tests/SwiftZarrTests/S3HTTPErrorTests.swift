import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import SwiftZarr
import Testing

private final class ChunkStatusHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let status: HTTPResponseStatus

    init(status: HTTPResponseStatus) { self.status = status }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let request):
            #expect(request.method == .HEAD)
            #expect(request.uri == "/array/0")
        case .end:
            let head = HTTPResponseHead(
                version: .http1_1,
                status: status,
                headers: HTTPHeaders([("Content-Length", "0"), ("Connection", "close")])
            )
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        case .body:
            Issue.record("Unexpected request body")
        }
    }
}

@Test(arguments: [400, 403, 404])
func testS3ChunkHTTPStatus(code: Int) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ChunkStatusHandler(status: .init(statusCode: code)))
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
            if code == 404 {
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
