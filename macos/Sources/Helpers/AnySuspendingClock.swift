import Foundation

/// A small, Sendable clock boundary for cancellable UI lifetimes and deterministic tests.
struct AnySuspendingClock: Sendable {
    private let sleepOperation: @Sendable (Duration) async throws -> Void

    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        sleepOperation = sleep
    }

    func sleep(for duration: Duration) async throws {
        try await sleepOperation(duration)
    }
}
