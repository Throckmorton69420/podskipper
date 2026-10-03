import Foundation

/// Uses the catalog's pinned files and CoreAIKit's atomic cache layout, with
/// the same cellular rule as MLX. A cancelled/partial bundle is never installed.
actor CoreAIModelDownload {
    private let baseURL: URL
    private let sessionConfiguration: URLSessionConfiguration?
    init(baseURL: URL = URL(string: "https://huggingface.co")!, configuration: URLSessionConfiguration? = nil) {
        self.baseURL = baseURL
        self.sessionConfiguration = configuration
    }
    struct File: Codable, Sendable { let path: String; let size: Int64 }
    struct Listing: Decodable {
        struct Sibling: Decodable { let rfilename: String; let size: Int64? }
        let siblings: [Sibling]
    }

    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    func download(repo: String, revision: String, variant: String, final: URL,
                  allowCellular: Bool,
                  progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard Self.safePath(repo), repo.split(separator: "/").count == 2,
              Self.safePath(revision), !revision.contains("/"),
              variant.isEmpty || Self.safePath(variant) else { throw CocoaError(.fileReadInvalidFileName) }
        let configuration = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? .default
        configuration.allowsCellularAccess = allowCellular
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "\(baseURL.absoluteString)/api/models/\(repo)/revision/\(revision)?blobs=true")!
        let (data, response) = try await session.data(from: url)
        try Self.check(response)
        let prefix = variant.isEmpty ? "" : variant + "/"
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        let candidates = listing.siblings.filter { $0.rfilename.hasPrefix(prefix) }
        let files = try candidates.map { sibling -> File in
            let path = String(sibling.rfilename.dropFirst(prefix.count))
            guard Self.safePath(path), let size = sibling.size, size > 0 else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The catalog bundle has an invalid path or file size."])
            }
            return File(path: path, size: size)
        }
        guard !files.isEmpty, Set(files.map(\.path)).count == files.count,
              files.contains(where: { $0.path == "metadata.json" }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The catalog bundle is missing its metadata or files."])
        }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let fm = FileManager.default
        let parent = final.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let free = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? .max
        let staging = parent.appendingPathComponent(".podskipper-staging-" + final.lastPathComponent)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var stagingValues = URLResourceValues(); stagingValues.isExcludedFromBackup = true
        var stagingFolder = staging; try stagingFolder.setResourceValues(stagingValues)
        let completed = files.reduce(Int64(0)) { sum, file in
            let size = try? staging.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return sum + (size.map(Int64.init) == file.size ? file.size : 0)
        }
        guard free > total - completed + 500_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.path)
            let present = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if present.map(Int64.init) == file.size {
                done += file.size
                progress(Double(done) / Double(total), file.path)
                continue
            }
            let remote = URL(string: "\(baseURL.absoluteString)/\(repo)/resolve/\(revision)/\(prefix)\(file.path)")!
            let base = done
            let delegate = FileProgress { bytes in progress(min(1, Double(base + bytes) / Double(total)), file.path) }
            let resumeURL = staging.appendingPathComponent(".resume/" + file.path)
            let resumed = try? Data(contentsOf: resumeURL)
            let temporary: URL
            let response: URLResponse
            do {
                if let resumed { (temporary, response) = try await session.download(resumeFrom: resumed, delegate: delegate) }
                else { (temporary, response) = try await session.download(from: remote, delegate: delegate) }
            } catch {
                if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    try? fm.createDirectory(at: resumeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: resumeURL, options: .atomic)
                } else if resumed != nil { try? fm.removeItem(at: resumeURL) }
                throw error
            }
            try Self.check(response)
            try Task.checkCancellation()
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(size) == file.size else { throw CocoaError(.fileReadCorruptFile) }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: temporary, to: destination)
            try? fm.removeItem(at: resumeURL)
            done += file.size
            progress(Double(done) / Double(total), file.path)
        }
        try Task.checkCancellation()
        // Preserve any existing complete cache. Downloads never replace a model
        // being used by inference or expose their staging directory to selection.
        try? fm.removeItem(at: staging.appendingPathComponent(".resume"))
        if !fm.fileExists(atPath: final.path) { try fm.moveItem(at: staging, to: final) }
        else { try? fm.removeItem(at: staging) }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var installed = final; try installed.setResourceValues(values)
        progress(1, "")
    }

    private static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

private final class FileProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Int64) -> Void
    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
