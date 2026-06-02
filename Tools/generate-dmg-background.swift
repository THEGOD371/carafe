#!/usr/bin/env swift

// Procedural DMG background generator.
//
// Produces `dmg-background.png` in CARAFE_BUILD_DIR (1320×800 pixels = 2× the
// 660×400-point Finder window we'll show), drawn in the same wine-
// purple gradient as the app icon so the install experience reads as
// one continuous brand surface.
//
// Layout in logical (660×400) terms:
//
//   y=20–100   Carafe logo (small app-icon at 80×80)
//   y=110–138  "Carafe" wordmark, centered, 30 pt
//   y=145–168  version label, centered, 16 pt
//   y=201–329  Free zone where `create-dmg` will composite the
//              .app and Applications icons (icon-size 128, centered
//              on y=265)
//
// The icons themselves are NOT drawn into the background — that's
// `create-dmg`'s job. The background only provides the gradient +
// branding chrome; the icons sit on top.
//
// Usage (from repo root):
//
//     swift Tools/generate-dmg-background.swift
//
// FRAGILITY
// ---------
// * The 1320×800 size is hard-coded to match the window size we set
//   in `build-dmg.sh` (660×400 × 2 for retina). If you change one,
//   change both.
// * Text positions assume SF Pro is available (system default on
//   macOS 14+). On a stripped-down build host it might fall back to
//   Helvetica — the layout still works but the wordmark looks less
//   "Apple-native".
// * The carafe-icon drawing routine is duplicated from
//   `Tools/generate-app-icon.swift`. Standalone scripts are easier to
//   reason about than a shared module; if you change the icon design
//   keep them in sync.

import AppKit
import CoreGraphics
import Foundation

let carafeVersion = ProcessInfo.processInfo.environment["CARAFE_VERSION"] ?? "0.1.4"
import ImageIO
import UniformTypeIdentifiers

// MARK: - Canvas

let canvasWidth = 1320
let canvasHeight = 800

func makeBitmap(width: Int, height: Int) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Couldn't create CGContext at \(width)x\(height)")
    }
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    return ctx
}

// MARK: - Carafe-icon drawing (duplicated from generate-app-icon.swift)
//
// Keep this in sync with the canonical version in
// Tools/generate-app-icon.swift. Both produce the exact same visual
// design — colors, gradient direction, Bezier control points.

func drawCarafeIcon(into ctx: CGContext, size: CGFloat) {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * size, y: y * size)
    }

    let bgRadius = size * 0.2237
    let bgPath = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
        cornerWidth: bgRadius, cornerHeight: bgRadius,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let bgGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(srgbRed: 0.18, green: 0.07, blue: 0.13, alpha: 1.0),
            CGColor(srgbRed: 0.04, green: 0.01, blue: 0.03, alpha: 1.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )

    let carafe = CGMutablePath()
    carafe.move(to: p(0.30, 0.14))
    carafe.addCurve(to: p(0.70, 0.14), control1: p(0.40, 0.12), control2: p(0.60, 0.12))
    carafe.addCurve(to: p(0.80, 0.32), control1: p(0.77, 0.16), control2: p(0.82, 0.24))
    carafe.addCurve(to: p(0.66, 0.55), control1: p(0.80, 0.42), control2: p(0.73, 0.50))
    carafe.addCurve(to: p(0.58, 0.62), control1: p(0.63, 0.58), control2: p(0.60, 0.60))
    carafe.addLine(to: p(0.58, 0.80))
    carafe.addCurve(to: p(0.60, 0.86), control1: p(0.58, 0.82), control2: p(0.59, 0.84))
    carafe.addCurve(to: p(0.40, 0.86), control1: p(0.55, 0.88), control2: p(0.45, 0.88))
    carafe.addCurve(to: p(0.42, 0.80), control1: p(0.41, 0.84), control2: p(0.42, 0.82))
    carafe.addLine(to: p(0.42, 0.62))
    carafe.addCurve(to: p(0.34, 0.55), control1: p(0.40, 0.60), control2: p(0.37, 0.58))
    carafe.addCurve(to: p(0.20, 0.32), control1: p(0.27, 0.50), control2: p(0.20, 0.42))
    carafe.addCurve(to: p(0.30, 0.14), control1: p(0.18, 0.24), control2: p(0.23, 0.16))
    carafe.closeSubpath()

    ctx.saveGState()
    ctx.addPath(carafe)
    ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.91, blue: 0.80, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(carafe)
    ctx.clip()
    ctx.setFillColor(CGColor(srgbRed: 0.50, green: 0.05, blue: 0.10, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size * 0.40))
    ctx.restoreGState()

    if size >= 64 {
        ctx.saveGState()
        ctx.addPath(carafe)
        ctx.clip()
        ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.20))
        ctx.setLineWidth(size * 0.018)
        ctx.setLineCap(.round)
        let hl = CGMutablePath()
        hl.move(to: p(0.26, 0.42))
        hl.addCurve(to: p(0.33, 0.20), control1: p(0.23, 0.34), control2: p(0.27, 0.24))
        ctx.addPath(hl)
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

