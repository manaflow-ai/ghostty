import AppKit
import Sparkle

@MainActor
final class UpdatePopoverContentView: NSView, UpdateViewModelObserver {
    private let model: UpdateViewModel
    private let onDismiss: () -> Void

    init(model: UpdateViewModel, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 1))
        model.addObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        guard let content = subviews.first else { return NSSize(width: 300, height: 1) }
        return NSSize(width: 300, height: max(1, content.fittingSize.height + 32))
    }

    func updateViewModelDidChange(_ model: UpdateViewModel) {
        rebuild()
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        switch model.state {
        case .idle:
            content = NSView()
        case .permissionRequest(let request):
            content = permissionRequestView(request)
        case .checking(let checking):
            content = checkingView(checking)
        case .updateAvailable(let update):
            content = updateAvailableView(update)
        case .downloading(let download):
            content = downloadingView(download)
        case .extracting(let extracting):
            content = extractingView(extracting)
        case .installing(let installing):
            content = installingView(installing)
        case .notFound(let notFound):
            content = notFoundView(notFound)
        case .error(let error):
            content = errorView(error)
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 300),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        invalidateIntrinsicContentSize()
        layoutSubtreeIfNeeded()
    }

    private func permissionRequestView(_ request: UpdateState.PermissionRequest) -> NSView {
        verticalStack([
            textGroup(
                title: String(localized: "Enable automatic updates?"),
                detail: String(localized: "Ghostty can automatically check for updates in the background.")
            ),
            actionRow([
                button(String(localized: "Not Now"), keyEquivalent: "\u{1b}") {
                    request.reply(.init(automaticUpdateChecks: false, sendSystemProfile: false))
                    self.onDismiss()
                },
                flexibleSpace(),
                button(String(localized: "Allow"), keyEquivalent: "\r") {
                    request.reply(.init(automaticUpdateChecks: true, sendSystemProfile: false))
                    self.onDismiss()
                },
            ]),
        ])
    }

    private func checkingView(_ checking: UpdateState.Checking) -> NSView {
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        let status = actionRow([progress, label(String(localized: "Checking for updates…"), size: 13)])
        return verticalStack([
            status,
            actionRow([
                flexibleSpace(),
                button(String(localized: "Cancel"), keyEquivalent: "\u{1b}") {
                    checking.cancel()
                    self.onDismiss()
                },
            ]),
        ])
    }

    private func updateAvailableView(_ update: UpdateState.UpdateAvailable) -> NSView {
        var rows: [[NSView]] = [[
            detailLabel(String(localized: "Version:"), alignment: .right),
            selectableLabel(update.appcastItem.displayVersionString),
        ]]
        if update.appcastItem.contentLength > 0 {
            rows.append([
                detailLabel(String(localized: "Size:"), alignment: .right),
                selectableLabel(ByteCountFormatter.string(
                    fromByteCount: Int64(update.appcastItem.contentLength), countStyle: .file
                )),
            ])
        }
        if let date = update.appcastItem.date {
            rows.append([
                detailLabel(String(localized: "Released:"), alignment: .right),
                selectableLabel(date.formatted(date: .abbreviated, time: .omitted)),
            ])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
        grid.columnSpacing = 6
        grid.column(at: 0).width = 60

        var views: [NSView] = [
            label(String(localized: "Update Available"), size: 13, weight: .semibold),
            grid,
            actionRow([
                button(String(localized: "Skip")) {
                    update.reply(.skip)
                    self.onDismiss()
                },
                button(String(localized: "Later"), keyEquivalent: "\u{1b}") {
                    update.reply(.dismiss)
                    self.onDismiss()
                },
                flexibleSpace(),
                button(String(localized: "Install and Relaunch"), keyEquivalent: "\r") {
                    update.reply(.install)
                    self.onDismiss()
                },
            ]),
        ]

        if let notes = update.releaseNotes {
            views.append(separator())
            let notesButton = button(notes.label) {
                NSWorkspace.shared.open(notes.url)
            }
            notesButton.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            notesButton.imagePosition = .imageLeading
            notesButton.alignment = .left
            views.append(notesButton)
        }
        return verticalStack(views)
    }

    private func downloadingView(_ download: UpdateState.Downloading) -> NSView {
        let progress = NSProgressIndicator()
        progress.controlSize = .small
        var progressViews: [NSView] = [progress]
        if let expectedLength = download.expectedLength, expectedLength > 0 {
            let value = min(1, max(0, Double(download.progress) / Double(expectedLength)))
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            progress.doubleValue = value
            progressViews.append(detailLabel(String(format: "%.0f%%", value * 100)))
        } else {
            progress.style = .spinning
            progress.isIndeterminate = true
            progress.startAnimation(nil)
        }
        return verticalStack([
            label(String(localized: "Downloading Update"), size: 13, weight: .semibold),
            verticalStack(progressViews, spacing: 6),
            actionRow([
                flexibleSpace(),
                button(String(localized: "Cancel"), keyEquivalent: "\u{1b}") {
                    download.cancel()
                    self.onDismiss()
                },
            ]),
        ])
    }

    private func extractingView(_ extracting: UpdateState.Extracting) -> NSView {
        let value = min(1, max(0, extracting.progress))
        let progress = NSProgressIndicator()
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = value
        return verticalStack([
            label(String(localized: "Preparing Update"), size: 13, weight: .semibold),
            progress,
            detailLabel(String(format: "%.0f%%", value * 100)),
        ], spacing: 8)
    }

    private func installingView(_ installing: UpdateState.Installing) -> NSView {
        verticalStack([
            textGroup(
                title: String(localized: "Restart Required"),
                detail: String(localized: "The update is ready. Please restart the application to complete the installation.")
            ),
            actionRow([
                button(String(localized: "Restart Later"), keyEquivalent: "\u{1b}") {
                    installing.dismiss()
                    self.onDismiss()
                },
                flexibleSpace(),
                button(String(localized: "Restart Now"), keyEquivalent: "\r") {
                    installing.retryTerminatingApplication()
                    self.onDismiss()
                },
            ]),
        ])
    }

    private func notFoundView(_ notFound: UpdateState.NotFound) -> NSView {
        verticalStack([
            textGroup(
                title: String(localized: "No Updates Found"),
                detail: String(localized: "You're already running the latest version.")
            ),
            actionRow([
                flexibleSpace(),
                button(String(localized: "OK"), keyEquivalent: "\r") {
                    notFound.acknowledgement()
                    self.model.state = .idle
                    self.onDismiss()
                },
            ]),
        ])
    }

    private func errorView(_ error: UpdateState.Error) -> NSView {
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = .systemOrange
        return verticalStack([
            actionRow([
                icon,
                label(String(localized: "Update Failed"), size: 13, weight: .semibold),
            ]),
            detailLabel(error.error.localizedDescription),
            actionRow([
                button(String(localized: "OK"), keyEquivalent: "\u{1b}") {
                    error.dismiss()
                    self.onDismiss()
                },
                flexibleSpace(),
                button(String(localized: "Retry"), keyEquivalent: "\r") {
                    error.retry()
                    self.onDismiss()
                },
            ]),
        ])
    }

    private func textGroup(title: String, detail: String) -> NSView {
        verticalStack([
            label(title, size: 13, weight: .semibold),
            detailLabel(detail),
        ], spacing: 8)
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat = 16) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func actionRow(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func detailLabel(
        _ text: String,
        alignment: NSTextAlignment = .left
    ) -> NSTextField {
        let field = label(text, size: 11)
        field.textColor = .secondaryLabelColor
        field.alignment = alignment
        return field
    }

    private func selectableLabel(_ text: String) -> NSTextField {
        let field = detailLabel(text)
        field.isSelectable = true
        field.textColor = .labelColor
        return field
    }

    private func button(
        _ title: String,
        keyEquivalent: String = "",
        action: @escaping () -> Void
    ) -> UpdateCallbackButton {
        let button = UpdateCallbackButton(title: title, action: action)
        button.controlSize = .small
        button.keyEquivalent = keyEquivalent
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

@MainActor
private final class UpdateCallbackButton: NSButton {
    private let callback: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.callback = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(performAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performAction() {
        callback()
    }
}
