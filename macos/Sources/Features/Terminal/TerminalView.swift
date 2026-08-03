import AppKit
import Combine
import GhosttyKit
import SwiftUI

protocol TerminalViewDelegate: AnyObject {
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)
    func pwdDidChange(to: URL?)
    func cellSizeDidChange(to: NSSize)
    func performAction(_ action: String, on: Ghostty.SurfaceView)
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// Native terminal root. The command palette remains hosted temporarily while
/// that feature is migrated independently.
@MainActor
final class TerminalView: NSView {
    private let ghostty: Ghostty.App
    private weak var viewModel: BaseTerminalController?
    private weak var delegate: (any TerminalViewDelegate)?

    private var mainContent: NSView?
    private var splitTreeView: TerminalSplitTreeView?
    private var paletteView: NSView?
    private var updatePill: UpdatePillView?
    private var cancellables: Set<AnyCancellable> = []
    private var surfaceCancellables: Set<AnyCancellable> = []
    private var focusedSurfaceCancellables: Set<AnyCancellable> = []
    private weak var lastFocusedSurface: Ghostty.SurfaceView?

    init(
        ghostty: Ghostty.App,
        viewModel: BaseTerminalController,
        delegate: any TerminalViewDelegate
    ) {
        self.ghostty = ghostty
        self.viewModel = viewModel
        self.delegate = delegate
        super.init(frame: .zero)

        ghostty.$readiness
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.renderReadiness() }
            .store(in: &cancellables)

        viewModel.$surfaceTree
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tree in self?.surfaceTreeDidChange(tree) }
            .store(in: &cancellables)

        viewModel.$commandPaletteIsShowing
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshCommandPalette() }
            .store(in: &cancellables)

        viewModel.$updateOverlayIsVisible
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshUpdatePill() }
            .store(in: &cancellables)

        renderReadiness()
        surfaceTreeDidChange(viewModel.surfaceTree)
        focus(surface: viewModel.focusedSurface)
        refreshCommandPalette()
        refreshUpdatePill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        lastFocusedSurface?.initialSize ?? super.intrinsicContentSize
    }

    private func renderReadiness() {
        mainContent?.removeFromSuperview()
        splitTreeView = nil

        let content: NSView
        switch ghostty.readiness {
        case .loading:
            let label = NSTextField(labelWithString: String(localized: "Loading"))
            label.alignment = .center
            content = label

        case .error:
            content = ErrorView()

        case .ready:
            guard let viewModel else { return }
            let splitTree = TerminalSplitTreeView(
                ghostty: ghostty,
                tree: viewModel.surfaceTree,
                action: { [weak delegate] in delegate?.performSplitAction($0) }
            )
            splitTreeView = splitTree

            if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG ||
                Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                let warning = DebugBuildWarningView()
                let stack = NSStackView(views: [warning, splitTree])
                stack.orientation = .vertical
                stack.alignment = .width
                stack.spacing = 0
                warning.setContentHuggingPriority(.required, for: .vertical)
                content = stack
            } else {
                content = splitTree
            }
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content, positioned: .below, relativeTo: paletteView ?? updatePill)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        mainContent = content
    }

    private func surfaceTreeDidChange(_ tree: SplitTree<Ghostty.SurfaceView>) {
        splitTreeView?.update(tree: tree)
        observeSurfaces(in: tree)
        if let focused = viewModel?.focusedSurface, tree.contains(focused) {
            focus(surface: focused)
        } else if let lastFocusedSurface, !tree.contains(lastFocusedSurface) {
            focus(surface: tree.first)
        }
        invalidateIntrinsicContentSize()
    }

    private func observeSurfaces(in tree: SplitTree<Ghostty.SurfaceView>) {
        surfaceCancellables.removeAll()
        for surface in tree {
            surface.$focusInstant
                .dropFirst()
                .compactMap { $0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak surface] _ in
                    guard let self, let surface, surface.isFirstResponder else { return }
                    self.focus(surface: surface)
                }
                .store(in: &surfaceCancellables)
        }
    }

    private func focus(surface: Ghostty.SurfaceView?) {
        guard lastFocusedSurface !== surface else { return }
        lastFocusedSurface = surface
        delegate?.focusedSurfaceDidChange(to: surface)
        focusedSurfaceCancellables.removeAll()
        refreshCommandPalette()
        invalidateIntrinsicContentSize()

        guard let surface else {
            delegate?.pwdDidChange(to: nil)
            return
        }

        surface.$pwd
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                let url = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                self?.delegate?.pwdDidChange(to: url)
            }
            .store(in: &focusedSurfaceCancellables)

        surface.$cellSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in self?.delegate?.cellSizeDidChange(to: size) }
            .store(in: &focusedSurfaceCancellables)
    }

    private func refreshCommandPalette() {
        paletteView?.removeFromSuperview()
        paletteView = nil
        guard
            let viewModel,
            viewModel.commandPaletteIsShowing,
            let surface = lastFocusedSurface
        else { return }

        let binding = Binding<Bool>(
            get: { [weak viewModel] in viewModel?.commandPaletteIsShowing ?? false },
            set: { [weak viewModel] in viewModel?.commandPaletteIsShowing = $0 }
        )
        let root = TerminalCommandPaletteView(
            surfaceView: surface,
            isPresented: binding,
            ghosttyConfig: ghostty.config,
            updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel,
            onAction: { [weak delegate, weak surface] action in
                guard let surface else { return }
                delegate?.performAction(action, on: surface)
            }
        )
        let palette = NSHostingView(rootView: root)
        palette.translatesAutoresizingMaskIntoConstraints = false
        addSubview(palette, positioned: .above, relativeTo: mainContent)
        NSLayoutConstraint.activate([
            palette.leadingAnchor.constraint(equalTo: leadingAnchor),
            palette.trailingAnchor.constraint(equalTo: trailingAnchor),
            palette.topAnchor.constraint(equalTo: topAnchor),
            palette.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        paletteView = palette
    }

    private func refreshUpdatePill() {
        updatePill?.removeFromSuperview()
        updatePill = nil
        guard
            viewModel?.updateOverlayIsVisible == true,
            let appDelegate = NSApp.delegate as? AppDelegate
        else { return }

        let pill = UpdatePillView(model: appDelegate.updateViewModel)
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill, positioned: .above, relativeTo: paletteView ?? mainContent)
        NSLayoutConstraint.activate([
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        updatePill = pill
    }
}

@MainActor
private final class DebugBuildWarningView: NSControl {
    private weak var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let image = NSImageView(image: NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        ) ?? NSImage())
        image.contentTintColor = .systemYellow

        let text = NSTextField(labelWithString: String(
            localized: "You're running a debug build of Ghostty! Performance will be degraded."
        ))
        let row = NSStackView(views: [image, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Debug build warning"))
        setAccessibilityValue(String(localized: "Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development."))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        let text = NSTextField(wrappingLabelWithString: String(localized: "Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development."))
        text.preferredMaxLayoutWidth = 360
        let controller = NSViewController()
        controller.view = text
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
