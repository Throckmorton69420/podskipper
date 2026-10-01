import Foundation

/// The entitlements this copy of the app was signed with, for Diagnostics.
///
/// iOS has no public call for an app to read its own entitlements: the
/// `SecTask` functions are macOS-only, and calling them broke the 97d39cd
/// build. The entitlements are stored in the code signature inside the app's
/// own executable (written by KSign when it signs on the phone), so they are
/// read from there. An unsigned build, like CI's, has none: every key reads
/// as missing.
enum SignedEntitlements {

    /// The keys signed in as `true`. Read once: the signature can't change
    /// while the app runs.
    static let granted: Set<String> = {
        guard let plist = read() else { return [] }
        return Set(plist.compactMap { ($0.value as? Bool) == true ? $0.key : nil })
    }()

    /// Apple's Background GPU Access: without it iOS refuses the GPU once
    /// the app leaves the screen, even inside a continued-processing task.
    static let backgroundGPUKey = "com.apple.developer.background-tasks.continued-processing.gpu"

    /// Whether the ad model may keep using the GPU off screen.
    static var backgroundGPU: Bool { granted.contains(backgroundGPUKey) }

    private static func read() -> [String: Any]? {
        // Mapped, not loaded: only the header and signature pages are touched.
        guard let url = Bundle.main.executableURL,
              let file = try? Data(contentsOf: url, options: .alwaysMapped),
              let slice = arm64Slice(file),
              let signature = codeSignature(file, slice: slice),
              let xml = entitlementsBlob(file, signature: signature),
              let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil)
        else { return nil }
        return plist as? [String: Any]
    }

    /// Where the arm64 code starts: the whole file, or one slice of a fat file.
    private static func arm64Slice(_ file: Data) -> Int? {
        if u32(file, 0, bigEndian: false) == 0xfeedfacf { return 0 }    // MH_MAGIC_64
        guard u32(file, 0, bigEndian: true) == 0xcafebabe,               // FAT_MAGIC
              let count = u32(file, 4, bigEndian: true), count <= 16 else { return nil }
        for index in 0..<Int(count) {
            let entry = 8 + index * 20                                   // fat_arch
            if u32(file, entry, bigEndian: true) == 0x0100000c,          // CPU_TYPE_ARM64
               let offset = u32(file, entry + 8, bigEndian: true) {
                return Int(offset)
            }
        }
        return nil
    }

    /// Where the signature starts, from the LC_CODE_SIGNATURE load command.
    private static func codeSignature(_ file: Data, slice: Int) -> Int? {
        guard u32(file, slice, bigEndian: false) == 0xfeedfacf,
              let commands = u32(file, slice + 16, bigEndian: false) else { return nil }
        var command = slice + 32                                         // after mach_header_64
        for _ in 0..<Int(commands) {
            guard let kind = u32(file, command, bigEndian: false),
                  let size = u32(file, command + 4, bigEndian: false), size >= 8 else { return nil }
            if kind == 0x1d,                                             // LC_CODE_SIGNATURE
               let offset = u32(file, command + 8, bigEndian: false) {
                return slice + Int(offset)
            }
            command += Int(size)
        }
        return nil
    }

    /// The XML plist in the signature's entitlements blob (big-endian, like
    /// the rest of the signature).
    private static func entitlementsBlob(_ file: Data, signature: Int) -> Data? {
        guard u32(file, signature, bigEndian: true) == 0xfade0cc0,       // CSMAGIC_EMBEDDED_SIGNATURE
              let count = u32(file, signature + 8, bigEndian: true), count <= 64 else { return nil }
        for index in 0..<Int(count) {
            let entry = signature + 12 + index * 8                       // CS_BlobIndex
            guard u32(file, entry, bigEndian: true) == 5,                // CSSLOT_ENTITLEMENTS
                  let offset = u32(file, entry + 4, bigEndian: true) else { continue }
            let blob = signature + Int(offset)
            guard u32(file, blob, bigEndian: true) == 0xfade7171,        // CSMAGIC_EMBEDDED_ENTITLEMENTS
                  let length = u32(file, blob + 4, bigEndian: true), length > 8,
                  blob + Int(length) <= file.count else { return nil }
            let start = file.startIndex
            return file.subdata(in: (start + blob + 8)..<(start + blob + Int(length)))
        }
        return nil
    }

    /// Four bytes at `offset`, or nil past the end of the file.
    private static func u32(_ file: Data, _ offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= file.count else { return nil }
        let raw = file.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        return bigEndian ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw)
    }
}
