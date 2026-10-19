import AppKit

struct CommandOption: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let description: String?
    let symbols: [String]?
    let leadingIcon: String?
    let leadingColor: NSColor?
    let badge: String?
    let emphasis: Bool
    let sortKey: AnySortKey?
    let action: () -> Void

    init(
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        symbols: [String]? = nil,
        leadingIcon: String? = nil,
        leadingColor: NSColor? = nil,
        badge: String? = nil,
        emphasis: Bool = false,
        sortKey: AnySortKey? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.symbols = symbols
        self.leadingIcon = leadingIcon
        self.leadingColor = leadingColor
        self.badge = badge
        self.emphasis = emphasis
        self.sortKey = sortKey
        self.action = action
    }

    static func == (lhs: CommandOption, rhs: CommandOption) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Native command palette with AppKit text input and table navigation.
@MainActor
final class CommandPaletteView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let queryField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let noMatchesLabel = NSTextField(labelWithString: String(localized: "No matches"))
    private let backgroundEffect = NSVisualEffectView()
    private let tintView = NSView()
    private let onDismiss: () -> Void

    var options: [CommandOption] {
        didSet { refilter() }
    }

    private(set) var filteredOptions: [CommandOption] = []
    private var selectedIndex: Int?
    private var rawQuery = ""

    init(
        backgroundColor: NSColor = .windowBackgroundColor,
        options: [CommandOption],
        onDismiss: @escaping () -> Void
    ) {
        self.options = options
        self.onDismiss = onDismiss
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.75).cgColor
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 32
        layer?.shadowOffset = CGSize(width: 0, height: -12)

        backgroundEffect.material = .popover
        backgroundEffect.blendingMode = .withinWindow
        backgroundEffect.state = .active
        backgroundEffect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundEffect)

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = backgroundColor.withAlphaComponent(0.72).cgColor
        tintView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tintView)

        queryField.placeholderString = String(localized: "Execute a command…")
        queryField.font = .systemFont(ofSize: 20, weight: .light)
        queryField.isBezeled = false
        queryField.drawsBackground = false
        queryField.focusRingType = .none
        queryField.delegate = self
        queryField.target = self
        queryField.action = #selector(submitQuery)
        queryField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(queryField)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        noMatchesLabel.textColor = .secondaryLabelColor
        noMatchesLabel.alignment = .left
        noMatchesLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noMatchesLabel)

        NSLayoutConstraint.activate([
            backgroundEffect.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffect.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffect.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffect.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),
            queryField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            queryField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            queryField.topAnchor.constraint(equalTo: topAnchor),
            queryField.heightAnchor.constraint(equalToConstant: 48),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: queryField.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            noMatchesLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            noMatchesLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
        ])

        refilter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 500, height: 249) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(queryField) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredOptions.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        filteredOptions[row].subtitle == nil ? 36 : 48
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("command-row")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? CommandPaletteRowView
            ?? CommandPaletteRowView()
        view.identifier = identifier
        view.configure(
            option: filteredOptions[row],
            query: query,
            selected: row == effectiveSelectedIndex
        )
        return view
    }

    func controlTextDidChange(_ notification: Notification) {
        let priorQueryWasEmpty = query.isEmpty
        rawQuery = queryField.stringValue
        refilter()
        if !query.isEmpty, selectedIndex == nil {
            selectedIndex = 0
        } else if query.isEmpty, !priorQueryWasEmpty, selectedIndex == 0 {
            selectedIndex = nil
        }
        reloadSelection()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss()
        case #selector(NSResponder.insertNewline(_:)):
            submitQuery()
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(up: true)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(up: false)
        default:
            return false
        }
        return true
    }

    @objc private func submitQuery() {
        let option = selectedOption
        onDismiss()
        option?.action()
    }

    @objc private func tableClicked() {
        guard tableView.clickedRow >= 0, tableView.clickedRow < filteredOptions.count else { return }
        let option = filteredOptions[tableView.clickedRow]
        onDismiss()
        option.action()
    }

    private var query: String {
        rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveSelectedIndex: Int? {
        guard let selectedIndex, !filteredOptions.isEmpty else { return nil }
        return min(selectedIndex, filteredOptions.count - 1)
    }

    private var selectedOption: CommandOption? {
        effectiveSelectedIndex.map { filteredOptions[$0] }
    }

    private func moveSelection(up: Bool) {
        guard !filteredOptions.isEmpty else { return }
        if up {
            let current = selectedIndex ?? filteredOptions.count
            selectedIndex = current == 0 ? filteredOptions.count - 1 : current - 1
        } else {
            let current = selectedIndex ?? -1
            selectedIndex = current >= filteredOptions.count - 1 ? 0 : current + 1
        }
        reloadSelection()
        if let index = effectiveSelectedIndex {
            tableView.scrollRowToVisible(index)
        }
    }

    private func refilter() {
        if query.isEmpty {
            filteredOptions = options
        } else {
            filteredOptions = options
                .filter { option in
                    option.title.matchedIndices(for: query) != nil ||
                        option.subtitle?.matchedIndices(for: query) != nil ||
                        colorMatchScore(for: option.leadingColor, query: query) > 0
                }
                .enumerated()
                .sorted { lhs, rhs in
                    let left = colorMatchScore(for: lhs.element.leadingColor, query: query)
                    let right = colorMatchScore(for: rhs.element.leadingColor, query: query)
                    return left == right ? lhs.offset < rhs.offset : left > right
                }
                .map(\.element)
        }
        noMatchesLabel.isHidden = !filteredOptions.isEmpty
        scrollView.isHidden = filteredOptions.isEmpty
        tableView.reloadData()
    }

    private func reloadSelection() {
        tableView.reloadData()
    }

    private func colorMatchScore(for color: NSColor?, query: String) -> Double {
        guard let color else { return 0 }
        let queryLower = query.lowercased()
        var bestScore = 0.0
        for name in NSColor.colorNames {
            guard
                queryLower.contains(name),
                let systemColor = NSColor(named: name)
            else { continue }
            let distance = color.distance(to: systemColor)
            if distance < 1.5 { bestScore = max(bestScore, 1 - distance / 1.5) }
        }
        return bestScore
    }
}

