#if canImport(AppKit)
import AppKit
import Combine

/// Native draggable search bar for a terminal surface.
@MainActor
final class NativeSurfaceSearchOverlay: NSView, NSTextFieldDelegate {
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    let searchState: Ghostty.SurfaceView.SearchState
    private let surfaceView: Ghostty.SurfaceView
    private let searchField = NSTextField()
    private let resultLabel = NSTextField(labelWithString: "")
    private var corner: Corner = .topRight
    private var dragStart: CGPoint?
    private var dragOffset = CGSize.zero
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    init(surfaceView: Ghostty.SurfaceView, searchState: Ghostty.SurfaceView.SearchState) {
        self.surfaceView = surfaceView
        self.searchState = searchState
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4

        searchField.placeholderString = String(localized: "Search")
        searchField.isBezeled = false
        searchField.drawsBackground = true
        searchField.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.stringValue = searchState.needle
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        resultLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.alignment = .right
        resultLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resultLabel)

        let next = button(symbol: "chevron.up", action: #selector(nextMatch))
        let previous = button(symbol: "chevron.down", action: #selector(previousMatch))
        let close = button(symbol: "xmark", action: #selector(closeSearch))
        let buttons = NSStackView(views: [next, previous, close])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 4
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 238),
            searchField.heightAnchor.constraint(equalToConstant: 30),
            resultLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: -8),
            resultLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            resultLabel.widthAnchor.constraint(equalToConstant: 48),
            buttons.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 4),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        searchState.$needle
            .removeDuplicates()
            .sink { [weak self] needle in
                guard let self, searchField.stringValue != needle else { return }
                searchField.stringValue = needle
                applySelection()
            }
            .store(in: &cancellables)
        searchState.$selected
            .combineLatest(searchState.$total)
            .sink { [weak self] in self?.updateResult(selected: $0, total: $1) }
            .store(in: &cancellables)
        searchState.$needleSelection
            .sink { [weak self] _ in self?.applySelection() }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak searchState] _ in
            Task { @MainActor in searchState?.readPasteboardNeedle() }
        })
        observers.append(center.addObserver(
            forName: .ghosttySearchFocus,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.focusSearchField() }
        })
        updateResult(selected: searchState.selected, total: searchState.total)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var intrinsicContentSize: NSSize { NSSize(width: 338, height: 46) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { focusSearchField() }
    }

    func position(in container: CGRect) {
        let size = intrinsicContentSize
        let padding: CGFloat = 8
        let base: CGPoint = switch corner {
        case .topLeft: CGPoint(x: padding, y: container.maxY - size.height - padding)
        case .topRight: CGPoint(x: container.maxX - size.width - padding, y: container.maxY - size.height - padding)
        case .bottomLeft: CGPoint(x: padding, y: padding)
        case .bottomRight: CGPoint(x: container.maxX - size.width - padding, y: padding)
        }
        frame = CGRect(
            x: base.x + dragOffset.width,
            y: base.y + dragOffset.height,
            width: min(size.width, container.width - padding * 2),
            height: size.height
        )
    }

    func controlTextDidChange(_ notification: Notification) {
        searchState.needle = searchField.stringValue
        updateSelectionFromEditor()
        searchState.writePasteboardNeedle()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            if searchState.needle.isEmpty {
                surfaceView.endSearch()
            } else {
                Ghostty.moveFocus(to: surfaceView)
            }
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                _ = surfaceView.navigateSearchToPrevious()
            } else {
                _ = surfaceView.navigateSearchToNext()
            }
        default:
            return false
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        dragOffset = CGSize(
            width: event.locationInWindow.x - dragStart.x,
            height: event.locationInWindow.y - dragStart.y
        )
        superview?.needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil, let superview else { return }
        self.dragStart = nil
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let left = center.x < superview.bounds.midX
        let top = center.y >= superview.bounds.midY
        corner = switch (top, left) {
        case (true, true): .topLeft
        case (true, false): .topRight
        case (false, true): .bottomLeft
        case (false, false): .bottomRight
        }
        dragOffset = .zero
        superview.needsLayout = true
    }

    private func button(symbol: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
            target: self,
            action: action
        )
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
        return button
    }

    private func updateResult(selected: UInt?, total: UInt?) {
        if let selected {
            resultLabel.stringValue = "\(selected + 1)/\(total.map(String.init) ?? "?")"
        } else if let total {
            resultLabel.stringValue = "-/\(total)"
        } else {
            resultLabel.stringValue = ""
        }
    }

    private func focusSearchField() {
        window?.makeFirstResponder(searchField)
        applySelection()
    }

    private func applySelection() {
        guard
            let selection = searchState.needleSelection,
            let editor = searchField.currentEditor()
        else { return }
        let location = searchState.needle.distance(from: searchState.needle.startIndex, to: selection.lowerBound)
        let length = searchState.needle.distance(from: selection.lowerBound, to: selection.upperBound)
        editor.selectedRange = NSRange(location: location, length: length)
    }

    private func updateSelectionFromEditor() {
        guard let range = searchField.currentEditor()?.selectedRange else { return }
        let needle = searchState.needle
        guard
            let lower = needle.index(needle.startIndex, offsetBy: range.location, limitedBy: needle.endIndex),
            let upper = needle.index(lower, offsetBy: range.length, limitedBy: needle.endIndex)
        else { return }
        searchState.needleSelection = lower..<upper
    }

    @objc private func nextMatch() { _ = surfaceView.navigateSearchToNext() }
    @objc private func previousMatch() { _ = surfaceView.navigateSearchToPrevious() }
    @objc private func closeSearch() { surfaceView.endSearch() }
}
#endif
