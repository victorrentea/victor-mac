#!/usr/bin/env swift
// The Dock icon: the menu bar's V in a ring (icon_v.png), as large as the canvas
// allows — the ring is the icon's edge, no squircle around it (Victor, 2026-11-19:
// "the same V in a circle, as large and visible as possible"). A dark disc inside
// the ring keeps the white marks readable on a light Dock as on a dark one.
//
//   swift tools/make-app-icon.swift [out.png]   (default: Sources/VictorAddons/Resources/icon_app.png)
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : "Sources/VictorAddons/Resources/icon_app.png"
let side: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let margin: CGFloat = 16
let disc = NSRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin)
NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
NSBezierPath(ovalIn: disc).fill()

let ring: CGFloat = 70
let circle = NSBezierPath(ovalIn: disc.insetBy(dx: ring / 2, dy: ring / 2))
circle.lineWidth = ring
NSColor.white.setStroke()
circle.stroke()

// The V, proportioned like icon_v.png's: arms from ~30 % to ~70 % across, tip low.
let v = NSBezierPath()
v.move(to: NSPoint(x: side * 0.335, y: side * 0.69))
v.line(to: NSPoint(x: side * 0.50, y: side * 0.30))
v.line(to: NSPoint(x: side * 0.665, y: side * 0.69))
v.lineWidth = 118
v.lineCapStyle = .round
v.lineJoinStyle = .round
v.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
