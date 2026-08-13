import Dispatch
import Foundation

enum MacMemoryPressureLevel: String, Codable, Sendable {
    case normal
    case warning
    case critical
}

struct MacMemoryPressureTransition: Codable, Equatable, Sendable {
    let level: MacMemoryPressureLevel
    let at: Date
}

final class MacMemoryPressureMonitor: @unchecked Sendable {
    static let shared = MacMemoryPressureMonitor()

    private let lock = NSLock()
    private var current = MacMemoryPressureLevel.normal
    private var history: [MacMemoryPressureTransition] = []
    private var source: (any DispatchSourceMemoryPressure)?

    init(native: Bool = true) {
        guard native else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "WhisperASR.memory-pressure")
        )
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self, let data = self.source?.data else { return }
            if data.contains(.critical) {
                self.record(.critical)
            } else if data.contains(.warning) {
                self.record(.warning)
            } else {
                self.record(.normal)
            }
        }
        source.resume()
    }

    deinit {
        source?.cancel()
    }

    var level: MacMemoryPressureLevel {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func record(_ level: MacMemoryPressureLevel, at: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard level != current else { return }
        current = level
        history.append(.init(level: level, at: at))
    }

    func transitions(since date: Date) -> [MacMemoryPressureTransition] {
        lock.lock()
        defer { lock.unlock() }
        return history.filter { $0.at >= date }
    }
}
