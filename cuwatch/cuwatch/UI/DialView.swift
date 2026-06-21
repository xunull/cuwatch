import AppKit
import CuwatchCore

/// The 16×16 dial that lives inside the NSStatusItem button.
///
/// Render strategy: CAShapeLayer sublayers for arc / tick / needle / centerCap.
/// `setFraction(_:animated:)` triggers a 280ms damped spring with 4° overshoot
/// on the needle rotation (per DESIGN.md). Color crossfades on state change.
///
/// Reduce Motion: animations become instant transitions (no interpolation),
/// per macOS accessibility guidelines and DESIGN.md.
///
/// Three-appearance matrix: dark menu bar / light menu bar / tinted accent
/// — switched on `viewDidChangeEffectiveAppearance()` callbacks.
final class DialView: NSView {

    // MARK: - Public state

    /// Current usage fraction in [0.0, 1.0].
    private(set) var fraction: Double = 1.0

    /// Current color state (drives palette).
    private(set) var colorState: DialColorState = .neutralGrey

    /// Whether to render in Reduce Motion mode (instant transitions).
    var reduceMotion: Bool = false

    // MARK: - Sublayers

    private let arcLayer = CAShapeLayer()
    private let tickLayer = CAShapeLayer()
    private let needleLayer = CAShapeLayer()
    private let centerCapLayer = CAShapeLayer()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false
        // Add sublayers in z-order: arc → tick → needle → cap.
        layer?.addSublayer(arcLayer)
        layer?.addSublayer(tickLayer)
        layer?.addSublayer(needleLayer)
        layer?.addSublayer(centerCapLayer)
        // Needle rotates around the dial center.
        needleLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        rebuildPaths()
        applyPalette(animated: false)
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        // The status item button is taller than the icon canvas; we render into 16×16.
        NSSize(width: Tokens.Layout.menuBarIconSize, height: Tokens.Layout.menuBarIconSize)
    }

    override func layout() {
        super.layout()
        layoutSublayers()
    }

    private func layoutSublayers() {
        // Position all sublayers in the view's local coordinate system.
        let r = bounds
        arcLayer.frame = r
        tickLayer.frame = r
        centerCapLayer.frame = r
        // Needle layer is sized so its origin is the view center and it
        // points along positive X by default; rotation places it correctly.
        needleLayer.frame = r
        rebuildPaths()
    }

    // MARK: - Path construction

    /// Inset from view bounds so the arc isn't flush with the edge.
    private var arcInset: CGFloat { 2 }

    private var dialCenter: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private var arcRadius: CGFloat {
        (min(bounds.width, bounds.height) / 2) - arcInset
    }

    private var needleLength: CGFloat {
        arcRadius - 1.5 // pull back a hair so it doesn't kiss the arc
    }

    private var tickInnerRadius: CGFloat {
        arcRadius - 2
    }

    private func rebuildPaths() {
        guard arcRadius > 0 else { return }

        // ---- ARC ----
        let arc = CGMutablePath()
        // Standard math angles, Cocoa y-up. Clockwise in math = clockwise on screen.
        let startRad = CGFloat(DialModel.arcStartDegrees * .pi / 180)
        let endRad = CGFloat(DialModel.arcEndDegrees * .pi / 180)
        // We want to draw from arcStart (225°) to arcEnd (-45°) going through the TOP
        // (90°). In math convention, this means going clockwise (decreasing angle)
        // 225 → 180 → 90 → 0 → -45.
        arc.addArc(
            center: dialCenter,
            radius: arcRadius,
            startAngle: startRad,
            endAngle: endRad,
            clockwise: true
        )
        arcLayer.path = arc

        // ---- TICK (75% redline) ----
        // Short radial line from `tickInnerRadius` to arc radius at the tick angle.
        let tick = CGMutablePath()
        let tickAng = CGFloat(DialModel.tickAngleRadians)
        let inner = CGPoint(
            x: dialCenter.x + cos(tickAng) * tickInnerRadius,
            y: dialCenter.y + sin(tickAng) * tickInnerRadius
        )
        let outer = CGPoint(
            x: dialCenter.x + cos(tickAng) * (arcRadius + 0.5),
            y: dialCenter.y + sin(tickAng) * (arcRadius + 0.5)
        )
        tick.move(to: inner)
        tick.addLine(to: outer)
        tickLayer.path = tick

        // ---- NEEDLE ----
        // We draw the needle along the positive X axis from the dial center,
        // then rotate `needleLayer` (anchored at center) to the actual angle.
        let needle = CGMutablePath()
        needle.move(to: dialCenter)
        // Hairline reach: center → endpoint along +X
        needle.addLine(to: CGPoint(x: dialCenter.x + needleLength, y: dialCenter.y))
        needleLayer.path = needle
        // Apply current rotation.
        applyNeedleRotation(animated: false)

        // ---- CENTER CAP ----
        let capRadius: CGFloat = 1.6
        let capRect = CGRect(
            x: dialCenter.x - capRadius,
            y: dialCenter.y - capRadius,
            width: capRadius * 2,
            height: capRadius * 2
        )
        let cap = CGMutablePath()
        cap.addEllipse(in: capRect)
        centerCapLayer.path = cap

        // Stroke / fill widths.
        arcLayer.lineWidth = 2.0
        arcLayer.fillColor = nil
        arcLayer.lineCap = .round

        tickLayer.lineWidth = 1.0
        tickLayer.fillColor = nil
        tickLayer.lineCap = .round

        needleLayer.lineWidth = 2.0
        needleLayer.fillColor = nil
        needleLayer.lineCap = .round

        centerCapLayer.lineWidth = 1.0
    }

    // MARK: - Palette

    private func currentAppearance() -> DialAppearance {
        // Sample the effective appearance to decide dark vs light.
        // Tinted-menu-bar detection: we use a heuristic for v1 — when the user
        // has the system "Accent color: Multicolor / Graphite" + accent menu bar,
        // the button reports `.darkAqua` or `.aqua` but with `contentTintColor` set.
        // True template-tinted behavior requires shipping an NSImage template;
        // v1 ships the two-color renderer and accepts that tinted menu bars
        // will show the dark/light palette underneath the system's tint blending.
        // v1.x can add proper template mode once we've measured the user impact.
        let name = effectiveAppearance.bestMatch(from: [
            .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
            .aqua, .vibrantLight, .accessibilityHighContrastAqua
        ]) ?? .aqua
        switch name {
        case .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua:
            return .darkMenuBar
        default:
            return .lightMenuBar
        }
    }

    private func applyPalette(animated: Bool) {
        let model = DialModel(fraction: fraction, state: colorState, appearance: currentAppearance())
        let arcColor = model.arcColor.nsColor.cgColor
        let needleColor = model.needleColor.nsColor.cgColor
        let tickColor = model.tickColor.nsColor.cgColor

        // Container for the transaction (animated vs immediate).
        let txn: () -> Void = {
            self.arcLayer.strokeColor = arcColor
            self.tickLayer.strokeColor = tickColor
            self.needleLayer.strokeColor = needleColor
            self.centerCapLayer.fillColor = needleColor
            self.centerCapLayer.strokeColor = arcColor
        }

        if animated && !reduceMotion {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Tokens.Motion.medium)
            txn()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            txn()
            CATransaction.commit()
        }
    }

    private func applyNeedleRotation(animated: Bool) {
        let model = DialModel(fraction: fraction, state: colorState, appearance: currentAppearance())
        // We drew the needle along +X (angle 0). Rotate to the model's needle angle.
        let targetRad = CGFloat(model.needleAngleRadians)

        if animated && !reduceMotion {
            let anim = CASpringAnimation(keyPath: "transform.rotation.z")
            anim.fromValue = needleLayer.value(forKeyPath: "transform.rotation.z") ?? 0
            anim.toValue = targetRad
            anim.duration = Tokens.Motion.needleSettle
            anim.damping = 14         // gives a noticeable but small overshoot
            anim.stiffness = 220
            anim.mass = 1.0
            anim.initialVelocity = 0
            anim.isRemovedOnCompletion = true
            needleLayer.add(anim, forKey: "needleRotate")
            needleLayer.setValue(targetRad, forKeyPath: "transform.rotation.z")
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            needleLayer.setValue(targetRad, forKeyPath: "transform.rotation.z")
            CATransaction.commit()
        }
    }

    // MARK: - Public API

    /// Update the displayed fraction, optionally animating the needle settle.
    func setFraction(_ value: Double, animated: Bool = true) {
        let clamped = max(0.0, min(1.0, value))
        guard clamped != fraction else { return }
        fraction = clamped
        applyNeedleRotation(animated: animated)
    }

    /// Update the color state, optionally crossfading the palette.
    func setColorState(_ state: DialColorState, animated: Bool = true) {
        guard state != colorState else { return }
        colorState = state
        applyPalette(animated: animated)
    }

    /// Update both at once (typical poll-tick update path).
    func setSnapshot(fraction: Double, state: DialColorState, animated: Bool = true) {
        let oldFraction = self.fraction
        let oldState = self.colorState
        self.fraction = max(0.0, min(1.0, fraction))
        self.colorState = state
        if oldState != state {
            applyPalette(animated: animated)
        }
        if oldFraction != self.fraction {
            applyNeedleRotation(animated: animated)
        }
    }

    // MARK: - Appearance change

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Re-apply palette without animation — appearance changes should be instant.
        applyPalette(animated: false)
    }
}
