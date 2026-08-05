import AppKit
import Sparkle

@MainActor
protocol UpdateViewModelObserver: AnyObject {
    func updateViewModelDidChange(_ model: UpdateViewModel)
}

@MainActor
final class UpdateViewModel {
    var state: UpdateState = .idle {
        didSet {
            guard state != oldValue else { return }
            scheduleNotFoundDismissal()
            notifyObservers()
        }
    }

    private let observers = NSHashTable<AnyObject>.weakObjects()
    private let sleep: @Sendable (Duration) async throws -> Void
    private var notFoundDismissalTask: Task<Void, Never>?

    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.sleep = sleep
    }

    deinit {
        notFoundDismissalTask?.cancel()
    }

    func addObserver(_ observer: any UpdateViewModelObserver) {
        observers.add(observer)
        observer.updateViewModelDidChange(self)
    }

    func removeObserver(_ observer: any UpdateViewModelObserver) {
        observers.remove(observer)
    }

    private func notifyObservers() {
        for case let observer as UpdateViewModelObserver in observers.allObjects {
            observer.updateViewModelDidChange(self)
        }
    }

    private func scheduleNotFoundDismissal() {
        notFoundDismissalTask?.cancel()
        notFoundDismissalTask = nil
        guard case .notFound(let notFound) = state else { return }

        let sleep = sleep
        notFoundDismissalTask = Task { @MainActor [weak self] in
            do {
                try await sleep(.seconds(5))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, case .notFound = state else { return }
            state = .idle
            notFound.acknowledgement()
        }
    }

    /// The text to display for the current update state.
    var text: String {
        switch state {
        case .idle:
            return ""
        case .permissionRequest:
            return String(localized: "Enable Automatic Updates?")
        case .checking:
            return String(localized: "Checking for Updates…")
        case .updateAvailable(let update):
            let version = update.appcastItem.displayVersionString
            if !version.isEmpty {
                return String(localized: "Update Available: \(version)")
            }
            return String(localized: "Update Available")
        case .downloading(let download):
            if let expectedLength = download.expectedLength, expectedLength > 0 {
                let progress = Double(download.progress) / Double(expectedLength)
                return String(format: String(localized: "Downloading: %.0f%%"), progress * 100)
            }
            return String(localized: "Downloading…")
        case .extracting(let extracting):
            return String(format: String(localized: "Preparing: %.0f%%"), extracting.progress * 100)
        case .installing(let install):
            return install.isAutoUpdate
                ? String(localized: "Restart to Complete Update")
                : String(localized: "Installing…")
        case .notFound:
            return String(localized: "No Updates Available")
        case .error(let error):
            return error.error.localizedDescription
        }
    }

    var maxWidthText: String {
        switch state {
        case .downloading:
            return String(localized: "Downloading: 100%")
        case .extracting:
            return String(localized: "Preparing: 100%")
        default:
            return text
        }
    }

    var iconName: String? {
        switch state {
        case .idle: return nil
        case .permissionRequest: return "questionmark.circle"
        case .checking: return "arrow.triangle.2.circlepath"
        case .updateAvailable: return "shippingbox.fill"
        case .downloading: return "arrow.down.circle"
        case .extracting: return "shippingbox"
        case .installing: return "power.circle"
        case .notFound: return "info.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var description: String {
        switch state {
        case .idle:
            return ""
        case .permissionRequest:
            return String(localized: "Configure automatic update preferences")
        case .checking:
            return String(localized: "Please wait while we check for available updates")
        case .updateAvailable(let update):
            return update.releaseNotes?.label
                ?? String(localized: "Download and install the latest version")
        case .downloading:
            return String(localized: "Downloading the update package")
        case .extracting:
            return String(localized: "Extracting and preparing the update")
        case .installing(let install):
            return install.isAutoUpdate
                ? String(localized: "Restart to Complete Update")
                : String(localized: "Installing update and preparing to restart")
        case .notFound:
            return String(localized: "You are running the latest version")
        case .error:
            return String(localized: "An error occurred during the update process")
        }
    }

    var badge: String? {
        switch state {
        case .updateAvailable(let update):
            let version = update.appcastItem.displayVersionString
            return version.isEmpty ? nil : version
        case .downloading(let download):
            guard let expectedLength = download.expectedLength, expectedLength > 0 else { return nil }
            let percentage = Double(download.progress) / Double(expectedLength) * 100
            return String(format: "%.0f%%", percentage)
        case .extracting(let extracting):
            return String(format: "%.0f%%", extracting.progress * 100)
        default:
            return nil
        }
    }

    var iconColor: NSColor {
        switch state {
        case .permissionRequest: return .white
        case .updateAvailable: return .controlAccentColor
        case .error: return .systemOrange
        default: return .secondaryLabelColor
        }
    }

    var backgroundColor: NSColor {
        switch state {
        case .permissionRequest:
            return NSColor.systemBlue.blended(withFraction: 0.3, of: .black) ?? .systemBlue
        case .updateAvailable:
            return .controlAccentColor
        case .notFound:
            return NSColor.systemBlue.blended(withFraction: 0.5, of: .black) ?? .systemBlue
        case .error:
            return NSColor.systemOrange.withAlphaComponent(0.2)
        default:
            return .controlBackgroundColor
        }
    }

    var foregroundColor: NSColor {
        switch state {
        case .permissionRequest, .updateAvailable, .notFound: return .white
        case .error: return .systemOrange
        default: return .labelColor
        }
    }
}

enum UpdateState: Equatable {
    case idle
    case permissionRequest(PermissionRequest)
    case checking(Checking)
    case updateAvailable(UpdateAvailable)
    case notFound(NotFound)
    case error(Error)
    case downloading(Downloading)
    case extracting(Extracting)
    case installing(Installing)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var isInstallable: Bool {
        switch self {
        case .checking, .updateAvailable, .downloading, .extracting, .installing:
            return true
        default:
            return false
        }
    }

    @MainActor
    func cancel() {
        switch self {
        case .checking(let checking): checking.cancel()
        case .updateAvailable(let available): available.reply(.dismiss)
        case .downloading(let downloading): downloading.cancel()
        case .notFound(let notFound): notFound.acknowledgement()
        case .error(let error): error.dismiss()
        default: break
        }
    }

    @MainActor
    func confirm() {
        if case .updateAvailable(let available) = self {
            available.reply(.install)
        }
    }

    static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.permissionRequest, .permissionRequest),
             (.checking, .checking), (.notFound, .notFound):
            return true
        case (.updateAvailable(let lhs), .updateAvailable(let rhs)):
            return lhs.appcastItem.displayVersionString == rhs.appcastItem.displayVersionString
        case (.error(let lhs), .error(let rhs)):
            return lhs.error.localizedDescription == rhs.error.localizedDescription
        case (.downloading(let lhs), .downloading(let rhs)):
            return lhs.progress == rhs.progress && lhs.expectedLength == rhs.expectedLength
        case (.extracting(let lhs), .extracting(let rhs)):
            return lhs.progress == rhs.progress
        case (.installing(let lhs), .installing(let rhs)):
            return lhs.isAutoUpdate == rhs.isAutoUpdate
        default:
            return false
        }
    }

    struct NotFound {
        let acknowledgement: @MainActor () -> Void
    }

    struct PermissionRequest {
        let request: SPUUpdatePermissionRequest
        let reply: @MainActor (SUUpdatePermissionResponse) -> Void
    }

    struct Checking {
        let cancel: @MainActor () -> Void
    }

    struct UpdateAvailable {
        let appcastItem: SUAppcastItem
        let reply: @MainActor (SPUUserUpdateChoice) -> Void

        var releaseNotes: ReleaseNotes? {
            let currentCommit = Bundle.main.infoDictionary?["GhosttyCommit"] as? String
            return ReleaseNotes(
                displayVersionString: appcastItem.displayVersionString,
                currentCommit: currentCommit
            )
        }
    }

    enum ReleaseNotes {
        case commit(URL)
        case compareTip(URL)
        case tagged(URL)

        init?(displayVersionString: String, currentCommit: String?) {
            if let semver = Self.extractSemanticVersion(from: displayVersionString) {
                let slug = semver.replacingOccurrences(of: ".", with: "-")
                guard let url = URL(
                    string: "https://ghostty.org/docs/install/release-notes/\(slug)"
                ) else { return nil }
                self = .tagged(url)
                return
            }

            guard let newHash = Self.extractGitHash(from: displayVersionString) else { return nil }
            if let currentCommit, !currentCommit.isEmpty,
               let url = URL(
                   string: "https://github.com/ghostty-org/ghostty/compare/\(currentCommit)...\(newHash)"
               ) {
                self = .compareTip(url)
            } else if let url = URL(
                string: "https://github.com/ghostty-org/ghostty/commit/\(newHash)"
            ) {
                self = .commit(url)
            } else {
                return nil
            }
        }

        private static func extractSemanticVersion(from version: String) -> String? {
            version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) == nil
                ? nil
                : version
        }

        private static func extractGitHash(from version: String) -> String? {
            guard let range = version.range(of: #"[0-9a-f]{7,40}"#, options: .regularExpression)
            else { return nil }
            return String(version[range])
        }

        var url: URL {
            switch self {
            case .commit(let url), .compareTip(let url), .tagged(let url): return url
            }
        }

        var label: String {
            switch self {
            case .commit: return String(localized: "View GitHub Commit")
            case .compareTip: return String(localized: "Changes Since This Tip Release")
            case .tagged: return String(localized: "View Release Notes")
            }
        }
    }

    struct Error {
        let error: any Swift.Error
        let retry: @MainActor () -> Void
        let dismiss: @MainActor () -> Void
    }

    struct Downloading {
        let cancel: @MainActor () -> Void
        let expectedLength: UInt64?
        let progress: UInt64
    }

    struct Extracting {
        let progress: Double
    }

    struct Installing {
        var isAutoUpdate = false
        let retryTerminatingApplication: @MainActor () -> Void
        let dismiss: @MainActor () -> Void
    }
}
