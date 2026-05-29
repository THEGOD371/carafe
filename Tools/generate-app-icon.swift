#!/usr/bin/env swift

// Procedural Carafe app-icon generator.
//
// Draws the carafe silhouette directly into a CGContext at each
// macOS-required pixel size, writes them into an `.iconset` working
// directory, then runs `iconutil -c icns` to produce a final
// `Carafe/Resources/AppIcon.icns` with all ten size slots populated.
//
// Usage (from repo root):
//
//     swift Tools/generate-app-icon.swift
//
// Why not use the Xcode asset-catalog AppIcon.appiconset?
// -------------------------------------------------------
// We tried that. Xcode's actool silently dedup-merges PNG slots
// that have byte-identical contents (e.g. our 32×32 `icon_32x32.png`
// and `icon_16x16@2x.png` are the same 32×32 image rendered
// twice). When it merges, it incorrectly drops six of the ten size
// slots from the produced `AppIcon.icns` — only 16, 32, 128, and
// 256 px survive. No warning is emitted. The dock then can't find
// a high-resolution image and renders the system default.
//
// `iconutil` (Apple's command-line tool, part of Xcode CLT) has no
// such dedup behaviour: it packs every `.iconset` entry into the
// corresponding icns chunk regardless of content. So we generate
// the PNGs, hand the iconset to iconutil, and ship the bare .icns
// as a bundle resource via CFBundleIconFile.
//
// DESIGN
// ------
// * Background: rounded rect (continuous corners — Apple Big Sur+
//   spec, ratio ≈0.2237) with a dark wine-purple gradient running
//   top-left → bottom-right.
// * Carafe: warm cream silhouette. Body bulges outward at ~32% of
//   icon height, narrows to a slim neck, flares slightly at mouth.
// * Wine fill: clipped red region inside the carafe body, ~40% of
//   icon height. Reinforces the "carafe = wine" double meaning.
// * Rim highlight: thin semi-transparent white arc on upper-left of
//   the body. Suppressed at sizes < 64 px (would just muddy the
//   silhouette).

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Bitmap context helper

func makeBitmap(size: Int) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Couldn't create CGContext at \(size)x\(size)")
    }
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    return ctx
}

// MARK: - Carafe drawing

func drawCarafeIcon(into ctx: CGContext, size: CGFloat) {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * size, y: y * size)
    }

    // 1. Background — rounded rect + wine-purple gradient.
    let bgRadius = size * 0.2237
    let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
    let bgPath = CGPath(
        roundedRect: bgRect,
        cornerWidth: bgRadius,
        cornerHeight: bgRadius,
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

    // 2. Carafe outline — closed Bezier path, counterclockwise.
    let carafe = CGMutablePath()
    carafe.move(to: p(0.30, 0.14))
    carafe.addCurve(to: p(0.70, 0.14),
                    control1: p(0.40, 0.12),
                    control2: p(0.60, 0.12))
    carafe.addCurve(to: p(0.80, 0.32),
                    control1: p(0.77, 0.16),
                    control2: p(0.82, 0.24))
    carafe.addCurve(to: p(0.66, 0.55),
                    control1: p(0.80, 0.42),
                    control2: p(0.73, 0.50))
    carafe.addCurve(to: p(0.58, 0.62),
                    control1: p(0.63, 0.58),
                    control2: p(0.60, 0.60))
    carafe.addLine(to: p(0.58, 0.80))
    carafe.addCurve(to: p(0.60, 0.86),
                    control1: p(0.58, 0.82),
                    control2: p(0.59, 0.84))
    carafe.addCurve(to: p(0.40, 0.86),
                    control1: p(0.55, 0.88),
                    control2: p(0.45, 0.88))
    carafe.addCurve(to: p(0.42, 0.80),
                    control1: p(0.41, 0.84),
                    control2: p(0.42, 0.82))
    carafe.addLine(to: p(0.42, 0.62))
    carafe.addCurve(to: p(0.34, 0.55),
                    control1: p(0.40, 0.60),
                    control2: p(0.37, 0.58))
    carafe.addCurve(to: p(0.20, 0.32),
                    control1: p(0.27, 0.50),
                    control2: p(0.20, 0.42))
    carafe.addCurve(to: p(0.30, 0.14),
                    control1: p(0.18, 0.24),
                    control2: p(0.23, 0.16))
    carafe.closeSubpath()

    // 3. Cream fill.
    ctx.saveGState()
    ctx.addPath(carafe)
    ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.91, blue: 0.80, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // 4. Wine fill — clipped to carafe outline + lower 40 %.
    ctx.saveGState()
    ctx.addPath(carafe)
    ctx.clip()
    ctx.setFillColor(CGColor(srgbRed: 0.50, green: 0.05, blue: 0.10, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size * 0.40))
    ctx.restoreGState()

    // 5. Rim highlight — suppress at small sizes.
    if size >= 64 {
        ctx.saveGState()
        ctx.addPath(carafe)
        ctx.clip()
        ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.20))
        ctx.setLineWidth(size * 0.018)
        ctx.setLineCap(.round)
        let hl = CGMutablePath()
        hl.move(to: p(0.26, 0.42))
        hl.addCurve(to: p(0.33, 0.20),
                    control1: p(0.23, 0.34),
                    control2: p(0.27, 0.24))
        ctx.addPath(hl)
        ctx.strokePath()
        ctx.restoreGState()
    }

    ctx.restoreGState()
}

