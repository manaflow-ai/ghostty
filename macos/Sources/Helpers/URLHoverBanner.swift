#if canImport(AppKit)
import AppKit

/// Bottom-edge URL preview that moves away from the pointer.
@MainActor
final class URLHoverBanner: NSView {
    private let leftLabel = URLHoverLabelView(roundedSide: .right)
    private let rightLabel = URLHoverLabelView(roundedSide: .left)
    private var trackingArea: NSTrackingArea?

    var url: String {
        didSet {
            leftLabel.stringValue = url
            rightLabel.stringValue = url
            needsLayout = true
        }
    }

    init(url: String) {
        self.url = url
        super.init(frame: .zero)
        addSubview(leftLabel)
        addSubview(rightLabel)
        leftLabel.stringValue = url
        rightLabel.stringValue = url
        rightLabel.alphaValue = 0
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: leftLabel.intrinsicContentSize.height + 10)
    }

    override func layout() {
        super.layout()
        let preferredWidth = min(max(leftLabel.intrinsicContentSize.width + 10, 40), bounds.width)
        let height = min(leftLabel.intrinsicContentSize.height + 10, bounds.height)
        leftLabel.frame = CGRect(x: 0, y: 0, width: preferredWidth, height: height)
        rightLabel.frame = CGRect(x: bounds.width - preferredWidth, y: 0, width: preferredWidth, height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: leftLabel.frame,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        leftLabel.alphaValue = 0
        rightLabel.alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        leftLabel.alphaValue = 1
        rightLabel.alphaValue = 0
    }
}

@MainActor
private final class URLHoverLabelView: NSTextField {
    enum RoundedSide { case left, right }

    private let roundedSide: RoundedSide

    init(roundedSide: RoundedSide) {
        self.roundedSide = roundedSide
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = true
        backgroundColor = .windowBackgroundColor
        lineBreakMode = .byTruncatingMiddle
        maximumNumberOfLines = 1
        cell?.wraps = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let radius: CGFloat = 9
        let path = CGMutablePath()
        let rect = bounds
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        switch roundedSide {
        case .left:
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        case .right:
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        let mask = CAShapeLayer()
        mask.path = path
        layer?.mask = mask
    }
}
#endif
