#if canImport(AppKit)
import AppKit
import Combine

extension Ghostty {
    /// Native AppKit composition root for a terminal surface and all pane overlays.
    @MainActor
    final class SurfaceContainerView: NSView {
        private let ghostty: Ghostty.App
        private let surfaceView: SurfaceView
        private let isSplit: Bool
        private let scrollView: SurfaceScrollView

        private let resizeOverlay: NativeSurfaceResizeOverlay
        private let secureInputOverlay = SecureInputOverlay()
        private let bellBorder = SurfaceBorderOverlay()
        private let highlightOverlay = SurfaceHighlightOverlay()
        private let dimOverlay = PassthroughColorView()
        private let readonlyBadge: SurfaceReadonlyBadge
        private let keyStateIndicator = SurfaceKeyStateIndicator()
        private let grabHandle: SurfaceGrabHandle

        private var progressBar: SurfaceProgressBar?
        private var urlBanner: URLHoverBanner?
        private var childExitedBar: ChildExitedMessageBar?
        private var searchOverlay: NativeSurfaceSearchOverlay?
        private var failureView: SurfaceFailureView?
        private var cancellables: Set<AnyCancellable> = []
        private var windowObservers: [NSObjectProtocol] = []

        init(ghostty: Ghostty.App, surfaceView: SurfaceView, isSplit: Bool) {
            self.ghostty = ghostty
            self.surfaceView = surfaceView
            self.isSplit = isSplit
            self.scrollView = SurfaceScrollView(contentSize: surfaceView.frame.size, surfaceView: surfaceView)
            self.resizeOverlay = NativeSurfaceResizeOverlay(surfaceView: surfaceView)
            self.readonlyBadge = SurfaceReadonlyBadge(surfaceView: surfaceView)
            self.grabHandle = SurfaceGrabHandle(surfaceView: surfaceView)
            super.init(frame: .zero)

            addSubview(scrollView)
            addSubview(resizeOverlay)
            addSubview(secureInputOverlay)
            addSubview(bellBorder)
            addSubview(highlightOverlay)
            addSubview(dimOverlay)
            addSubview(readonlyBadge)
            addSubview(keyStateIndicator)
            addSubview(grabHandle)

            dimOverlay.isHidden = true
            secureInputOverlay.isHidden = true
            readonlyBadge.isHidden = true
            keyStateIndicator.isHidden = true
            setAccessibilityElement(false)

            observeState()
            refreshAll()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        isolated deinit {
            windowObservers.forEach(NotificationCenter.default.removeObserver)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshFocusState()
        }

        override func layout() {
            super.layout()
            scrollView.frame = bounds
            resizeOverlay.frame = bounds
            bellBorder.frame = bounds
            highlightOverlay.frame = bounds
            dimOverlay.frame = bounds
            failureView?.frame = bounds
            grabHandle.frame = bounds

            progressBar?.frame = CGRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2)

            var bottom: CGFloat = 0
            if let childExitedBar {
                let height = min(max(childExitedBar.fittingSize.height, 24), max(24, bounds.height))
                childExitedBar.frame = CGRect(x: 0, y: bottom, width: bounds.width, height: height)
                bottom += height
            }
            if let urlBanner {
                let height = min(urlBanner.intrinsicContentSize.height, max(0, bounds.height - bottom))
                urlBanner.frame = CGRect(x: 0, y: bottom, width: bounds.width, height: height)
            }

            let secureSize = secureInputOverlay.intrinsicContentSize
            secureInputOverlay.frame = CGRect(
                x: bounds.maxX - secureSize.width - 10,
                y: bounds.maxY - secureSize.height - 10,
                width: secureSize.width,
                height: secureSize.height
            )

            let readonlySize = readonlyBadge.fittingSize
            readonlyBadge.frame = CGRect(
                x: bounds.maxX - readonlySize.width - 8,
                y: bounds.maxY - readonlySize.height - 8,
                width: readonlySize.width,
                height: readonlySize.height
            )

            keyStateIndicator.position(in: bounds)
            searchOverlay?.position(in: bounds)
            resizeOverlay.updateContainerSize(bounds.size)
            grabHandle.refresh()
        }

