#if canImport(AppKit)
import AppKit
import GhosttyKit

@MainActor
final class NativeSurfaceResizeOverlay: NSView {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let surfaceView: Ghostty.SurfaceView
    private let label = NSTextField(labelWithString: "")
    private let sleep: Sleep
    private var overlay: Ghostty.Config.ResizeOverlay = .never
    private var position: Ghostty.Config.ResizeOverlayPosition = .center
    private var duration: UInt = 0
    private var surfaceSize: ghostty_surface_size_s?
    private var lastContainerSize: CGSize?
    private var dismissTask: Task<Void, Never>?

    init(
        surfaceView: Ghostty.SurfaceView,
        sleep: @escaping Sleep = { try await ContinuousClock().sleep(for: $0) }
    ) {
        self.surfaceView = surfaceView
        self.sleep = sleep
        super.init(frame: .zero)
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        label.layer?.cornerRadius = 4
        label.layer?.shadowColor = NSColor.black.cgColor
        label.layer?.shadowOpacity = 0.3
        label.layer?.shadowRadius = 3
        label.alignment = .center
        addSubview(label)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { dismissTask?.cancel() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        overlay: Ghostty.Config.ResizeOverlay,
        position: Ghostty.Config.ResizeOverlayPosition,
        duration: UInt
    ) {
        self.overlay = overlay
        self.position = position
        self.duration = duration
        needsLayout = true
    }

    func updateSurfaceSize(_ size: ghostty_surface_size_s?) {
        surfaceSize = size
        if let size { label.stringValue = "\(size.columns) ⨯ \(size.rows)" }
    }

    func updateContainerSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != lastContainerSize else { return }
        let hadPriorSize = lastContainerSize != nil
        lastContainerSize = size

        guard hadPriorSize, surfaceSize != nil else {
            isHidden = true
            return
        }

        if let focusInstant = surfaceView.focusInstant,
           focusInstant.duration(to: ContinuousClock.now) < .milliseconds(500) {
            isHidden = true
            return
        }

        switch overlay {
        case .never:
            isHidden = true
            return
        case .after_first, .always:
            isHidden = false
        }
        needsLayout = true
        scheduleDismissal()
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        let labelSize = CGSize(width: size.width + 10, height: size.height + 10)
        let x: CGFloat
        if position.left() {
            x = 5
        } else if position.right() {
            x = bounds.maxX - labelSize.width - 5
        } else {
            x = bounds.midX - labelSize.width / 2
        }
        let y: CGFloat
        if position.top() {
            y = bounds.maxY - labelSize.height - 5
        } else if position.bottom() {
            y = 5
        } else {
            y = bounds.midY - labelSize.height / 2
        }
        label.frame = CGRect(origin: CGPoint(x: x, y: y), size: labelSize)
    }

    private func scheduleDismissal() {
        dismissTask?.cancel()
        guard duration > 0 else { return }
        let sleep = sleep
        let delay = Duration.milliseconds(duration)
        dismissTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.isHidden = true
        }
    }
}

@MainActor
final class SurfaceFailureView: NSView {
    enum Kind: Equatable { case renderer, initialization }
    let kind: Kind

    init(kind: Kind, backgroundColor: NSColor) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor

