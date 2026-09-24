import AppKit

@MainActor
final class AboutView: NSVisualEffectView {
  private let viewModel: AboutViewModel

  private let githubURL = URL(string: "https://github.com/ghostty-org/ghostty")
  private let docsURL = URL(string: "https://ghostty.org/docs")

  init(viewModel: AboutViewModel) {
    self.viewModel = viewModel
    super.init(frame: .zero)

    material = .underWindowBackground
    blendingMode = .behindWindow
    state = .active

    let icon = CyclingIconButton(viewModel: viewModel)
    let title = selectableLabel("Ghostty", font: .boldSystemFont(ofSize: 26))
    let tagline = selectableLabel(
      "Fast, native, feature-rich terminal\nemulator pushing modern features.",
      font: .systemFont(ofSize: NSFont.smallSystemFontSize)
    )
    tagline.alignment = .center
    tagline.textColor = .secondaryLabelColor

    let identity = NSStackView(views: [title, tagline])
    identity.orientation = .vertical
    identity.alignment = .centerX
    identity.spacing = 8

    let details = NSStackView()
    details.orientation = .vertical
    details.alignment = .centerX
    details.spacing = 2
    switch versionConfig {
    case .stable(let version):
      details.addArrangedSubview(
        propertyRow(label: "Version", text: version, url: versionConfig.url))
    case .tip:
      details.addArrangedSubview(propertyRow(label: "Version", text: "Tip Release", url: nil))
    case .other(let version):
      details.addArrangedSubview(propertyRow(label: "Version", text: version, url: nil))
    case .none:
      break
    }
    if let build {
      details.addArrangedSubview(propertyRow(label: "Build", text: build, url: nil))
    }
    if let commit, !commit.isEmpty,
      let url = githubURL?.appendingPathComponent("commits/\(commit)")
    {
      details.addArrangedSubview(propertyRow(label: "Commit", text: commit, url: url))
    }

    let links = NSStackView()
    links.orientation = .horizontal
    links.alignment = .centerY
    links.spacing = 8
    if let docsURL {
      links.addArrangedSubview(URLButton(title: "Docs", url: docsURL))
    }
    if let githubURL {
      links.addArrangedSubview(URLButton(title: "GitHub", url: githubURL))
    }

    let content = NSStackView(views: [icon, identity, details, links])
    content.translatesAutoresizingMaskIntoConstraints = false
    content.orientation = .vertical
    content.alignment = .centerX
    content.spacing = 32
    if let copyright {
      let label = selectableLabel(copyright, font: .systemFont(ofSize: NSFont.smallSystemFontSize))
      label.alignment = .center
      label.textColor = .secondaryLabelColor
      content.addArrangedSubview(label)
    }
    addSubview(content)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
      content.topAnchor.constraint(equalTo: topAnchor, constant: 40),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var build: String? {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String
  }

  private var commit: String? {
    Bundle.main.infoDictionary?["GhosttyCommit"] as? String
  }

  private var version: String? {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
  }

  private var copyright: String? {
    Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
  }

  private var versionConfig: VersionConfig { VersionConfig(version: version) }

  private func selectableLabel(_ text: String, font: NSFont) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = font
    label.isSelectable = true
    label.maximumNumberOfLines = 0
    return label
  }

  private func propertyRow(label: String, text: String, url: URL?) -> NSView {
    let key = selectableLabel(label, font: .systemFont(ofSize: NSFont.systemFontSize))
    key.alignment = .right
    key.widthAnchor.constraint(equalToConstant: 126).isActive = true

    let value: NSView
    if let url {
      let button = URLButton(title: text, url: url)
      button.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      button.alignment = .left
      value = button
    } else {
      let field = selectableLabel(
        text,
        font: .monospacedSystemFont(
          ofSize: NSFont.systemFontSize,
          weight: .regular
        ))
      field.textColor = .secondaryLabelColor
      value = field
    }
    value.widthAnchor.constraint(equalToConstant: 125).isActive = true

    let row = NSStackView(views: [key, value])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = 4
    return row
  }

  private enum VersionConfig {
    case stable(version: String)
    case tip(commit: String?)
    case other(String)
    case none

    init(version: String?) {
      guard let version else {
        self = .none
        return
      }
      if version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
        self = .stable(version: version)
      } else if version.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil {
        self = .tip(commit: version)
      } else {
        self = .other(version)
      }
    }

    var url: URL? {
      guard case .stable(let version) = self else { return nil }
      return URL(
        string:
          "https://ghostty.org/docs/install/release-notes/\(version.replacingOccurrences(of: ".", with: "-"))"
      )
    }
  }
}

@MainActor
private final class URLButton: NSButton {
  private let url: URL

  init(title: String, url: URL) {
    self.url = url
    super.init(frame: .zero)
    self.title = title
    bezelStyle = .inline
    target = self
    action = #selector(openURL)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc
  private func openURL() {
    NSWorkspace.shared.open(url)
  }
}

@MainActor
private final class CyclingIconButton: NSButton {
  private weak var viewModel: AboutViewModel?
  private var trackingArea: NSTrackingArea?

  init(viewModel: AboutViewModel) {
    self.viewModel = viewModel
    super.init(frame: .zero)
    isBordered = false
    imagePosition = .imageOnly
    imageScaling = .scaleProportionallyUpOrDown
    target = self
    action = #selector(advanceIcon)
    setAccessibilityLabel("Ghostty Application Icon")
    setAccessibilityHelp("Click to cycle through icon variants")
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 128),
      heightAnchor.constraint(equalToConstant: 128),
    ])
    viewModel.onIconChange = { [weak self] icon in
      self?.updateImage(icon)
    }
    updateImage(viewModel.currentIcon)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    viewModel?.isHovering = true
  }

  override func mouseExited(with event: NSEvent) {
    viewModel?.isHovering = false
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let icon = viewModel?.currentIcon else { return nil }
    let menu = NSMenu()
    let item = NSMenuItem(
      title: "Copy Icon Config", action: #selector(copyIconConfig(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = icon.rawValue
    menu.addItem(item)
    return menu
  }

  @objc
  private func advanceIcon() {
    viewModel?.advanceToNextIcon()
  }

  @objc
  private func copyIconConfig(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? String else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("macos-icon = \(value)", forType: .string)
  }

  private func updateImage(_ icon: Ghostty.MacOSIcon?) {
    if let assetName = icon?.assetName, let image = NSImage(named: assetName) {
      self.image = image
    } else {
      image =
        NSRunningApplication.current.icon
        ?? NSApp.applicationIconImage
        ?? NSImage(named: "AppIconImage")
    }
  }
}
