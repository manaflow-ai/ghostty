import AppKit
import Combine

extension Ghostty {
    /// Native grab handle overlay at the top center of a terminal pane.
    @MainActor
    final class SurfaceGrabHandle: NSView {
        private static let handleSize = CGSize(width: 80, height: 12)
        private static let hoverHeightFactor: CGFloat = 0.2

        private let surfaceView: SurfaceView
        private let dragSource = SurfaceDragSourceView()
        private let ellipsis = NSImageView()
        private var isHovering = false
        private var isDragging = false
        private var cancellables: Set<AnyCancellable> = []

        init(surfaceView: SurfaceView) {
            self.surfaceView = surfaceView
            super.init(frame: .zero)

            dragSource.surfaceView = surfaceView
            dragSource.onDragStateChanged = { [weak self] dragging in
                self?.isDragging = dragging
                self?.refresh()
            }
            dragSource.onHoverChanged = { [weak self] hovering in
                self?.isHovering = hovering
                self?.refresh()
            }
            addSubview(dragSource)

            ellipsis.image = NSImage(
                systemSymbolName: "ellipsis",
                accessibilityDescription: String(localized: "Drag terminal pane")
            )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            ellipsis.imageScaling = .scaleProportionallyDown
            addSubview(ellipsis)

            surfaceView.$cursorVisible
                .combineLatest(surfaceView.$mouseLocationInSurface)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            let size = Self.handleSize
            dragSource.frame = CGRect(
                x: bounds.midX - size.width / 2,
                y: bounds.maxY - size.height,
                width: size.width,
                height: size.height
            )
            ellipsis.frame = CGRect(
                x: dragSource.frame.midX - 12,
                y: dragSource.frame.midY - 8,
                width: 24,
                height: 12
            )
            refresh()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !dragSource.isHidden, dragSource.frame.contains(point) else { return nil }
            return dragSource.hitTest(convert(point, to: dragSource))
        }

        func refresh() {
            dragSource.isHidden = !handleVisible
            let visible = handleVisible && ellipsisVisible
            ellipsis.isHidden = !visible
            ellipsis.alphaValue = isHovering ? 0.8 : 0.3
        }

        private var handleVisible: Bool {
            guard let window = surfaceView.window else { return true }
            guard window.styleMask.contains(.fullScreen) else { return true }
            guard let controller = window.windowController as? BaseTerminalController else { return false }
            return controller.surfaceTree.isSplit
        }

        private var ellipsisVisible: Bool {
            guard surfaceView.cursorVisible else { return false }
            if isHovering || isDragging { return true }
            guard let location = surfaceView.mouseLocationInSurface else { return false }
            return Self.hoverRect(in: surfaceView.bounds).contains(location)
        }

        private static func hoverRect(in bounds: CGRect) -> CGRect {
            guard !bounds.isEmpty else { return .zero }
            let height = min(bounds.height, max(handleSize.height, bounds.height * hoverHeightFactor))
            return CGRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
        }
    }
}
