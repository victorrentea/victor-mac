import AppKit

/// The red **−1** that flies from an exploded ☕ to the break watch and takes a
/// minute off the countdown when it lands.
///
/// Why this one drawing stayed in addons while every other pixel left with
/// `EmojiAnimator`: `targetGlobal` is sampled EVERY FRAME. The watch may be
/// zooming in from a coffee that popped on the same tick, or be dragged
/// mid-flight, and the token has to end up wherever it actually is at that
/// moment — a cross-process call cannot re-sample a moving target 60 times a
/// second, and the deduction happens on ARRIVAL, so the number you watch coming
/// in IS the minute rather than a decoration next to one that already happened.
/// The ☕ themselves still live in the effects app; it fires
/// `/effects/event?type=coffee-popped&x=&y=` back here when one explodes.
final class MinuteToken {
    static let shared = MinuteToken()
    private init() {}

    private static let flightSeconds: CFTimeInterval = 1.15

    /// Created on the first flight and taken back down when the last one lands:
    /// a fullscreen panel that exists all day for a token that appears twice a
    /// workshop is a window in every screenshot and every Mission Control.
    private var panel: AddonsOverlayPanel?
    private var inFlight = 0
    /// −1s on their way to the watch, not yet landed or fizzled.
    var minutesInFlight: Int { inFlight }
    /// Landing explosions still drawing; they keep the panel up.
    private var bursting = 0

    /// Fling a **−1** from `point` (global coordinates) to the break timer and,
    /// when it lands, call `onArrival` — which is what actually takes the minute
    /// off the countdown.
    ///
    /// It shrinks to half its size on the way in (near → big, at the clock →
    /// small), so a cluster of coffees popping reads as several minutes
    /// converging on the watch. If the timer is closed mid-flight the token just
    /// fades out and `onArrival` never fires — there is nothing left to subtract
    /// from. Main thread only.
    ///
    /// `burstOnArrival`: the token ends in a small explosion where it lands — the
    /// menu-bar ☕ countdown, whose few pixels of text can't jolt like the watch
    /// does (2026-11-27, Victor: *"when it reaches the menu bar icon it should
    /// make like an explosion, and then the timer goes one minute lower"*).
    func fly(fromGlobal point: CGPoint,
             targetGlobal: @escaping () -> CGPoint?,
             burstOnArrival: Bool = false,
             onArrival: @escaping () -> Void) {
        guard let hostLayer = hostLayer() else { return }
        let screen = AppDelegate.findRetinaScreen().frame
        let start = CGPoint(x: point.x - screen.origin.x, y: point.y - screen.origin.y)

        let size: CGFloat = 190
        let token = CATextLayer()
        token.string = "−1"
        token.font = NSFont.boldSystemFont(ofSize: 130)
        token.fontSize = 130
        token.alignmentMode = .center
        token.foregroundColor = NSColor.systemRed.cgColor
        token.contentsScale = NSScreen.screens.first?.backingScaleFactor ?? 2.0
        // Black halo: the token crosses whatever is on the desktop on its way to
        // the clock, and red on red text needs an edge to stay readable.
        token.shadowColor = NSColor.black.cgColor
        token.shadowRadius = 6
        token.shadowOpacity = 1
        token.shadowOffset = .zero
        token.masksToBounds = false
        token.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        token.position = start
        hostLayer.addSublayer(token)
        inFlight += 1

        let t0 = CACurrentMediaTime()
        let dur = Self.flightSeconds
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak token] tm in
            guard let token else { tm.invalidate(); return }
            guard let tgGlobal = targetGlobal() else {
                // The clock went away mid-flight — drop the token, subtract nothing.
                tm.invalidate()
                CATransaction.begin()
                CATransaction.setCompletionBlock {
                    token.removeFromSuperlayer()
                    self?.landed()
                }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = token.presentation()?.opacity ?? 1
                fade.toValue = 0
                fade.duration = 0.25
                fade.fillMode = .forwards
                fade.isRemovedOnCompletion = false
                token.add(fade, forKey: "fizzle")
                CATransaction.commit()
                return
            }
            let target = CGPoint(x: tgGlobal.x - screen.origin.x, y: tgGlobal.y - screen.origin.y)
            let raw = min(1.0, (CACurrentMediaTime() - t0) / dur)
            // easeInOut: it leaves the blast gently, covers the distance, then settles.
            let e = CGFloat(raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2)
            let arc = sin(Double(e) * .pi) * 70                  // a hump, so it "floats" over
            CATransaction.begin()
            CATransaction.setDisableActions(true)                // we ARE the animation
            token.position = CGPoint(x: start.x + (target.x - start.x) * e,
                                     y: start.y + (target.y - start.y) * e + CGFloat(arc))
            let s = 1 - 0.5 * e                                  // full size → half at the clock
            token.transform = CATransform3DMakeScale(s, s, 1)
            token.opacity = Float(e > 0.88 ? (1 - (e - 0.88) / 0.12) : 1)
            CATransaction.commit()