        let image = NSImageView()
        image.image = NSImage(named: "AppIconImage")
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: String(localized: "Oh, no. 😭"))
        title.font = .preferredFont(forTextStyle: .title1)
        let message = switch kind {
        case .renderer:
            String(localized: "The renderer has failed. This is usually due to exhausting available GPU memory. Please free up available resources.")
        case .initialization:
            String(localized: "The terminal failed to initialize. Please check the logs for more information. This is usually a bug.")
        }
        let detail = NSTextField(wrappingLabelWithString: message)
        detail.preferredMaxLayoutWidth = 350
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 6
        let content = NSStackView(views: [image, labels])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 128),
            image.heightAnchor.constraint(equalToConstant: 128),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class SurfaceBorderOverlay: NSView {
    var isEnabled = true { didSet { refresh() } }
    var isActive = false { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderColor = NSColor(red: 1, green: 0.8, blue: 0, alpha: 0.5).cgColor
        layer?.borderWidth = 3
        layer?.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func refresh() {
        guard let layer else { return }
        let target: Float = isEnabled && isActive ? 1 : 0
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = target
        animation.duration = 0.3
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = target
        layer.add(animation, forKey: "visibility")
    }
}

@MainActor
final class SurfaceHighlightOverlay: NSView {
    private let glowLayer = CAGradientLayer()
    private let borderLayer = CALayer()

    var isActive = false { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.opacity = 0
        glowLayer.type = .radial
        glowLayer.colors = [
            NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor,
            NSColor.controlAccentColor.withAlphaComponent(0.03).cgColor,
            NSColor.clear.cgColor,
        ]
        glowLayer.locations = [0, 0.5, 1]
        layer?.addSublayer(glowLayer)
        borderLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        borderLayer.borderWidth = 2
        borderLayer.shadowColor = NSColor.controlAccentColor.cgColor
        borderLayer.shadowOpacity = 0.6
        borderLayer.shadowRadius = 8
        layer?.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        glowLayer.frame = bounds
        borderLayer.frame = bounds
    }

    private func refresh() {
        guard let layer else { return }
        let target: Float = isActive ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = target
        fade.duration = 0.4
        layer.opacity = target
        layer.add(fade, forKey: "visibility")

        if isActive {
            let width = CABasicAnimation(keyPath: "borderWidth")
            width.fromValue = 2
            width.toValue = 4
            width.duration = 0.4
            width.autoreverses = true
            width.repeatCount = .infinity
            borderLayer.add(width, forKey: "pulse")
        } else {
            borderLayer.removeAnimation(forKey: "pulse")
        }
    }
}

@MainActor
final class SurfaceReadonlyBadge: NSControl {
    private weak var popover: NSPopover?
    private let surfaceView: Ghostty.SurfaceView

    init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.6).cgColor

        let icon = NSImageView(image: NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemOrange
        let label = NSTextField(labelWithString: String(localized: "Read-only"))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .systemOrange
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Read-only terminal"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { showPopover() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func showPopover() {
        let title = NSTextField(labelWithString: String(localized: "Read-Only Mode"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: String(localized: "This terminal is in read-only mode. You can still view, select, and scroll through the content, but no input events will be sent to the running application."))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 248
        let disable = NSButton(title: String(localized: "Disable"), target: self, action: #selector(disableReadonly))
        disable.keyEquivalent = "\r"
        let content = NSStackView(views: [title, detail, disable])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    @objc private func disableReadonly() {
        surfaceView.toggleReadonly(nil)
        popover?.performClose(nil)
    }
}

@MainActor
final class SurfaceKeyStateIndicator: NSControl {
    private enum Position { case top, bottom }
    private let effect = NSVisualEffectView()
    private let content = NSStackView()
    private var position: Position = .bottom
    private var dragStart: CGPoint?
    private var dragOffset: CGFloat = 0
    private var keyTables: [String] = []
    private var keySequence: [Ghostty.Input.Shortcut] = []
    private weak var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        addSubview(effect)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        effect.addSubview(content)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        effect.frame = bounds
        content.frame = bounds
    }

    func update(keyTables: [String], keySequence: [Ghostty.Input.Shortcut]) {
        self.keyTables = keyTables
        self.keySequence = keySequence
        isHidden = keyTables.isEmpty && keySequence.isEmpty
        content.arrangedSubviews.forEach {
            content.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if !keyTables.isEmpty {
            let icon = NSImageView(image: NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            content.addArrangedSubview(icon)
            content.addArrangedSubview(NSTextField(labelWithString: keyTables.joined(separator: "  ›  ")))
        }
        if !keyTables.isEmpty && !keySequence.isEmpty {
            let separator = NSBox()
            separator.boxType = .separator
            NSLayoutConstraint.activate([
                separator.widthAnchor.constraint(equalToConstant: 1),
                separator.heightAnchor.constraint(equalToConstant: 14),
            ])
            content.addArrangedSubview(separator)
        }
        if !keySequence.isEmpty {
            let sequence = NSTextField(labelWithString: keySequence.map(\.description).joined(separator: "  "))
            sequence.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            content.addArrangedSubview(sequence)
            let pending = NSTextField(labelWithString: "•••")
            pending.textColor = .secondaryLabelColor
            content.addArrangedSubview(pending)
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.3
            pulse.toValue = 1
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pending.wantsLayer = true
            pending.layer?.add(pulse, forKey: "pending")
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let size = content.fittingSize
        return NSSize(width: max(1, size.width), height: max(1, size.height))
    }

    func position(in container: CGRect) {
        guard !isHidden else { return }
        let size = intrinsicContentSize
        let baseY: CGFloat = switch position {
        case .top: container.maxY - size.height - 8
        case .bottom: 8
        }
        frame = CGRect(
            x: container.midX - size.width / 2,
            y: baseY + dragOffset,
            width: size.width,
            height: size.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        dragOffset = event.locationInWindow.y - dragStart.y
        superview?.needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStart else { return }
        let translation = event.locationInWindow.y - dragStart.y
        self.dragStart = nil
        if position == .bottom, translation > 50 {
            position = .top
        } else if position == .top, translation < -50 {
            position = .bottom
        } else if abs(translation) < 4 {
            showPopover()
        }
        dragOffset = 0
        superview?.needsLayout = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func showPopover() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        if !keyTables.isEmpty {
            let title = NSTextField(labelWithString: String(localized: "Key Table"))
            title.font = .preferredFont(forTextStyle: .headline)
            stack.addArrangedSubview(title)
            stack.addArrangedSubview(NSTextField(wrappingLabelWithString: String(localized: "A key table is a named set of keybindings, activated by another key. Keys use this table until it is deactivated.")))
        }
        if !keySequence.isEmpty {
            let title = NSTextField(labelWithString: String(localized: "Key Sequence"))
            title.font = .preferredFont(forTextStyle: .headline)
            stack.addArrangedSubview(title)
            stack.addArrangedSubview(NSTextField(wrappingLabelWithString: String(localized: "A pending series of key presses is waiting to trigger an action.")))
        }
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: position == .top ? .maxY : .minY)
    }
}
#endif
