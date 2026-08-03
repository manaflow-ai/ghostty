import AppKit

/// Clickable native indicator for macOS Secure Input.
@MainActor
final class SecureInputOverlay: NSControl {
    private let gradientLayer = CAGradientLayer()
    private let iconLayer = CALayer()
    private weak var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        gradientLayer.type = .conic
        gradientLayer.colors = [
            NSColor.systemCyan.cgColor,
            NSColor.systemBlue.cgColor,
            NSColor.systemYellow.cgColor,
            NSColor.systemBlue.cgColor,
            NSColor.systemCyan.cgColor,
        ]
        gradientLayer.locations = [0, 0.25, 0.5, 0.75, 1]
        gradientLayer.opacity = 0.5
        layer?.addSublayer(gradientLayer)

        iconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Secure Input"))
        updateColors()
        updateIcon()
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 35, height: 35))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 35, height: 35) }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds.insetBy(dx: -6, dy: -6)
        iconLayer.frame = bounds.insetBy(dx: 5, dy: 5)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            gradientLayer.removeAllAnimations()
        } else {
            installAnimations()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
        updateIcon()
    }

    override func mouseDown(with event: NSEvent) {
        showExplanation()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateColors() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.gray.cgColor
    }

    private func updateIcon() {
        let image = NSImage(
            systemSymbolName: "lock.shield.fill",
            accessibilityDescription: String(localized: "Secure Input")
        )?.withSymbolConfiguration(.init(pointSize: 25, weight: .regular))
        image?.isTemplate = true
        iconLayer.contents = image
        iconLayer.compositingFilter = "sourceAtop"
        iconLayer.backgroundColor = NSColor.labelColor.cgColor
    }

    private func installAnimations() {
        guard gradientLayer.animation(forKey: "rotation") == nil else { return }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 2
        rotation.repeatCount = .infinity
        gradientLayer.add(rotation, forKey: "rotation")

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.5
        pulse.toValue = 1
        pulse.duration = 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        gradientLayer.add(pulse, forKey: "opacity")
    }

    private func showExplanation() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let text = NSTextField(wrappingLabelWithString: String(localized: """
            Secure Input is active. Secure Input is a macOS security feature that prevents applications from reading keyboard events. This is enabled automatically whenever Ghostty detects a password prompt in the terminal, or at all times if `Ghostty > Secure Keyboard Entry` is active.
            """))
        text.preferredMaxLayoutWidth = 360
        text.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            text.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 392),
        ])

        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }
}
