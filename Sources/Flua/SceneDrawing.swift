import CoreGraphics

enum SceneDrawing {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    static func render(scene: String, time: Double, dimming: Double, in c: CGContext, bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        c.saveGState()
        c.translateBy(x: bounds.minX, y: bounds.minY)
        c.scaleBy(x: bounds.width, y: bounds.height)
        c.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        switch scene {
        case "cosmos": cosmos(c, time)
        case "ocean": ocean(c, time)
        case "ember": ember(c, time)
        case "ink": ink(c, time)
        case "dunes": dunes(c, time)
        case "contour": contour(c, time)
        case "opal": opal(c, time)
        default: aurora(c, time)
        }
        let shade = dimming.isFinite ? CGFloat(min(max(dimming, 0), 0.9)) : 0.12
        c.setFillColor(rgb(0, 0, 0, shade))
        c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        c.restoreGState()
    }

    static func linear(_ c: CGContext, colors: [CGColor], from: CGPoint, to: CGPoint) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil) else { return }
        c.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func glow(_ c: CGContext, x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat, color: CGColor) {
        c.saveGState()
        c.translateBy(x: x, y: y)
        c.scaleBy(x: rx, y: ry)
        let transparent = color.copy(alpha: 0) ?? rgb(0, 0, 0, 0)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color, transparent] as CFArray, locations: [0, 1]) {
            c.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        }
        c.restoreGState()
    }

    static func noise(_ seed: Int) -> CGFloat {
        let n = sin(Double(seed) * 127.1 + 311.7) * 43758.5453123
        return CGFloat(n - floor(n))
    }

    static func stars(_ c: CGContext, _ t: Double, count: Int, minimumY: CGFloat = 0.25) {
        for i in 0..<count {
            let x = noise(i * 3 + 1)
            let y = minimumY + noise(i * 3 + 2) * (1 - minimumY)
            let radius = 0.00045 + noise(i * 3 + 3) * 0.00075
            let alpha = 0.18 + 0.54 * (0.5 + 0.5 * sin(t * 0.35 + Double(i)))
            c.setFillColor(rgb(0.8, 0.9, 1, alpha))
            c.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius * 1.7))
        }
    }

    static func pigment(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        // Use the shader's RGB space so the newer palettes match across both renderers.
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
    }

    private static let paperGrain: CGImage = {
        var pixels = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
        for y in 0..<1024 {
            for x in 0..<1024 {
                var seed = UInt32(x) &* 374761393 &+ UInt32(y) &* 668265263
                seed = (seed ^ (seed >> 13)) &* 1274126177
                pixels[(y * 1024 + x) * 4 + 3] = UInt8((seed ^ (seed >> 16)) % 20)
            }
        }
        let data = CFDataCreate(nil, pixels, pixels.count)!
        return CGImage(width: 1024, height: 1024, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4096,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }()

    static func inkHeight(_ x: Double, _ ridge: Int) -> Double {
        let r = Double(ridge)
        let peak = exp(-pow((x - (0.12 + r * 0.16)) / 0.24, 2))
        return 0.46 - r * 0.075 + peak * 0.29 + 0.045 * sin(x * 13 + r * 2.1)
            + 0.018 * sin(x * 34 + r) + 0.012 * sin(x * 83 + r * 3)
            + 0.005 * sin(x * 181 + r * 7)
    }

    static func ink(_ c: CGContext, _ t: Double) {
        linear(c, colors: [pigment(0.90, 0.88, 0.82), pigment(0.97, 0.955, 0.91)], from: .zero, to: CGPoint(x: 0, y: 1))
        c.setFillColor(pigment(0.67, 0.25, 0.18, 0.80))
        c.fillEllipse(in: CGRect(x: 0.735, y: 0.735, width: 0.057, height: 0.096))
        for ridge in 0..<6 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -0.01, y: -0.01))
            for step in 0...400 {
                let x = Double(step) / 400
                path.addLine(to: CGPoint(x: x, y: inkHeight(x, ridge)))
            }
            path.addLine(to: CGPoint(x: 1.01, y: -0.01))
            path.closeSubpath()
            let r = CGFloat(ridge)
            c.saveGState()
            c.addPath(path)
            c.clip()
            linear(c, colors: [pigment(0.87 - r * 0.065, 0.86 - r * 0.067, 0.81 - r * 0.062),
                               pigment(0.66 - r * 0.10, 0.69 - r * 0.10, 0.66 - r * 0.093)],
                   from: CGPoint(x: 0, y: -0.10), to: CGPoint(x: 0, y: 0.65 - Double(ridge) * 0.055))
            c.restoreGState()
            let mistY = 0.37 - r * 0.068
            let drift = CGFloat(sin(t * 0.065 + Double(ridge))) * 0.13
            glow(c, x: 0.30 + drift, y: mistY, rx: 0.62, ry: 0.10, color: pigment(0.96, 0.95, 0.90, 0.32))
            glow(c, x: 0.85 - drift, y: mistY + 0.015, rx: 0.45, ry: 0.075, color: pigment(0.96, 0.95, 0.90, 0.26))
        }
        c.interpolationQuality = .none
        c.draw(paperGrain, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    static func duneHeight(_ x: Double, _ layer: Int, _ t: Double) -> Double {
        let l = Double(layer)
        return 0.55 - l * 0.125 + 0.14 * sin(x * 3.6 + l * 1.15)
            + 0.045 * sin(x * 7.3 - l * 0.8) + 0.006 * sin(t * 0.08 + l)
    }

    static func dunes(_ c: CGContext, _ t: Double) {
        linear(c, colors: [pigment(0.91, 0.66, 0.46), pigment(0.96, 0.86, 0.69)], from: .zero, to: CGPoint(x: 0, y: 1))
        glow(c, x: 0.72, y: 0.80, rx: 0.23, ry: 0.38, color: pigment(1, 0.94, 0.79, 0.25))
        c.setFillColor(pigment(1, 0.93, 0.77, 0.78))
        c.fillEllipse(in: CGRect(x: 0.684, y: 0.738, width: 0.072, height: 0.122))
        for layer in 0..<5 {
            let path = CGMutablePath()
            for step in 0...240 {
                let x = Double(step) / 240
                let point = CGPoint(x: x, y: duneHeight(x, layer, t))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let surface = CGMutablePath()
            surface.addPath(path)
            surface.addLine(to: CGPoint(x: 1, y: -0.2))
            surface.addLine(to: CGPoint(x: 0, y: -0.2))
            surface.closeSubpath()
            let l = CGFloat(layer)
            c.saveGState()
            c.addPath(surface)
            c.clip()
            linear(c, colors: [pigment(0.39 + l * 0.025, 0.16 + l * 0.008, 0.115),
                               pigment(0.88 - l * 0.047, 0.59 - l * 0.055, 0.36 - l * 0.037)],
                   from: CGPoint(x: 0.2, y: -0.18), to: CGPoint(x: 0.65, y: 0.63 - Double(layer) * 0.12))
            for ripple in 1...22 {
                let detail = CGMutablePath()
                for step in 0...160 {
                    let x = Double(step) / 160
                    let depth = Double(ripple) * 0.008
                    let y = duneHeight(x, layer, t) - depth * (1 + 0.18 * sin(x * 8 + Double(layer)))
                        + 0.0015 * sin(x * 65 + Double(ripple) * 0.7 - t * 0.12)
                    if step == 0 { detail.move(to: CGPoint(x: x, y: y)) }
                    else { detail.addLine(to: CGPoint(x: x, y: y)) }
                }
                c.addPath(detail)
                c.setLineWidth(0.00055)
                c.setStrokeColor(pigment(1, 0.78, 0.51, 0.055))
                c.strokePath()
            }
            c.restoreGState()
            c.addPath(path)
            c.setLineWidth(0.0011)
            c.setStrokeColor(pigment(1, 0.83, 0.59, 0.52))
            c.strokePath()
        }
    }

    static func contour(_ c: CGContext, _ t: Double) {
        linear(c, colors: [pigment(0.015, 0.055, 0.065), pigment(0.035, 0.13, 0.14)], from: .zero, to: CGPoint(x: 1, y: 1))
        glow(c, x: 0.63, y: 0.51, rx: 0.65, ry: 0.9, color: pigment(0.05, 0.30, 0.27, 0.25))
        for ring in 0..<74 {
            let level = 0.045 + Double(ring) * 0.018
            let path = CGMutablePath()
            for step in 0...360 {
                let a = Double(step) / 360 * .pi * 2
                let radius = level * (1 + 0.12 * sin(a * 3 + level * 5 + t * 0.06)
                    + 0.065 * cos(a * 5 - level * 4 - t * 0.04))
                let p = CGPoint(x: 0.63 + cos(a) * radius / 1.6, y: 0.51 + sin(a) * radius)
                if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            c.addPath(path)
            let major = ring % 5 == 0
            c.setLineWidth(major ? 0.00105 : 0.00065)
            c.setStrokeColor(major ? pigment(0.76, 0.70, 0.42, 0.62) : pigment(0.27, 0.65, 0.58, 0.42))
            c.strokePath()
        }
    }

    static func opticalWarp(_ y: Double, _ t: Double) -> Double {
        0.19 * sin(y * 4.8 + t * 0.075) + 0.055 * sin(y * 10.5 - t * 0.045)
    }

    static func opal(_ c: CGContext, _ t: Double) {
        c.setFillColor(pigment(0.075, 0.085, 0.10))
        c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let stripes = CGMutablePath()
        for stripe in -20..<94 {
            let x = Double(stripe) / 72
            stripes.move(to: CGPoint(x: x - opticalWarp(0, t), y: 0))
            for step in 0...220 {
                let y = Double(step) / 220
                stripes.addLine(to: CGPoint(x: x - opticalWarp(y, t), y: y))
            }
            for step in stride(from: 220, through: 0, by: -1) {
                let y = Double(step) / 220
                stripes.addLine(to: CGPoint(x: x + 0.006 - opticalWarp(y, t), y: y))
            }
            stripes.closeSubpath()
        }
        c.saveGState()
        c.addPath(stripes)
        c.clip()
        linear(c, colors: [pigment(0.53, 0.58, 0.62), pigment(0.94, 0.925, 0.87), pigment(0.74, 0.76, 0.74)],
               from: .zero, to: CGPoint(x: 1, y: 1))
        c.restoreGState()
    }

    static func aurora(_ c: CGContext, _ t: Double) {
        linear(c, colors: [rgb(0.012, 0.025, 0.065), rgb(0.025, 0.11, 0.16), rgb(0.025, 0.04, 0.10)], from: CGPoint(x: 0, y: 1), to: .zero)
        glow(c, x: 0.65, y: 0.65, rx: 0.65, ry: 0.55, color: rgb(0.05, 0.36, 0.33, 0.3))
        stars(c, t, count: 135, minimumY: 0.39)
        for ribbon in stride(from: 6, through: 0, by: -1) {
            let r = Double(ribbon)
            let phase = t * 0.10 + r * 0.22
            let base = 0.64 + r * 0.025
            let path = CGMutablePath()
            func height(_ x: Double) -> Double {
                base + 0.10 * sin(x * 5.0 + phase) + 0.075 * sin(x * 8.2 - phase * 0.6)
            }
            path.move(to: CGPoint(x: -0.05, y: height(-0.05)))
            for step in 0...90 {
                let x = Double(step) / 90 * 1.1 - 0.05
                path.addLine(to: CGPoint(x: x, y: height(x)))
            }
            for step in stride(from: 90, through: 0, by: -1) {
                let x = Double(step) / 90 * 1.1 - 0.05
                let thickness = 0.06 + 0.07 * (0.5 + 0.5 * sin(x * 7 + phase))
                path.addLine(to: CGPoint(x: x, y: height(x) + thickness))
            }
            path.closeSubpath()
            c.saveGState()
            c.addPath(path)
            c.clip()
            let hue = CGFloat(r / 6)
            linear(c, colors: [rgb(0.10 + hue * 0.2, 0.9 - hue * 0.3, 0.62 + hue * 0.35, 0), rgb(0.1, 0.95, 0.69, 0.15), rgb(0.35, 0.6, 1, 0)], from: CGPoint(x: 0.2, y: 0.54), to: CGPoint(x: 0.8, y: 0.98))
            c.restoreGState()
        }
        // Low distant ridges anchor the flowing sky.
        for ridge in 0..<3 {
            let path = CGMutablePath()
            path.move(to: .zero)
            for step in 0...60 {
                let x = Double(step) / 60
                let h = 0.20 + Double(ridge) * 0.034 + 0.03 * sin(x * 16 + Double(ridge) * 2) + 0.014 * sin(x * 43)
                path.addLine(to: CGPoint(x: x, y: h))
            }
            path.addLine(to: CGPoint(x: 1, y: 0))
            path.closeSubpath()
            c.addPath(path)
            c.setFillColor(rgb(0.012, 0.025 + CGFloat(2 - ridge) * 0.008, 0.045 + CGFloat(2 - ridge) * 0.014))
            c.fillPath()
        }
        // Thin reflected light on the lake, in front of the silhouette.
        glow(c, x: 0.6, y: 0.075, rx: 0.55, ry: 0.14, color: rgb(0.06, 0.45, 0.40, 0.26))
        for i in 0..<28 {
            let y = CGFloat(i) * 0.0057
            let width = 0.18 + noise(i + 77) * 0.4
            let x = 0.55 - width / 2 + CGFloat(sin(t * 0.12 + Double(i))) * 0.012
            c.setStrokeColor(rgb(0.2, 0.8, 0.65, 0.025 + noise(i + 10) * 0.04))
            c.setLineWidth(0.00065)
            c.move(to: CGPoint(x: x, y: y))
            c.addLine(to: CGPoint(x: x + width, y: y))
            c.strokePath()
        }
    }

    static func cosmos(_ c: CGContext, _ t: Double) {
        linear(c, colors: [rgb(0.008, 0.012, 0.04), rgb(0.025, 0.018, 0.08)], from: .zero, to: CGPoint(x: 1, y: 1))
        let drift = CGFloat(sin(t * 0.055)) * 0.035
        for i in 0..<9 {
            let p = CGFloat(i) / 8
            let x = -0.05 + p * 1.15 + drift
            let y = 0.28 + p * 0.4 + CGFloat(sin(Double(i) * 1.3 + t * 0.045)) * 0.055
            glow(c, x: x, y: y, rx: 0.25, ry: 0.27, color: rgb(0.19 + p * 0.10, 0.08 + p * 0.13, 0.55, 0.18))
            glow(c, x: x + 0.045, y: y, rx: 0.15, ry: 0.12, color: rgb(0.05, 0.3, 0.6, 0.14))
        }
        stars(c, t, count: 230, minimumY: 0)
        // A quiet, shadowed planet with a luminous atmospheric rim.
        let px: CGFloat = 0.76 + drift * 0.15
        let py: CGFloat = 0.47
        glow(c, x: px, y: py, rx: 0.139, ry: 0.241, color: rgb(0.25, 0.39, 0.75, 0.22))
        c.saveGState()
        c.addEllipse(in: CGRect(x: px - 0.11, y: py - 0.19, width: 0.22, height: 0.38))
        c.clip()
        linear(c, colors: [rgb(0.22, 0.3, 0.47), rgb(0.035, 0.048, 0.10), rgb(0.006, 0.009, 0.024)], from: CGPoint(x: px - 0.12, y: py + 0.16), to: CGPoint(x: px + 0.08, y: py - 0.03))
        c.restoreGState()
        glow(c, x: 0.23, y: 0.71, rx: 0.032, ry: 0.055, color: rgb(0.65, 0.75, 1, 0.65))
        c.setFillColor(rgb(0.92, 0.94, 1, 0.95))
        c.fillEllipse(in: CGRect(x: 0.2289, y: 0.708, width: 0.0022, height: 0.0038))
    }

    static func ocean(_ c: CGContext, _ t: Double) {
        linear(c, colors: [rgb(0.018, 0.043, 0.10), rgb(0.045, 0.15, 0.19), rgb(0.008, 0.04, 0.075)], from: CGPoint(x: 0, y: 1), to: .zero)
        stars(c, t, count: 75, minimumY: 0.57)
        glow(c, x: 0.69, y: 0.77, rx: 0.17, ry: 0.29, color: rgb(0.50, 0.77, 0.85, 0.12))
        c.setFillColor(rgb(0.78, 0.87, 0.86, 0.9))
        c.fillEllipse(in: CGRect(x: 0.671, y: 0.738, width: 0.038, height: 0.065))
        glow(c, x: 0.66, y: 0.46, rx: 0.65, ry: 0.20, color: rgb(0.09, 0.47, 0.53, 0.2))
        for row in 0..<34 {
            let depth = Double(row) / 33
            let base = 0.49 - pow(depth, 1.5) * 0.57
            let amplitude = 0.0015 + pow(depth, 1.7) * 0.025
            let path = CGMutablePath()
            for step in 0...120 {
                let x = Double(step) / 120
                let phase = x * (24 - depth * 16) + t * (0.22 + depth * 0.28) + Double(row) * 1.7
                let y = base + sin(phase) * amplitude + sin(x * 19 - t * 0.13 + depth * 7) * amplitude * 0.4
                if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            let surface = CGMutablePath()
            surface.addPath(path)
            surface.addLine(to: CGPoint(x: 1, y: -0.1))
            surface.addLine(to: CGPoint(x: 0, y: -0.1))
            surface.closeSubpath()
            c.addPath(surface)
            c.setFillColor(rgb(0.013, 0.09 + CGFloat(depth) * 0.025, 0.14 + CGFloat(depth) * 0.025))
            c.fillPath()
            c.addPath(path)
            c.setLineWidth(0.0007 + CGFloat(depth) * 0.0012)
            c.setStrokeColor(rgb(0.19, 0.64, 0.68, 0.10 + CGFloat(depth) * 0.22))
            c.strokePath()
            if row % 2 == 0 {
                let reflection = 0.02 + depth * 0.17
                let x = 0.69 + sin(t * 0.2 + Double(row)) * reflection * 0.2
                c.setStrokeColor(rgb(0.66, 0.84, 0.81, 0.17 * (1 - CGFloat(depth) * 0.6)))
                c.setLineWidth(0.001)
                c.move(to: CGPoint(x: x - reflection, y: base))
                c.addLine(to: CGPoint(x: x + reflection, y: base))
                c.strokePath()
            }
        }
    }

    static func ember(_ c: CGContext, _ t: Double) {
        linear(c, colors: [rgb(0.028, 0.012, 0.025), rgb(0.11, 0.025, 0.025), rgb(0.19, 0.038, 0.015)], from: CGPoint(x: 0, y: 1), to: .zero)
        glow(c, x: 0.46, y: 0.02, rx: 0.8, ry: 0.75, color: rgb(0.75, 0.18, 0.025, 0.32))
        for i in 0..<7 {
            let phase = t * 0.12 + Double(i) * 0.9
            let x = 0.5 + CGFloat(sin(phase)) * 0.2
            let y = 0.13 + CGFloat(i) * 0.055
            glow(c, x: x, y: y, rx: 0.36, ry: 0.15, color: rgb(0.70, 0.15, 0.045, 0.08))
        }
        // Slow ribbons of hot air, with fine amber edges.
        for i in 0..<8 {
            let path = CGMutablePath()
            for step in 0...100 {
                let x = Double(step) / 100
                let y = 0.07 + Double(i) * 0.025 + 0.045 * sin(x * 9 + t * 0.16 + Double(i) * 0.3) + 0.018 * sin(x * 19 - t * 0.09)
                if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            c.addPath(path)
            c.setLineWidth(0.001 + CGFloat(i) * 0.00025)
            c.setStrokeColor(rgb(1, 0.36 + CGFloat(i) * 0.035, 0.10, 0.055))
            c.strokePath()
        }
        for i in 0..<95 {
            let seed = Double(noise(i * 7 + 1))
            let travel = seed + t * (0.012 + Double(noise(i + 42)) * 0.023)
            let y = travel - floor(travel)
            let x = Double(noise(i * 7 + 3)) + sin(t * 0.15 + Double(i)) * 0.027 * y
            let radius = CGFloat(0.0006 + Double(noise(i + 8)) * 0.0012)
            let alpha = CGFloat(sin(y * .pi)) * (0.3 + noise(i + 33) * 0.6)
            if i % 7 == 0 {
                glow(c, x: x, y: y, rx: radius * 5, ry: radius * 9, color: rgb(1, 0.34, 0.06, alpha * 0.45))
            }
            c.setFillColor(rgb(1, 0.45 + noise(i) * 0.4, 0.15, alpha))
            c.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius * (1.7 + noise(i) * 1.7)))
        }
    }
}
