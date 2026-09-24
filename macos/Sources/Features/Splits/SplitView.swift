import AppKit

enum SplitViewDirection: Codable {
    case horizontal, vertical
}

/// Two-pane native split container with Ghostty ratio semantics.
@MainActor
final class SplitView: NSSplitView, NSSplitViewDelegate {
    let direction: SplitViewDirection
    private(set) var splitRatio: CGFloat
    private let resizeIncrements: NSSize
    private let onResize: (CGFloat) -> Void
    private let onEqualize: () -> Void
    private var applyingRatio = false
    private var ratioNeedsApplication = true
    private var configuredDividerColor: NSColor

    init(
        _ direction: SplitViewDirection,
        split: CGFloat,
        dividerColor: NSColor,
        resizeIncrements: NSSize = NSSize(width: 1, height: 1),
        left: NSView,
        right: NSView,
        onResize: @escaping (CGFloat) -> Void,
        onEqualize: @escaping () -> Void
    ) {
        self.direction = direction
        self.splitRatio = split
        self.resizeIncrements = resizeIncrements
        self.onResize = onResize
        self.onEqualize = onEqualize
        self.configuredDividerColor = dividerColor
        super.init(frame: .zero)

        isVertical = direction == .horizontal
        dividerStyle = .thin
        delegate = self
        addSubview(left)
        addSubview(right)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitGroup)
        setAccessibilityLabel(splitViewLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var dividerColor: NSColor { configuredDividerColor }
    override var dividerThickness: CGFloat { 1 }

    override func layout() {
        super.layout()
        if ratioNeedsApplication { applyRatio() }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, dividerHitRect.contains(point) {
            onEqualize()
            return
        }
        super.mouseDown(with: event)
    }

    func update(split: CGFloat, dividerColor: NSColor) {
        configuredDividerColor = dividerColor
        needsDisplay = true
        guard abs(splitRatio - split) > 0.0001 else { return }
        splitRatio = split
        ratioNeedsApplication = true
        needsLayout = true
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let length = isVertical ? bounds.width : bounds.height
        let increment = max(1, isVertical ? resizeIncrements.width : resizeIncrements.height)
        let snapped = (proposedPosition / increment).rounded() * increment
        return min(max(10, snapped), max(10, length - 10))
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applyingRatio, subviews.count == 2 else { return }
        let length = isVertical ? bounds.width : bounds.height
        guard length > 0 else { return }
        let leadingLength = isVertical ? subviews[0].frame.width : subviews[0].frame.height
        let ratio = min(max(leadingLength / length, 0.01), 0.99)
        guard abs(splitRatio - ratio) > 0.0001 else { return }
        splitRatio = ratio
        onResize(ratio)
    }

    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        if isVertical {
            return drawnRect.insetBy(dx: -3, dy: 0)
        }
        return drawnRect.insetBy(dx: 0, dy: -3)
    }

    private func applyRatio() {
        let length = isVertical ? bounds.width : bounds.height
        guard length > 0, subviews.count == 2 else { return }
        applyingRatio = true
        setPosition(length * splitRatio, ofDividerAt: 0)
        applyingRatio = false
        ratioNeedsApplication = false
    }

    private var dividerHitRect: CGRect {
        guard let first = subviews.first else { return .zero }
        if isVertical {
            return CGRect(x: first.frame.maxX - 3, y: 0, width: 7, height: bounds.height)
        }
        return CGRect(x: 0, y: first.frame.minY - 3, width: bounds.width, height: 7)
    }

    private var splitViewLabel: String {
        switch direction {
        case .horizontal: String(localized: "Horizontal split view")
        case .vertical: String(localized: "Vertical split view")
        }
    }
}
