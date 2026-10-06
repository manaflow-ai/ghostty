import AppKit

enum TerminalTabColor: Int, CaseIterable, Codable {
    case none
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal
    case graphite

    var localizedName: String {
        switch self {
        case .none:
            return String(localized: "None")
        case .blue:
            return String(localized: "Blue")
        case .purple:
            return String(localized: "Purple")
        case .pink:
            return String(localized: "Pink")
        case .red:
            return String(localized: "Red")
        case .orange:
            return String(localized: "Orange")
        case .yellow:
            return String(localized: "Yellow")
        case .green:
            return String(localized: "Green")
        case .teal:
            return String(localized: "Teal")
        case .graphite:
            return String(localized: "Graphite")
        }
    }

    var displayColor: NSColor? {
        switch self {
        case .none:
            return nil
        case .blue:
            return .systemBlue
        case .purple:
            return .systemPurple
        case .pink:
            return .systemPink
        case .red:
            return .systemRed
        case .orange:
            return .systemOrange
        case .yellow:
            return .systemYellow
        case .green:
            return .systemGreen
        case .teal:
            if #available(macOS 13.0, *) {
                return .systemMint
            } else {
                return .systemTeal
            }
        case .graphite:
            return .systemGray
        }
    }

    func swatchImage(selected: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            let circleRect = rect.insetBy(dx: 1, dy: 1)
            let circlePath = NSBezierPath(ovalIn: circleRect)

            if let fillColor = self.displayColor {
                fillColor.setFill()
                circlePath.fill()
            } else {
                NSColor.clear.setFill()
                circlePath.fill()
                NSColor.quaternaryLabelColor.setStroke()
                circlePath.lineWidth = 1
                circlePath.stroke()
            }

            if self == .none {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: circleRect.minX + 2, y: circleRect.minY + 2))
                slash.line(to: NSPoint(x: circleRect.maxX - 2, y: circleRect.maxY - 2))
                slash.lineWidth = 1.5
                NSColor.secondaryLabelColor.setStroke()
                slash.stroke()
            }

            if selected {
                let highlight = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                highlight.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                highlight.stroke()
            }

            return true
        }
    }
}

// MARK: - Menu View

@MainActor
final class TabColorMenuView: NSView {
    private var currentSelection: TerminalTabColor
    private let onSelect: (TerminalTabColor) -> Void
    private var buttons: [TerminalTabColor: NSButton] = [:]

    private static let paletteRows: [[TerminalTabColor]] = [
        [.none, .blue, .purple, .pink, .red],
        [.orange, .yellow, .green, .teal, .graphite],
    ]

    private static var leadingPadding: CGFloat {
        if #available(macOS 26.0, *) {
            return 40
        } else {
            return 12
        }
    }

    init(selectedColor: TerminalTabColor, onSelect: @escaping (TerminalTabColor) -> Void) {
        self.currentSelection = selectedColor
        self.onSelect = onSelect
        super.init(frame: .zero)

        let title = NSTextField(labelWithString: String(localized: "Tab Color"))
        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 3
        content.addArrangedSubview(title)

        for row in Self.paletteRows {
            let rowView = NSStackView()
            rowView.orientation = .horizontal
            rowView.spacing = 2
            for color in row {
                let button = NSButton(
                    image: color.swatchImage(selected: color == currentSelection),
                    target: self,
                    action: #selector(selectColor(_:))
                )
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.toolTip = color.localizedName
                button.setAccessibilityLabel(color.localizedName)
                button.tag = color.rawValue
                NSLayoutConstraint.activate([
                    button.widthAnchor.constraint(equalToConstant: 20),
                    button.heightAnchor.constraint(equalToConstant: 20),
                ])
                buttons[color] = button
                rowView.addArrangedSubview(button)
            }
            content.addArrangedSubview(rowView)
        }

        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingPadding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        frame.size = fittingSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard let color = TerminalTabColor(rawValue: sender.tag) else { return }
        currentSelection = color
        for (candidate, button) in buttons {
            button.image = candidate.swatchImage(selected: candidate == color)
        }
        onSelect(color)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
