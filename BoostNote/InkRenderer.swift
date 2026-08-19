import UIKit
import PencilKit

// IL MOTORE D'INCHIOSTRO — disegno dei tratti fatto da noi.
//
// (Nasceva come laboratorio a fianco di PencilKit; da quando l'inchiostro
// è tutto nostro questo file È il motore delle note a pagine, e la
// schermata di confronto non esiste più.)
//
// PencilKit rasterizza i tratti alla propria scala: se lo zoom lo fa una
// scroll view esterna (com'è nelle nostre note a pagine), quella bitmap
// viene semplicemente stirata e l'inchiostro sgrana. La geometria però
// c'è ed è esatta: `PKStroke.path` è una spline di punti con posizione,
// spessore, forza e inclinazione. Da lì si può ridisegnare il tratto a
// QUALSIASI scala — e lo stesso codice, mandato in un contesto PDF,
// produce l'export vettoriale vero.
//
enum InkRenderer {

    // Passo di campionamento della spline, in punti di contenuto e
    // MISURATO LUNGO LA CURVA (`.distance`), non nel parametro. Il passo
    // parametrico dava al massimo uno stampo per campione di tocco: sui
    // tratti veloci i campioni distano anche 5-8 pt e i raccordi dritti
    // fra stampi lontani si vedevano come una spezzata ("a tratti").
    // A distanza costante la B-spline viene percorsa davvero, comunque
    // sia stata scritta. Più si è ingranditi, più fitto (pixel finali);
    // il budget sul tratto chilometrico evita decine di migliaia di
    // stampi a ogni ridisegno.
    private static func samplingStep(for scale: CGFloat, length: CGFloat) -> CGFloat {
        max(max(0.3, 0.75 / max(scale, 1)), length / 6000)
    }

    // Dal punto della spline al pennino davvero disegnato.
    //
    // `PKStrokePoint.size` NON è la larghezza del tratto: PencilKit ci
    // applica sopra una legge propria, diversa per ogni inchiostro.
    // Misurata rendendo tratti dritti a spessore noto con PencilKit e
    // leggendone la larghezza in pixel (13 spessori da 1 a 32 punti,
    // sui due assi):
    //
    //   penna          larghezza = 2·size − 4   (esatta su tutti i campioni)
    //   matita         larghezza = 2·size
    //   evidenziatore  pennino a scalpello, 1.48·size in orizzontale
    //                  e 0.5625·size in verticale
    //
    // Il rapporto sembrava dipendere dalla pressione perché cresce con lo
    // spessore (2 − 4/size) e lo spessore lo detta la pressione: la forza
    // è GIÀ dentro `size`, non va modellata a parte.
    private static func nibSize(for point: PKStrokePoint, ink: PKInk.InkType) -> CGSize {
        let size = point.size
        switch ink {
        case .pencil:
            return CGSize(width: size.width * 2, height: size.height * 2)
        case .marker:
            return CGSize(width: size.width * 1.48, height: size.height * 0.5625)
        default:
            // Penna e i tipi introdotti dopo (monoline, stilografica...),
            // che finché non sono misurati seguono la legge della penna.
            return CGSize(width: max(0, size.width * 2 - 4), height: max(0, size.height * 2 - 4))
        }
    }

    // Correzione manuale sopra la legge misurata, per rifinire dal
    // laboratorio senza ricompilare. 1 = legge pura.
    static var widthScale: CGFloat = 1

    // TUTTO l'inchiostro è nostro: per decisione, non per copertura.
    // Tenere due motori sovrapposti (il nostro per la penna, PencilKit
    // per matita e gomma) voleva dire coreografie di visibilità, doppi
    // specchi e la burocrazia interna di PencilKit nel percorso caldo —
    // era ciò che rendeva le note più lente del Laboratorio. La matita
    // perde la grana texturizzata di Apple e diventa un tratto pieno con
    // la sua legge di larghezza misurata (2·size): un prezzo accettato
    // esplicitamente in cambio di un motore solo.
    static func handles(_ inkType: PKInk.InkType) -> Bool {
        true
    }

    static func draw(_ drawing: PKDrawing, in context: CGContext, scale: CGFloat = 1, clipTo rect: CGRect? = nil) {
        draw(drawing.strokes, in: context, scale: scale, clipTo: rect)
    }

