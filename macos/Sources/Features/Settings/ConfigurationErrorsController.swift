import AppKit

@MainActor
final class ConfigurationErrorsController: NSWindowController, NSWindowDelegate {
    static let sharedInstance = ConfigurationErrorsController()

    override var windowNibName: NSNib.Name? { "ConfigurationErrors" }

  var errors: [String] = [] {
        didSet {
      errorsView?.update(errors: errors)
      if errors.isEmpty {
        window?.performClose(nil)
            }
        }
    }

  private weak var errorsView: ConfigurationErrorsView?

    override func windowWillLoad() {
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
    guard let window else { return }
    let content = ConfigurationErrorsView()
    content.onIgnore = { [weak self] in self?.errors = [] }
    content.onReload = {
      guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
      delegate.reloadConfig(nil)
    }
    content.update(errors: errors)
    errorsView = content

    window.contentView = content
    window.setContentSize(NSSize(width: 640, height: 360))
        window.center()
        window.level = .popUpMenu
        window.titlebarAppearsTransparent = true
    }
}
