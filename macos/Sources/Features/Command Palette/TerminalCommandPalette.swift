import AppKit
import Combine
import GhosttyKit

/// Full-window overlay that positions and owns the native command palette.
@MainActor
final class TerminalCommandPaletteView: NSView, UpdateViewModelObserver {
    private let surfaceView: Ghostty.SurfaceView
    private weak var viewModel: BaseTerminalController?
    private let ghostty: Ghostty.App
    private let updateViewModel: UpdateViewModel?
    private let onAction: (String) -> Void
    private let palette: CommandPaletteView
    private var cancellables: Set<AnyCancellable> = []

    init(
        surfaceView: Ghostty.SurfaceView,
        viewModel: BaseTerminalController,
        ghostty: Ghostty.App,
        updateViewModel: UpdateViewModel?,
        onAction: @escaping (String) -> Void
    ) {
        self.surfaceView = surfaceView
        self.viewModel = viewModel
        self.ghostty = ghostty
        self.updateViewModel = updateViewModel
        self.onAction = onAction
        self.palette = CommandPaletteView(
            backgroundColor: ghostty.config.backgroundColor,
            options: [],
            onDismiss: { [weak viewModel, weak surfaceView] in
                viewModel?.commandPaletteIsShowing = false
                if let surfaceView { surfaceView.window?.makeFirstResponder(surfaceView) }
            }
        )
        super.init(frame: .zero)

        addSubview(palette)
        palette.options = commandOptions
        updateViewModel?.addObserver(self)

        ghostty.$config
            .dropFirst()
            .sink { [weak self] _ in self?.palette.options = self?.commandOptions ?? [] }
            .store(in: &cancellables)

        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let size = palette.intrinsicContentSize
        let width = min(size.width, max(0, bounds.width - 32))
        let height = min(size.height, max(0, bounds.height - 32))
        let topMargin = bounds.height * 0.05 + 16
        palette.frame = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.maxY - topMargin - height,
            width: width,
            height: height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard palette.frame.contains(point) else {
            viewModel?.commandPaletteIsShowing = false
            surfaceView.window?.makeFirstResponder(surfaceView)
            return nil
        }
        return super.hitTest(point)
    }

    func updateViewModelDidChange(_ model: UpdateViewModel) {
        palette.options = commandOptions
    }

    private var commandOptions: [CommandOption] {
        var options = updateOptions
        options.append(contentsOf: (jumpOptions + terminalOptions).sorted { first, second in
            let firstTitle = first.title.replacingOccurrences(of: ":", with: "\t")
            let secondTitle = second.title.replacingOccurrences(of: ":", with: "\t")
            let comparison = firstTitle.localizedCaseInsensitiveCompare(secondTitle)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if let firstKey = first.sortKey, let secondKey = second.sortKey {
                return firstKey < secondKey
            }
            return false
        })
        return options
    }

    private var updateOptions: [CommandOption] {
        guard let updateViewModel, updateViewModel.state.isInstallable else { return [] }
        let title = if case .updateAvailable = updateViewModel.state {
            String(localized: "Update Ghostty and Restart")
        } else {
            updateViewModel.text
        }
        return [
            CommandOption(
                title: title,
                description: updateViewModel.description,
                leadingIcon: updateViewModel.iconName ?? "shippingbox.fill",
                badge: updateViewModel.badge,
                emphasis: true
            ) {
                (NSApp.delegate as? AppDelegate)?.updateController.installUpdate()
            },
            CommandOption(
                title: String(localized: "Cancel or Skip Update"),
                description: String(localized: "Dismiss the current update process")
            ) {
                updateViewModel.state.cancel()
            },
        ]
    }

    private var terminalOptions: [CommandOption] {
        ghostty.config.commandPaletteEntries
            .filter(\.isSupported)
            .map { entry in
                CommandOption(
                    title: entry.title,
                    description: entry.description,
                    symbols: ghostty.config.keyboardShortcut(for: entry.action)?.keyList
                ) { [onAction] in
                    onAction(entry.action)
                }
            }
    }

    private var jumpOptions: [CommandOption] {
        TerminalController.all.flatMap { controller -> [CommandOption] in
            guard let window = controller.window else { return [] }
            let color = (window as? TerminalWindow)?.tabColor
            let displayColor: NSColor? = if let color, color != TerminalTabColor.none {
                color.displayColor
            } else {
                nil
            }

            return controller.surfaceTree.map { surface in
                let terminalTitle = surface.title.isEmpty ? window.title : surface.title
                let displayTitle: String
                if let override = controller.titleOverride, !override.isEmpty {
                    displayTitle = override
                } else if !terminalTitle.isEmpty {
                    displayTitle = terminalTitle
                } else {
                    displayTitle = String(localized: "Untitled")
                }
                let pwd = surface.pwd?.abbreviatedPath
                let subtitle: String? = if let pwd, !displayTitle.contains(pwd) { pwd } else { nil }

                return CommandOption(
                    title: String(localized: "Focus: \(displayTitle)"),
                    subtitle: subtitle,
                    leadingIcon: "rectangle.on.rectangle",
                    leadingColor: displayColor,
                    sortKey: AnySortKey(ObjectIdentifier(surface))
                ) {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyPresentTerminal,
                        object: surface
                    )
                }
            }
        }
    }
}