    // Variante su array puro: i PKStroke sono struct semplici, e nel
    // percorso caldo (gomma, anteprime) evitare PKDrawing evita anche il
    // suo PKReplicaManager — la macchineria interna di PencilKit che si
    // registra a OGNI costruzione di un disegno, e che martellata
    // centinaia di volte al secondo crollava (riprodotto: crash in
    // -[PKReplicaManager _saveStateImmediately] torturando la gomma).
    static func draw(_ strokes: [PKStroke], in context: CGContext, scale: CGFloat = 1, clipTo rect: CGRect? = nil) {
        for stroke in strokes {
            if let rect, !stroke.renderBounds.intersects(rect) { continue }
            draw(stroke, in: context, scale: scale, clipTo: rect)
        }
    }

    // `clipTo` è in coordinate della VISTA (lo stesso rettangolo che
    // arriva a draw(_ rect:)). Senza, disegnare la coda di un tratto
    // costava quanto disegnarlo tutto: il clip di CoreGraphics scarta i
    // pixel ma noi emettevamo comunque migliaia di stampi, e con la
    // Pencil a 240 Hz il costo per campione cresceva con la lunghezza del
    // tratto — era l'attrito che si sentiva DURANTE un tratto lungo.
    static func draw(_ stroke: PKStroke, in context: CGContext, scale: CGFloat = 1, clipTo rect: CGRect? = nil) {
        let length = stroke.renderBounds.width + stroke.renderBounds.height
        let step = samplingStep(for: scale, length: length)
        let points = sampledPoints(of: stroke, step: step)
        guard !points.isEmpty else { return }

        // Il rettangolo va portato nello spazio del tratto (che può
        // essere stato spostato col lasso) e allargato del pennino: uno
        // stampo il cui centro è appena fuori dipinge ancora dentro.
        let localClip: CGRect? = rect.map { visible in
            let inflate = max(stroke.renderBounds.width, stroke.renderBounds.height) > 0
                ? maxNibReach(of: points, ink: stroke.ink.inkType)
                : 0
            return visible
                .applying(stroke.transform.inverted())
                .insetBy(dx: -inflate, dy: -inflate)
        }

        context.saveGState()
        defer { context.restoreGState() }

        // La trasformazione del tratto (es. una selezione spostata) è
        // separata dalla geometria: senza applicarla, i tratti mossi
        // tornerebbero dov'erano stati disegnati la prima volta.
        context.concatenate(stroke.transform)

        // Quando cancelli in parte un tratto, PencilKit NON lo riscrive:
        // gli applica una maschera. Ignorarla farebbe ricomparire
        // l'inchiostro che hai cancellato.
        if let mask = stroke.mask {
            context.addPath(mask.cgPath)
            context.clip()
        }

        // L'alfa si legge dal CGColor: `getWhite(nil, alpha:)` fallisce in
        // silenzio sui colori che non stanno nello spazio dei grigi (e su
        // AppKit solleva proprio un'eccezione).
        let color = stroke.ink.color
        let alpha = color.cgColor.alpha

        switch stroke.ink.inkType {
        case .marker:
            // L'evidenziatore sta SOTTO a ciò che copre: moltiplica
            // invece di coprire, come sulla carta.
            context.setBlendMode(.multiply)
        default:
            context.setBlendMode(.normal)
        }

        // UNO STAMPO, UN RIEMPIMENTO. Sembra sprecato e invece è la via
        // veloce: provato a raccogliere tutti gli stampi in un CGPath
        // solo e riempirlo una volta con la regola non-zero (2026-08-19),
        // ed è risultato dalle 5 alle 44 volte PIÙ LENTO, con il divario
        // che cresce sulla lunghezza del tratto — una pagina piena 16
        // volte più lenta, l'evidenziatore peggio ancora (ellissi ruotate
        // e `multiply` su un'area grande). Il motivo: il rasterizzatore
        // di CoreGraphics lavora per scanline sull'elenco degli spigoli,
        // e migliaia di sotto-percorsi sovrapposti dentro un solo path
        // fanno esplodere quell'elenco; mille riempimenti piccoli sono
        // invece limitati ciascuno alla propria area. NON riprovarci.
        //
        // Il livello di trasparenza però serve SOLO quando il colore è
        // semitrasparente (l'evidenziatore): stampi opachi disegnati uno
        // per uno non si sommano, quindi sulla penna il buffer fuori
        // schermo era puro spreco.
        context.setAlpha(alpha)
        let needsTransparencyLayer = alpha < 0.999
        if needsTransparencyLayer { context.beginTransparencyLayer(auxiliaryInfo: nil) }
        context.setFillColor(color.withAlphaComponent(1).cgColor)

        let inkType = stroke.ink.inkType
        var previous: (point: PKStrokePoint, nib: CGSize, visible: Bool)?
        for point in points {
            let nib = nibSize(for: point, ink: inkType)
            let visible = isVisible(point, nib: nib, clip: localClip)
            if visible { stamp(point, nib: nib, in: context) }
            // A curvatura alta due stampi consecutivi possono staccarsi:
            // il quadrilatero che li unisce chiude il buco. Si traccia se
            // ALMENO uno dei due estremi è nella regione da ridisegnare.
            if let previous, previous.visible || visible,
               distance(previous.point.location, point.location) > step * 1.5 {
                connect((previous.point, previous.nib), (point, nib), in: context)
            }
            previous = (point, nib, visible)
        }
        if needsTransparencyLayer { context.endTransparencyLayer() }
    }

