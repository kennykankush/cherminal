import AppKit
import GhosttyKit
import QuartzCore
import Darwin

// ─────────────────────────────────────────────────────────────────────────────
// CANVAS v2 — ENGINE  (branch v2/genesis)
//
// First-principles foundation: the canvas is ONE owned transform,
//
//     screen = world · zoom + pan
//
// and that is the single source of truth. No NSScrollView, no NSView frame/bounds
// scaling — those let AppKit's geometry (axis-locked scroll, auto-scroll-to-focus,
// momentum, magnify routing) leak in as "wonk". Here WE own (pan, zoom); nodes are
// direct subviews positioned by projecting their worldFrame; pan/zoom are pure
// arithmetic. Terminals are FIXED SIZE and crisp (zoom is parked at 1:1 for now —
// the crisp text-tile zoom-out overview is the next beat). Placement is a GRID with
// magic-cursor drop + snap-on-release.
//
// Launch:  CANVAS_V2=1 [CANVAS_V2_BENCH=1] CherminalDev
// ─────────────────────────────────────────────────────────────────────────────

enum CanvasV2 {
    private(set) static var controller: CanvasController?
    @MainActor
    static func launch(ghostty: Ghostty.App, attempt: Int = 0) {
        guard let app = ghostty.app else {
            if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    MainActor.assumeIsolated { launch(ghostty: ghostty, attempt: attempt + 1) }
                }
            } else { NSLog("[canvas] no ghostty app handle — aborting") }
            return
        }
        let c = CanvasController(ghosttyApp: app)
        controller = c
        c.show()
        CanvasLog.line("canvas v2 launched — keys: n/N nodes · s stream · p auto-pan · m motion-freeze · f center · [ ] budget · b bench")
        if ProcessInfo.processInfo.environment["CANVAS_V2_BENCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { c.runBenchmark() }
            }
        }
    }
}

// MARK: - Engine view (the canvas: owns the transform; nodes are direct subviews)

@MainActor
final class CanvasEngineView: NSView {
    private(set) var nodes: [CanvasNode] = []
    private(set) var activeID: UUID?
    var liveBudget = 20
    let prefetch: CGFloat = 600
    var freezeOnMotion = true

    // The owned transform (single source of truth).
    private(set) var zoom: CGFloat = 1.0
    private(set) var pan: CGPoint = .zero
    let minZoom: CGFloat = 0.15
    let maxZoom: CGFloat = 1.0              // never zoom IN past native (no upscale blur)
    private let liveZoom: CGFloat = 0.97   // below this, terminals are tiles (no live surface → no reflow)

    // Layout
    let cardSize = CGSize(width: 460, height: 320)
    let gap: CGFloat = 56
    private let snapThreshold: CGFloat = 8        // magnetic-snap distance (world px)
    private let guideLayer = CAShapeLayer()       // alignment guide lines, drawn on top

