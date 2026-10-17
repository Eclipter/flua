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
