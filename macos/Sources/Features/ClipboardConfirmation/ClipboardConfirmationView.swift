import AppKit

@MainActor
protocol ClipboardConfirmationViewDelegate: AnyObject {
  func clipboardConfirmationComplete(
    _ action: ClipboardConfirmationView.Action,
    _ request: Ghostty.ClipboardRequest
  )
}

@MainActor
final class ClipboardConfirmationView: NSView {
    enum Action: String {
        case cancel
        case confirm

        static func text(_ action: Action, _ reason: Ghostty.ClipboardRequest) -> String {
            switch (action, reason) {
            case (.cancel, .paste):
        "Cancel"
            case (.cancel, .osc_52_read), (.cancel, .osc_52_write):
        "Deny"
            case (.confirm, .paste):
        "Paste"
            case (.confirm, .osc_52_read), (.confirm, .osc_52_write):
        "Allow"
            }
        }
    }

  private let request: Ghostty.ClipboardRequest
  private weak var delegate: ClipboardConfirmationViewDelegate?
  private var cursorHiddenCount: UInt = 0
  private var revealedCursor = false

  init(
    contents: String,
    request: Ghostty.ClipboardRequest,
    delegate: ClipboardConfirmationViewDelegate?
  ) {
    self.request = request
    self.delegate = delegate
    super.init(frame: .zero)

    let icon = NSImageView(
      image: NSImage(
        systemSymbolName: "exclamationmark.triangle.fill",
        accessibilityDescription: nil
      ) ?? NSImage())
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 42, weight: .regular)
    icon.contentTintColor = .systemYellow
    icon.setContentHuggingPriority(.required, for: .horizontal)

    let message = NSTextField(wrappingLabelWithString: request.text())
    message.maximumNumberOfLines = 0
    message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let warning = NSStackView(views: [icon, message])
    warning.orientation = .horizontal
    warning.alignment = .centerY
    warning.spacing = 16

    let textView = NSTextView()
    textView.string = contents
    textView.isEditable = false
    textView.isSelectable = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .bezelBorder
    scrollView.documentView = textView

    let cancel = NSButton(
      title: Action.text(.cancel, request), target: self, action: #selector(cancel))
    cancel.keyEquivalent = "\u{1b}"
    let confirm = NSButton(
      title: Action.text(.confirm, request), target: self, action: #selector(confirm))
    confirm.keyEquivalent = "\r"
    confirm.bezelStyle = .rounded

    let actions = NSStackView(views: [NSView(), cancel, confirm, NSView()])
    actions.orientation = .horizontal
    actions.alignment = .centerY
    actions.spacing = 8

    let content = NSStackView(views: [warning, scrollView, actions])
    content.translatesAutoresizingMaskIntoConstraints = false
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 12
    addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      content.topAnchor.constraint(equalTo: topAnchor, constant: 16),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
      warning.widthAnchor.constraint(equalTo: content.widthAnchor),
      scrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
      actions.widthAnchor.constraint(equalTo: content.widthAnchor),
    ])
            }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
            }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window != nil, newWindow == nil {
      rehideCursorIfNeeded()
    }
    super.viewWillMove(toWindow: newWindow)
        }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, !revealedCursor else { return }
    revealedCursor = true
    cursorHiddenCount = Cursor.unhideCompletely()
            if cursorHiddenCount == 0 {
                _ = Cursor.unhide()
            }
        }

  @objc
  private func cancel() {
        delegate?.clipboardConfirmationComplete(.cancel, request)
    }

  @objc
  private func confirm() {
        delegate?.clipboardConfirmationComplete(.confirm, request)
    }

  private func rehideCursorIfNeeded() {
    guard revealedCursor else { return }
    revealedCursor = false
    for _ in 0..<cursorHiddenCount {
      Cursor.hide()
    }
    cursorHiddenCount = 0
  }
}