// MARK: - Text helpers

/// Draw text centered horizontally at `x`, with `visualTopY` being
/// the desired y-coordinate of the text's TOP edge measured from the
/// VISUAL TOP of the canvas (top-down, as a human reads). Internally
/// converts to the CGContext's bottom-up coordinate system.
func drawCenteredText(
    _ str: String,
    attrs: [NSAttributedString.Key: Any],
    x: CGFloat,
    visualTopY: CGFloat
) {
    let s = str as NSString
    let size = s.size(withAttributes: attrs)
    let cgX = x - size.width / 2
    let cgY = CGFloat(canvasHeight) - visualTopY - size.height
    s.draw(at: NSPoint(x: cgX, y: cgY), withAttributes: attrs)
}

// MARK: - PNG output

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1, nil
    ) else { fatalError("Couldn't create PNG dest at \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Couldn't finalize PNG at \(url.path)")
    }
}

// MARK: - Driver

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CARAFE_BUILD_DIR"] ?? repoRoot.appendingPathComponent("Tools/build").path)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let outURL = outDir.appendingPathComponent("dmg-background.png")

// 1. Create the canvas with the gradient already painted.
let ctx = makeBitmap(width: canvasWidth, height: canvasHeight)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let bgGradient = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(srgbRed: 0.18, green: 0.07, blue: 0.13, alpha: 1.0),  // deep wine
        CGColor(srgbRed: 0.04, green: 0.01, blue: 0.03, alpha: 1.0),  // near-black plum
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: CGFloat(canvasHeight)),
    end: CGPoint(x: CGFloat(canvasWidth), y: 0),
    options: []
)

// 2. Render the carafe logo into an off-screen context, then
//    composite it into the background. Drawing at 2× the destination
//    size and then downscaling gives a crisp logo on retina.
let logoPixelSize = 160              // pixel dimensions in the bg canvas (= 80×80 logical)
let logoSourceSize = logoPixelSize * 2  // 2× supersample for crispness
let logoCtx = makeBitmap(width: logoSourceSize, height: logoSourceSize)
drawCarafeIcon(into: logoCtx, size: CGFloat(logoSourceSize))
guard let logoImage = logoCtx.makeImage() else {
    fatalError("Couldn't render carafe logo")
}

// Logo destination: centered horizontally (canvas 1320, logo 160 → x=580),
// with visual top at y=40 (= pixel y=40 from visual top
// = CG y = 800 - 40 - 160 = 600).
let logoCGY = CGFloat(canvasHeight) - 40 - CGFloat(logoPixelSize)
ctx.draw(
    logoImage,
    in: CGRect(x: 580, y: logoCGY, width: CGFloat(logoPixelSize), height: CGFloat(logoPixelSize))
)

// 3. Set up NSGraphicsContext for text drawing. The CGContext stays
//    bottom-up; NSString.draw uses the same coordinate system when
//    `flipped: false`, so y-handling matches what we did for the
//    logo composite above.
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

let cream = NSColor(srgbRed: 0.96, green: 0.91, blue: 0.80, alpha: 1.0)

// 4. "Carafe" wordmark.
let wordmarkAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 60, weight: .semibold),
    .foregroundColor: cream,
]
drawCenteredText(
    "Carafe",
    attrs: wordmarkAttrs,
    x: CGFloat(canvasWidth) / 2,
    visualTopY: 220   // pixel y=220 from visual top of canvas
)

// 5. Version label, muted.
let versionAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 30, weight: .regular),
    .foregroundColor: cream.withAlphaComponent(0.60),
]
drawCenteredText(
    carafeVersion,
    attrs: versionAttrs,
    x: CGFloat(canvasWidth) / 2,
    visualTopY: 300   // pixel y=300 (sits ~10 px below the wordmark)
)

NSGraphicsContext.restoreGraphicsState()

// 6. Save.
guard let finalImage = ctx.makeImage() else {
    fatalError("Couldn't finalize background image")
}
writePNG(finalImage, to: outURL)
print("✓ DMG background → \(outURL.path) (\(canvasWidth)×\(canvasHeight))")
