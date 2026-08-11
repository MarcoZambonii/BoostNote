import SwiftUI

// Disegno condiviso del grafico di una funzione y = f(x), usato sia dal
// pannello Grafici standalone sia dal widget grafico inseribile nella nota.
enum MathGraphRenderer {
    static func draw(expressionText: String, in context: GraphicsContext, size: CGSize, range: ClosedRange<Double> = -10...10) -> Bool {
        var axes = Path()
        axes.move(to: CGPoint(x: 0, y: size.height / 2))
        axes.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        axes.move(to: CGPoint(x: size.width / 2, y: 0))
        axes.addLine(to: CGPoint(x: size.width / 2, y: size.height))
        context.stroke(axes, with: .color(DesignColor.borderDefault), lineWidth: 1)

        guard let expression = try? MathExpression(expressionText) else { return false }

        let samples = 160
        var maxAbsY: Double = 1
        var rawValues: [Double?] = []

        for i in 0...samples {
            let x = range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / Double(samples)
            if let y = try? expression.evaluate(x: x), y.isFinite {
                rawValues.append(y)
                maxAbsY = max(maxAbsY, abs(y))
            } else {
                rawValues.append(nil)
            }
        }

        let scaleX = size.width / (range.upperBound - range.lowerBound)
        let scaleY = (size.height / 2) / (maxAbsY * 1.15)

        var path = Path()
        var started = false
        for (i, y) in rawValues.enumerated() {
            let x = range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / Double(samples)
            guard let y else { started = false; continue }
            let point = CGPoint(x: (x - range.lowerBound) * scaleX, y: size.height / 2 - y * scaleY)
            if !started {
                path.move(to: point)
                started = true
            } else {
                path.addLine(to: point)
            }
        }

        context.stroke(path, with: .color(DesignColor.brandPrimary), lineWidth: 2)
        return true
    }
}
