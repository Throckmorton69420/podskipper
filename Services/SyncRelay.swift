import Foundation
import CryptoKit
import Security

/// Pass 54: syncing two devices that iCloud can't connect.
///
/// His iPhone's copy is signed by developer team A7Y7U3PCZJ (bundle
/// app.ivory2951.coral5096) and his iPad's by N686NPXZQZ
/// (app.starfruit2689.orange1525) — certificates bought from two different
/// accounts. iCloud's key-value store and CloudKit containers belong to one
/// team, so the two installs name different stores ("A7Y7U3PCZJ.*" and
/// "N686NPXZQZ.*") and can never see each other's. No setting changes that;
/// only signing both with one team's certificate does.
///
/// So the same records go through his own Cloudflare R2 bucket instead —
/// the storage PodSkipper already publishes feeds to — as one sealed file per
/// device. Everything iCloud sync merges (shows, positions, played and
/// starred, settings, corrections, found ads) is merged the same way, by the
/// same code: `CloudSync` and `CloudRecords` read and write a `SyncStore`,
/// and this one behaves as iCloud's does — each key's newest write wins.
///
/// Authenticated twice: R2 accepts only requests signed with his access key,
/// and every file is sealed (AES-GCM) with a key derived from a random secret
/// that only his devices hold, so a public bucket shows nothing readable and
/// a file nobody sealed with it is ignored. The folder's name is derived from
/// the same secret.
protocol SyncStore: CloudRecords.Store {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func array(forKey key: String) -> [Any]?
    func dictionary(forKey key: String) -> [String: Any]?
    var dictionaryRepresentation: [String: Any] { get }
}

extension NSUbiquitousKeyValueStore: SyncStore {}

/// The secret both devices share, and (to set up the second device in one
/// step) the R2 access the first one uses. Kept in the Keychain.
struct SyncRelaySetup: Codable, Equatable {
    var secret: Data
    var credentials: R2Uploader.Credentials?

    static let prefix = "podskipper-sync:1:"

    static func new(credentials: R2Uploader.Credentials?) -> SyncRelaySetup {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return SyncRelaySetup(secret: Data(bytes), credentials: credentials)
    }

    /// The folder in the bucket: named from the secret, so only his devices
    /// can find it.
    var folder: String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("folder".utf8), using: SymmetricKey(data: secret))
        return "sync/" + Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined() + "/"
    }

    var sealKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data("PodSkipper sync relay".utf8),
                               info: Data("seal 1".utf8), outputByteCount: 32)
    }

    /// The text copied to the other device.
    var text: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init(secret: Data, credentials: R2Uploader.Credentials?) {
        self.secret = secret
        self.credentials = credentials
    }

    /// Reads a pasted setup; nil for anything else.
    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix) else { return nil }
        var base64 = String(trimmed.dropFirst(Self.prefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let setup = try? JSONDecoder().decode(SyncRelaySetup.self, from: data),
              setup.secret.count == 32 else { return nil }
        self = setup
    }

    // MARK: Keychain

    private static let account = "sync-relay"
    private static let service = "com.yourname.podskipper"

    static func load() -> SyncRelaySetup? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                    kSecAttrService as String: service, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SyncRelaySetup.self, from: data)
    }

    func save() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: Self.account,
                                    kSecAttrService as String: Self.service]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = try JSONEncoder().encode(self)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: "Keychain", code: Int(status)) }
    }

    static func clear() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                    kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
}

/// Where the sealed files go: the R2 bucket, or (tests) memory.
protocol RelayTransport: Sendable {
    func put(_ data: Data, name: String) async throws
    func get(name: String) async throws -> Data?
    func names() async throws -> [String]
}

struct R2RelayTransport: RelayTransport {
    let uploader: R2Uploader
    let folder: String

    func put(_ data: Data, name: String) async throws {
        try await uploader.upload(data: data, key: folder + name, contentType: "application/octet-stream")
    }

    func get(name: String) async throws -> Data? { try await uploader.download(key: folder + name) }

