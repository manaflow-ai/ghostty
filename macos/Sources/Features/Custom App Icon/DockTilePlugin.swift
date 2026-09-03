@preconcurrency import AppKit

@MainActor
class DockTilePlugin: NSObject, @preconcurrency NSDockTilePlugIn {
    // WARNING: An instance of this class is alive as long as Ghostty's icon is
    // in the doc (running or not!), so keep any state and processing to a
    // minimum to respect resource usage.

    private let pluginBundle = Bundle(for: DockTilePlugin.self)

    // Separate defaults based on debug vs release builds so we can test icons
    // without messing up releases.
    #if DEBUG
    private let ghosttyUserDefaults = UserDefaults(suiteName: "com.mitchellh.ghostty.debug")
    #else
    private let ghosttyUserDefaults = UserDefaults(suiteName: "com.mitchellh.ghostty")
    #endif

    private var iconChangeObserver: NSObjectProtocol?
    private weak var dockTile: NSDockTile?

    /// The primary NSDockTilePlugin function.
    func setDockTile(_ dockTile: NSDockTile?) {
        if let iconChangeObserver {
            DistributedNotificationCenter.default().removeObserver(iconChangeObserver)
            self.iconChangeObserver = nil
        }

        // If no dock tile or no access to Ghostty defaults, we can't do anything.
        guard let dockTile, let ghosttyUserDefaults else {
            self.dockTile = nil
            return
        }
        self.dockTile = dockTile

        // Try to restore the previous icon on launch.
        iconDidChange(ghosttyUserDefaults.appIcon, dockTile: dockTile)

        // Setup a new observer for when the icon changes so we can update. This message
        // is sent by the primary Ghostty app.
        iconChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: .ghosttyIconDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let dockTile = self.dockTile else { return }
                self.iconDidChange(self.ghosttyUserDefaults?.appIcon, dockTile: dockTile)
            }
        }
    }

    private func iconDidChange(_ newIcon: AppIcon?, dockTile: NSDockTile) {
        guard let appIcon = newIcon?.image(in: pluginBundle) else {
            resetIcon(dockTile: dockTile)
            return
        }

        dockTile.setIcon(appIcon)
    }

    /// Reset the application icon and dock tile icon to the default.
    private func resetIcon(dockTile: NSDockTile) {
        let appIcon: NSImage?
        if #available(macOS 26.0, *) {
            #if DEBUG
            // Use the `Blueprint` icon to distinguish Debug from Release builds.
            appIcon = pluginBundle.image(forResource: "BlueprintImage")!
            #else
            // Reset to Ghostty.icon
            appIcon = nil
            #endif
        } else {
            // Use the bundled icon to keep the corner radius consistent with pre-Tahoe apps.
            appIcon = pluginBundle.image(forResource: "AppIconImage")!
        }
        dockTile.setIcon(appIcon)
    }
}

private extension NSDockTile {
    func setIcon(_ newIcon: NSImage?) {
        guard let newIcon else {
            contentView = nil
            self.display()
            return
        }
        let iconView = NSImageView(frame: CGRect(origin: .zero, size: size))
        iconView.wantsLayer = true
        iconView.image = newIcon
        contentView = iconView
        display()
    }
}
