import ArgumentParser
import Foundation
import EverLiteClient

struct ConnectionOptions: ParsableArguments {
    @OptionGroup var configuration: ConfigurationOptions
    @Option(name: [.customLong("host"), .customLong("ip")],
            help: "Server IP or hostname; overrides liteclient.ip in the configuration.") var host: String?
    @Option(help: "Server TCP port; overrides liteclient.port in the configuration.") var port: Int?
    @Option(help: "Server Ed25519 key, hex or base64; overrides liteclient.publicKey in the configuration.")
    var publicKey: String?
    @Option(help: "Zero-based server index for a global-config liteservers array.") var serverIndex = 0
    @Option(help: "Connection and ADNL handshake timeout in seconds (0 < timeout <= 86400).")
    var connectionTimeout: Double = 10
    @Option(help: "Timeout per lite-server request in seconds (0 < timeout <= 86400).")
    var requestTimeout: Double = 15
    @Option(help: "Maximum ADNL payload in bytes, including the query envelope.")
    var maximumPayloadSize: Int = (1 << 24) - 64

    var config: String? {
        get { configuration.config }
        set { configuration.config = newValue }
    }

    mutating func validate() throws {
        guard connectionTimeout.isFinite, connectionTimeout > 0, connectionTimeout <= 86_400,
              requestTimeout.isFinite, requestTimeout > 0, requestTimeout <= 86_400 else {
            throw ValidationError("Timeouts must be finite, greater than zero and at most 86400 seconds.")
        }
        guard maximumPayloadSize >= 0, UInt64(maximumPayloadSize) <= UInt64(UInt32.max) - 64 else {
            throw ValidationError("--maximum-payload-size must be between 0 and 4294967231.")
        }
    }

    func resolvedServer(environment: [String: String] = ProcessInfo.processInfo.environment,
                        directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) throws -> LiteServer {
        let configURL = try configuration.resolvedFile(environment: environment, directory: directory)
        let needsDefaults = host == nil || port == nil || publicKey == nil
        var defaults: OpenEverConfiguration.Connection?
        if let configURL, needsDefaults || configuration.hasExplicitPath(environment: environment) {
            let decoded: OpenEverConfiguration
            do { decoded = try JSONDecoder().decode(OpenEverConfiguration.self, from: Input.file(configURL.path)) }
            catch { throw ValidationError("Cannot load configuration '\(configURL.path)': \(error)") }
            if let liteclient = decoded.liteclient {
                guard serverIndex == 0 else { throw ValidationError("--server-index requires a global-config liteservers array.") }
                defaults = liteclient
            } else if let servers = decoded.liteservers {
                guard servers.indices.contains(serverIndex) else {
                    throw ValidationError("--server-index is outside the configuration's liteservers array.")
                }
                let server = try servers[serverIndex].server()
                defaults = OpenEverConfiguration.Connection(ip: server.host, port: server.port,
                                                            publicKey: servers[serverIndex].id.key)
            } else {
                throw ValidationError("Configuration '\(configURL.path)' must contain a liteclient section or a liteservers array.")
            }
        } else if serverIndex != 0 {
            throw ValidationError("--server-index requires a global-config liteservers array.")
        }
        let resolvedHost = host ?? defaults?.ip
        let resolvedKey = publicKey ?? defaults?.publicKey
        let resolvedPort = port ?? defaults?.port
        guard let resolvedHost, let resolvedPort, let resolvedKey else {
            throw ValidationError("Set liteclient.ip, liteclient.port and liteclient.publicKey in the configuration (--config, OPENEVER_CONFIG or ./openever.json), or provide --ip/--host, --port and --public-key.")
        }
        return try LiteServer(host: resolvedHost, port: resolvedPort, publicKey: Input.hash(resolvedKey).data)
    }

    func withClient<Result>(_ operation: (LiteClient) async throws -> Result) async throws -> Result {
        let client = try LiteClient(server: resolvedServer(), connectionTimeout: connectionTimeout,
                                    requestTimeout: requestTimeout, maximumPayloadSize: maximumPayloadSize)
        do {
            let result = try await operation(client)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }
}

struct OpenEverConfiguration: Codable {
    let liteclient: Connection?
    let liteservers: [Server]?

    static let empty = OpenEverConfiguration(liteclient: Connection(ip: "", port: 0, publicKey: ""), liteservers: nil)

    struct Connection: Codable {
        let ip: String?
        let port: Int?
        let publicKey: String?
    }

    struct Server: Codable {
        struct Key: Codable {
            let type: String?
            let key: String
            enum CodingKeys: String, CodingKey { case type = "@type", key }
        }
        let host: String?
        let ip: Int64?
        let port: Int
        let id: Key

        func server() throws -> LiteServer {
            guard id.type == nil || id.type == "pub.ed25519" else {
                throw ValidationError("Only pub.ed25519 lite-server keys are supported.")
            }
            let hostname: String
            if let host { hostname = host }
            else if let ip, ip >= Int64(Int32.min), ip <= Int64(UInt32.max) {
                let value = UInt32(truncatingIfNeeded: ip)
                hostname = [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".")
            } else { throw ValidationError("Each lite server requires host or a signed/unsigned 32-bit IPv4 ip.") }
            return try LiteServer(host: hostname, port: port, publicKey: Input.hash(id.key).data)
        }
    }
}
