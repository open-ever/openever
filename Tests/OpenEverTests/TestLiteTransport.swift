import Foundation
import EverLiteClient
import EverLiteClientTL
import EverTL
import adnl_swift

func testClient(_ transport: TestLiteTransport) throws -> LiteClient {
    let server = try LiteServer(host: "localhost", port: 3030,
                                publicKey: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
    return try LiteClient(server: server, requestTimeout: 2, transport: transport)
}

actor TestLiteTransport: ADNLTransport {
    let reply: @Sendable (Data) throws -> Data
    private var cipher: ADNLCipher?
    private var plaintext = Data()
    private var incoming: [Data] = []
    private var reader: CheckedContinuation<Data?, any Error>?
    private(set) var requests: [Data] = []
    private(set) var closed = false

    init(reply: @escaping @Sendable (Data) throws -> Data) { self.reply = reply }

    func connect(host: String, port: Int) async throws {}

    func send(_ data: Data) async throws {
        guard let cipher else {
            let cipher = try ADNLHandshake.adnlHandshakeAssets(
                data, secretKey: "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"
            )
            self.cipher = cipher
            enqueue(try cipher.encryptor.adnlSerializeMessage(data: Data()))
            return
        }
        plaintext.append(try cipher.decryptor.update(data))
        while let packet = try ADNLPacket.parse(data: plaintext) {
            plaintext.removeFirst(packet.length)
            let query = try TLCodec.decode(AdnlMessageQueryConstructor.self, from: packet.payload)
            let request = try TLCodec.decode(LiteServerQueryRequest.self, from: query.query)
            requests.append(request.data)
            let answer = try TLCodec.encode(AdnlMessageAnswerConstructor(query_id: query.query_id, answer: reply(request.data)))
            enqueue(try cipher.encryptor.adnlSerializeMessage(data: answer))
        }
    }

    func receive() async throws -> Data? {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if closed { return nil }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }

    func close() async {
        closed = true
        reader?.resume(returning: nil)
        reader = nil
    }

    private func enqueue(_ data: Data) {
        if let reader {
            self.reader = nil
            reader.resume(returning: data)
        } else { incoming.append(data) }
    }
}
