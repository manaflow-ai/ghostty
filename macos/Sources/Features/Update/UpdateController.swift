import Sparkle
import Cocoa

/// Standard controller for managing Sparkle updates in Ghostty.
///
/// This controller wraps SPUStandardUpdaterController to provide a simpler interface
/// for managing updates with Ghostty's custom driver and delegate. It handles
/// initialization, starting the updater, and provides the check for updates action.
@MainActor
final class UpdateController: UpdateViewModelObserver {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver
    private var forceInstalling = false
    private var delayedCheckTask: Task<Void, Never>?
    private let sleep: @Sendable (Duration) async throws -> Void

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    /// True if we're installing an update.
    var isInstalling: Bool {
        forceInstalling
    }

    /// Initialize a new update controller.
    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.sleep = sleep
        let hostBundle = Bundle.main
        self.userDriver = UpdateDriver(
            viewModel: .init(),
            hostBundle: hostBundle)
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: userDriver
        )
        userDriver.viewModel.addObserver(self)
    }

    deinit {
        delayedCheckTask?.cancel()
    }

    /// Start the updater.
    ///
    /// This must be called before the updater can check for updates. If starting fails,
    /// the error will be shown to the user.
    func startUpdater() {
        do {
            try updater.start()
        } catch {
            userDriver.viewModel.state = .error(.init(
                error: error,
                retry: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                    self?.startUpdater()
                },
                dismiss: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                }
            ))
        }
    }

    /// Force install the current update. As long as we're in some "update available" state this will
    /// trigger all the steps necessary to complete the update.
    func installUpdate() {
        // Must be in an installable state
        guard viewModel.state.isInstallable else { return }

        // If we're already force installing then do nothing.
        guard !forceInstalling else { return }
        forceInstalling = true
        continueForcedInstallation(for: viewModel.state)
    }

    func updateViewModelDidChange(_ model: UpdateViewModel) {
        guard forceInstalling else { return }
        continueForcedInstallation(for: model.state)
    }

    private func continueForcedInstallation(for state: UpdateState) {
        guard state.isInstallable else {
            forceInstalling = false
            return
        }
        state.confirm()
    }

    /// Check for updates.
    ///
    /// This is typically connected to a menu item action.
    @objc func checkForUpdates() {
        // If we're already idle, then just check for updates immediately.
        if viewModel.state == .idle {
            updater.checkForUpdates()
            return
        }

        // If we're not idle then we need to cancel any prior state.
        forceInstalling = false
        viewModel.state.cancel()

        // Sparkle settles cancellation asynchronously. Keep the bounded delay
        // cancellable and injectable so controller teardown and tests can stop it.
        delayedCheckTask?.cancel()
        let sleep = sleep
        delayedCheckTask = Task { @MainActor [weak self] in
            do {
                try await sleep(.milliseconds(100))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            updater.checkForUpdates()
            delayedCheckTask = nil
        }
    }

    /// Validate the check for updates menu item.
    ///
    /// - Parameter item: The menu item to validate
    /// - Returns: Whether the menu item should be enabled
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) {
            return updater.canCheckForUpdates
        }
        return true
    }
}
