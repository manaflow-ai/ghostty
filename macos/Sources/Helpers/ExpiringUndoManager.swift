/// An UndoManager subclass that supports registering undo operations that automatically expire after a specified duration.
///
/// This class extends the standard UndoManager to add time-based expiration for undo operations.
/// When an undo operation expires, it is automatically removed from the undo stack and cannot be invoked.
///
/// Example usage:
/// ```swift
/// let undoManager = ExpiringUndoManager()
/// undoManager.registerUndo(withTarget: myObject, expiresAfter: .seconds(30)) { target in
///     // Undo operation that expires after 30 seconds
///     target.restorePreviousState()
/// }
/// ```
@MainActor
class ExpiringUndoManager: UndoManager {
    typealias Sleep = @Sendable (Duration) async throws -> Void
    var sleep: Sleep = { duration in
        try await ContinuousClock().sleep(for: duration)
    }

    /// The set of expiring targets so we can properly clean them up when removeAllActions
    /// is called with the real target.
    private lazy var expiringTargets: [ObjectIdentifier: ExpiringTarget] = [:]

    /// Registers an undo operation that automatically expires after the specified duration.
    ///
    /// - Parameters:
    ///   - target: The target object for the undo operation. The undo operation will be removed
    ///             if this object is deallocated before the operation is invoked.
    ///   - duration: The duration after which the undo operation should expire and be removed from the undo stack.
    ///   - handler: The closure to execute when the undo operation is invoked. The closure receives
    ///              the target object as its parameter.
    func registerUndo<TargetType: AnyObject>(
        withTarget target: TargetType,
        expiresAfter duration: Duration,
        handler: @escaping (TargetType) -> Void
    ) {
        // Ignore instantly expiring undos
        guard duration.timeInterval > 0 else { return }

        // Ignore when undo registration is disabled. UndoManager still lets
        // registration happen then cancels later but I was seeing some
        // weird behavior with this so let's just guard on it.
        guard self.isUndoRegistrationEnabled else { return }

        let expiringTarget = ExpiringTarget(
            target,
            expiresAfter: duration,
            in: self,
            sleep: sleep)
        expiringTargets[ObjectIdentifier(expiringTarget)] = expiringTarget

        super.registerUndo(withTarget: expiringTarget) { [weak self] expiringTarget in
            self?.expiringTargets.removeValue(forKey: ObjectIdentifier(expiringTarget))
            guard let target = expiringTarget.target as? TargetType else { return }
            handler(target)
        }
    }

    /// Removes all undo and redo operations from the undo manager.
    ///
    /// This override ensures that all expiring targets are also cleared when
    /// the undo manager is reset.
    override func removeAllActions() {
        super.removeAllActions()
        expiringTargets = [:]
    }

    /// Removes all undo and redo operations involving the specified target.
    ///
    /// This override ensures that when actions are removed for a target, any associated
    /// expiring targets are also properly cleaned up.
    ///
    /// - Parameter target: The target object whose actions should be removed.
    override func removeAllActions(withTarget target: Any) {
        // Call super to handle standard removal
        super.removeAllActions(withTarget: target)

        // If the target is an expiring target, remove it.
        if let expiring = target as? ExpiringTarget {
            expiringTargets.removeValue(forKey: ObjectIdentifier(expiring))
        } else {
            // Find and remove any ExpiringTarget instances that wrap this target.
            expiringTargets.values
                .filter { $0.target == nil || $0.target === (target as AnyObject) }
                .forEach {
                    // Technically they'll always expire when they get deinitialized
                    // but we want to make sure it happens right now.
                    $0.expire()
                    expiringTargets.removeValue(forKey: ObjectIdentifier($0))
                }
        }
    }
}

/// A target object for ExpiringUndoManager that removes itself from the
/// undo manager after it expires.
///
/// This class acts as a proxy for the real target object in undo operations.
/// It holds a weak reference to the actual target and automatically removes
/// all associated undo operations when either:
/// - The specified duration expires
/// - The ExpiringTarget instance is deallocated
/// - The expire() method is called manually
@MainActor
private final class ExpiringTarget {
    /// The actual target object for the undo operation, held weakly to avoid retain cycles.
    private(set) weak var target: AnyObject?

    /// Cancellable task that triggers expiration after the specified duration.
    private var expiryTask: Task<Void, Never>?

    /// The undo manager from which to remove actions when this target expires.
    private weak var undoManager: UndoManager?

    /// Creates an expiring target that will automatically remove undo actions after the specified duration.
    ///
    /// - Parameters:
    ///   - target: The target object to hold weakly.
    ///   - duration: The time after which the target should expire.
    ///   - undoManager: The UndoManager from which to remove actions when expired.
    init(
        _ target: AnyObject? = nil,
        expiresAfter duration: Duration,
        in undoManager: UndoManager,
        sleep: @escaping ExpiringUndoManager.Sleep
    ) {
        self.target = target
        self.undoManager = undoManager
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            expire()
        }
    }

    /// Manually expires the target, removing all associated undo actions and cancelling the task.
    ///
    /// This method is called automatically when the expiry task completes, but can also be called
    /// manually before the duration has elapsed.
    func expire() {
        target = nil
        undoManager?.removeAllActions(withTarget: self)
        expiryTask?.cancel()
        expiryTask = nil
    }

    isolated deinit {
        expiryTask?.cancel()
        target = nil
    }
}
