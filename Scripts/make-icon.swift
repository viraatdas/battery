#!/usr/bin/env swift
//
// make-icon.swift — draws BatteryScope.app's icon and emits Resources/AppIcon.icns.
//
// No external tools or packages: CoreGraphics does the drawing, AppKit's
// NSBitmapImageRep does PNG encoding, and the `iconutil` that ships with every
// Mac turns the resulting .iconset into a proper .icns. Run it whenever the
// icon design changes and commit the regenerated Resources/AppIcon.icns —
// bundle-app.sh only copies it, it does not regenerate it.
//
//   swift Scripts/make-icon.swift
//
import AppKit
import CoreGraphics
import Foundation

// MARK: - Paths

// Resolve relative to this script's own path (not the caller's cwd) so the
// script works the same whether it is invoked from the repo root or elsewhere.
let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let resourcesDir = repoRoot.appendingPathComponent("Resources")
let outputICNS = resourcesDir.appendingPathComponent("AppIcon.icns")

let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("batteryscope-icon-\(ProcessInfo.processInfo.globallyUniqueString)")
let iconsetDir = workDir.appendingPathComponent("AppIcon.iconset")

try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// MARK: - Drawing

// The plate reads as "battery" (deep green-to-near-black, the same family
// macOS uses for its own Battery preference icon) so it sits naturally next
// to system icons. The motif inside is a battery whose fill is split into
// distinct, proportional segments — a breakdown, not a charge indicator.
// A bolt-in-a-battery reads as "charging," which is the opposite of what
// this app does: it shows where charge already went. A divided battery says
// "measured and attributed" instead, and three flat color blocks stay
// legible at 16pt where a bolt's diagonal strokes go muddy.
let plateTop = CGColor(red: 0.22, green: 0.78, blue: 0.49, alpha: 1.0)
let plateBottom = CGColor(red: 0.03, green: 0.20, blue: 0.14, alpha: 1.0)
let shellColor = CGColor(red: 0.96, green: 0.99, blue: 0.97, alpha: 0.96)
// Three deliberately distinct hues (warm amber, coral, sky blue) so the
// segments read as separate categories rather than one muddy block, even
// once anti-aliased down to a handful of pixels.
let segmentColors: [CGColor] = [
    CGColor(red: 1.00, green: 0.76, blue: 0.27, alpha: 1.0),
    CGColor(red: 1.00, green: 0.35, blue: 0.37, alpha: 1.0),
    CGColor(red: 0.35, green: 0.78, blue: 0.98, alpha: 1.0),
]
// Biggest consumer first, smallest last — the same shape as the app's own
// top-offenders breakdown.
let segmentProportions: [CGFloat] = [0.48, 0.32, 0.20]

