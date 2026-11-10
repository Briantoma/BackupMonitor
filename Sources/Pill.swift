import AppKit
import QuartzCore

/// The menu bar readout while a job runs: a pill that fades in as a circle, widens to fit the
/// numbers, follows them as they get longer or shorter, and folds back the same way, coloured by
/// how the copy is going. Drawn by hand as the button's own image, so the text is never cut short
/// with "…", and so menu bar managers like Ice, which draw their own backgrounds behind items, never
/// find an uncovered gap beside it while it changes size.
@MainActor
final class MenuBarPill: NSObject {
    static let duration: TimeInterval = 1
    static let toneFade: TimeInterval = 0.3
    static let textFade: TimeInterval = 0.25
    /// As slow as the widening, so a new digit never makes the menu bar jump.
    static let resize: TimeInterval = 0.5
    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private let item: NSStatusItem
    private let idleIcon: NSImage?
    private let view = PillPicture()
    private var openness: Double = 0
    private var target: Double = 0
    private var frames: AnyObject?
    private var lastFrame = Date()
    private var resizeFrom: CGFloat = 0
    private var resizeTo: CGFloat = 0
    private var resizeStart = Date.distantPast
    /// A longer text waits until the pill has grown to fit it.
    private var waitingText: String?
    /// When the closing began: the text fades out before the pill starts to shrink.
    private var closing: Date?
    private var isResizing: Bool { Date().timeIntervalSince(resizeStart) < Self.resize }

    init(item: NSStatusItem, idleIcon: NSImage?) {
        self.item = item
        self.idleIcon = idleIcon
        super.init()
        item.button?.image = idleIcon
        item.button?.imagePosition = .imageOnly
    }

    /// The pill's width when fully open: the wheel's circle, then the text.
    private func fullWidth(_ text: String, wheel: Bool) -> CGFloat {
        guard !text.isEmpty else { return view.diameter }
        let width = PillPicture.slots(text).reduce(0) { $0 + $1.width }
        return ceil((wheel ? view.diameter : PillPicture.textInset) + width + PillPicture.textInset)
    }

    func update(open: Bool, text: String, fraction: Double?, wheel: Bool, tone: PillTone) {
        target = open ? 1 : 0
        if open {
            closing = nil
            view.textOut = 1
        } else if closing == nil && openness > 0 {
            closing = Date()
        }
        // Closing keeps the last text and width, so the text fades away rather than vanishing.
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
        if frames == nil && (openness != target || view.isFading || view.isTextFading || isResizing) { startAnimating() }
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
        if let closing, !view.text.isEmpty {
            view.textOut = max(1 - now.timeIntervalSince(closing) / Self.textFade, 0)
        }
        if target > openness {
            openness = min(openness + move, target)
        } else if view.textOut == 0 || view.text.isEmpty || closing == nil {
            openness = max(openness - move, target)
        }
        if openness == 0 {
            view.shownSince = [:]
            view.textOut = 1
            closing = nil
        }
        let resized = min(now.timeIntervalSince(resizeStart) / Self.resize, 1)
        view.fullWidth = resizeFrom + (resizeTo - resizeFrom) * (1 - pow(1 - resized, 3))
        if resized >= 1, let text = waitingText {
            view.text = text
            waitingText = nil
        }
        apply()
        if openness == target && !view.isFading && !view.isTextFading && !isResizing && waitingText == nil { stopAnimating() }
    }

    private func apply() {
        guard let button = item.button else { return }
        view.shape = PillShape(openness: openness)
        view.scale = button.window?.backingScaleFactor ?? 2
        if openness == 0 {
            if button.image !== idleIcon { button.image = idleIcon }
            if item.length != NSStatusItem.variableLength { item.length = NSStatusItem.variableLength }
            return
        }
        // Whole pixels only, so the menu bar isn't relaid out for every fraction of a point.
        let width = view.pixel(view.pillWidth)
        let picture = view
        let image = NSImage(size: NSSize(width: width, height: view.diameter), flipped: false) { rect in
            // Drawn when shown, so the colours match the menu bar's own light or dark look.
            MainActor.assumeIsolated { picture.draw(in: rect) }
            return true
        }
        image.accessibilityDescription = view.text
        button.image = image
        if item.length != width { item.length = width }
    }
}

