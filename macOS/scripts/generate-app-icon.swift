import AppKit
import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let projectRoot = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let outputDirectory = projectRoot.appendingPathComponent("assets/icons", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let canvasSize = 1024

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [NSColor], in path: NSBezierPath, angle: CGFloat = 90) {
    NSGradient(colors: colors)!.draw(in: path, angle: angle)
}

func drawBridgeGlow() {
    let path = NSBezierPath()
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: NSPoint(x: 400, y: 494))
    path.curve(to: NSPoint(x: 716, y: 486), controlPoint1: NSPoint(x: 468, y: 594), controlPoint2: NSPoint(x: 655, y: 588))

    let glow = NSShadow()
    glow.shadowColor = color(0x4BC8FF, alpha: 0.9)
    glow.shadowBlurRadius = 28
    glow.shadowOffset = .zero
    glow.set()
    color(0x4BC8FF, alpha: 0.72).setStroke()
    path.lineWidth = 21
    path.stroke()
    NSShadow().set()

    color(0xD8F6FF, alpha: 0.95).setStroke()
    path.lineWidth = 8
    path.stroke()

    for point in [NSPoint(x: 400, y: 494), NSPoint(x: 716, y: 486)] {
        let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20))
        color(0xE7FBFF).setFill()
        dot.fill()
    }
}

func drawDevices() {
    let laptopBase = NSBezierPath()
    laptopBase.move(to: NSPoint(x: 180, y: 347))
    laptopBase.line(to: NSPoint(x: 648, y: 347))
    laptopBase.line(to: NSPoint(x: 720, y: 291))
    laptopBase.curve(to: NSPoint(x: 665, y: 274), controlPoint1: NSPoint(x: 706, y: 274), controlPoint2: NSPoint(x: 685, y: 274))
    laptopBase.line(to: NSPoint(x: 158, y: 274))
    laptopBase.curve(to: NSPoint(x: 111, y: 291), controlPoint1: NSPoint(x: 132, y: 274), controlPoint2: NSPoint(x: 116, y: 277))
    laptopBase.close()
    gradient([color(0xE5EFFB), color(0x667C9D), color(0x34445F)], in: laptopBase, angle: 90)
    color(0xF4FAFF, alpha: 0.64).setStroke()
    laptopBase.lineWidth = 4
    laptopBase.stroke()

    let laptopScreen = NSBezierPath(roundedRect: NSRect(x: 158, y: 328, width: 532, height: 398), xRadius: 57, yRadius: 57)
    let laptopShadow = NSShadow()
    laptopShadow.shadowColor = color(0x000711, alpha: 0.52)
    laptopShadow.shadowBlurRadius = 38
    laptopShadow.shadowOffset = NSSize(width: 0, height: -22)
    laptopShadow.set()
    gradient([color(0xD8E6F4), color(0x687F9F), color(0x344461)], in: laptopScreen, angle: 115)
    NSShadow().set()
    color(0xF3FAFF, alpha: 0.8).setStroke()
    laptopScreen.lineWidth = 5
    laptopScreen.stroke()

    let laptopDisplay = NSBezierPath(roundedRect: NSRect(x: 184, y: 354, width: 480, height: 346), xRadius: 39, yRadius: 39)
    gradient([color(0x19284C), color(0x11182D), color(0x202A45)], in: laptopDisplay, angle: 132)
    color(0xA9C9FF, alpha: 0.42).setStroke()
    laptopDisplay.lineWidth = 3
    laptopDisplay.stroke()

    let laptopShine = NSBezierPath()
    laptopShine.move(to: NSPoint(x: 222, y: 676))
    laptopShine.curve(to: NSPoint(x: 590, y: 672), controlPoint1: NSPoint(x: 335, y: 712), controlPoint2: NSPoint(x: 468, y: 707))
    laptopShine.lineCapStyle = .round
    color(0xFFFFFF, alpha: 0.17).setStroke()
    laptopShine.lineWidth = 7
    laptopShine.stroke()

    drawBridgeGlow()

    let phoneBody = NSBezierPath(roundedRect: NSRect(x: 579, y: 252, width: 262, height: 516), xRadius: 72, yRadius: 72)
    let phoneShadow = NSShadow()
    phoneShadow.shadowColor = color(0x000711, alpha: 0.66)
    phoneShadow.shadowBlurRadius = 42
    phoneShadow.shadowOffset = NSSize(width: 5, height: -18)
    phoneShadow.set()
    gradient([color(0xF3F7FE), color(0x8EA1BE), color(0x445673)], in: phoneBody, angle: 125)
    NSShadow().set()
    color(0xF9FCFF, alpha: 0.92).setStroke()
    phoneBody.lineWidth = 5
    phoneBody.stroke()

    let phoneScreen = NSBezierPath(roundedRect: NSRect(x: 600, y: 274, width: 220, height: 472), xRadius: 57, yRadius: 57)
    gradient([color(0x121A2B), color(0x192B50), color(0x122038)], in: phoneScreen, angle: 120)
    color(0xB8D6FF, alpha: 0.45).setStroke()
    phoneScreen.lineWidth = 3
    phoneScreen.stroke()

    let speaker = NSBezierPath(roundedRect: NSRect(x: 671, y: 713, width: 72, height: 8), xRadius: 4, yRadius: 4)
    color(0xE4F1FF, alpha: 0.82).setFill()
    speaker.fill()
    let camera = NSBezierPath(ovalIn: NSRect(x: 751, y: 710, width: 11, height: 11))
    color(0x8BE1FF).setFill()
    camera.fill()

    let screenReflection = NSBezierPath()
    screenReflection.move(to: NSPoint(x: 612, y: 641))
    screenReflection.curve(to: NSPoint(x: 794, y: 662), controlPoint1: NSPoint(x: 650, y: 685), controlPoint2: NSPoint(x: 748, y: 694))
    screenReflection.lineCapStyle = .round
    color(0xFFFFFF, alpha: 0.12).setStroke()
    screenReflection.lineWidth = 8
    screenReflection.stroke()
}

