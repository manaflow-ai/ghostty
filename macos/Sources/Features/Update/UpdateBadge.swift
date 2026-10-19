import AppKit
import QuartzCore

@MainActor
final class UpdateBadgeView: NSView {
    private let imageView = NSImageView()
    private let progressView = UpdateProgressRingView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.wantsLayer = true
        progressView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        addSubview(progressView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 14),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressView.topAnchor.constraint(equalTo: topAnchor),
            progressView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with model: UpdateViewModel) {
        setAccessibilityLabel(model.text)
        imageView.layer?.removeAnimation(forKey: "updateRotation")
        progressView.isHidden = true
        imageView.isHidden = false

        switch model.state {
        case .downloading(let download):
            if let expectedLength = download.expectedLength, expectedLength > 0 {
                showProgress(Double(download.progress) / Double(expectedLength))
            } else {
                showSymbol(model.iconName, color: model.iconColor)
            }
        case .extracting(let extracting):
            showProgress(extracting.progress)
        case .checking:
            showSymbol(model.iconName, color: model.iconColor)
            startRotation()
        default:
            showSymbol(model.iconName, color: model.iconColor)
        }
    }

    private func showProgress(_ progress: Double) {
        imageView.isHidden = true
        progressView.isHidden = false
        progressView.progress = min(1, max(0, progress))
    }

    private func showSymbol(_ name: String?, color: NSColor) {
        imageView.contentTintColor = color
        imageView.image = name.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(
                .init(pointSize: 12, weight: .regular)
            )
        }
    }

    private func startRotation() {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = Double.pi * 2
        animation.duration = 2.5
        animation.repeatCount = .infinity
        imageView.layer?.add(animation, forKey: "updateRotation")
    }
}

@MainActor
private final class UpdateProgressRingView: NSView {
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let lineWidth: CGFloat = 2
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)

        NSColor.labelColor.withAlphaComponent(0.2).setStroke()
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        track.stroke()

        NSColor.labelColor.setStroke()
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: NSPoint(x: bounds.midX, y: bounds.midY),
            radius: max(0, min(rect.width, rect.height) / 2),
            startAngle: 90,
            endAngle: 90 - CGFloat(progress * 360),
            clockwise: true
        )
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        arc.stroke()
    }
}