// MARK: - PNG / iconutil pipeline

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("Couldn't create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Couldn't write PNG at \(url.path)")
    }
}

/// Run `xcrun iconutil -c icns <iconsetDir> -o <icnsPath>` and bail
/// on non-zero exit. The output is captured and printed for
/// transparency — iconutil typically stays silent on success.
func runIconutil(iconsetDir: URL, icnsPath: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["iconutil", "-c", "icns", iconsetDir.path, "-o", icnsPath.path]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fatalError("Failed to launch iconutil: \(error)")
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    if !output.isEmpty {
        print("iconutil: \(output)")
    }
    guard process.terminationStatus == 0 else {
        fatalError("iconutil failed (exit \(process.terminationStatus))")
    }
}

// MARK: - Driver

// Iconset directory is a build artifact — kept out of the source
// tree so xcodegen doesn't try to include its PNGs as separate
// bundle resources. The final .icns IS in the source tree (so
// xcodegen picks it up automatically) but the intermediate PNGs
// don't ship.
let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetDir = repoRoot.appendingPathComponent("Tools/build/AppIcon.iconset")
let icnsPath = repoRoot.appendingPathComponent("Carafe/Resources/AppIcon.icns")

// Clean + recreate the iconset dir so stale entries from a previous
// design can't sneak into the .icns.
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: icnsPath.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)

// iconset format — 10 specific filenames iconutil recognises.
let sizes: [(pixels: Int, filename: String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

print("Generating Carafe app icon — \(sizes.count) PNGs into \(iconsetDir.path)")
for (px, filename) in sizes {
    let ctx = makeBitmap(size: px)
    drawCarafeIcon(into: ctx, size: CGFloat(px))
    guard let cgImage = ctx.makeImage() else {
        fatalError("Couldn't materialize image for \(filename)")
    }
    let url = iconsetDir.appendingPathComponent(filename)
    writePNG(cgImage, to: url)
    print("  ✓ \(filename) (\(px)×\(px))")
}

print("Packing into \(icnsPath.path)…")
runIconutil(iconsetDir: iconsetDir, icnsPath: icnsPath)

// Verify the icns landed and looks plausible.
if let attrs = try? FileManager.default.attributesOfItem(atPath: icnsPath.path),
   let size = attrs[.size] as? Int {
    print("  ✓ AppIcon.icns (\(size) bytes)")
} else {
    fatalError("AppIcon.icns missing after iconutil ran")
}

// Strip the `com.apple.provenance` extended attribute that Swift's
// toolchain auto-applies to script outputs. codesign treats it as
// detritus and refuses to sign bundles containing files that carry
// it. `xattr -c` clears every xattr — safer than enumerating just
// the offender, since other Apple-internal attrs hit the same trap.
let xattr = Process()
xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
xattr.arguments = ["-c", icnsPath.path]
try? xattr.run()
xattr.waitUntilExit()

print("Done.")