            if raw >= 1.0 {
                tm.invalidate()
                let host = token.superlayer
                token.removeFromSuperlayer()
                if burstOnArrival, let host, let self {
                    // The panel must outlive the burst — but not as a minute in
                    // flight, which `coffeePopWins` counts.
                    self.bursting += 1
                    Self.burst(at: target, in: host) { [weak self] in
                        guard let self else { return }
                        self.bursting -= 1
                        self.takeDownIfIdle()
                    }
                }
                self?.landed()
                onArrival()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static let burstSeconds: CFTimeInterval = 0.6

    /// A flash, a shock ring and a spray of red/orange/yellow sparks out of
    /// `center`, all gone in `burstSeconds`; `done` once the layers are removed.
    /// Sparks fly mostly sideways and down — up is off the top of the screen.
    private static func burst(at center: CGPoint, in host: CALayer, done: @escaping () -> Void) {
        let group = CALayer()
        group.frame = host.bounds
        host.addSublayer(group)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            group.removeFromSuperlayer()
            done()
        }
        func fadeAndGrow(_ layer: CALayer, scale: CGFloat) {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.2; grow.toValue = scale
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [grow, fade]
            g.duration = burstSeconds
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.fillMode = .forwards; g.isRemovedOnCompletion = false
            layer.add(g, forKey: "burst")
        }
        // White-hot core.
        let flash = CALayer()
        flash.bounds = CGRect(x: 0, y: 0, width: 46, height: 46)
        flash.cornerRadius = 23
        flash.position = center
        flash.backgroundColor = NSColor(calibratedRed: 1, green: 0.95, blue: 0.7, alpha: 1).cgColor
        flash.shadowColor = NSColor.systemOrange.cgColor
        flash.shadowRadius = 14; flash.shadowOpacity = 1; flash.shadowOffset = .zero
        group.addSublayer(flash)
        fadeAndGrow(flash, scale: 1.6)
        // Shock ring.
        let ring = CALayer()
        ring.bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        ring.cornerRadius = 30
        ring.position = center
        ring.borderWidth = 4
        ring.borderColor = NSColor.systemRed.cgColor
        group.addSublayer(ring)
        fadeAndGrow(ring, scale: 3.2)
        // Sparks.
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow]
        let count = 18
        for i in 0..<count {
            // Lower half-circle plus a bit above the horizon (angles in AppKit's y-up space).
            let angle = Double.pi * (1.1 + 0.8 * Double(i) / Double(count - 1))
                + Double.random(in: -0.12...0.12)
            let dist = CGFloat.random(in: 55...110)
            let spark = CALayer()
            let d = CGFloat.random(in: 6...10)
            spark.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            spark.cornerRadius = d / 2
            spark.backgroundColor = colors[i % colors.count].cgColor
            spark.position = center
            group.addSublayer(spark)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: center)
            move.toValue = NSValue(point: CGPoint(x: center.x + CGFloat(cos(angle)) * dist,
                                                  y: center.y + CGFloat(sin(angle)) * dist))
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1; shrink.toValue = 0.3
            let g = CAAnimationGroup()
            g.animations = [move, fade, shrink]
            g.duration = burstSeconds
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.fillMode = .forwards; g.isRemovedOnCompletion = false
            spark.add(g, forKey: "burst")
        }
        CATransaction.commit()
    }

    /// The panel's layer, creating and showing the panel on first use.
    private func hostLayer() -> CALayer? {
        if panel == nil {
            let fresh = AddonsOverlayPanel(screen: AppDelegate.findRetinaScreen())
            panel = fresh
        }
        panel?.refreshScreenFrame()
        panel?.orderFrontRegardless()
        return panel?.contentView?.layer
    }

    private func landed() {
        inFlight = max(0, inFlight - 1)
        takeDownIfIdle()
    }

    private func takeDownIfIdle() {
        guard inFlight == 0, bursting == 0 else { return }
        panel?.orderOut(nil)
        panel = nil
    }
}
