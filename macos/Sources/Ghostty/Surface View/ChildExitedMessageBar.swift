import AppKit

/// Bottom message shown after the terminal child process exits.
@MainActor
final class ChildExitedMessageBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    init(message: Ghostty.ChildExitedMessage, fontSize: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        update(message: message, fontSize: fontSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
        animator().alphaValue = 0
    }

    override func mouseExited(with event: NSEvent) {
        animator().alphaValue = 1
    }

    func update(message: Ghostty.ChildExitedMessage, fontSize: CGFloat) {
        let attributed = (try? AttributedString(markdown: message.text)) ?? AttributedString(message.text)
        let value = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        value.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: fontSize),
            range: NSRange(location: 0, length: value.length)
        )
        label.attributedStringValue = value
        label.textColor = .labelColor
        layer?.backgroundColor = switch message.level {
        case .success: NSColor.windowBackgroundColor.cgColor
        case .error: NSColor.systemRed.withAlphaComponent(0.5).cgColor
        }
        setAccessibilityLabel(message.text)
        invalidateIntrinsicContentSize()
    }
}
