import UIKit

// Disegna il modello del foglio (quadretti / righe / crocette / bianco)
// come sfondo statico dentro l'area di contenuto del canvas.
final class TemplateBackgroundView: UIView {
    var template: NoteTemplate = .blank {
        didSet {
            guard oldValue != template else { return }
            setNeedsDisplay()
        }
    }

    // Moltiplicatore della dimensione del pattern (non si applica a "blank").
    var patternScale: CGFloat = 1 {
        didSet {
            guard oldValue != patternScale else { return }
            setNeedsDisplay()
        }
    }

    // Altezza di una "pagina virtuale" (0 = nessuna divisione, es. lavagna
    // infinita): disegna una riga leggermente più marcata a ogni multiplo,
    // per rendere visibile dove finisce una pagina e inizia la successiva.
    var pageHeight: CGFloat = 0 {
        didSet {
            guard oldValue != pageHeight else { return }
            setNeedsDisplay()
        }
    }

    private let baseStep: CGFloat = 24
    private var step: CGFloat { baseStep * patternScale }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // La filigrana si allinea alla GRIGLIA DI PIXEL del dispositivo.
        // Una riga da 1pt che cade a metà pixel viene spalmata
        // dall'antialiasing su due file: si vede più spessa, più sbiadita
        // e di spessore diverso da riga a riga — è quello che la faceva
        // sembrare sporca. Allineata, ogni riga copre pixel interi ed
        // esce netta, il che permette anche di assottigliarla.
        let deviceScale = max(contentScaleFactor, 1)
        func snapped(_ value: CGFloat) -> CGFloat {
            ((value * deviceScale).rounded() + 0.5) / deviceScale
        }

        if template != .blank {
            let lineColor = UIColor.label.withAlphaComponent(0.12)
            ctx.setStrokeColor(lineColor.cgColor)
            ctx.setLineWidth(0.75)

            switch template {
            case .blank:
                break

            case .grid:
                var x = rect.minX.truncatingRemainder(dividingBy: step)
                while x <= rect.maxX {
                    ctx.move(to: CGPoint(x: snapped(x), y: rect.minY))
                    ctx.addLine(to: CGPoint(x: snapped(x), y: rect.maxY))
                    x += step
                }
                var y = rect.minY.truncatingRemainder(dividingBy: step)
                while y <= rect.maxY {
                    ctx.move(to: CGPoint(x: rect.minX, y: snapped(y)))
                    ctx.addLine(to: CGPoint(x: rect.maxX, y: snapped(y)))
                    y += step
                }
                ctx.strokePath()

            case .lines:
                let rowHeight = step * 1.4
                var y = rect.minY.truncatingRemainder(dividingBy: rowHeight)
                while y <= rect.maxY {
                    ctx.move(to: CGPoint(x: rect.minX, y: snapped(y)))
                    ctx.addLine(to: CGPoint(x: rect.maxX, y: snapped(y)))
                    y += rowHeight
                }
                ctx.strokePath()

            case .cross:
                let crossSize: CGFloat = 3 * patternScale
                var y = rect.minY.truncatingRemainder(dividingBy: step)
                while y <= rect.maxY {
                    var x = rect.minX.truncatingRemainder(dividingBy: step)
                    while x <= rect.maxX {
                        ctx.move(to: CGPoint(x: x - crossSize, y: snapped(y)))
                        ctx.addLine(to: CGPoint(x: x + crossSize, y: snapped(y)))
                        ctx.move(to: CGPoint(x: snapped(x), y: y - crossSize))
                        ctx.addLine(to: CGPoint(x: snapped(x), y: y + crossSize))
                        x += step
                    }
                    y += step
                }
                ctx.strokePath()
            }
        }

        guard pageHeight > 0 else { return }
        let breakColor = UIColor.label.withAlphaComponent(0.2)
        ctx.setStrokeColor(breakColor.cgColor)
        ctx.setLineWidth(1.2)
        var pageY = (rect.minY / pageHeight).rounded(.down) * pageHeight
        while pageY <= rect.maxY {
            if pageY > 0 {
                ctx.move(to: CGPoint(x: rect.minX, y: pageY))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: pageY))
            }
            pageY += pageHeight
        }
        ctx.strokePath()
    }
}
