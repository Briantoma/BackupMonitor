import AppKit

/// The menu bar readout while a job runs: a pill that fades in as a circle, widens to fit the
/// numbers and folds back the same way, coloured by how the copy is going. Drawn by hand, so the
/// text is never cut short with "…" while the width changes.
@MainActor
final class MenuBarPill {
    static let duration: TimeInterval = 1
    static let toneFade: TimeInterval = 0.3
    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// Room left between the pill and the items beside it.
    static let margin: CGFloat = 3

    private let item: NSStatusItem
    private let idleIcon: NSImage?
    private let view = PillView()
    private var openness: Double = 0
    private var target: Double = 0
    private var timer: Timer?
    private var lastFrame = Date()

    var diameter: CGFloat { view.diameter }

    init(item: NSStatusItem, idleIcon: NSImage?) {
        self.item = item
        self.idleIcon = idleIcon
        item.button?.image = idleIcon
        if let button = item.button {
            view.frame = button.bounds
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
        }
        view.isHidden = true
    }

    /// The pill's width when fully open: the wheel's circle, then the text.
    func fullWidth(texts: [String], wheel: Bool) -> CGFloat {
        let text = texts.map { NSAttributedString(string: $0, attributes: [.font: Self.font]).size().width }.max() ?? 0
        guard text > 0 else { return diameter }
        return ceil((wheel ? diameter : 10) + text + 10)
    }

    func update(open: Bool, text: String, fraction: Double?, wheel: Bool, tone: PillTone, fullWidth: CGFloat) {
        view.text = text
        view.fraction = fraction ?? 0
        view.wheel = wheel
        view.fullWidth = max(fullWidth, diameter)
        if tone != view.tone {
            view.previousTone = view.tone
            view.tone = tone
            view.toneChanged = Date()
        }
        target = open ? 1 : 0
        view.needsDisplay = true
        if timer == nil && (openness != target || view.isFading) { startAnimating() }
        if timer == nil { apply() }
    }

    private func startAnimating() {
        lastFrame = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        // Common modes, so it keeps moving while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        let now = Date()
        let move = now.timeIntervalSince(lastFrame) / Self.duration
        lastFrame = now
        openness = target > openness ? min(openness + move, target) : max(openness - move, target)
        apply()
        if openness == target && !view.isFading {
            timer?.invalidate()
            timer = nil
        }
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
            item.button?.image = nil
            item.length = view.pillWidth + Self.margin * 2
        }
    }
}

final class PillView: NSView {
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

    override func draw(_ dirtyRect: NSRect) {
        let mix = min(Date().timeIntervalSince(toneChanged) / MenuBarPill.toneFade, 1)
        let (fill, ink) = Self.blend(previousTone, tone, mix)
        let pill = NSRect(x: (bounds.width - pillWidth) / 2, y: (bounds.height - diameter) / 2,
                          width: pillWidth, height: diameter)
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
        if shape.text > 0 && !text.isEmpty {
            let title = NSAttributedString(string: text, attributes: [
                .font: MenuBarPill.font, .foregroundColor: ink.withAlphaComponent(shape.text),
            ])
            let size = title.size()
            title.draw(at: NSPoint(x: pill.minX + (wheel ? diameter : 10), y: pill.midY - size.height / 2))
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