@MainActor
private final class CommandPaletteRowView: NSTableCellView {
    private var selected = false
    private var hovered = false
    private var emphasized = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateBackground()
    }

    func configure(option: CommandOption, query: String, selected: Bool) {
        subviews.forEach { $0.removeFromSuperview() }
        self.selected = selected
        emphasized = option.emphasis

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false

        if let color = option.leadingColor {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 4
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
            row.addArrangedSubview(dot)
        }

        if let icon = option.leadingIcon,
           let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            let imageView = NSImageView(image: image)
            imageView.contentTintColor = option.emphasis ? .controlAccentColor : .secondaryLabelColor
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
            ])
            row.addArrangedSubview(imageView)
        }

        let title = NSTextField(labelWithAttributedString: highlighted(
            option.title,
            query: query,
            font: .systemFont(ofSize: NSFont.systemFontSize, weight: option.emphasis ? .medium : .regular)
        ))
        let labels = NSStackView(views: [title])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        if let subtitle = option.subtitle {
            let subtitleQuery = option.title.matchedIndices(for: query) == nil ? query : ""
            let subtitleLabel = NSTextField(labelWithAttributedString: highlighted(
                subtitle,
                query: subtitleQuery,
                font: .systemFont(ofSize: NSFont.smallSystemFontSize)
            ))
            subtitleLabel.textColor = .secondaryLabelColor
            labels.addArrangedSubview(subtitleLabel)
        }
        row.addArrangedSubview(labels)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        if let badge = option.badge, !badge.isEmpty {
            let badgeLabel = NSTextField(labelWithString: badge)
            badgeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            badgeLabel.textColor = .controlAccentColor
            badgeLabel.wantsLayer = true
            badgeLabel.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            badgeLabel.layer?.cornerRadius = 7
            row.addArrangedSubview(badgeLabel)
        }

        if let symbols = option.symbols {
            let shortcut = NSTextField(labelWithString: symbols.joined())
            shortcut.textColor = .secondaryLabelColor
            shortcut.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            row.addArrangedSubview(shortcut)
        }

        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = option.description
        updateBackground()
    }

    private func highlighted(_ text: String, query: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        guard !query.isEmpty, let indices = text.matchedIndices(for: query) else { return result }
        for index in indices {
            let offset = text.distance(from: text.startIndex, to: index)
            result.addAttributes([
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: .bold),
                .foregroundColor: NSColor.controlAccentColor,
            ], range: NSRange(location: offset, length: 1))
        }
        return result
    }

    private func updateBackground() {
        layer?.backgroundColor = if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        } else if hovered {
            NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor
        } else {
            NSColor.clear.cgColor
        }
        layer?.borderWidth = emphasized && !selected ? 1.5 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
    }
}

extension String {
    func matchedIndices(for query: String) -> [String.Index]? {
        guard !query.isEmpty else { return nil }
        if let range = range(of: query, options: .caseInsensitive) {
            return Array(self[range].indices)
        }

        let words = split(whereSeparator: \.isWhitespace)
        var queryIndex = query.startIndex
        var matched: [String.Index] = []
        for word in words {
            guard queryIndex < query.endIndex else { break }
            if word.first?.lowercased() == query[queryIndex].lowercased() {
                matched.append(word.startIndex)
                queryIndex = query.index(after: queryIndex)
            }
        }
        return queryIndex == query.endIndex ? matched : nil
    }
}
