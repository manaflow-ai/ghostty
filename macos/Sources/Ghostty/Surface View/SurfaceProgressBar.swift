import AppKit

/// Native progress indicator for terminal progress reports.
@MainActor
final class SurfaceProgressBar: NSView {
    private static let barWidthRatio: CGFloat = 0.25

    private let trackLayer = CALayer()
    private let progressLayer = CALayer()
    private var report: Ghostty.Action.ProgressReport

    init(report: Ghostty.Action.ProgressReport) {
        self.report = report
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 2))
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(progressLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        updatePresentation(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 2)
    }

    override func layout() {
        super.layout()
        updateLayerFrames(animated: false)
    }

    func update(report: Ghostty.Action.ProgressReport) {
        self.report = report
        updatePresentation(animated: true)
    }

    private var color: NSColor {
        switch report.state {
        case .error: .systemRed
        case .pause: .systemOrange
        default: .controlAccentColor
        }
    }

    private var progress: UInt8? {
        if let progress = report.progress { return progress }
        return report.state == .pause ? 100 : nil
    }

    private func updatePresentation(animated: Bool) {
        progressLayer.backgroundColor = color.cgColor
        updateLayerFrames(animated: animated)
        updateAccessibility()
    }

    private func updateLayerFrames(animated: Bool) {
        guard let layer else { return }
        let bounds = layer.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds

        if let progress {
            trackLayer.backgroundColor = NSColor.clear.cgColor
            progressLayer.removeAnimation(forKey: "bounce")
            let width = bounds.width * CGFloat(progress) / 100
            let newFrame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            if animated, let presentation = progressLayer.presentation() {
                let animation = CABasicAnimation(keyPath: "bounds.size.width")
                animation.fromValue = presentation.bounds.width
                animation.toValue = width
                animation.duration = 0.2
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                progressLayer.add(animation, forKey: "progress")
            }
            progressLayer.frame = newFrame
        } else {
            trackLayer.backgroundColor = color.withAlphaComponent(0.3).cgColor
            progressLayer.frame = CGRect(
                x: 0,
                y: 0,
                width: bounds.width * Self.barWidthRatio,
                height: bounds.height
            )
            installBounceAnimation(in: bounds)
        }
        CATransaction.commit()
    }

    private func installBounceAnimation(in bounds: CGRect) {
        guard bounds.width > 0, progressLayer.animation(forKey: "bounce") == nil else { return }
        let travel = bounds.width * (1 - Self.barWidthRatio)
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = travel
        animation.duration = 1.2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        progressLayer.add(animation, forKey: "bounce")
    }

    private func updateAccessibility() {
        let label = switch report.state {
        case .error: String(localized: "Terminal progress - Error")
        case .pause: String(localized: "Terminal progress - Paused")
        case .indeterminate: String(localized: "Terminal progress - In progress")
        default: String(localized: "Terminal progress")
        }
        setAccessibilityLabel(label)

        let value: String
        if let progress {
            value = String(format: String(localized: "%d percent complete"), progress)
        } else {
            value = switch report.state {
            case .error: String(localized: "Operation failed")
            case .pause: String(localized: "Operation paused at completion")
            case .indeterminate: String(localized: "Operation in progress")
            default: String(localized: "Indeterminate progress")
            }
        }
        setAccessibilityValue(value)
    }
}
