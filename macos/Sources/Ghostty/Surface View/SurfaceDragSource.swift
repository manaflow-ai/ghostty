import AppKit

extension Ghostty {
    /// Native drag source for moving a terminal surface between split positions.
    @MainActor
    final class SurfaceDragSourceView: NSView, NSDraggingSource {
        private static let previewScale: CGFloat = 0.2

        var surfaceView: SurfaceView?
        var onDragStateChanged: ((Bool) -> Void)?
        var onHoverChanged: ((Bool) -> Void)?

        private var isTracking = false
        private var escapeMonitor: Any?
        private var dragCancelledByEscape = false

        deinit {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // Consume the event so window dragging does not steal the pane drag.
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self,
                userInfo: nil
            ))
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: isTracking ? .closedHand : .openHand)
        }

        override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
        override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

        override func mouseDragged(with event: NSEvent) {
            guard !isTracking, let surfaceView else { return }
            guard let pasteboardItem = surfaceView.pasteboardItem() else { return }
            let item = NSDraggingItem(pasteboardWriter: pasteboardItem)

            if let snapshot = surfaceView.asImage {
                let imageSize = NSSize(
                    width: snapshot.size.width * Self.previewScale,
                    height: snapshot.size.height * Self.previewScale
                )
                let scaledImage = NSImage(size: imageSize)
                scaledImage.lockFocus()
                snapshot.draw(
                    in: NSRect(origin: .zero, size: imageSize),
                    from: NSRect(origin: .zero, size: snapshot.size),
                    operation: .copy,
                    fraction: 1
                )
                scaledImage.unlockFocus()

                let mouseLocation = convert(event.locationInWindow, from: nil)
                item.setDraggingFrame(
                    NSRect(
                        x: mouseLocation.x - imageSize.width / 2,
                        y: mouseLocation.y - imageSize.height / 2,
                        width: imageSize.width,
                        height: imageSize.height
                    ),
                    contents: scaledImage
                )
            }

            setDragging(true)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = false
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            isTracking = true
            dragCancelledByEscape = false
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.dragCancelledByEscape = true }
                return event
            }
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            NSCursor.closedHand.set()
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }

            if operation == [], !dragCancelledByEscape {
                let endsInWindow = NSApplication.shared.windows.contains { window in
                    window.isVisible && window.frame.contains(screenPoint)
                }
                if !endsInWindow {
                    NotificationCenter.default.post(
                        name: .ghosttySurfaceDragEndedNoTarget,
                        object: surfaceView,
                        userInfo: [
                            Foundation.Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey: screenPoint
                        ]
                    )
                }
            }

            isTracking = false
            setDragging(false)
        }

        private func setDragging(_ dragging: Bool) {
            onDragStateChanged?(dragging)
            NotificationCenter.default.post(
                name: .ghosttySurfaceDragDidChange,
                object: surfaceView,
                userInfo: [Foundation.Notification.Name.ghosttySurfaceDragStateKey: dragging]
            )
        }
    }
}

extension Notification.Name {
    static let ghosttySurfaceDragDidChange = Notification.Name("ghosttySurfaceDragDidChange")
    static let ghosttySurfaceDragStateKey = "dragging"
    static let ghosttySurfaceDragEndedNoTarget = Notification.Name("ghosttySurfaceDragEndedNoTarget")
    static let ghosttySurfaceDragEndedNoTargetPointKey = "endedAtPoint"
}
