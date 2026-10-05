import Foundation
import CryptoKit

/// One exact MLX request's window plan and completed, validated answers.
/// Completed windows retain their boundaries if memory pressure makes the
/// remaining windows smaller on the next launch.
struct ModelWindowCheckpoint {
    let checkpoint: DetectionCheckpoint
    let identity: String

    static func identity(fields: [String]) -> String {
        let input = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var planKey: String { "mlx-windows-v1/" + identity }
    private func answerKey(_ window: Range<Int>) -> String {
        planKey + "/\(window.lowerBound)-\(window.upperBound)"
    }
    func answer(_ window: Range<Int>) -> String? { checkpoint.cache.get(answerKey(window)) }

    func plan(proposed: [Range<Int>], lineCount: Int,
              fits: (Range<Int>) -> Bool,
              split: (Range<Int>) -> [Range<Int>],
              isReusable: (String) -> Bool = { _ in true }) -> [Range<Int>] {
        let saved = checkpoint.cache.get(planKey).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([Range<Int>].self, from: $0) }
        let validBounds = saved?.allSatisfy { !$0.isEmpty && $0.lowerBound >= 0 && $0.upperBound <= lineCount } == true
        // A decodable but truncated plan must never turn unread lines into an
        // apparent ad-free result. It must cover the entire requested scope.
        let valid = validBounds && saved?.isEmpty == false
            && Set(saved!.flatMap { Array($0) }) == Set(proposed.flatMap { Array($0) })
        let windows = (valid ? saved! : proposed).flatMap { window in
            let cached = answer(window)
            return cached.map(isReusable) == true || fits(window) ? [window] : split(window)
        }
        if let data = try? JSONEncoder().encode(windows), let text = String(data: data, encoding: .utf8) {
            checkpoint.cache.set(planKey, text)
            checkpoint.save()
        }
        return windows
    }
    @discardableResult func store(_ answer: String, window: Range<Int>) -> Bool {
        checkpoint.cache.set(answerKey(window), answer)
        // A single window can cost minutes. Do not wait for eight replies.
        return checkpoint.save()
    }
}

/// Cancels and joins the operation when its interruption monitor throws.
/// Returning never leaves inference running in an unstructured task.
enum InterruptibleOperation {
    static func run<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value,
        monitor: @escaping @Sendable () async throws -> Void
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask { try await monitor(); throw CancellationError() }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return value
        }
    }
}

/// Registers synchronously, before inference starts, so a scene resignation
/// between task creation and the monitor's first await cannot be lost.
final class NotificationInterruption: @unchecked Sendable {
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let token: NSObjectProtocol
    private let center: NotificationCenter

    init(_ name: Notification.Name, center: NotificationCenter = .default) {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            pair.continuation.yield(())
        }
    }
    func finish() {
        center.removeObserver(token)
        continuation.finish()
    }
    deinit { finish() }
}
