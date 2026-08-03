import AppKit

@MainActor
final class AboutController: NSWindowController, NSWindowDelegate {
  static let shared = AboutController()

    private let viewModel = AboutViewModel()
    override var windowNibName: NSNib.Name? { "About" }

    override func windowDidLoad() {
    guard let window else { return }
    let content = AboutView(viewModel: viewModel)
    window.contentView = content
    window.setContentSize(content.fittingSize)
        window.center()
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        viewModel.startCyclingIcons()
    }

    func hide() {
        window?.close()
    }

  @IBAction
  func close(_ sender: Any) {
    window?.performClose(sender)
    }

  @IBAction
  func closeWindow(_ sender: Any) {
    window?.performClose(sender)
    }

  @objc
  func cancel(_ sender: Any?) {
    window?.performClose(sender)
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.stopCyclingIcons()
    }
}
