import AppKit
import QuartzCore

/// The menu bar readout while a job runs: a pill that fades in as a circle, widens to fit the
/// numbers, follows them as they get longer or shorter, and folds back the same way, coloured by
/// how the copy is going. Drawn by hand, so the text is never cut short with "…".
@MainActor
final class MenuBarPill: NSObject {
    static let duration: TimeInterval = 1
    static let toneFade: TimeInterval = 0.3
    /// As slow as the widening, so a new digit never makes the menu bar jump.
    static let resize: TimeInterval = 0.5
    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private let item: NSStatusItem
    private let idleIcon: NSImage?
    private let view = PillView()
    private var openness: Double = 0
    private var target: Double = 0
    private var frames: AnyObject?
    private var lastFrame = Date()
    private var resizeFrom: CGFloat = 0
    private var resizeTo: CGFloat = 0
    private var resizeStart = Date.distantPast
    /// A longer text waits until the pill has grown to fit it.
    private var waitingText: String?
    private var isResizing: Bool { Date().timeIntervalSince(resizeStart) < Self.resize }

    init(item: NSStatusItem, idleIcon: NSImage?) {
        self.item = item
        self.idleIcon = idleIcon
        super.init()
        item.button?.image = idleIcon
        if let button = item.button {
            view.frame = button.bounds
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
        }
        view.isHidden = true
    }

    /// The pill's width when fully open: the wheel's circle, then the text.
    private func fullWidth(_ text: String, wheel: Bool) -> CGFloat {
        guard !text.isEmpty else { return view.diameter }
        let width = NSAttributedString(string: text, attributes: [.font: Self.font]).size().width
        return ceil((wheel ? view.diameter : PillView.textInset) + width + PillView.textInset)
    }

    func update(open: Bool, text: String, fraction: Double?, wheel: Bool, tone: PillTone) {
        target = open ? 1 : 0
        // Closing keeps the last text and width, so the text folds away rather than vanishing.
        guard open || openness == 0 else { return keepAnimating() }
        view.fraction = fraction ?? 0
        view.wheel = wheel
        let width = fullWidth(text, wheel: wheel)
        if openness == 0 {
            // Closed: the opening itself will widen it.
            view.text = text
            view.fullWidth = width
            resizeTo = width
            waitingText = nil
        } else if width > resizeTo {
            waitingText = text
            resize(to: width)
        } else if width < resizeTo {
            view.text = text
            waitingText = nil
            resize(to: width)
        } else if waitingText != nil {
            waitingText = text
        } else {
            view.text = text
        }
        if tone != view.tone {
            view.previousTone = view.tone
            view.tone = tone
            view.toneChanged = Date()
        }
        keepAnimating()
    }

    private func resize(to width: CGFloat) {
        resizeFrom = view.fullWidth
        resizeTo = width
        resizeStart = Date()
    }

    private func keepAnimating() {
        view.needsDisplay = true
        if frames == nil && (openness != target || view.isFading || isResizing) { startAnimating() }
        if frames == nil { apply() }
    }

    /// In step with the display where macOS allows it, so the pill moves without stutter. The main
    /// display's clock, not the item's: an item pushed off-screen by a full menu bar gets no frames.
    private func startAnimating() {
        lastFrame = Date()
        if #available(macOS 14, *), let screen = NSScreen.main ?? NSScreen.screens.first {
            let link = screen.displayLink(target: self, selector: #selector(frame))
            link.add(to: .main, forMode: .common)
            frames = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
            // Common modes, so it keeps moving while the menu is open.
            RunLoop.main.add(timer, forMode: .common)
            frames = timer
        }
    }

    @objc private func frame() { step() }

    private func stopAnimating() {
        if #available(macOS 14, *), let link = frames as? CADisplayLink { link.invalidate() }
        (frames as? Timer)?.invalidate()
        frames = nil
    }

    private func step() {
        let now = Date()
        let move = now.timeIntervalSince(lastFrame) / Self.duration
        lastFrame = now
        openness = target > openness ? min(openness + move, target) : max(openness - move, target)
        let resized = min(now.timeIntervalSince(resizeStart) / Self.resize, 1)
        view.fullWidth = resizeFrom + (resizeTo - resizeFrom) * (1 - pow(1 - resized, 3))
        if resized >= 1, let text = waitingText {
            view.text = text
            waitingText = nil
        }
        apply()
        if openness == target && !view.isFading && !isResizing && waitingText == nil { stopAnimating() }
    }

