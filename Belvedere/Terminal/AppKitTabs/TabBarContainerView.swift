import AppKit

/// Sits in the position of the macOS titlebar (window has hiddenTitleBar
/// style). Holds equal-width tab cells across the full window width,
/// padded on the left to clear the traffic-light buttons. Matches
/// Ghostty's tab strip 1:1: equal distribution, no separators, no fixed
/// width, no permanent close affordance.
final class TabBarContainerView: NSView {

    private enum Const {
        /// Total height of the bar.
        static let height: CGFloat = 32
        /// Trailing slot for the "+" button.
        static let plusWidth: CGFloat = 28
    }

    var tabs: [TabCellView.Model] = [] {
        didSet {
            guard tabs != oldValue else { return }
            rebuildCells()
        }
    }

    var onActivate: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?

    private let background = NSVisualEffectView()
    private let stack = NSStackView()
    private let plusButton = NSButton()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setupBackground()
        setupStack()
        setupPlusButton()
        setupConstraints()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupBackground() {
        background.material = .titlebar
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
    }

    private func setupStack() {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        // Equal-width distribution is what gives Ghostty's tabs their
        // recognisable "share the bar evenly" look.
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
    }

    private func setupPlusButton() {
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        plusButton.bezelStyle = .smallSquare
        plusButton.isBordered = false
        plusButton.title = ""
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")?
            .withSymbolConfiguration(config)
        plusButton.imagePosition = .imageOnly
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.target = self
        plusButton.action = #selector(plusTapped)
        plusButton.toolTip = "New terminal (⌘T)"
        addSubview(plusButton)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: Const.plusWidth),
            plusButton.heightAnchor.constraint(equalToConstant: 22),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Const.height)
    }

    // MARK: - Cells

    private func rebuildCells() {
        var existing: [UUID: TabCellView] = [:]
        for view in stack.arrangedSubviews {
            if let cell = view as? TabCellView { existing[cell.modelID] = cell }
        }

        var keep: [UUID: TabCellView] = [:]
        for model in tabs {
            let cell: TabCellView
            if let reused = existing[model.id] {
                reused.update(model: model)
                cell = reused
            } else {
                cell = TabCellView(model: model)
                cell.onActivate = { [weak self] id in
                    // Optimistic: instantly re-style cells so the click
                    // feels native. The SwiftUI cycle catches up after,
                    // by which point the cells already match its state.
                    self?.optimisticallyActivate(id)
                    self?.onActivate?(id)
                }
                cell.onClose = { [weak self] id in self?.onClose?(id) }
                cell.translatesAutoresizingMaskIntoConstraints = false
            }
            keep[model.id] = cell
        }

        for (id, cell) in existing where keep[id] == nil {
            stack.removeArrangedSubview(cell)
            cell.removeFromSuperview()
        }

        let ordered = tabs.compactMap { keep[$0.id] }
        for (index, cell) in ordered.enumerated() {
            if stack.arrangedSubviews.indices.contains(index),
               stack.arrangedSubviews[index] === cell {
                continue
            }
            if cell.superview != nil {
                stack.removeArrangedSubview(cell)
                cell.removeFromSuperview()
            }
            stack.insertArrangedSubview(cell, at: index)
        }
    }

    @objc private func plusTapped() {
        onNewTab?()
    }

    private func optimisticallyActivate(_ id: UUID) {
        for view in stack.arrangedSubviews {
            guard let cell = view as? TabCellView else { continue }
            cell.setActive(cell.modelID == id)
        }
    }
}