    func names() async throws -> [String] {
        try await uploader.list(prefix: folder).map { String($0.dropFirst(folder.count)) }
    }
}

/// A key-value store kept on this device and exchanged through a
/// `RelayTransport`: each device writes its whole view as one sealed file
/// (`<device id>.sealed`) and reads the others'. For each key the newest
/// write wins, deletions included — iCloud key-value semantics.
final class RelayStore: SyncStore, @unchecked Sendable {
    struct Entry: Codable, Equatable {
        /// The value as a binary property list; nil once removed.
        var value: Data?
        /// When it was written (seconds since 1970) and by which device.
        var at: Double
        var by: String
    }

    struct Document: Codable {
        var device: String
        var kind: String
        var sent: Double
        var entries: [String: Entry]
    }

    enum RelayError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let device): return "A file from another device (\(device)) couldn't be opened with this sync setup."
            }
        }
    }

    let deviceID: String
    private let transport: RelayTransport
    private let key: SymmetricKey
    private let file: URL?
    private let clock: () -> Date
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Devices whose files were read last time, with when each was sent.
    private(set) var devices: [String: (kind: String, sent: Date)] = [:]

    init(transport: RelayTransport, key: SymmetricKey, deviceID: String, file: URL?, clock: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.key = key
        self.deviceID = deviceID
        self.file = file
        self.clock = clock
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    // MARK: SyncStore

    func object(forKey key: String) -> Any? {
        lock.withLock { entries[key]?.value }.flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)
        }
    }

    func set(_ value: Any?, forKey key: String) {
        let data = value.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
        lock.withLock {
            if entries[key]?.value == data { return }
            entries[key] = Entry(value: data, at: clock().timeIntervalSince1970, by: deviceID)
        }
        persist()
    }

    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func setData(_ data: Data?, forKey key: String) { set(data, forKey: key) }
    func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }

    var dictionaryRepresentation: [String: Any] {
        let keys = lock.withLock { entries.filter { $0.value.value != nil }.map(\.key) }
        var out: [String: Any] = [:]
        for key in keys { out[key] = object(forKey: key) }
        return out
    }

    // MARK: Exchange

    /// Seals and uploads this device's view.
    func send(kind: String) async throws {
        let document = Document(device: deviceID, kind: kind, sent: clock().timeIntervalSince1970,
                                entries: lock.withLock { entries })
        let sealed = try AES.GCM.seal(try JSONEncoder().encode(document), using: key).combined ?? Data()
        try await transport.put(sealed, name: deviceID + ".sealed")
    }

    /// Reads every other device's file and takes each key that is newer
    /// there. Returns the keys that changed here.
    @discardableResult
    func receive() async throws -> Set<String> {
        var changed = Set<String>()
        var seen: [String: (kind: String, sent: Date)] = [:]
        var unreadable: String?
        for name in try await transport.names() where name.hasSuffix(".sealed") && name != deviceID + ".sealed" {
            guard let sealed = try await transport.get(name: name) else { continue }
            guard let box = try? AES.GCM.SealedBox(combined: sealed),
                  let plain = try? AES.GCM.open(box, using: key),
                  let document = try? JSONDecoder().decode(Document.self, from: plain) else {
                unreadable = String(name.dropLast(".sealed".count))
                continue
            }
            seen[document.device] = (document.kind, Date(timeIntervalSince1970: document.sent))
            lock.withLock {
                for (k, theirs) in document.entries {
                    let mine = entries[k]
                    if mine == nil || theirs.at > mine!.at || (theirs.at == mine!.at && theirs.by > mine!.by) {
                        if mine?.value != theirs.value { changed.insert(k) }
                        entries[k] = theirs
                    }
                }
            }
        }
        lock.withLock { devices = seen }
        if !changed.isEmpty { persist() }
        if let unreadable, seen.isEmpty { throw RelayError.unreadable(unreadable) }
        return changed
    }

    private func persist() {
        guard let file else { return }
        let snapshot = lock.withLock { entries }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