func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// A superellipse ("squircle") traced across the full rect, the continuous
// corner curve modern macOS app icons use — visibly smoother through the
// corner than a quarter-circle rounded rect, with no straight run before the
// curve starts. Exponent 5 approximates Apple's own icon curvature.
func squirclePath(_ rect: CGRect, exponent: CGFloat = 5, steps: Int = 240) -> CGPath {
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    let path = CGMutablePath()
    for i in 0...steps {
        let t = (CGFloat(i) / CGFloat(steps)) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = cx + a * (cosT < 0 ? -1 : 1) * pow(abs(cosT), 2 / exponent)
        let y = cy + b * (sinT < 0 ? -1 : 1) * pow(abs(sinT), 2 / exponent)
        let point = CGPoint(x: x, y: y)
        if i == 0 {
            path.move(to: point)
        } else {
            path.addLine(to: point)
        }
    }
    path.closeSubpath()
    return path
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("failed to create bitmap context at size \(size)")
    }
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // 1. Squircle plate. A real margin (~10% a side) instead of a near-full-bleed
    //    fill is what makes it read as an icon sitting in a Dock/Finder grid
    //    rather than a swatch cropped by the canvas edge.
    let inset = s * 0.10
    let plateRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let platePath = squirclePath(plateRect)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [plateTop, plateBottom] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: plateRect.midX, y: plateRect.maxY),
        end: CGPoint(x: plateRect.midX, y: plateRect.minY),
        options: []
    )
    // Subtle top gloss so the plate reads as a physical surface, not a flat
    // fill — restrained enough that it disappears at 16pt rather than muddying it.
    let glossRect = CGRect(
        x: plateRect.minX,
        y: plateRect.midY,
        width: plateRect.width,
        height: plateRect.height * 0.55
    )
    let glossGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.16), CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        glossGradient,
        start: CGPoint(x: glossRect.midX, y: glossRect.maxY),
        end: CGPoint(x: glossRect.midX, y: glossRect.minY),
        options: []
    )
    ctx.restoreGState()

    // 2. Battery shell: a stroked rounded rect with a small terminal nub,
    //    centered on the plate.
    let bodyWidth = plateRect.width * 0.52
    let bodyHeight = plateRect.height * 0.30
    let bodyRect = CGRect(
        x: plateRect.midX - bodyWidth / 2 - plateRect.width * 0.02,
        y: plateRect.midY - bodyHeight / 2,
        width: bodyWidth,
        height: bodyHeight
    )
    let strokeWidth = max(s * 0.045, 1.0)
    let bodyRadius = bodyHeight * 0.28

    ctx.setStrokeColor(shellColor)
    ctx.setLineWidth(strokeWidth)
    ctx.setLineJoin(.round)
    ctx.addPath(roundedRectPath(bodyRect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2), radius: bodyRadius))
    ctx.strokePath()

    let nubWidth = plateRect.width * 0.045
    let nubHeight = bodyHeight * 0.42
    let nubRect = CGRect(
        x: bodyRect.maxX - strokeWidth * 0.2,
        y: plateRect.midY - nubHeight / 2,
        width: nubWidth,
        height: nubHeight
    )
    ctx.setFillColor(shellColor)
    ctx.addPath(roundedRectPath(nubRect, radius: nubWidth * 0.35))
    ctx.fillPath()

    // 3. The breakdown motif: the battery's fill split into proportional
    //    segments with real padding on every side, so they nest inside the
    //    shell instead of colliding with its stroke.
    let interiorRect = bodyRect
        .insetBy(dx: strokeWidth * 1.4, dy: strokeWidth * 1.4)
        .insetBy(dx: bodyHeight * 0.05, dy: bodyHeight * 0.16)
    let segmentGap = interiorRect.width * 0.05
    let totalGap = segmentGap * CGFloat(segmentProportions.count - 1)
    let usableWidth = interiorRect.width - totalGap
    let segmentRadius = interiorRect.height * 0.22

    var cursorX = interiorRect.minX
    for (index, proportion) in segmentProportions.enumerated() {
        let segmentWidth = usableWidth * proportion
        let segmentRect = CGRect(x: cursorX, y: interiorRect.minY, width: segmentWidth, height: interiorRect.height)
        ctx.setFillColor(segmentColors[index % segmentColors.count])
        ctx.addPath(roundedRectPath(segmentRect, radius: segmentRadius))
        ctx.fillPath()
        cursorX += segmentWidth + segmentGap
    }

    guard let image = ctx.makeImage() else {
        fatalError("failed to render icon at size \(size)")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("failed to encode PNG at \(url.path)")
    }
    do {
        try data.write(to: url)
    } catch {
        fatalError("failed to write \(url.path): \(error)")
    }
}

// MARK: - Iconset

// (filename, pixel size) pairs iconutil expects for a complete .icns.
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

print("==> Rendering \(variants.count) icon sizes")
for (name, size) in variants {
    let image = drawIcon(size: size)
    writePNG(image, to: iconsetDir.appendingPathComponent(name))
    print("    \(name) (\(size)x\(size))")
}

// MARK: - iconutil

print("==> Running iconutil")
try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir.path, "-o", outputICNS.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    fatalError("iconutil exited with status \(task.terminationStatus)")
}

try? FileManager.default.removeItem(at: workDir)

let attributes = try FileManager.default.attributesOfItem(atPath: outputICNS.path)
let byteSize = (attributes[.size] as? Int) ?? 0
print("==> Wrote \(outputICNS.path) (\(byteSize) bytes)")
