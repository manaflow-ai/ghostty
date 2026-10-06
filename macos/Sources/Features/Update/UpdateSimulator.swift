import Foundation
import Sparkle

/// Simulates update scenarios for manually exercising the update UI.
@MainActor
enum UpdateSimulator {
    case happyPath
    case notFound
    case error
    case slowDownload
    case permissionRequest
    case cancelDuringDownload
    case cancelDuringChecking
    case installing
    case autoUpdate

    private static var activeRuns: [ObjectIdentifier: UpdateSimulationRun] = [:]

    func simulate(
        with viewModel: UpdateViewModel,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        let id = ObjectIdentifier(viewModel)
        Self.activeRuns[id]?.cancel()
        let run = UpdateSimulationRun(viewModel: viewModel, sleep: sleep) {
            Self.activeRuns[id] = nil
        }
        Self.activeRuns[id] = run
        run.start(self)
    }
}

@MainActor
private final class UpdateSimulationRun: UpdateViewModelObserver {
    private let viewModel: UpdateViewModel
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onFinish: () -> Void
    private var task: Task<Void, Never>?
    private var hasStarted = false

    init(
        viewModel: UpdateViewModel,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.sleep = sleep
        self.onFinish = onFinish
        viewModel.addObserver(self)
    }

    func start(_ scenario: UpdateSimulator) {
        hasStarted = true
        replaceTask { [self] in
            switch scenario {
            case .happyPath: await showAvailable(slow: false)
            case .notFound: await showNotFound()
            case .error: await showError()
            case .slowDownload: await showAvailable(slow: true)
            case .permissionRequest: showPermissionRequest()
            case .cancelDuringDownload: await showCancelDuringDownload()
            case .cancelDuringChecking: await showCancelDuringChecking()
            case .installing: showInstalling()
            case .autoUpdate: showInstalling(isAutoUpdate: true)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if !viewModel.state.isIdle {
            viewModel.state = .idle
        }
    }

    func updateViewModelDidChange(_ model: UpdateViewModel) {
        guard hasStarted, model.state.isIdle else { return }
        task?.cancel()
        task = nil
        onFinish()
    }

    private func replaceTask(_ operation: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { @MainActor [self] in
            await operation()
            if Task.isCancelled { return }
            task = nil
        }
    }

    private func wait(for duration: Duration) async -> Bool {
        do {
            try await sleep(duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func beginChecking() {
        viewModel.state = .checking(.init(cancel: { [self] in cancel() }))
    }

    private func showAvailable(slow: Bool) async {
        beginChecking()
        guard await wait(for: .seconds(2)) else { return }
        viewModel.state = .updateAvailable(.init(
            appcastItem: SUAppcastItem.empty(),
            reply: { [self] choice in
                guard choice == .install else {
                    viewModel.state = .idle
                    return
                }
                replaceTask { [self] in
                    await showDownload(stepCount: slow ? 20 : 10, stepDuration: slow ? .milliseconds(500) : .milliseconds(300))
                }
            }
        ))
    }

    private func showNotFound() async {
        beginChecking()
        guard await wait(for: .seconds(2)) else { return }
        viewModel.state = .notFound(.init(acknowledgement: {}))
    }

    private func showError() async {
        beginChecking()
        guard await wait(for: .seconds(2)) else { return }
        viewModel.state = .error(.init(
            error: NSError(domain: "UpdateError", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to check for updates"
            ]),
            retry: { [self] in
                replaceTask { [self] in await showAvailable(slow: false) }
            },
            dismiss: { [self] in viewModel.state = .idle }
        ))
    }

    private func showPermissionRequest() {
        let request = SPUUpdatePermissionRequest(systemProfile: [])
        viewModel.state = .permissionRequest(.init(
            request: request,
            reply: { [self] response in
                guard response.automaticUpdateChecks else {
                    viewModel.state = .idle
                    return
                }
                replaceTask { [self] in await showAvailable(slow: false) }
            }
        ))
    }

    private func showCancelDuringDownload() async {
        beginChecking()
        guard await wait(for: .seconds(2)) else { return }
        viewModel.state = .updateAvailable(.init(
            appcastItem: SUAppcastItem.empty(),
            reply: { [self] choice in
                guard choice == .install else {
                    viewModel.state = .idle
                    return
                }
                replaceTask { [self] in await showDownloadThenCancel() }
            }
        ))
    }

    private func showCancelDuringChecking() async {
        beginChecking()
        guard await wait(for: .seconds(1)) else { return }
        viewModel.state = .idle
    }

    private func showDownload(stepCount: Int, stepDuration: Duration) async {
        let cancel: @MainActor () -> Void = { [self] in self.cancel() }
        viewModel.state = .downloading(.init(cancel: cancel, expectedLength: nil, progress: 0))
        for step in 1...stepCount {
            guard await wait(for: stepDuration) else { return }
            viewModel.state = .downloading(.init(
                cancel: cancel,
                expectedLength: UInt64(stepCount * 100),
                progress: UInt64(step * 100)
            ))
        }
        guard await wait(for: .milliseconds(500)) else { return }
        await showExtracting()
    }

    private func showDownloadThenCancel() async {
        let cancel: @MainActor () -> Void = { [self] in self.cancel() }
        viewModel.state = .downloading(.init(cancel: cancel, expectedLength: nil, progress: 0))
        for step in 1...5 {
            guard await wait(for: .milliseconds(300)) else { return }
            viewModel.state = .downloading(.init(
                cancel: cancel,
                expectedLength: 1_000,
                progress: UInt64(step * 100)
            ))
        }
        guard await wait(for: .milliseconds(500)) else { return }
        viewModel.state = .idle
    }

    private func showExtracting() async {
        viewModel.state = .extracting(.init(progress: 0))
        for step in 1...5 {
            guard await wait(for: .milliseconds(300)) else { return }
            viewModel.state = .extracting(.init(progress: Double(step) / 5))
        }
        guard await wait(for: .milliseconds(500)) else { return }
        showInstalling()
    }

    private func showInstalling(isAutoUpdate: Bool = false) {
        viewModel.state = .installing(.init(
            isAutoUpdate: isAutoUpdate,
            retryTerminatingApplication: { [self] in viewModel.state = .idle },
            dismiss: { [self] in viewModel.state = .idle }
        ))
    }
}
