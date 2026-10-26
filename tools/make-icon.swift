import AppKit
import ImageIO
import UniformTypeIdentifiers

let W: CGFloat = 1024

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: colors as CFArray,
               locations: locations)!
}

func fillPath(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
    ctx.restoreGState()
}

func fillRadial(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, center: CGPoint, radius: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
}

func arcPath(center: CGPoint, radius: CGFloat, startDeg: CGFloat, endDeg: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let steps = 260
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let deg = startDeg + (endDeg - startDeg) * t
        let a = deg * .pi / 180
        let pt = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    return p
}

func drawIcon(to url: URL) {
    guard let ctx = CGContext(data: nil, width: Int(W), height: Int(W),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("context")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: W)
    ctx.scaleBy(x: 1, y: -1)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 194, cornerHeight: 194, transform: nil)

    // Base
    fillPath(ctx, bodyPath,
             gradient([c(0xFDFEFF), c(0xF6F9FD), c(0xE8EFF9)],
                      [0, 0.5, 1]),
             from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))

    // Ambient glows
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    fillRadial(ctx, bodyPath,
               gradient([c(0x5C9CFF, 0.16), c(0x5C9CFF, 0.0)], [0, 1]),
               center: CGPoint(x: 240, y: 190), radius: 640)
    fillRadial(ctx, bodyPath,
               gradient([c(0xB7A5FF, 0.12), c(0xB7A5FF, 0.0)], [0, 1]),
               center: CGPoint(x: 870, y: 150), radius: 560)
    fillRadial(ctx, bodyPath,
               gradient([c(0xFFC2AC, 0.10), c(0xFFC2AC, 0.0)], [0, 1]),
               center: CGPoint(x: 540, y: 960), radius: 580)
    ctx.restoreGState()

    // inner edge highlight
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.setStrokeColor(c(0xFFFFFF, 0.75))
    ctx.setLineWidth(3)
    ctx.addPath(bodyPath)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.addPath(bodyPath)
    ctx.setStrokeColor(c(0xFFFFFF, 0.45))
    ctx.setLineWidth(1)
    ctx.strokePath()

    // Orb
    let orbCenter = CGPoint(x: 512, y: 502)
    let orbR: CGFloat = 298
    let orbRect = CGRect(x: orbCenter.x - orbR, y: orbCenter.y - orbR,
                         width: orbR * 2, height: orbR * 2)
    let orbPath = CGPath(ellipseIn: orbRect, transform: nil)

    // Contact shadow
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let shadowRect = CGRect(x: orbCenter.x - 235, y: orbCenter.y + 205, width: 470, height: 150)
    fillRadial(ctx, CGPath(ellipseIn: shadowRect, transform: nil),
               gradient([c(0x123163, 0.22), c(0x123163, 0.08), c(0x123163, 0.0)],
                        [0, 0.5, 1]),
               center: CGPoint(x: orbCenter.x, y: orbCenter.y + 275), radius: 270)
    ctx.restoreGState()

    // Sphere shading
    ctx.saveGState()
    ctx.addPath(orbPath)
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([c(0xC5DFFF), c(0x8ABAFE), c(0x4A88F2), c(0x1D55BE), c(0x0B2F7B)],
                 [0, 0.22, 0.52, 0.8, 1]),
        startCenter: CGPoint(x: orbCenter.x - 110, y: orbCenter.y - 150), startRadius: 10,
        endCenter: CGPoint(x: orbCenter.x + 70, y: orbCenter.y + 100), endRadius: 470,
        options: [])
    // deep corner
    fillRadial(ctx, orbPath,
               gradient([c(0x041B4A, 0.38), c(0x041B4A, 0.10), c(0x041B4A, 0.0)],
                        [0, 0.4, 1]),
               center: CGPoint(x: orbCenter.x + 265, y: orbCenter.y + 260), radius: 420)
    // bottom bounce
    fillRadial(ctx, orbPath,
               gradient([c(0x8EC2FF, 0.26), c(0x8EC2FF, 0.0)], [0, 1]),
               center: CGPoint(x: orbCenter.x + 20, y: orbCenter.y + 305), radius: 230)
    // soft top-left light
    fillRadial(ctx, orbPath,
               gradient([c(0xFFFFFF, 0.28), c(0xFFFFFF, 0.08), c(0xFFFFFF, 0.0)],
                        [0, 0.5, 1]),
               center: CGPoint(x: orbCenter.x - 145, y: orbCenter.y - 170), radius: 300)
    ctx.restoreGState()

    // Rim
    ctx.saveGState()
    ctx.addPath(orbPath)
    ctx.setStrokeColor(c(0xCFE5FF, 0.26))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // Small specular
    ctx.saveGState()
    ctx.addPath(orbPath)
    ctx.clip()
    ctx.setShadow(offset: .zero, blur: 34, color: c(0xFFFFFF, 0.45))
    ctx.setFillColor(c(0xFFFFFF, 0.22))
    ctx.fillEllipse(in: CGRect(x: orbCenter.x - 185, y: orbCenter.y - 218,
                               width: 164, height: 72))
    ctx.restoreGState()

    // Glyph: shadow silhouette first, then clean overpaint
    ctx.saveGState()
    ctx.translateBy(x: orbCenter.x, y: orbCenter.y)
    ctx.scaleBy(x: 1, y: -1)

    let glyphR: CGFloat = 136
    let startDeg: CGFloat = 118
    let endDeg: CGFloat = 426   // 66 + 360
    let strokeW: CGFloat = 46
    let endA = endDeg * .pi / 180
    let endPoint = CGPoint(x: cos(endA) * glyphR, y: sin(endA) * glyphR)
    let arc = arcPath(center: .zero, radius: glyphR, startDeg: startDeg, endDeg: endDeg)

    let tangent = CGPoint(x: -sin(endA), y: cos(endA))
    let radial = CGPoint(x: cos(endA), y: sin(endA))
    let tip = CGPoint(x: endPoint.x + tangent.x * 48, y: endPoint.y + tangent.y * 48)
    let halfWidth: CGFloat = 46
    let head = CGMutablePath()
    head.move(to: tip)
    head.addLine(to: CGPoint(x: endPoint.x + radial.x * halfWidth, y: endPoint.y + radial.y * halfWidth))
    head.addLine(to: CGPoint(x: endPoint.x - radial.x * halfWidth, y: endPoint.y - radial.y * halfWidth))
    head.closeSubpath()

    // 1) shadow silhouette
    let silhouette = CGMutablePath()
    silhouette.addPath(arc.copy(strokingWithWidth: strokeW, lineCap: .round, lineJoin: .round, miterLimit: 10))
    silhouette.addPath(head)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: c(0x04173A, 0.30))
    ctx.setFillColor(c(0xFFFFFF, 0.99))
    ctx.addPath(silhouette)
    ctx.fillPath()

    // 2) clean glyph, no shadow
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setStrokeColor(c(0xFFFFFF, 0.99))
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(arc)
    ctx.strokePath()
    ctx.setFillColor(c(0xFFFFFF, 0.99))
    ctx.addPath(head)
    ctx.fillPath()

    ctx.restoreGState()

    // sparkle
    ctx.saveGState()
    ctx.translateBy(x: orbCenter.x - 238, y: orbCenter.y - 244)
    ctx.setFillColor(c(0xFFFFFF, 0.90))
    let spark = CGMutablePath()
    spark.move(to: CGPoint(x: 0, y: -26))
    spark.addQuadCurve(to: CGPoint(x: 6, y: 0), control: CGPoint(x: 1, y: -7))
    spark.addQuadCurve(to: CGPoint(x: 29, y: 6), control: CGPoint(x: 5, y: 1))
    spark.addQuadCurve(to: CGPoint(x: 6, y: 14), control: CGPoint(x: 6, y: 6))
    spark.addQuadCurve(to: CGPoint(x: 0, y: 38), control: CGPoint(x: 1, y: 12))
    spark.addQuadCurve(to: CGPoint(x: -6, y: 14), control: CGPoint(x: -1, y: 14))
    spark.addQuadCurve(to: CGPoint(x: -29, y: 6), control: CGPoint(x: -5, y: 6))
    spark.addQuadCurve(to: CGPoint(x: -6, y: 0), control: CGPoint(x: -6, y: 1))
    spark.addQuadCurve(to: CGPoint(x: 0, y: -26), control: CGPoint(x: -1, y: -6))
    spark.closeSubpath()
    ctx.addPath(spark)
    ctx.fillPath()
    ctx.restoreGState()

    guard let img = ctx.makeImage() else { fatalError("image") }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("dest")
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize") }
}

let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/recall-icon/icon-1024.png")
drawIcon(to: url)
print(url.path)
