import AppKit

enum TerminalSplitOperation {
    case resize(Resize)
    case drop(Drop)

    struct Resize {
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let ratio: Double
    }

    struct Drop {
        let payload: Ghostty.SurfaceView
        let destination: Ghostty.SurfaceView
        let zone: TerminalSplitDropZone
    }
}

/// Native AppKit renderer for Ghostty's immutable split tree.
@MainActor
final class TerminalSplitTreeView: NSView {
    private let ghostty: Ghostty.App
    private let action: (TerminalSplitOperation) -> Void
    fileprivate var rootNodeView: TerminalSplitNodeView?

    init(
        ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        action: @escaping (TerminalSplitOperation) -> Void
    ) {
        self.ghostty = ghostty
        self.action = action
        super.init(frame: .zero)
        update(tree: tree)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(tree: SplitTree<Ghostty.SurfaceView>) {
        guard let node = tree.zoomed ?? tree.root else {
            rootNodeView?.removeFromSuperview()
            rootNodeView = nil
            return
        }

        if let rootNodeView, rootNodeView.update(node: node, isRoot: node == tree.root) {
            return
        }

        rootNodeView?.removeFromSuperview()
        let rootNodeView = TerminalSplitNodeView(
            ghostty: ghostty,
            node: node,
            isRoot: node == tree.root,
            action: action
        )
        rootNodeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootNodeView)
        NSLayoutConstraint.activate([
            rootNodeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootNodeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootNodeView.topAnchor.constraint(equalTo: topAnchor),
            rootNodeView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.rootNodeView = rootNodeView
    }
}

@MainActor
fileprivate final class TerminalSplitNodeView: NSView {
    private let ghostty: Ghostty.App
    private let action: (TerminalSplitOperation) -> Void
    private var node: SplitTree<Ghostty.SurfaceView>.Node
    private var isRoot: Bool
    private var renderedView: NSView!
    private var leftNodeView: TerminalSplitNodeView?
    private var rightNodeView: TerminalSplitNodeView?

    init(
        ghostty: Ghostty.App,
        node: SplitTree<Ghostty.SurfaceView>.Node,
        isRoot: Bool,
        action: @escaping (TerminalSplitOperation) -> Void
    ) {
        self.ghostty = ghostty
        self.node = node
        self.isRoot = isRoot
        self.action = action
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(node: SplitTree<Ghostty.SurfaceView>.Node, isRoot: Bool) -> Bool {
        guard self.node.structuralIdentity == node.structuralIdentity else { return false }
        self.node = node
        self.isRoot = isRoot

        switch (node, renderedView) {
        case (.leaf, let leaf as TerminalSplitLeafView):
            leaf.update(isSplit: !isRoot)
            return true

        case (.split(let split), let splitView as SplitView):
            guard
                let leftNodeView,
                let rightNodeView,
                leftNodeView.update(node: split.left, isRoot: false),
                rightNodeView.update(node: split.right, isRoot: false)
            else { return false }
            splitView.update(split: CGFloat(split.ratio), dividerColor: ghostty.config.splitDividerColor)
            return true

        default:
            return false
        }
    }

    private func build() {
        switch node {
        case .leaf(let surfaceView):
            renderedView = TerminalSplitLeafView(
                ghostty: ghostty,
                surfaceView: surfaceView,
                isSplit: !isRoot,
                action: action
            )

        case .split(let split):
            let left = TerminalSplitNodeView(
                ghostty: ghostty,
                node: split.left,
                isRoot: false,
                action: action
            )
            let right = TerminalSplitNodeView(
                ghostty: ghostty,
                node: split.right,
                isRoot: false,
                action: action
            )
            leftNodeView = left
            rightNodeView = right
            renderedView = SplitView(
                split.direction == .horizontal ? .horizontal : .vertical,
                split: CGFloat(split.ratio),
                dividerColor: ghostty.config.splitDividerColor,
                left: left,
                right: right,
                onResize: { [weak self] ratio in
                    guard let self else { return }
                    self.action(.resize(.init(node: self.node, ratio: ratio)))
                },
                onEqualize: { [weak self] in
                    guard
                        let self,
                        let surface = self.node.leftmostLeaf().surface
                    else { return }
                    self.ghostty.splitEqualize(surface: surface)
                }
            )
        }

        renderedView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(renderedView)
        NSLayoutConstraint.activate([
            renderedView.leadingAnchor.constraint(equalTo: leadingAnchor),
            renderedView.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderedView.topAnchor.constraint(equalTo: topAnchor),
            renderedView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

@MainActor
private final class TerminalSplitLeafView: NSView {
    private let surfaceView: Ghostty.SurfaceView
    private let action: (TerminalSplitOperation) -> Void
    private let contentView: Ghostty.InspectableSurfaceView
    private let dropOverlay = NSView()
    private var dropZone: TerminalSplitDropZone?
    private var isSelfDragging = false

    init(
        ghostty: Ghostty.App,
        surfaceView: Ghostty.SurfaceView,
        isSplit: Bool,
        action: @escaping (TerminalSplitOperation) -> Void
    ) {
        self.surfaceView = surfaceView
        self.action = action
        self.contentView = Ghostty.InspectableSurfaceView(
            ghostty: ghostty,
            surfaceView: surfaceView,
            isSplit: isSplit
        )
        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        dropOverlay.wantsLayer = true
        dropOverlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        dropOverlay.isHidden = true
        addSubview(dropOverlay, positioned: .above, relativeTo: contentView)

        registerForDraggedTypes([.ghosttySurfaceId])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dragStateDidChange(_:)),
            name: .ghosttySurfaceDragDidChange,
            object: surfaceView
        )
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Terminal pane"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        updateDropOverlayFrame()
    }

    func update(isSplit: Bool) {
        // A leaf's split state only changes with a structural rebuild, so the
        // existing native content remains valid here.
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDragging(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDragging(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropOverlay()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !isSelfDragging && draggedSurface(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let source = draggedSurface(from: sender),
            source !== surfaceView
        else {
            clearDropOverlay()
            return false
        }
        let zone = dropZone ?? dropZone(at: sender.draggingLocation)
        clearDropOverlay()
        action(.drop(.init(payload: source, destination: surfaceView, zone: zone)))
        return true
    }

    private func updateDragging(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard
            !isSelfDragging,
            let source = draggedSurface(from: sender),
            source !== surfaceView
        else {
            clearDropOverlay()
            return []
        }
        dropZone = dropZone(at: sender.draggingLocation)
        dropOverlay.isHidden = false
        updateDropOverlayFrame()
        return .move
    }

    private func draggedSurface(from sender: NSDraggingInfo) -> Ghostty.SurfaceView? {
        guard
            let data = sender.draggingPasteboard.data(forType: .ghosttySurfaceId),
            data.count == MemoryLayout<uuid_t>.size
        else { return nil }
        let uuid = data.withUnsafeBytes { $0.loadUnaligned(as: UUID.self) }
        return Ghostty.SurfaceView.find(uuid: uuid)
    }

    private func dropZone(at windowPoint: CGPoint) -> TerminalSplitDropZone {
        let point = convert(windowPoint, from: nil)
        let topOriginPoint = CGPoint(x: point.x, y: bounds.height - point.y)
        return TerminalSplitDropZone.calculate(at: topOriginPoint, in: bounds.size)
    }

    private func updateDropOverlayFrame() {
        guard let dropZone else { return }
        dropOverlay.frame = switch dropZone {
        case .top: CGRect(x: 0, y: bounds.midY, width: bounds.width, height: bounds.height / 2)
        case .bottom: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2)
        case .left: CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        case .right: CGRect(x: bounds.midX, y: 0, width: bounds.width / 2, height: bounds.height)
        }
    }

    private func clearDropOverlay() {
        dropZone = nil
        dropOverlay.isHidden = true
    }

    @objc private func dragStateDidChange(_ notification: Foundation.Notification) {
        isSelfDragging = notification.userInfo?[Foundation.Notification.Name.ghosttySurfaceDragStateKey] as? Bool ?? false
        if isSelfDragging { clearDropOverlay() }
    }
}

enum TerminalSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right

    static func calculate(at point: CGPoint, in size: CGSize) -> TerminalSplitDropZone {
        let relativeX = point.x / size.width
        let relativeY = point.y / size.height
        let left = relativeX
        let right = 1 - relativeX
        let top = relativeY
        let bottom = 1 - relativeY
        let minimum = min(left, right, top, bottom)

        if minimum == left { return .left }
        if minimum == right { return .right }
        if minimum == top { return .top }
        return .bottom
    }
}