func drawBackground() {
    let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize), xRadius: 220, yRadius: 220)
    gradient([color(0x11172C), color(0x152743), color(0x201B3D)], in: background, angle: 138)

    NSGradient(colors: [color(0x2877E8, alpha: 0.38), color(0x2877E8, alpha: 0)])!
        .draw(fromCenter: NSPoint(x: 298, y: 648), radius: 0, toCenter: NSPoint(x: 298, y: 648), radius: 510, options: [.drawsAfterEndingLocation])
    NSGradient(colors: [color(0x9A60FF, alpha: 0.22), color(0x9A60FF, alpha: 0)])!
        .draw(fromCenter: NSPoint(x: 835, y: 705), radius: 0, toCenter: NSPoint(x: 835, y: 705), radius: 440, options: [.drawsAfterEndingLocation])

    let rim = NSBezierPath(roundedRect: NSRect(x: 18, y: 18, width: 988, height: 988), xRadius: 204, yRadius: 204)
    color(0xFFFFFF, alpha: 0.18).setStroke()
    rim.lineWidth = 3
    rim.stroke()

    for (x, y, radius, alpha) in [(142.0, 826.0, 7.0, 0.65), (880.0, 560.0, 5.0, 0.48), (324.0, 188.0, 4.0, 0.46), (824.0, 846.0, 6.0, 0.38)] {
        let sparkle = NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        color(0xDDF4FF, alpha: alpha).setFill()
        sparkle.fill()
    }
}

func renderIcon(background: Bool, scaleForeground: Bool) throws -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canvasSize,
        pixelsHigh: canvasSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    if background { drawBackground() }
    if scaleForeground {
        let transform = NSAffineTransform()
        transform.translateX(by: CGFloat(canvasSize) / 2, yBy: CGFloat(canvasSize) / 2)
        transform.scale(by: 0.72)
        transform.translateX(by: -CGFloat(canvasSize) / 2, yBy: -CGFloat(canvasSize) / 2)
        transform.concat()
    }
    drawDevices()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconURL = outputDirectory.appendingPathComponent("PhoneBridgeIcon.png")
let foregroundURL = outputDirectory.appendingPathComponent("PhoneBridgeForeground.png")
try renderIcon(background: true, scaleForeground: false).write(to: iconURL)
try renderIcon(background: false, scaleForeground: true).write(to: foregroundURL)
print("Created \(iconURL.path)")
print("Created \(foregroundURL.path)")