/// What the pill looks like at one moment, drawn into the button's image.
@MainActor
final class PillPicture {
    static let textInset: CGFloat = 10

    var text = ""
    var fraction = 0.0
    var wheel = true
    var fullWidth: CGFloat = 0
    var shape = PillShape(openness: 0)
    var tone = PillTone.neutral
    var previousTone = PillTone.neutral
    var toneChanged = Date.distantPast
    var scale: CGFloat = 2

    /// The menu bar's height less a small margin, like macOS's own camera and recording pills.
    var diameter: CGFloat { min(NSStatusBar.system.thickness - 4, 22) }
    var pillWidth: CGFloat { diameter + (fullWidth - diameter) * shape.widen }
    var isFading: Bool { Date().timeIntervalSince(toneChanged) < MenuBarPill.toneFade }
    /// When each part of the text first fitted whole, for its fade in.
    var shownSince: [Int: Date] = [:]
    /// The whole text's opacity while it fades out at the end of a job.
    var textOut: Double = 1
    var isTextFading: Bool {
        textOut > 0 && textOut < 1 || shownSince.values.contains { Date().timeIntervalSince($0) < MenuBarPill.textFade }
    }

    /// Rounded to the screen's pixels: an edge between two pixels blends into the menu bar as a grey rim.
    func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

    /// Each part of the text with the room it keeps, "· " included after the first, so numbers
    /// changing length don't resize the pill or move the parts after them.
    static func slots(_ text: String) -> [(piece: String, width: CGFloat, alignRight: Bool)] {
        func width(_ string: String) -> CGFloat {
            NSAttributedString(string: string, attributes: [.font: MenuBarPill.font]).size().width
        }
        return text.components(separatedBy: " · ").enumerated().map { index, part in
            let lead = index == 0 ? "" : " · "
            let room = max(width(lead + part), width(lead + MenuBarStatus.room(for: part)))
            return (lead + part, room, part.hasSuffix("%"))
        }
    }

    func draw(in bounds: NSRect) {
        let mix = min(Date().timeIntervalSince(toneChanged) / MenuBarPill.toneFade, 1)
        let (fill, ink) = Self.blend(previousTone, tone, mix)
        // The item's actual width, which can trail the animation by a frame, so the pill always covers it.
        let pill = NSRect(x: 0, y: 0, width: max(bounds.width, diameter), height: diameter)
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

        // Each part ("42%", "· 466.6 MB/s", "· 2m 10s") fades in once it fits whole in the pill.
        let now = Date()
        var x = pill.minX + (wheel ? diameter : Self.textInset)
        let reach = pill.maxX - Self.textInset
        for (index, slot) in Self.slots(text).enumerated() where !text.isEmpty {
            let piece = slot.piece
            let size = NSAttributedString(string: piece, attributes: [.font: MenuBarPill.font]).size()
            let fits = x + slot.width <= reach + 4
            if !fits { shownSince[index] = nil } else if shownSince[index] == nil { shownSince[index] = now }
            let alpha = shownSince[index].map { min(now.timeIntervalSince($0) / MenuBarPill.textFade, 1) * textOut } ?? 0
            if alpha > 0 {
                NSAttributedString(string: piece, attributes: [
                    .font: MenuBarPill.font, .foregroundColor: ink.withAlphaComponent(alpha),
                ]).draw(at: NSPoint(x: slot.alignRight ? x + slot.width - size.width : x, y: pill.midY - size.height / 2))
            }
            x += slot.width
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
