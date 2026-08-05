import AppKit

@MainActor
final class ConfigurationErrorsView: NSView {
  private let summaryLabel = NSTextField(wrappingLabelWithString: "")
  private let errorsTextView = NSTextView()
  private let ignoreButton = NSButton(title: "Ignore", target: nil, action: nil)
  private let reloadButton = NSButton(title: "Reload Configuration", target: nil, action: nil)

  var onIgnore: (() -> Void)?
  var onReload: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    let icon = NSImageView(
      image: NSImage(
        systemSymbolName: "exclamationmark.triangle.fill",
        accessibilityDescription: nil
      ) ?? NSImage())
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 52, weight: .regular)
    icon.contentTintColor = .systemYellow
    icon.setContentHuggingPriority(.required, for: .horizontal)

    summaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
    summaryLabel.maximumNumberOfLines = 0
    summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let summary = NSStackView(views: [icon, summaryLabel])
    summary.orientation = .horizontal
    summary.alignment = .centerY
    summary.spacing = 16

    errorsTextView.isEditable = false
    errorsTextView.isSelectable = true
    errorsTextView.drawsBackground = false
    errorsTextView.textContainerInset = NSSize(width: 12, height: 12)
    errorsTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    errorsTextView.isVerticallyResizable = true
    errorsTextView.isHorizontallyResizable = false
    errorsTextView.autoresizingMask = [.width]
    errorsTextView.textContainer?.widthTracksTextView = true
    errorsTextView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )

    let scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .controlBackgroundColor
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = errorsTextView

    ignoreButton.keyEquivalent = "\u{1b}"
    ignoreButton.target = self
    ignoreButton.action = #selector(ignore)
    reloadButton.keyEquivalent = "\r"
    reloadButton.target = self
    reloadButton.action = #selector(reload)

    let actions = NSStackView(views: [NSView(), ignoreButton, reloadButton])
    actions.orientation = .horizontal
    actions.alignment = .centerY
    actions.spacing = 8
    actions.setHuggingPriority(.defaultLow, for: .horizontal)

    let content = NSStackView(views: [summary, scrollView, actions])
    content.translatesAutoresizingMaskIntoConstraints = false
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 16
    addSubview(content)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
      widthAnchor.constraint(lessThanOrEqualToConstant: 960),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 270),
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
      content.topAnchor.constraint(equalTo: topAnchor, constant: 20),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
      summary.widthAnchor.constraint(equalTo: content.widthAnchor),
      scrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
      actions.widthAnchor.constraint(equalTo: content.widthAnchor),
    ])
            }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
            }

  func update(errors: [String]) {
    let count = errors.count
    let finding = count == 1 ? "1 error was" : "\(count) errors were"
    summaryLabel.stringValue =
      "\(finding) found while loading the configuration. "
      + "Please review the errors below and reload your configuration or ignore the erroneous lines."
    errorsTextView.string = errors.joined(separator: "\n\n")
        }

  @objc
  private func ignore() {
    onIgnore?()
    }

  @objc
  private func reload() {
    onReload?()
    }
}