        private func observeState() {
            surfaceView.$progressReport
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.updateProgress($0) }
                .store(in: &cancellables)
            surfaceView.$hoverUrl
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.updateURL($0) }
                .store(in: &cancellables)
            surfaceView.$childExitedMessage
                .combineLatest(surfaceView.$cellSize)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.updateChildExited($0, cellSize: $1) }
                .store(in: &cancellables)
            surfaceView.$searchState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.updateSearch($0) }
                .store(in: &cancellables)
            surfaceView.$bell
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.bellBorder.isActive = $0 }
                .store(in: &cancellables)
            surfaceView.$highlighted
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.highlightOverlay.isActive = $0 }
                .store(in: &cancellables)
            surfaceView.$healthy
                .combineLatest(surfaceView.$error)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.updateFailure(healthy: $0, error: $1) }
                .store(in: &cancellables)
            surfaceView.$readonly
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.readonlyBadge.isHidden = !$0 }
                .store(in: &cancellables)
            surfaceView.$keyTables
                .combineLatest(surfaceView.$keySequence)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] tables, sequence in
                    self?.keyStateIndicator.update(keyTables: tables, keySequence: sequence)
                    self?.needsLayout = true
                }
                .store(in: &cancellables)
            surfaceView.$focusInstant
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshFocusState() }
                .store(in: &cancellables)
            surfaceView.$surfaceSize
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.resizeOverlay.updateSurfaceSize($0) }
                .store(in: &cancellables)
            ghostty.$config
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshConfiguration() }
                .store(in: &cancellables)
            SecureInput.shared.$enabled
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshFocusState() }
                .store(in: &cancellables)

            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(center.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refreshFocusState() }
                })
            }
        }

        private func refreshAll() {
            updateProgress(surfaceView.progressReport)
            updateURL(surfaceView.hoverUrl)
            updateChildExited(surfaceView.childExitedMessage, cellSize: surfaceView.cellSize)
            updateSearch(surfaceView.searchState)
            updateFailure(healthy: surfaceView.healthy, error: surfaceView.error)
            bellBorder.isActive = surfaceView.bell
            highlightOverlay.isActive = surfaceView.highlighted
            readonlyBadge.isHidden = !surfaceView.readonly
            keyStateIndicator.update(keyTables: surfaceView.keyTables, keySequence: surfaceView.keySequence)
            resizeOverlay.updateSurfaceSize(surfaceView.surfaceSize)
            refreshConfiguration()
            refreshFocusState()
        }

        private func refreshConfiguration() {
            resizeOverlay.configure(
                overlay: ghostty.config.resizeOverlay,
                position: ghostty.config.resizeOverlayPosition,
                duration: ghostty.config.resizeOverlayDuration
            )
            bellBorder.isEnabled = ghostty.config.bellFeatures.contains(.border)
            dimOverlay.color = ghostty.config.unfocusedSplitFill.withAlphaComponent(
                ghostty.config.unfocusedSplitOpacity
            )
            refreshFocusState()
        }

        private func refreshFocusState() {
            let controller = surfaceView.window?.windowController as? BaseTerminalController
            let isFocused = controller?.focusedSurface === surfaceView || surfaceView.isFirstResponder
            let isKey = surfaceView.window?.isKeyWindow ?? false
            dimOverlay.isHidden = !isSplit || isFocused || ghostty.config.unfocusedSplitOpacity <= 0
            secureInputOverlay.isHidden = !(
                ghostty.config.secureInputIndication &&
                    SecureInput.shared.enabled &&
                    isFocused &&
                    isKey
            )
            needsLayout = true
        }

        private func updateProgress(_ report: Ghostty.Action.ProgressReport?) {
            guard let report, report.state != .remove else {
                progressBar?.removeFromSuperview()
                progressBar = nil
                return
            }
            if let progressBar {
                progressBar.update(report: report)
            } else {
                let progressBar = SurfaceProgressBar(report: report)
                addSubview(progressBar, positioned: .above, relativeTo: scrollView)
                self.progressBar = progressBar
            }
            needsLayout = true
        }

        private func updateURL(_ url: String?) {
            guard let url else {
                urlBanner?.removeFromSuperview()
                urlBanner = nil
                return
            }
            if let urlBanner {
                urlBanner.url = url
            } else {
                let banner = URLHoverBanner(url: url)
                addSubview(banner, positioned: .above, relativeTo: scrollView)
                urlBanner = banner
            }
            needsLayout = true
        }

        private func updateChildExited(_ message: ChildExitedMessage?, cellSize: CGSize) {
            guard let message else {
                childExitedBar?.removeFromSuperview()
                childExitedBar = nil
                return
            }
            let fontSize = min(cellSize.height * 0.8, 30)
            if let childExitedBar {
                childExitedBar.update(message: message, fontSize: fontSize)
            } else {
                let bar = ChildExitedMessageBar(message: message, fontSize: fontSize)
                addSubview(bar, positioned: .above, relativeTo: scrollView)
                childExitedBar = bar
            }
            needsLayout = true
        }

        private func updateSearch(_ state: SurfaceView.SearchState?) {
            guard let state else {
                searchOverlay?.removeFromSuperview()
                searchOverlay = nil
                return
            }
            if searchOverlay?.searchState === state { return }
            searchOverlay?.removeFromSuperview()
            let overlay = NativeSurfaceSearchOverlay(surfaceView: surfaceView, searchState: state)
            addSubview(overlay, positioned: .above, relativeTo: scrollView)
            searchOverlay = overlay
            needsLayout = true
        }

        private func updateFailure(healthy: Bool, error: Error?) {
            let kind: SurfaceFailureView.Kind? = if !healthy {
                .renderer
            } else if error != nil {
                .initialization
            } else {
                nil
            }
            guard let kind else {
                failureView?.removeFromSuperview()
                failureView = nil
                return
            }
            if failureView?.kind == kind { return }
            failureView?.removeFromSuperview()
            let view = SurfaceFailureView(kind: kind, backgroundColor: ghostty.config.backgroundColor)
            addSubview(view, positioned: .above, relativeTo: scrollView)
            failureView = view
            needsLayout = true
        }
    }
}

@MainActor
private final class PassthroughColorView: NSView {
    var color: NSColor = .clear {
        didSet {
            wantsLayer = true
            layer?.backgroundColor = color.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
