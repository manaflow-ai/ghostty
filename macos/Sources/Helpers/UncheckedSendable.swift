/// A narrow bridge for values supplied by legacy Objective-C APIs whose
/// imported declarations lack `Sendable` annotations.
///
/// Callers must provide the synchronization or actor boundary that makes each
/// use safe. Prefer a native `Sendable` value whenever the API permits one.
nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// Weak counterpart used by legacy callback APIs with `@Sendable` handlers.
nonisolated final class UncheckedWeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}
