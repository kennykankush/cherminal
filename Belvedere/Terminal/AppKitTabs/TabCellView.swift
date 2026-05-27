import AppKit

/// One AppKit-rendered tab cell, styled to match Ghostty's native
/// titlebar tabs: centered title, no permanent badge or close button,
/// subtle background fill when active.
final class TabCellView: NSView {

    struct Model: Equatable {
        let id: UUID
        let title: String
        let isActive: Bool
    }

    private var model: Model
    private var isHovering = false

    var onActivate: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?

    var modelID: UUID { model.id }

    // MARK: - Layers

    private let backgroundLayer = CALayer()
    private let titleLayer = CATextLayer()
    private let closeLayer = CATextLayer()
    private let closeHitView = NSView()

    private var trackingArea: NSTrackingArea?

    init(model: Model) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = false

        guard let root = layer else { return }
        root.addSublayer(backgroundLayer)
        root.addSublayer(titleLayer)
        root.addSublayer(closeLayer)
        addSubview(closeHitView)

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        titleLayer.contentsScale = scale
        titleLayer.alignmentMode = .center
        titleLayer.truncationMode = .middle
        closeLayer.contentsScale = scale
        closeLayer.alignmentMode = .center

        apply(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(model: Model) {
        self.model = model
        apply(animated: true)
    }

    /// Flip the active state immediately without waiting for the SwiftUI
    /// → updateNSView roundtrip. Used by the bar's optimistic-click path
    /// so a click feels instant.
    func setActive(_ active: Bool) {
        guard model.isActive != active else { return }
        model = Model(id: model.id, title: model.title, isActive: active)
        apply(animated: false)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        backgroundLayer.frame = bounds

        // Close button is anchored to the left, only visible on hover.
        let closeSize: CGFloat = 14
        let closeY = (h - closeSize) / 2
        closeLayer.frame = NSRect(x: 8, y: closeY, width: closeSize, height: closeSize)
        closeHitView.frame = NSRect(x: 4, y: closeY - 2, width: closeSize + 8, height: closeSize + 4)

        // Title spans the full width so it centers properly inside the cell.
        // We deliberately don't reserve close-button space — the close icon
        // floats on top so the title doesn't shift when it appears.
        let titleHeight: CGFloat = 16
        titleLayer.frame = NSRect(x: 16, y: (h - titleHeight) / 2 - 1,
                                   width: bounds.width - 32, height: titleHeight)
    }

    // MARK: - Apply

    private func apply(animated: Bool) {
        let run = {
            self.backgroundLayer.backgroundColor = self.backgroundColor.cgColor
            self.titleLayer.string = self.attributedTitle()
            self.closeLayer.opacity = self.isHovering ? 1 : 0
            self.closeLayer.string = self.attributedClose()
        }
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.10)
            run()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            run()
            CATransaction.commit()
        }
    }

    private var backgroundColor: NSColor {
        if model.isActive {
            // Subtle lighter overlay — Ghostty's active-tab treatment.
            return NSColor.labelColor.withAlphaComponent(0.10)
        }
        if isHovering {
            return NSColor.labelColor.withAlphaComponent(0.05)
        }
        return .clear
    }

    private func attributedTitle() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        para.alignment = .center
        let weight: NSFont.Weight = model.isActive ? .medium : .regular
        let color: NSColor = model.isActive ? .labelColor : .secondaryLabelColor
        return NSAttributedString(string: model.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: para
        ])
    }

    private func attributedClose() -> NSAttributedString {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let attachment = NSTextAttachment()
        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            attachment.image = image
        }
        let mut = NSMutableAttributedString(attachment: attachment)
        mut.addAttributes([.foregroundColor: NSColor.secondaryLabelColor],
                          range: NSRange(location: 0, length: mut.length))
        return mut
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        apply(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        apply(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isHovering, closeHitView.frame.contains(point) {
            onClose?(model.id)
        } else {
            onActivate?(model.id)
        }
    }
}
