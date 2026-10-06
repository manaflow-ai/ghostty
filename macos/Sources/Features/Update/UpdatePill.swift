import AppKit

@MainActor
final class UpdatePillView: NSButton, UpdateViewModelObserver {
    private let model: UpdateViewModel
    private let badgeView = UpdateBadgeView()
    private let textField = NSTextField(labelWithString: "")
    private var textWidthConstraint: NSLayoutConstraint?
    private var popover: NSPopover?

    init(model: UpdateViewModel) {
        self.model = model
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(pressed)
        setButtonType(.momentaryChange)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 11, weight: .medium)
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1

        let stack = NSStackView(views: [badgeView, textField])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        model.addObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        guard !model.state.isIdle else { return .zero }
        let textWidth = (model.maxWidthText as NSString).size(withAttributes: [
            .font: textField.font ?? NSFont.systemFont(ofSize: 11)
        ]).width
        return NSSize(width: ceil(textWidth) + 36, height: 22)
    }

    func updateViewModelDidChange(_ model: UpdateViewModel) {
        isHidden = model.state.isIdle
        textField.stringValue = model.text
        textField.textColor = model.foregroundColor
        badgeView.update(with: model)
        layer?.backgroundColor = model.backgroundColor.cgColor
        toolTip = model.text
        setAccessibilityLabel(model.text)

        textWidthConstraint?.isActive = false
        let textWidth = (model.maxWidthText as NSString).size(withAttributes: [
            .font: textField.font ?? NSFont.systemFont(ofSize: 11)
        ]).width
        let constraint = textField.widthAnchor.constraint(equalToConstant: ceil(textWidth))
        constraint.isActive = true
        textWidthConstraint = constraint

        invalidateIntrinsicContentSize()
        superview?.invalidateIntrinsicContentSize()
        if model.state.isIdle {
            popover?.performClose(nil)
        } else if let content = popover?.contentViewController?.view as? UpdatePopoverContentView {
            popover?.contentSize = content.intrinsicContentSize
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    @objc private func pressed() {
        if case .notFound(let notFound) = model.state {
            model.state = .idle
            notFound.acknowledgement()
            return
        }

        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        let content = UpdatePopoverContentView(model: model) { [weak popover] in
            popover?.performClose(nil)
        }
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.intrinsicContentSize
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}