    private var dirty = false
    private var lastChange: CFTimeInterval = 0
    private var panAnchorScreen: CGPoint = .zero
    private var panAnchorValue: CGPoint = .zero
    private var dragAnchorWorld: CGPoint = .zero
    private var dragAnchorFrame: CGRect = .zero

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
        guideLayer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        guideLayer.lineWidth = 1
        guideLayer.fillColor = nil
        guideLayer.zPosition = 10_000            // above every node layer
        layer?.addSublayer(guideLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Transform

    func project(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * zoom + pan.x, y: r.minY * zoom + pan.y, width: r.width * zoom, height: r.height * zoom)
    }
    func screenToWorld(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - pan.x) / zoom, y: (p.y - pan.y) / zoom) }
    private func reproject() { for n in nodes { n.view.frame = project(n.worldFrame) } }
    private func reprojectNode(_ n: CanvasNode) { n.view.frame = project(n.worldFrame) }
    var visibleWorldRect: CGRect {
        CGRect(x: -pan.x / zoom, y: -pan.y / zoom, width: bounds.width / zoom, height: bounds.height / zoom)
    }

    // MARK: Pan (empty-space drag + trackpad scroll = free 2D, no axis lock)

    override func mouseDown(with e: NSEvent) {
        panAnchorScreen = convert(e.locationInWindow, from: nil)
        panAnchorValue = pan
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with e: NSEvent) {
        let now = convert(e.locationInWindow, from: nil)
        pan = CGPoint(x: panAnchorValue.x + (now.x - panAnchorScreen.x),
                      y: panAnchorValue.y + (now.y - panAnchorScreen.y))
        reproject(); markDirty()
    }
    override func mouseUp(with e: NSEvent) { NSCursor.arrow.set() }
    override func scrollWheel(with e: NSEvent) {
        pan = CGPoint(x: pan.x + e.scrollingDeltaX, y: pan.y + e.scrollingDeltaY)
        reproject(); markDirty()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    func panBy(_ dx: CGFloat, _ dy: CGFloat) { pan = CGPoint(x: pan.x + dx, y: pan.y + dy); reproject(); markDirty() }

    /// Zoom by `factor` anchored at screen point `p` (the world point under the
    /// cursor stays put). Snaps to crisp 1:1 near the top so you land in work mode.
    func zoomBy(_ factor: CGFloat, atScreen p: CGPoint) {
        let worldPt = screenToWorld(p)
        var nz = min(max(zoom * factor, minZoom), maxZoom)
        if nz > 0.95 { nz = 1.0 }
        zoom = nz
        pan = CGPoint(x: p.x - worldPt.x * nz, y: p.y - worldPt.y * nz)
        reproject(); markDirty()
    }

    /// Pan so a world point sits at the viewport centre (keeps zoom).
    func centerViewport(on w: CGPoint) {
        pan = CGPoint(x: bounds.midX - w.x * zoom, y: bounds.midY - w.y * zoom)
        reproject(); markDirty()
    }

    private func markDirty() {
        dirty = true
        lastChange = CACurrentMediaTime()
        if !freezeOnMotion { reconcile() }
    }
    func maybeReconcile(now: CFTimeInterval) {
        guard dirty else { return }
        if !freezeOnMotion || now - lastChange > 0.09 { reconcile() }
    }

    // MARK: Node drag (driven by the node's forwarded events; geometry lives here)

    func beginNodeDrag(_ n: CanvasNode, isResize: Bool, event e: NSEvent) {
        dragAnchorWorld = screenToWorld(convert(e.locationInWindow, from: nil))
        dragAnchorFrame = n.worldFrame
        setActive(n)
    }
    func moveNodeDrag(_ n: CanvasNode, isResize: Bool, event e: NSEvent) {
        let now = screenToWorld(convert(e.locationInWindow, from: nil))
        let dx = now.x - dragAnchorWorld.x, dy = now.y - dragAnchorWorld.y
        var f = dragAnchorFrame
        if isResize {
            f.size = CGSize(width: max(220, dragAnchorFrame.width + dx), height: max(140, dragAnchorFrame.height + dy))
        } else {
            f.origin = CGPoint(x: dragAnchorFrame.minX + dx, y: dragAnchorFrame.minY + dy)
        }
        let (snapped, lines) = snap(f, excluding: n, resizing: isResize)
        n.worldFrame = snapped
        reprojectNode(n)
        showGuides(lines)
    }
    func endNodeDrag(_ n: CanvasNode) { clearGuides(); markDirty() }

    // MARK: Magnetic placement + snapping

    /// A world frame for a new node: open space near the viewport centre, spaced by
    /// a gap so it tucks in beside neighbours (then magnetic snapping aligns it).
    func placementWorldFrame() -> CGRect {
        let c = screenToWorld(CGPoint(x: bounds.midX, y: bounds.midY))
        let w = cardSize.width, h = cardSize.height
        let stepX = w + gap, stepY = h + gap
        for ring in 0..<32 {
            for dy in -ring...ring {
                for dx in -ring...ring where max(abs(dx), abs(dy)) == ring {
                    let f = CGRect(x: c.x - w / 2 + CGFloat(dx) * stepX,
                                   y: c.y - h / 2 + CGFloat(dy) * stepY, width: w, height: h)
                    if !nodes.contains(where: { $0.worldFrame.intersects(f.insetBy(dx: -gap / 2, dy: -gap / 2)) }) {
                        return f
                    }
                }
            }
        }
        return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    /// Magnetic snap: align the dragged frame to neighbours' edges, centres, and
    /// even gaps — independently per axis — and return the alignment guide lines.
    private func snap(_ frame: CGRect, excluding: CanvasNode, resizing: Bool) -> (CGRect, [SnapLine]) {
        var f = frame
        var lines: [SnapLine] = []
        let others = nodes.filter { $0.id != excluding.id }.map(\.worldFrame)
        guard !others.isEmpty else { return (f, []) }

        var bestX: (CGFloat, SnapLine)?
        var bestY: (CGFloat, SnapLine)?
        for o in others {
            let yA = min(f.minY, o.minY), yB = max(f.maxY, o.maxY)
            let xCands: [(CGFloat, CGFloat, CGFloat)] = resizing
                ? [(f.maxX, o.maxX, o.maxX), (f.maxX, o.minX - gap, o.minX)]
                : [(f.minX, o.minX, o.minX), (f.maxX, o.maxX, o.maxX), (f.midX, o.midX, o.midX),
                   (f.minX, o.maxX + gap, o.maxX), (f.maxX, o.minX - gap, o.minX)]
            for (src, tgt, lineX) in xCands {
                let d = tgt - src
                if abs(d) <= snapThreshold, abs(d) < (bestX.map { abs($0.0) } ?? .infinity) {
                    bestX = (d, SnapLine(vertical: true, pos: lineX, a: yA, b: yB))
                }
            }
            let xA = min(f.minX, o.minX), xB = max(f.maxX, o.maxX)
            let yCands: [(CGFloat, CGFloat, CGFloat)] = resizing
                ? [(f.maxY, o.maxY, o.maxY), (f.maxY, o.minY - gap, o.minY)]
                : [(f.minY, o.minY, o.minY), (f.maxY, o.maxY, o.maxY), (f.midY, o.midY, o.midY),
                   (f.minY, o.maxY + gap, o.maxY), (f.maxY, o.minY - gap, o.minY)]
            for (src, tgt, lineY) in yCands {
                let d = tgt - src
                if abs(d) <= snapThreshold, abs(d) < (bestY.map { abs($0.0) } ?? .infinity) {
                    bestY = (d, SnapLine(vertical: false, pos: lineY, a: xA, b: xB))
                }
            }
        }
        if let (d, line) = bestX {
            if resizing { f.size.width = max(220, f.size.width + d) } else { f.origin.x += d }
            lines.append(line)
        }
        if let (d, line) = bestY {
            if resizing { f.size.height = max(140, f.size.height + d) } else { f.origin.y += d }
            lines.append(line)
        }
        return (f, lines)
    }

    private func showGuides(_ lines: [SnapLine]) {
        let path = CGMutablePath()
        for L in lines {
            if L.vertical {
                let x = L.pos * zoom + pan.x
                path.move(to: CGPoint(x: x, y: L.a * zoom + pan.y))
                path.addLine(to: CGPoint(x: x, y: L.b * zoom + pan.y))
            } else {
                let y = L.pos * zoom + pan.y
                path.move(to: CGPoint(x: L.a * zoom + pan.x, y: y))
                path.addLine(to: CGPoint(x: L.b * zoom + pan.x, y: y))
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        guideLayer.path = path.isEmpty ? nil : path
        CATransaction.commit()
    }
    private func clearGuides() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        guideLayer.path = nil
        CATransaction.commit()
    }

    // MARK: Nodes

    func addNode(_ node: CanvasNode, animated: Bool = false) {
        node.view.frame = project(node.worldFrame)
        addSubview(node.view)
        nodes.append(node)
        if animated, let layer = node.view.layer {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.0; fade.toValue = 1.0
            let rise = CABasicAnimation(keyPath: "transform.translation.y"); rise.fromValue = 12; rise.toValue = 0
            let g = CAAnimationGroup(); g.animations = [fade, rise]; g.duration = 0.26
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(g, forKey: "addIn")
        }
        reconcile()
    }

    func disposeAll() {
        for n in nodes { n.dispose(); n.view.removeFromSuperview() }
        nodes.removeAll(); activeID = nil
    }

    func setActive(_ node: CanvasNode) {
        activeID = node.id
        // Bring to front via zPosition — NOT addSubview, which re-inserts the view
        // and cancels an in-progress drag (that's why resize/move died on grab).
        for n in nodes {
            n.view.layer?.zPosition = (n.id == node.id) ? 1 : 0
            (n as? TerminalCanvasNode)?.setActive(n.id == node.id)
        }
    }

    var liveCount: Int { nodes.reduce(0) { $0 + ($1.state == .live ? 1 : 0) } }
    var frozenCount: Int { nodes.reduce(0) { $0 + ($1.state == .frozen ? 1 : 0) } }

    /// Visible nodes stay LIVE up to the budget; off-screen nodes cull (kept alive
    /// under dtach for instant thaw). No zoom-based grey demote.
    func reconcile() {
        let vis = visibleWorldRect.insetBy(dx: -prefetch, dy: -prefetch)
        let center = CGPoint(x: vis.midX, y: vis.midY)
        let inView = nodes.filter { $0.worldFrame.intersects(vis) }
            .sorted { dist($0.worldCenter, center) < dist($1.worldCenter, center) }
        // Zoomed out → everything is a tile (no live surface, so no PTY reflow); at
        // ~1:1 the nearest in-view nodes go live up to the budget.
        let liveSet = zoom < liveZoom ? Set<UUID>() : Set(inView.prefix(liveBudget).map(\.id))
        for node in nodes {
            if liveSet.contains(node.id) {
                if node.state != .live { node.goLive() }
            } else if node.worldFrame.intersects(vis) {
                if node.state != .frozen { node.freeze() }
            } else {
                if node.state != .culled { node.cull() }
            }
        }
        dirty = false
    }

    /// Pan to centre the bounding box of all nodes (real fit needs zoom — next beat).
    func centerOnAll() {
        guard let first = nodes.first else { return }
        var box = first.worldFrame
        for n in nodes.dropFirst() { box = box.union(n.worldFrame) }
        centerViewport(on: CGPoint(x: box.midX, y: box.midY))
    }
}

// MARK: - Controller

@MainActor
final class CanvasController: NSObject, NSWindowDelegate {
    private let ghosttyApp: ghostty_app_t
    private var window: NSWindow!
    private let engine = CanvasEngineView(frame: NSRect(x: 0, y: 0, width: 1500, height: 950))
    private let hud = NSTextField(labelWithString: "")

    private var streaming = false
    private var autoPan = false
    private var nodeCount = 0

    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var frameDts: [Double] = []
    private var hitches = 0
    private var expectedInterval = 1.0 / 120.0
    private var lastLog: CFTimeInterval = 0
    private var panPhase: Double = 0
    private var keyMonitor: Any?
    private var scrollMonitor: Any?

    init(ghosttyApp: ghostty_app_t) { self.ghosttyApp = ghosttyApp; super.init() }

    func show() {
        let frame = NSRect(x: 0, y: 0, width: 1500, height: 950)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Canvas v2"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let container = FlippedView(frame: frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1).cgColor
        engine.frame = container.bounds
        engine.autoresizingMask = [.width, .height]
        container.addSubview(engine)

        hud.frame = NSRect(x: 12, y: 12, width: 640, height: 22)
        hud.autoresizingMask = [.maxXMargin, .maxYMargin]
        hud.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        hud.textColor = .white
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        hud.drawsBackground = true
        hud.isBezeled = false
        hud.isEditable = false
        container.addSubview(hud)

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installKeyMonitor()
        installScrollMonitor()
        startDisplayLink()
        DispatchQueue.main.async { [weak self] in self?.addTerminals(1) }
    }

    func windowWillClose(_ notification: Notification) {
        engine.disposeAll()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
    }

    /// Capture scroll + pinch globally so navigation works EVERYWHERE — even with
    /// the cursor over a terminal (that's why pan stopped before: the terminal ate
    /// the scroll). Plain scroll = pan; ⌘/⌃ + scroll, or pinch = zoom at the cursor.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            let p = self.engine.convert(e.locationInWindow, from: nil)
            if e.type == .magnify {
                self.engine.zoomBy(1 + e.magnification, atScreen: p)
                return nil
            }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.command) || mods.contains(.control) {
                let factor = 1 + max(-0.25, min(0.25, e.scrollingDeltaY * 0.01))
                self.engine.zoomBy(factor, atScreen: p)
            } else {
                self.engine.panBy(e.scrollingDeltaX, e.scrollingDeltaY)
            }
            return nil
        }
    }

    // MARK: Nodes

    private func addTerminals(_ count: Int, staggered: Bool = true) {
        guard count > 0 else { return }
        if staggered {
            addOneTerminal()
            if count > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                    self?.addTerminals(count - 1, staggered: true)
                }
            }
        } else {
            for _ in 0..<count { addOneTerminal() }
        }
    }

    private func addOneTerminal() {
        let convo = Conversation.shellConversation(cwd: URL(fileURLWithPath: NSHomeDirectory()))
        let node = TerminalCanvasNode(conversation: convo,
                                      worldFrame: engine.placementWorldFrame(),   // magic-cursor: nearest free grid cell
                                      ghosttyApp: ghosttyApp,
                                      streaming: streaming,
                                      title: "term \(nodeCount)")
        node.onActivate  = { [weak self] n in self?.engine.setActive(n) }
        node.onDragBegan = { [weak self] n, r, e in self?.engine.beginNodeDrag(n, isResize: r, event: e) }
        node.onDragMove  = { [weak self] n, r, e in self?.engine.moveNodeDrag(n, isResize: r, event: e) }
        node.onDragEnded = { [weak self] n in self?.engine.endNodeDrag(n) }
        nodeCount += 1
        engine.addNode(node, animated: true)
        engine.setActive(node)
        CanvasLog.line("nodes → \(engine.nodes.count)")
    }

    private func rebuildForStreaming() {
        let count = engine.nodes.count
        engine.disposeAll()
        nodeCount = 0
        addTerminals(max(1, count), staggered: false)
    }

    // MARK: Keys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  let chars = event.charactersIgnoringModifiers else { return event }
            return self.handleKey(chars) ? nil : event
        }
    }

    private func handleKey(_ chars: String) -> Bool {
        switch chars {
        case "n": addTerminals(1); return true
        case "N": addTerminals(5); return true
        case "s": streaming.toggle(); CanvasLog.line("streaming → \(streaming)"); rebuildForStreaming(); return true
        case "p": autoPan.toggle(); CanvasLog.line("auto-pan → \(autoPan)"); return true
        case "m": engine.freezeOnMotion.toggle(); CanvasLog.line("freeze-on-motion → \(engine.freezeOnMotion)"); return true
        case "[": engine.liveBudget = max(1, engine.liveBudget - 2); engine.reconcile(); return true
        case "]": engine.liveBudget += 2; engine.reconcile(); return true
        case "f": engine.centerOnAll(); return true
        case "b": runBenchmark(); return true
        case " ": dumpStats(prefix: "manual"); return true
        default: return false
        }
    }

    // MARK: Display link

    private func startDisplayLink() {
        let link = (window.contentView ?? engine).displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .current, forMode: .common)
        displayLink = link
        if let max = window.screen?.maximumFramesPerSecond, max > 0 { expectedInterval = 1.0 / Double(max) }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastTick > 0 {
            let dt = now - lastTick
            frameDts.append(dt)
            if dt > expectedInterval * 1.7 { hitches += 1 }
        }
        lastTick = now
        if autoPan {
            panPhase += expectedInterval
            engine.panBy(cos(panPhase * 1.6) * 9, sin(panPhase * 1.6) * 9)
        }
        engine.maybeReconcile(now: now)
        if now - lastLog >= 0.5 { dumpStats(prefix: "live"); lastLog = now }
    }

    private func dumpStats(prefix: String) {
        let avg = frameDts.isEmpty ? 0 : frameDts.reduce(0, +) / Double(frameDts.count)
        let worst = frameDts.max() ?? 0
        let avgFps = avg > 0 ? 1 / avg : 0
        let minFps = worst > 0 ? 1 / worst : 0
        let s = String(format: "%@ fps=%.0f(min %.0f) hitch=%d | nodes=%d live=%d frozen=%d | pan=(%.0f,%.0f) stream=%@ autopan=%@ budget=%d | rss=%.0fMB",
                       prefix, avgFps, minFps, hitches, engine.nodes.count, engine.liveCount, engine.frozenCount,
                       engine.pan.x, engine.pan.y, yn(streaming), yn(autoPan), engine.liveBudget, residentMB())
        hud.stringValue = "n/N nodes · drag empty to pan · drag header to move (snaps) · corner to resize · f center · s stream · b bench"
        if prefix != "live" || Int(lastTick) % 2 == 0 { CanvasLog.line(s) }
        frameDts.removeAll(keepingCapacity: true)
    }

    private func yn(_ b: Bool) -> String { b ? "ON" : "off" }

    // MARK: Benchmark

    func runBenchmark() {
        CanvasLog.line("════ CANVAS BENCH START ════")
        streaming = true
        rebuildForStreaming()
        autoPan = true
        var steps: [(Int, Bool)] = []
        for n in [8, 16, 32, 64] { steps.append((n, true)) }
        for n in [32, 64] { steps.append((n, false)) }
        runStep(steps, 0)
    }

    private func runStep(_ steps: [(Int, Bool)], _ i: Int) {
        guard i < steps.count else {
            streaming = false
            engine.freezeOnMotion = true
            autoPan = false
            engine.disposeAll()
            nodeCount = 0
            addTerminals(8, staggered: false)
            CanvasLog.line("════ CANVAS BENCH END (cleaned up, live=\(engine.liveCount)) ════")
            return
        }
        let (target, motionFreeze) = steps[i]
        engine.freezeOnMotion = motionFreeze
        if engine.nodes.count < target { addTerminals(target - engine.nodes.count, staggered: false) }
        engine.reconcile()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.hitches = 0; self.frameDts.removeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                self.dumpStats(prefix: String(format: "BENCH n=%d motionFreeze=%@", target, self.yn(motionFreeze)))
                self.runStep(steps, i + 1)
            }
        }
    }
}

// MARK: - helpers

/// One alignment guide line, in world coordinates: `pos` on its axis, spanning `a…b`.
struct SnapLine { let vertical: Bool; let pos: CGFloat; let a: CGFloat; let b: CGFloat }

private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { let dx = a.x - b.x, dy = a.y - b.y; return dx*dx + dy*dy }

private func residentMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1024 / 1024 : 0
}

enum CanvasLog {
    private static let path = (NSHomeDirectory() as NSString).appendingPathComponent("cherminal-canvas.log")
    private static let handle: FileHandle? = {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    static func line(_ s: String) {
        let stamped = "[canvas] \(s)"
        NSLog("%@", stamped)
        handle?.write((stamped + "\n").data(using: .utf8) ?? Data())
    }
}
