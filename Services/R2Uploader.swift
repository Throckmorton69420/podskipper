import Foundation
import CryptoKit
import Security

/// Uploads to Cloudflare R2 over its S3-compatible API.
///
/// R2's free tier is 10 GB of storage with no egress charge, which is the
/// piece that makes this whole architecture cost nothing: the phone does the
/// compute, R2 does the serving, and Apple Podcasts never knows the
/// difference.
///
/// Credentials go in the Keychain, not here. See `R2Credentials`.
struct R2Uploader {

    struct Credentials: Codable, Sendable {
        var accountID: String       // from the Cloudflare dashboard
        var accessKeyID: String     // R2 API token
        var secretAccessKey: String
        var bucket: String
        /// Public base URL for the bucket, e.g. https://pods.ha50e76.win
        /// This is what goes into the RSS feed, so it must be the custom
        /// domain, not the internal endpoint.
        var publicBaseURL: String

        var endpointHost: String { "\(accountID).r2.cloudflarestorage.com" }
    }

    let credentials: Credentials
    private let region = "auto"        // R2 always uses "auto"
    private let service = "s3"

    // MARK: - Public API

    /// Upload a file already on disk. Streams from disk, so a 60 MB episode
    /// never sits in memory.
    @discardableResult
    func upload(fileURL: URL, key: String, contentType: String) async throws -> URL {
        let payloadHash = try Self.streamingSHA256(of: fileURL)
        let request = try signedRequest(method: "PUT",
                                        key: key,
                                        contentType: contentType,
                                        payloadHash: payloadHash)

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        try Self.check(response, data)
        return publicURL(for: key)
    }

    /// Upload in-memory data — used for the feed XML, which is tiny.
    @discardableResult
    func upload(data: Data, key: String, contentType: String) async throws -> URL {
        let payloadHash = SHA256.hash(data: data).hexString
        let request = try signedRequest(method: "PUT",
                                        key: key,
                                        contentType: contentType,
                                        payloadHash: payloadHash)

        let (respData, response) = try await URLSession.shared.upload(for: request, from: data)
        try Self.check(response, respData)
        return publicURL(for: key)
    }

    func delete(key: String) async throws {
        let emptyHash = SHA256.hash(data: Data()).hexString
        let request = try signedRequest(method: "DELETE",
                                        key: key,
                                        contentType: nil,
                                        payloadHash: emptyHash)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
    }

    func publicURL(for key: String) -> URL {
        URL(string: credentials.publicBaseURL.trimmingTrailingSlash() + "/" + key)!
    }

    // MARK: - SigV4

    private func signedRequest(method: String,
                               key: String,
                               contentType: String?,
                               payloadHash: String) throws -> URLRequest {

        let now = Date()
        let amzDate = Self.amzDateFormatter.string(from: now)     // 20260910T142530Z
        let dateStamp = String(amzDate.prefix(8))                  // 20260910

        let host = credentials.endpointHost
        let canonicalURI = "/\(credentials.bucket)/\(key.uriEncodedPath())"

        // Headers must be sorted by lowercase name in both places.
        var headers: [String: String] = [
            "host": host,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate
        ]
        if let contentType { headers["content-type"] = contentType }

        let signedHeaderNames = headers.keys.sorted()
        let canonicalHeaders = signedHeaderNames
            .map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }
            .joined()
        let signedHeaders = signedHeaderNames.joined(separator: ";")

        let canonicalRequest = [
            method,
            canonicalURI,
            "",                       // no query string
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            SHA256.hash(data: Data(canonicalRequest.utf8)).hexString
        ].joined(separator: "\n")

        // Derive the signing key: date -> region -> service -> aws4_request
        let kDate = Self.hmac(key: Data("AWS4\(credentials.secretAccessKey)".utf8), data: dateStamp)
        let kRegion = Self.hmac(key: kDate, data: region)
        let kService = Self.hmac(key: kRegion, data: service)
        let kSigning = Self.hmac(key: kService, data: "aws4_request")
        let signature = Self.hmac(key: kSigning, data: stringToSign).hexString

        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"

        var request = URLRequest(url: URL(string: "https://\(host)\(canonicalURI)")!)
        request.httpMethod = method
        for (name, value) in headers where name != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300
        return request
    }

    // MARK: - Helpers

    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static func hmac(key: Data, data: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(data.utf8),
                                                  using: SymmetricKey(data: key))
        return Data(mac)
    }

    /// Hash a file in 1 MB chunks so a large episode doesn't blow up memory.
    private static func streamingSHA256(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString
    }

    private static func check(_ response: URLResponse, _ body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: body, encoding: .utf8) ?? ""
            throw NSError(domain: "R2", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "R2 returned \(http.statusCode). \(text.prefix(400))"
            ])
        }
    }
}

// MARK: - Small extensions

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension String {
    /// SigV4 wants each path segment percent-encoded, but not the slashes.
    func uriEncodedPath() -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    func trimmingTrailingSlash() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}

// MARK: - Keychain storage

enum R2Credentials {
    private static let account = "r2-credentials"
    private static let service = "com.yourname.podskipper"

    static func save(_ credentials: R2Uploader.Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "Keychain", code: Int(status))
        }
    }

    static func load() -> R2Uploader.Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(R2Uploader.Credentials.self, from: data)
    }
}