    private func apply() {
        view.shape = PillShape(openness: openness)
        view.needsDisplay = true
        if openness == 0 {
            view.isHidden = true
            if item.button?.image == nil { item.button?.image = idleIcon }
            if item.length != NSStatusItem.variableLength { item.length = NSStatusItem.variableLength }
        } else {
            view.isHidden = false
            if item.button?.image != nil { item.button?.image = nil }
            // Exactly the pill: any spare width shows macOS's grey item background beside it.
            // Whole pixels only, so the menu bar isn't relaid out for every fraction of a point.
            let length = view.pixel(view.pillWidth)
            if item.length != length { item.length = length }
        }
    }
}

final class PillView: NSView {
    static let textInset: CGFloat = 10

    var text = ""
    var fraction = 0.0
    var wheel = true
    var fullWidth: CGFloat = 0
    var shape = PillShape(openness: 0)
    var tone = PillTone.neutral
    var previousTone = PillTone.neutral
    var toneChanged = Date.distantPast

    /// The menu bar's height less a small margin, like macOS's own camera and recording pills.
    var diameter: CGFloat { min(NSStatusBar.system.thickness - 4, 22) }
    var pillWidth: CGFloat { diameter + (fullWidth - diameter) * shape.widen }
    var isFading: Bool { Date().timeIntervalSince(toneChanged) < MenuBarPill.toneFade }

    /// Rounded to the screen's pixels: an edge between two pixels blends into the menu bar as a grey rim.
    func pixel(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    override func draw(_ dirtyRect: NSRect) {
        let mix = min(Date().timeIntervalSince(toneChanged) / MenuBarPill.toneFade, 1)
        let (fill, ink) = Self.blend(previousTone, tone, mix)
        // The item's actual width, which can trail the animation by a frame, so the pill always covers it.
        let pill = NSRect(x: 0, y: pixel((bounds.height - diameter) / 2), width: max(bounds.width, diameter), height: diameter)
        let outline = NSBezierPath(roundedRect: pill, xRadius: diameter / 2, yRadius: diameter / 2)
        fill.withAlphaComponent(fill.alphaComponent * shape.alpha).setFill()
        outline.fill()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()

        if wheel {
            let ring = NSRect(x: pill.minX, y: pill.minY, width: diameter, height: diameter).insetBy(dx: 5, dy: 5)
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = 2.2
            ink.withAlphaComponent(0.3 * shape.alpha).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            ink.withAlphaComponent(shape.alpha).setStroke()
            arc.stroke()
        }

        // Each part ("42%", "· 466.6 MB/s", "· 2m 10s") shows once it fits whole in the pill.
        var x = pill.minX + (wheel ? diameter : Self.textInset)
        let reach = pill.maxX - Self.textInset
        for (index, part) in text.components(separatedBy: " · ").enumerated() where !text.isEmpty {
            let piece = (index == 0 ? "" : " · ") + part
            let plain = NSAttributedString(string: piece, attributes: [.font: MenuBarPill.font])
            let size = plain.size()
            let alpha = PillShape.partAlpha(end: x + size.width, reach: reach)
            if alpha > 0 {
                NSAttributedString(string: piece, attributes: [
                    .font: MenuBarPill.font, .foregroundColor: ink.withAlphaComponent(alpha),
                ]).draw(at: NSPoint(x: x, y: pill.midY - size.height / 2))
            }
            x += size.width
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Fill and text colour, resolved for the menu bar's own appearance, part way from one tone to the next.
    private static func blend(_ from: PillTone, _ to: PillTone, _ mix: Double) -> (NSColor, NSColor) {
        func colors(_ tone: PillTone) -> (NSColor, NSColor) {
            switch tone {
            case .neutral: return (NSColor.labelColor.withAlphaComponent(0.15), .labelColor)
            case .orange: return (.systemOrange, .white)
            case .red: return (.systemRed, .white)
            case .green: return (.systemGreen, .white)
            }
        }
        func srgb(_ color: NSColor) -> NSColor { color.usingColorSpace(.sRGB) ?? color }
        let a = colors(from), b = colors(to)
        let fill = srgb(a.0).blended(withFraction: mix, of: srgb(b.0)) ?? srgb(b.0)
        let ink = srgb(a.1).blended(withFraction: mix, of: srgb(b.1)) ?? srgb(b.1)
        return (fill, ink)
    }
}
