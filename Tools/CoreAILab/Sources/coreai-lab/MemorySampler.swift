import Darwin
import Foundation
import Metal

/// Pass 54 lab: the process's physical footprint (what iOS's memory limit
/// counts) and the Metal device's allocation, every 10 ms, beside the last
/// mark the reader set — to see what a Core AI read does to memory part by
/// part and step by step.
final class MemorySampler: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var marker = "load"
    private var running = false
    private var lines: [String] = []
    private let device = MTLCreateSystemDefaultDevice()
    private let started = Date()

    init(path: String) { self.path = path }

    func mark(_ text: String) {
        lock.lock(); marker = text; lock.unlock()
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func start() {
        running = true
        let thread = Thread { [self] in
            while true {
                lock.lock()
                let go = running, mark = marker
                lock.unlock()
                if !go { break }
                let line = String(format: "%.3f\t%d\t%d\t%@", Date().timeIntervalSince(started),
                                  Self.footprint() / 1_048_576, (device?.currentAllocatedSize ?? 0) / 1_048_576, mark)
                lock.lock(); lines.append(line); lock.unlock()
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        thread.start()
    }

    func stop() {
        lock.lock(); running = false; let out = lines.joined(separator: "\n"); lock.unlock()
        try? (out + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