    // Il raggio massimo del pennino sui punti campionati: serve solo ad
    // allargare il rettangolo di clip quanto basta.
    private static func maxNibReach(of points: [PKStrokePoint], ink: PKInk.InkType) -> CGFloat {
        var reach: CGFloat = 0
        for point in points {
            let nib = nibSize(for: point, ink: ink)
            reach = max(reach, max(nib.width, nib.height))
        }
        return reach * widthScale / 2 + 1
    }

    private static func isVisible(_ point: PKStrokePoint, nib: CGSize, clip: CGRect?) -> Bool {
        guard let clip else { return true }
        return clip.contains(point.location)
    }

    // Uno stampo del pennino nella posizione del punto.
    private static func stamp(_ point: PKStrokePoint, nib: CGSize, in context: CGContext) {
        let size = CGSize(width: nib.width * widthScale, height: nib.height * widthScale)
        guard size.width > 0, size.height > 0 else { return }
        let rect = CGRect(
            x: point.location.x - size.width / 2,
            y: point.location.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        if abs(size.width - size.height) < 0.01 {
            context.fillEllipse(in: rect)
        } else {
            // Pennino ellittico (evidenziatore): va orientato secondo
            // l'azimut, altrimenti l'inclinazione del tratto sparisce.
            context.saveGState()
            context.translateBy(x: point.location.x, y: point.location.y)
            context.rotate(by: point.azimuth)
            context.fillEllipse(in: CGRect(
                x: -size.width / 2,
                y: -size.height / 2,
                width: size.width,
                height: size.height
            ))
            context.restoreGState()
        }
    }

    // Raccordo fra due stampi: il quadrilatero costruito sulle due
    // perpendicolari al segmento che li unisce.
    private static func connect(
        _ from: (point: PKStrokePoint, nib: CGSize),
        _ to: (point: PKStrokePoint, nib: CGSize),
        in context: CGContext
    ) {
        let dx = to.point.location.x - from.point.location.x
        let dy = to.point.location.y - from.point.location.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return }
        let nx = -dy / length
        let ny = dx / length
        let r1 = from.nib.width * widthScale / 2
        let r2 = to.nib.width * widthScale / 2

        context.beginPath()
        context.move(to: CGPoint(x: from.point.location.x + nx * r1, y: from.point.location.y + ny * r1))
        context.addLine(to: CGPoint(x: to.point.location.x + nx * r2, y: to.point.location.y + ny * r2))
        context.addLine(to: CGPoint(x: to.point.location.x - nx * r2, y: to.point.location.y - ny * r2))
        context.addLine(to: CGPoint(x: from.point.location.x - nx * r1, y: from.point.location.y - ny * r1))
        context.closePath()
        context.fillPath()
    }

    private static func sampledPoints(of stroke: PKStroke, step: CGFloat) -> [PKStrokePoint] {
        var points: [PKStrokePoint] = []
        stroke.path.forEach(sampleAt: step) { points.append($0) }
        return points
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }
}

private extension PKStrokePath {
    // `interpolatedPoints(by:)` restituisce una sequenza pigra: questo
    // wrapper la percorre a passo costante LUNGO LA CURVA.
    //
    // Il passo parametrico che c'era prima era ingannevole: l'unità del
    // parametro è l'intervallo fra due punti di controllo, cioè fra due
    // campioni di tocco. Con passo 1 si otteneva uno stampo per campione
    // e la spline non veniva percorsa affatto — a mano veloce i campioni
    // distano parecchi punti e il tratto degenerava nella spezzata dei
    // raccordi dritti. `.distance` è indipendente da come si è scritto.
    func forEach(sampleAt step: CGFloat, _ body: (PKStrokePoint) -> Void) {
        for point in interpolatedPoints(by: .distance(step)) {
            body(point)
        }
    }
}

