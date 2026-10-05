import Foundation

private final class Samples: @unchecked Sendable {
    let lock = NSLock()
    private var received: [Int64] = []
    func report(_ value: Int64) { lock.withLock { received.append(value) } }
    var values: [Int64] { lock.withLock { received } }
}

@main struct ModelTransferProbe {
    static func main() async throws {
        let bytes = 2_097_152
        let remote = URL(string: CommandLine.arguments[1])!
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let samples = Samples()
        let transfer = ModelFileTransfer(configuration: .ephemeral, destination: folder.appending(path: "complete"),
                                         expectedBytes: Int64(bytes), report: { samples.report($0) })
        try await transfer.download(from: remote, resumeData: nil)
        let values = samples.values
        precondition(values.contains { $0 > 0 && $0 < bytes }, "No progress before completion")
        precondition(values.last == Int64(bytes))
        precondition(values == values.sorted())
        print("PASS: intermediate progress,", values.count, "callbacks")

        let destination = folder.appending(path: "interrupted")
        let interrupted = ModelFileTransfer(configuration: .ephemeral, destination: destination,
                                            expectedBytes: Int64(bytes), report: { _ in })
        let task = Task { try await interrupted.download(from: remote, resumeData: nil) }
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()
        let resume: Data
        do { try await task.value; fatalError("Cancelled transfer returned success") }
        catch {
            precondition(!FileManager.default.fileExists(atPath: destination.path))
            guard let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data else {
                fatalError("Cancellation failed to preserve resume data")
            }
            resume = data
        }
        let resumed = ModelFileTransfer(configuration: .ephemeral, destination: destination,
                                        expectedBytes: Int64(bytes), report: { _ in })
        try await resumed.download(from: remote, resumeData: resume)
        let downloaded = try Data(contentsOf: destination)
        precondition(downloaded == Data(repeating: 120, count: bytes))
        print("PASS: cancellation and resumed file contents")

        for (name, url, size) in [("http-error", remote.appendingPathComponent("missing"), bytes),
                                  ("wrong-size", remote, bytes + 1)] {
            let rejected = folder.appending(path: name)
            let transfer = ModelFileTransfer(configuration: .ephemeral, destination: rejected,
                                             expectedBytes: Int64(size), report: { _ in })
            do { try await transfer.download(from: url, resumeData: nil); fatalError("Invalid transfer accepted") }
            catch { precondition(!FileManager.default.fileExists(atPath: rejected.path)) }
            print("PASS:", name, "never installed")
        }
    }
}