// LA GOMMA NOSTRA — cancellazione senza PencilKit.
//
// Lavora sulla geometria dei tratti, quindi cancella TUTTI gli inchiostri
// (anche la matita, che pure viene disegnata da PencilKit): un tratto è
// sempre una spline di punti, comunque venga reso.
//
// Gomma a oggetti: sparisce l'intero tratto toccato. Gomma parziale: il
// tratto viene DIVISO — si tolgono i punti dentro il cerchio della gomma
// e i segmenti superstiti diventano tratti indipendenti, con lo stesso
// inchiostro, la stessa trasformazione e la stessa maschera (quella
// conserva le cancellazioni parziali fatte in passato da PencilKit).
enum InkEraser {

    // Esito di un passaggio: i tratti aggiornati e la regione di pagina
    // da ridisegnare — così il feedback della gomma invalida solo la
    // zona toccata, non l'intera pagina.
    struct EraseResult {
        var strokes: [PKStroke]
        var dirtyRect: CGRect
    }

    // Applica un passaggio di gomma. Ritorna nil se non cambia niente,
    // così il chiamante evita riassegnazioni (e undo) a vuoto.
    // Lavora su [PKStroke] e non su PKDrawing: vedi il commento su
    // draw(_ strokes:) — PKDrawing costruito a raffica fa crollare la
    // macchineria interna di PencilKit.
    static func erase(_ strokes: [PKStroke], at point: CGPoint, radius: CGFloat, partial: Bool) -> EraseResult? {
        var changed = false
        var dirty = CGRect.null
        var result: [PKStroke] = []
        result.reserveCapacity(strokes.count)

        for stroke in strokes {
            // Scarto veloce sul rettangolo: la gomma tocca quasi mai più
            // di un paio di tratti per volta.
            guard stroke.renderBounds.insetBy(dx: -radius, dy: -radius).contains(point) else {
                result.append(stroke)
                continue
            }
            // Il cerchio della gomma va portato nello spazio del tratto:
            // un tratto spostato col lasso ha la geometria dove è NATO.
            let local = point.applying(stroke.transform.inverted())

            if partial {
                if let pieces = split(stroke, around: local, radius: radius) {
                    changed = true
                    result.append(contentsOf: pieces)
                    // La zona cancellata sta nel cerchio della gomma, più
                    // un margine generoso per lo spessore del pennino che
                    // vi si affacciava.
                    let reach = radius + 48
                    dirty = dirty.union(CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2))
                } else {
                    result.append(stroke)
                }
            } else if hits(stroke, at: local, radius: radius) {
                changed = true
                dirty = dirty.union(stroke.renderBounds)
            } else {
                result.append(stroke)
            }
        }
        guard changed else { return nil }
        return EraseResult(strokes: result, dirtyRect: dirty)
    }

    private static func hits(_ stroke: PKStroke, at point: CGPoint, radius: CGFloat) -> Bool {
        for sample in stroke.path.interpolatedPoints(by: .distance(max(radius / 2, 2))) {
            let reach = radius + sample.size.width
            if hypot(sample.location.x - point.x, sample.location.y - point.y) <= reach {
                return true
            }
        }
        return false
    }

    // Divide un tratto attorno al cerchio della gomma. Ritorna i pezzi
    // superstiti, oppure nil se il tratto non è toccato — così il
    // chiamante lo conserva intatto, senza ricampionarlo.
    private static func split(_ stroke: PKStroke, around point: CGPoint, radius: CGFloat) -> [PKStroke]? {
        // Si campiona fitto invece di usare i control point: sui tratti
        // fatti da PencilKit i control point possono essere radi, e la
        // gomma passata TRA due di loro non cancellerebbe niente.
        var samples: [PKStrokePoint] = []
        for sample in stroke.path.interpolatedPoints(by: .parametricStep(0.25)) {
            samples.append(sample)
        }
        guard !samples.isEmpty else { return nil }

        var touched = false
        var runs: [[PKStrokePoint]] = []
        var current: [PKStrokePoint] = []
        for sample in samples {
            let reach = radius + sample.size.width / 2
            let erased = hypot(sample.location.x - point.x, sample.location.y - point.y) <= reach
            if erased {
                touched = true
                if !current.isEmpty { runs.append(current); current = [] }
            } else {
                current.append(sample)
            }
        }
        if !current.isEmpty { runs.append(current) }

        // Non toccato: si restituisce l'originale, senza ricampionarlo.
        guard touched else { return nil }

        return runs.compactMap { run in
            guard run.count >= 2 else { return nil }
            return PKStroke(
                ink: stroke.ink,
                path: PKStrokePath(controlPoints: run, creationDate: Date()),
                transform: stroke.transform,
                mask: stroke.mask
            )
        }
    }
}
