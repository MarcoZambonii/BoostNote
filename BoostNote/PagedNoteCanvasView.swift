import SwiftUI
import SwiftData
import PencilKit
import PDFKit

// Vista che, se il tocco non cade su nessun subview (testo/media),
// si rende "invisibile" all'hit-test così il tocco passa alla pagina
// sottostante per disegnare — a meno che passthroughEmptyAreas sia false
// (strumento testo: anche il tocco su area vuota deve essere catturato,
// per creare una nuova casella).
final class PassthroughOverlayView: UIView {
    var passthroughEmptyAreas = true

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if passthroughEmptyAreas, result == self { return nil }
        return result
    }
}

// Sfondo PDF di UNA pagina, disegnato direttamente con CoreGraphics.
// Prima qui c'era una PDFView per pagina: PDFView è a sua volta una
// scroll view con renderer a tile, quindi una nota di 30 pagine ne
// teneva vive 30 — era il peso principale dell'editor. Questa vista
// disegna la pagina e basta: vettoriale, ridisegnata alla risoluzione
// giusta quando cambia lo zoom, e il documento viene aperto solo quando
// serve davvero disegnarla.
// Sfondo PDF a PIASTRELLE (CATiledLayer), come fanno Notability e i
// lettori PDF veri: si rasterizzano solo le tessere visibili, in
// background e alla risoluzione dello zoom corrente (i livelli di
// dettaglio li gestisce CoreAnimation leggendo la trasformazione dello
// scroll). Memoria proporzionale allo schermo, zoom che non paga mai la
// pagina intera, e il "morbido che si affina" tessera per tessera al
// posto del bianco. Promosso a motore UNICO dopo la prova sulle
// dispense vere.
final class TiledPDFPageView: UIView {
    // La dissolvenza di default delle tessere (0,25s) fa sembrare la
    // pagina "che si accende a chiazze": quasi istantanea è meglio.
    private final class QuickFadeTiledLayer: CATiledLayer {
        override class func fadeDuration() -> CFTimeInterval { 0.08 }
    }

    override class var layerClass: AnyClass { QuickFadeTiledLayer.self }

    private var data: Data?
    private var cachedDocument: PDFDocument?
    // Le tessere si disegnano su thread di CoreAnimation: il documento
    // PDF va toccato una tessera alla volta.
    private let documentLock = NSLock()
    // Dimensione letta dai thread di disegno: le proprietà di UIView non
    // si leggono fuori dal main thread.
    private var drawSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .white
        let tiled = layer as! CATiledLayer
        // Tessere in PIXEL. 512pt @2x: abbastanza grandi da non
        // frammentare il disegno, abbastanza piccole da buttarne poche
        // quando escono dallo schermo. La scala vera arriva in
        // didMoveToWindow (UIScreen.main è deprecato e con Stage Manager
        // lo schermo giusto è quello della finestra, non "il principale").
        tiled.tileSize = CGSize(width: 512 * UITraitCollection.current.displayScale, height: 512 * UITraitCollection.current.displayScale)
        // Fino a 4 livelli verso lo zoom-out (il foglio si può ridurre a
        // 0,25×) e 2 raddoppi verso lo zoom-in (fino a 4×).
        tiled.levelsOfDetail = 3
        tiled.levelsOfDetailBias = 2
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let scale = window?.screen.scale, scale > 0 else { return }
        let side = 512 * scale
        let tiled = layer as! CATiledLayer
        if tiled.tileSize.width != side {
            tiled.tileSize = CGSize(width: side, height: side)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        documentLock.lock()
        drawSize = bounds.size
        documentLock.unlock()
    }

    func setPDFData(_ newData: Data?) {
        documentLock.lock()
        let changed = newData != data
        if changed {
            data = newData
            cachedDocument = nil
        }
        documentLock.unlock()
        if changed { layer.setNeedsDisplay() }
    }

    var page: PDFPage? {
        documentLock.lock()
        defer { documentLock.unlock() }
        if cachedDocument == nil, let data {
            cachedDocument = PDFDocument(data: data)
        }
        return cachedDocument?.page(at: 0)
    }

    func releaseDocumentCache() {
        documentLock.lock()
        cachedDocument = nil
        documentLock.unlock()
    }

    // Lo zoom lo gestiscono i livelli di dettaglio del layer: niente da fare.
    func setRenderScale(_ scale: CGFloat) {}

    // Le tessere fuori schermo le butta CoreAnimation da sé: qui si
    // rilascia solo la cache del documento.
    func suspendRendering() {
        releaseDocumentCache()
    }

    func renderAsyncIfNeeded() {
        layer.setNeedsDisplay()
    }

    // Chiamato PER TESSERA, su thread di CoreAnimation, col clip già
    // impostato sul rettangolo della tessera.
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        documentLock.lock()
        defer { documentLock.unlock() }
        if cachedDocument == nil, let data {
            cachedDocument = PDFDocument(data: data)
        }
        let size = drawSize
        guard let page = cachedDocument?.page(at: 0), size.width > 0 else { return }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return }

        UIColor.white.setFill()
        ctx.fill(rect)

        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let fit = size.width / box.width
        ctx.scaleBy(x: fit, y: fit)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
    }
}

// Inchiostro committato su TESSERE (CATiledLayer), come lo sfondo PDF.
//
// La bitmap a pagina intera che c'era prima costringeva a ridisegnare
// TUTTA la pagina sul main thread a ogni cambio di zoom, con la scala
// tenuta bassa apposta per non esplodere in memoria: era il motivo per
// cui il PDF sotto zoom era nitido e fluido e l'inchiostro no. Con le
// tessere CoreAnimation ridisegna solo le regioni visibili, al livello
// di dettaglio dello zoom, sui suoi thread in background — i tratti
// sono vettoriali, quindi ogni tessera esce nitida a qualunque zoom.
final class PageInkView: UIView {
    // NIENTE dissolvenza sulle tessere dell'inchiostro: al distacco
    // della penna la tessera ridisegnata cross-fadava sotto il tratto
    // vivo ancora acceso, e il tratto sembrava "ri-renderizzarsi". Il
    // fade serve al PDF che scorre, non all'inchiostro che deve
    // apparire già pronto sotto la copertura del live.
    private final class QuickFadeInkLayer: CATiledLayer {
        override class func fadeDuration() -> CFTimeInterval { 0 }
    }
    override class var layerClass: AnyClass { QuickFadeInkLayer.self }

    // I thread delle tessere leggono i tratti mentre il main li
    // sostituisce (la gomma fino a 240 volte al secondo): l'accesso
    // passa da un lock e il disegno lavora sulla copia presa lì dentro
    // (economica: array copy-on-write di struct).
    private let strokesLock = NSLock()
    private var lockedStrokes: [PKStroke] = []
    // Generazione dei tratti: serve al passaggio di consegne qui sotto
    // per ignorare tessere partite PRIMA dell'ultimo commit.
    private var strokesGeneration = 0
    var strokes: [PKStroke] {
        get {
            strokesLock.lock(); defer { strokesLock.unlock() }
            return lockedStrokes
        }
        set {
            strokesLock.lock()
            lockedStrokes = newValue
            strokesGeneration += 1
            strokesLock.unlock()
        }
    }

    // PASSAGGIO DI CONSEGNE live→tessere. Le tessere disegnano in
    // asincrono e non offrono un "ho finito": ma il disegno passa da
    // draw(_:) NOSTRO, quindi possiamo accorgerci di quando le tessere
    // hanno coperto la regione del tratto appena committato — è il
    // momento esatto in cui il tratto vivo può spegnersi senza buco
    // (spegnerlo prima = lampo) né doppio disegno (spegnerlo dopo =
    // l'evidenziatore si scurisce per la sovrapposizione dei multiply).
    private var handoffRegion: CGRect?
    private var handoffDrawn: CGRect = .null
    private var handoffGeneration = 0
    private var handoffCompletion: (() -> Void)?

    func notifyWhenCovered(_ region: CGRect, completion: @escaping () -> Void) {
        strokesLock.lock()
        // Fuori dai bounds le tessere non disegnano mai, e il pelo di
        // margine tolto ai bordi evita che un confine di tessera a
        // filo della regione non faccia MAI scattare la copertura
        // (si finirebbe sempre sul timer di ripiego, che è visibile).
        handoffRegion = region.insetBy(dx: 1, dy: 1).intersection(bounds)
        handoffDrawn = .null
        handoffGeneration = strokesGeneration
        handoffCompletion = completion
        strokesLock.unlock()
    }
    // Compatibilità con i chiamanti: la densità di campionamento ora la
    // detta la scala della tessera (LOD), non una scala imposta da fuori.
    var renderScale: CGFloat = 1

    // Letta nei draw su thread CA: si aggiorna solo sul main (in
    // didMoveToWindow, dalla finestra vera — UIScreen.main è deprecato e
    // sbaglia scala su un display esterno) e si legge sotto lo stesso
    // lock dei tratti.
    private var screenScale = UITraitCollection.current.displayScale

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        if let tiled = layer as? CATiledLayer {
            tiled.tileSize = CGSize(width: 512 * screenScale, height: 512 * screenScale)
            tiled.levelsOfDetail = 3
            tiled.levelsOfDetailBias = 2
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let scale = window?.screen.scale, scale > 0 else { return }
        strokesLock.lock()
        let changed = screenScale != scale
        screenScale = scale
        strokesLock.unlock()
        if changed, let tiled = layer as? CATiledLayer {
            tiled.tileSize = CGSize(width: 512 * scale, height: 512 * scale)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        strokesLock.lock()
        let snapshot = lockedStrokes
        let generation = strokesGeneration
        let screenScale = self.screenScale
        strokesLock.unlock()
        // La scala vera della tessera (LOD × densità schermo) sta nella
        // CTM: a zoom alto arrivano tessere più dense e il campionamento
        // della spline si infittisce da solo, senza plumbing esterno.
        let scale = abs(ctx.ctm.a) / screenScale
        InkRenderer.draw(snapshot, in: ctx, scale: max(scale, 0.5), clipTo: rect)

        // Copertura del passaggio di consegne: la generazione scarta le
        // tessere partite con i tratti di PRIMA del commit (avrebbero
        // segnalato copertura senza contenere il tratto nuovo).
        strokesLock.lock()
        var completion: (() -> Void)?
        if let region = handoffRegion, generation == handoffGeneration {
            handoffDrawn = handoffDrawn.union(rect)
            if handoffDrawn.contains(region) {
                completion = handoffCompletion
                handoffRegion = nil
                handoffCompletion = nil
            }
        }
        strokesLock.unlock()
        if let completion { DispatchQueue.main.async(execute: completion) }
    }
}

// L'inchiostro della PAGINA ATTIVA (quella su cui si sta scrivendo),
// su una vista sincrona a pagina intera — il motore "pesante" di prima.
//
// Divisione del lavoro proposta dall'utente e adottata: la pagina dove
// la penna sta scrivendo usa questa vista sincrona (distacco del tratto
// perfetto PER COSTRUZIONE: live e commit nello stesso fotogramma, come
// nel motore a bitmap originale), tutte le altre pagine stanno sulle
// tessere (leggerezza e nitidezza da PDF sulle dispense lunghe). Il
// travaso verso le tessere avviene UNA volta, quando si lascia la
// pagina — un momento in cui nessuno sta guardando il tratto.
final class PageActiveInkView: UIView {
    // I tratti ci sono ancora, ma NON sono più la sorgente del disegno a
    // ogni ridisegno: servono solo a ricostruire la bitmap quando cambia
    // qualcosa di strutturale (gomma, undo, zoom, caricamento).
    private(set) var strokes: [PKStroke] = []
    var renderScale: CGFloat = 1

    // LA BITMAP È NOSTRA — misurato 2026-08-19, ed è il motivo di tutto
    // questo file.
    //
    // Prima si ridisegnava dai tratti a ogni `draw(_:)`, chiedendo un
    // ridisegno MIRATO al rettangolo del tratto nuovo. Quel rettangolo
    // veniva ignorato: `setNeedsDisplay(rect:)` su una UIView normale è
    // un suggerimento, il backing store viene rigenerato per intero e
    // `draw(_:)` riceve sempre i bounds completi (il parziale vero lo fa
    // solo CATiledLayer — ed è per questo che le altre pagine stanno su
    // tessere). Su una pagina da 785 tratti significava ristamparli
    // TUTTI a ogni sollevamento di penna: 112-148 ms misurati, cioè
    // 13-18 fotogrammi persi per far comparire un tratto solo.
    //
    // Con un CGLayer nostro l'inchiostro si ACCUMULA: al commit si
    // dipinge dentro il solo tratto nuovo, e `draw(_:)` si limita a
    // riversare la bitmap. Il costo per sollevamento smette di dipendere
    // da quanti tratti ci sono sulla pagina.
    private var inkLayer: CGLayer?
    private var builtAtSize: CGSize = .zero
    private var builtAtScale: CGFloat = 0
    private var needsRebuild = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // Sostituzione dei tratti. Con un rettangolo (gomma, lasso) il
    // ridisegno è PARZIALE: si azzera la zona toccata nella bitmap e si
    // ridipingono solo i tratti che ci passano dentro. È esattamente il
    // ridisegno mirato che UIKit rifiutava di fare — ora possiamo,
    // perché i pixel sono nostri. Senza rettangolo (caricamento, undo,
    // cambio zoom) si rifà tutto.
    func setStrokes(_ newStrokes: [PKStroke], invalidating rect: CGRect? = nil) {
        strokes = newStrokes
        guard !needsRebuild,
              let context = inkLayer?.context,
              let rect, !rect.isNull, !rect.isEmpty else {
            needsRebuild = true
            return
        }
        context.saveGState()
        // Il clip serve a garantire che un tratto che sborda dalla zona
        // non ridipinga anche fuori: là i pixel sono già giusti, e
        // ripassarli raddoppierebbe il multiply dell'evidenziatore.
        context.clear(rect)
        context.addRect(rect)
        context.clip()
        InkRenderer.draw(strokes, in: context, scale: renderScale, clipTo: rect)
        context.restoreGState()
    }

    // Il percorso caldo: un tratto solo, dipinto sopra a ciò che c'è già.
    func appendStroke(_ stroke: PKStroke) {
        strokes.append(stroke)
        guard !needsRebuild, let context = inkLayer?.context else { return }
        InkRenderer.draw(stroke, in: context, scale: renderScale)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        _ = prepareLayer(in: ctx)
        if let inkLayer { ctx.draw(inkLayer, in: bounds) }
    }

    // Ritorna quanti tratti ha ridisegnato: 0 quando la bitmap era già
    // pronta, che deve essere il caso normale.
    private func prepareLayer(in ctx: CGContext) -> Int {
        let scale = contentScaleFactor
        if inkLayer != nil, !needsRebuild, builtAtSize == bounds.size, builtAtScale == scale {
            return 0
        }
        guard bounds.width > 0, bounds.height > 0,
              let layer = CGLayer(ctx, size: bounds.size, auxiliaryInfo: nil),
              let layerContext = layer.context else {
            inkLayer = nil
            return 0
        }
        // NIENTE ribaltamento manuale: il contesto di un CGLayer creato
        // da un contesto UIKit eredita già il suo sistema di coordinate
        // (y verso il basso). Aggiungerne uno ribalta la nota — pagato
        // in prova, 2026-08-19.
        InkRenderer.draw(strokes, in: layerContext, scale: renderScale)
        inkLayer = layer
        builtAtSize = bounds.size
        builtAtScale = scale
        needsRebuild = false
        return strokes.count
    }

    func clearContents() {
        strokes = []
        inkLayer = nil
        needsRebuild = true
        layer.contents = nil
    }
}

// Il SOLO tratto in corso, su una vista dedicata — come nel Laboratorio.
//
// La prima versione lo disegnava dentro lo specchio della pagina: ogni
// campione della Pencil (fino a 240 al secondo) ridisegnava l'INTERA
// pagina alla risoluzione dello zoom, ed era questo a rendere la
// scrittura meno fluida che nel Laboratorio. Qui si invalida solo il
// rettangolo della coda nuova del tratto: il costo per campione è
// proporzionale a quanto inchiostro si aggiunge, non alla pagina.
final class PageLiveStrokeView: UIView {
    var stroke: PKStroke?
    var renderScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ rect: CGRect) {
        guard let stroke, let ctx = UIGraphicsGetCurrentContext() else { return }
        // `rect` è la coda appena aggiunta: il renderer emette solo gli
        // stampi che ci cadono dentro, invece di riemettere tutto il
        // tratto a ogni campione della Pencil.
        InkRenderer.draw(stroke, in: ctx, scale: renderScale, clipTo: rect)
    }

    // Butta anche il backing store: a fine sessione di scrittura la
    // memoria della vista (pagina intera alla scala dello zoom) torna
    // libera invece di restare allocata per un tratto che non c'è più.
    func clearContents() {
        stroke = nil
        layer.contents = nil
    }
}

// Una pagina reale della nota: il proprio sfondo (pattern, oppure una
// pagina di un PDF importato) e il proprio inchiostro.
//
// NIENTE PencilKit: l'inchiostro è un array di PKStroke (usati come puri
// dati geometrici) reso dal nostro renderer, il tratto vivo va su una
// vista dedicata, gomma lasso e undo sono nostri. PKDrawing sopravvive
// SOLO come formato di serializzazione su disco.
final class NotePageView: UIView {
    let backgroundView = TemplateBackgroundView()
    private let pdfPageView = TiledPDFPageView()
    let penInkView = PageInkView()
    // L'inchiostro sincrono della pagina attiva (vedi PageActiveInkView).
    let activeInkView = PageActiveInkView()
    // Il tratto in corso, su una vista sua (vedi PageLiveStrokeView).
    let liveStrokeView = PageLiveStrokeView()
    // Pagina in modalità scrittura: l'inchiostro sta su activeInkView
    // (sincrono), le tessere sono spente. Vedi beginWriting/endWriting.
    private(set) var isActiveForWriting = false
    // Regione toccata mentre la pagina era attiva: è ciò che le tessere
    // devono ridisegnare al travaso.
    private var activeDirtyRegion = CGRect.null
    private(set) var pdfPageData: Data?
    // Identità della NotePage che questa vista sta mostrando (il
    // PersistentIdentifier, opaco per questo livello). È la chiave con
    // cui il salvataggio differito attribuisce l'inchiostro: prima si
    // salvava PER INDICE, e un riordino delle pagine (undo di un import
    // PDF) tra il tratto e il flush scriveva il disegno sulla pagina
    // sbagliata o lo perdeva.
    var pageID: AnyHashable?
    // Ultimi dati-disegno applicati/salvati per questa pagina: permette a
    // sync() di saltare il confronto via dataRepresentation() (serializza
    // l'intero disegno, per ogni pagina, a ogni aggiornamento).
    var appliedDrawingData: Data?
    private var zoomForInk: CGFloat = 1

    // L'inchiostro della pagina. La verità è qui, non in un canvas.
    private(set) var strokes: [PKStroke] = []

    // RESIDENZA — il cuore della tenuta sulle dispense lunghe. Ogni vista
    // disegnata (sfondo PDF, pattern, inchiostro) alloca una bitmap a
    // pagina intera, fino a 6 volte la scala dello schermo sotto zoom:
    // ~14 MB a pagina a riposo, ~120 sotto zoom. Tenerle TUTTE vive, come
    // si faceva, con una dispensa da 60 pagine supera il gigabyte e iOS
    // uccide l'app. Restano materializzate solo le pagine vicine allo
    // schermo; le altre sono rettangoli bianchi senza backing store.
    private(set) var isResident = true
    private var pendingRenderZoom: CGFloat = 1
    private var lastAppliedRenderTarget: CGFloat = 0

    init(pageWidth: CGFloat, pageHeight: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        backgroundColor = .white
        clipsToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.withAlphaComponent(0.5).cgColor

        backgroundView.frame = bounds
        backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(backgroundView)

        pdfPageView.isHidden = true
        pdfPageView.frame = bounds
        pdfPageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(pdfPageView)

        penInkView.frame = bounds
        penInkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(penInkView)

        activeInkView.frame = bounds
        activeInkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(activeInkView)

        liveStrokeView.frame = bounds
        liveStrokeView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(liveStrokeView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Inchiostro

    // Aggiornamento dei tratti (gomma, lasso, undo, caricamento). Sulla
    // pagina ATTIVA tutto passa dalla vista sincrona — è il vecchio
    // motore, feedback nello stesso fotogramma; sulle altre pagine si
    // aggiornano le tessere.
    func setStrokes(_ newStrokes: [PKStroke], invalidating rect: CGRect? = nil) {
        strokes = newStrokes
        if isActiveForWriting {
            if let rect, !rect.isNull { activeDirtyRegion = activeDirtyRegion.union(rect) } else { activeDirtyRegion = bounds }
            activeInkView.setStrokes(newStrokes, invalidating: rect)
            activeInkView.isHidden = !isResident
            if let rect, !rect.isNull {
                activeInkView.setNeedsDisplay(rect.insetBy(dx: -8, dy: -8))
            } else {
                activeInkView.setNeedsDisplay()
            }
            return
        }
        penInkView.strokes = newStrokes
        // Una pagina senza inchiostro non paga nessuna bitmap: la vista
        // resta nascosta e il suo backing store non nasce proprio — sui
        // PDF importati è il caso di quasi tutte le pagine.
        penInkView.isHidden = newStrokes.isEmpty || !isResident
        if let rect, !rect.isNull {
            penInkView.setNeedsDisplay(rect.insetBy(dx: -8, dy: -8))
        } else {
            penInkView.setNeedsDisplay()
        }
    }

    // Percorso APPEND del commit di penna: sempre su pagina attiva
    // (l'overlay la attiva al primo tocco), sincrono nello stesso
    // fotogramma in cui il live si spegne.
    func appendCommittedStroke(_ stroke: PKStroke, invalidating rect: CGRect) {
        if !isActiveForWriting { beginWriting() }
        strokes.append(stroke)
        activeDirtyRegion = activeDirtyRegion.union(rect)
        activeInkView.appendStroke(stroke)
        activeInkView.isHidden = !isResident
        activeInkView.setNeedsDisplay(rect)
    }

    // Entra in modalità scrittura: la vista sincrona prende TUTTI i
    // tratti della pagina e le tessere si spengono, nella stessa
    // transazione — le due viste mostrano gli stessi pixel, lo scambio
    // non si vede. Da qui in poi il distacco è quello del motore vecchio.
    func beginWriting() {
        guard !isActiveForWriting else { return }
        isActiveForWriting = true
        activeDirtyRegion = .null
        activeInkView.renderScale = zoomForInk
        if lastAppliedRenderTarget > 0 { activeInkView.contentScaleFactor = lastAppliedRenderTarget }
        activeInkView.setStrokes(strokes)
        activeInkView.isHidden = !isResident
        activeInkView.setNeedsDisplay()
        penInkView.isHidden = true
    }

    // Lascia la modalità scrittura: i tratti tornano alle tessere. La
    // vista sincrona resta accesa finché le tessere non hanno disegnato
    // E composto la regione cambiata — mai un buco; la sovrapposizione
    // dura un fotogramma su una pagina che si sta LASCIANDO.
    func endWriting() {
        guard isActiveForWriting else { return }
        isActiveForWriting = false
        let dirty = activeDirtyRegion
        activeDirtyRegion = .null
        penInkView.strokes = strokes
        penInkView.isHidden = strokes.isEmpty || !isResident
        guard !dirty.isNull else {
            // Niente è cambiato: le tessere sono già giuste.
            activeInkView.clearContents()
            activeInkView.isHidden = true
            return
        }
        let region = dirty.insetBy(dx: -8, dy: -8)
        penInkView.setNeedsDisplay(region)
        let finish: () -> Void = { [weak self] in
            guard let self, !self.isActiveForWriting else { return }
            self.activeInkView.clearContents()
            self.activeInkView.isHidden = true
        }
        penInkView.notifyWhenCovered(region) {
            CATransaction.setCompletionBlock(finish)
        }
        // Rete di sicurezza se una tessera non arriva (pagina ormai
        // fuori schermo); doppia esecuzione innocua.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: finish)
    }

    func setResident(_ resident: Bool) {
        guard resident != isResident else { return }
        isResident = resident
        let hasPDF = pdfPageData != nil
        if resident {
            pdfPageView.isHidden = !hasPDF
            backgroundView.isHidden = hasPDF
            penInkView.isHidden = strokes.isEmpty
            applyRenderScale(pendingRenderZoom)
            pdfPageView.renderAsyncIfNeeded()
            backgroundView.setNeedsDisplay()
            penInkView.setNeedsDisplay()
        } else {
            pdfPageView.isHidden = true
            backgroundView.isHidden = true
            penInkView.isHidden = true
            // layer.contents = nil è ciò che RESTITUISCE la memoria:
            // nascondere non basta, il backing store resterebbe allocato.
            // (L'inchiostro ora è su CATiledLayer come il PDF: le sue
            // tessere fuori schermo le libera CoreAnimation da sola,
            // toccare `contents` di una tiled layer non si fa.)
            pdfPageView.suspendRendering()
            backgroundView.layer.contents = nil
            liveStrokeView.clearContents()
            // La pagina attiva si scarica nelle tessere in silenzio:
            // fuori dalla finestra di residenza nessuno vede il travaso,
            // e la bitmap sincrona torna libera.
            isActiveForWriting = false
            activeDirtyRegion = .null
            penInkView.strokes = strokes
            activeInkView.clearContents()
            activeInkView.isHidden = true
        }
    }

    // Carica da storage senza passare per l'undo (il caricamento non è
    // un'azione annullabile).
    func loadDrawingData(_ data: Data) {
        setStrokes((try? PKDrawing(data: data))?.strokes ?? [])
    }

    // Estensione verticale dell'inchiostro, per la crescita automatica
    // delle pagine.
    var inkBounds: CGRect {
        strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
    }

    func setPDFPage(_ data: Data?) {
        guard data != pdfPageData else { return }
        pdfPageData = data
        cachedNaturalHeight = nil
        pdfPageView.setPDFData(data)
        let hasPDF = data != nil
        pdfPageView.isHidden = !hasPDF
        backgroundView.isHidden = hasPDF
        // La chiamata dentro setPDFData è caduta nel vuoto: la vista era
        // ancora nascosta (l'ordine qui sopra la scopre DOPO). Rilanciata
        // ora che è visibile.
        pdfPageView.renderAsyncIfNeeded()
    }

    // Pagina PDF di sfondo (se c'è), per ridisegnarla vettorialmente
    // nell'export invece di rasterizzarla.
    var pdfPage: PDFPage? { pdfPageView.page }

    // Nitidezza dello sfondo PDF e dell'inchiostro allo zoom corrente:
    // ingrandire una rasterizzazione fatta a 1× è ciò che rendeva tutto
    // sfocato sotto zoom. Alzando la scala di rendering si ridisegna alla
    // risoluzione che serve davvero (tetto a 3× per non esagerare con la
    // memoria).
    func applyRenderScale(_ zoomScale: CGFloat) {
        // Fuori dalla finestra di residenza non si rasterizza niente: la
        // scala giusta arriva al rientro.
        guard isResident else {
            pendingRenderZoom = zoomScale
            return
        }
        pendingRenderZoom = zoomScale
        let deviceScale = window?.screen.scale ?? traitCollection.displayScale
        let target = min(max(zoomScale, 1), 3) * deviceScale
        guard abs(lastAppliedRenderTarget - target) > 0.01 else { return }
        lastAppliedRenderTarget = target
        zoomForInk = min(max(zoomScale, 1), 3)
        pdfPageView.setRenderScale(target)
        backgroundView.contentScaleFactor = target
        backgroundView.setNeedsDisplay()
        // L'inchiostro committato non ha più bisogno di questa scala:
        // sta su tessere con LOD, la nitidezza sotto zoom la gestisce
        // CoreAnimation come per il PDF. Restano da scalare le viste
        // sincrone: tratto vivo e tratti recenti.
        liveStrokeView.contentScaleFactor = target
        liveStrokeView.renderScale = zoomForInk
        activeInkView.contentScaleFactor = target
        activeInkView.renderScale = zoomForInk
        if !activeInkView.strokes.isEmpty { activeInkView.setNeedsDisplay() }
    }

    // Altezza naturale della pagina: quella del PDF (scalata alla
    // larghezza foglio) se c'è uno sfondo, altrimenti l'altezza standard
    // della nota (pattern/bianco).
    private var cachedNaturalHeight: CGFloat?
    func naturalHeight(pageWidth: CGFloat, fallback: CGFloat) -> CGFloat {
        if let cachedNaturalHeight { return cachedNaturalHeight }
        guard let page = pdfPage else { return fallback }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0 else { return fallback }
        let height = pageWidth * (box.height / box.width)
        cachedNaturalHeight = height
        // sync() interroga l'altezza di TUTTE le pagine all'apertura:
        // senza rilascio, restavano aperti 60 documenti solo per un
        // rapporto d'aspetto ormai memorizzato.
        if !isResident { pdfPageView.releaseDocumentCache() }
        return height
    }
}

// IL TRATTO NOSTRO — cattura dei tocchi per penna ed evidenziatore.
//
// Validato nel Laboratorio ("Motore nostro"): la Pencil parla
// direttamente con noi, senza PencilKit in mezzo. `coalescedTouches`
// recupera i campioni a 240 Hz fra un fotogramma e l'altro (senza, il
// tratto esce spigoloso).
//
// NIENTE `predictedTouches` (tolti 2026-08-19). Disegnavano qualche
// millisecondo avanti alla punta per mascherare la latenza, ma erano una
// scommessa: a ogni fotogramma quella coda veniva cancellata e rifatta
// altrove, e al sollevamento spariva del tutto perché nel tratto salvato
// i punti previsti non entrano mai. Il risultato era una codina che
// ballava mentre si scrive e cambiava forma quando si alzava — che
// l'utente leggeva come lentezza, mentre i ridisegni stavano a 0,1-1,6 ms
// su una pagina da 750 tratti. Meno inchiostro attaccato alla punta, ma
// fermo: era il fastidio vero.
//
// Il tratto finito diventa un PKStroke vero dentro il PKDrawing della
// pagina: lo storage non cambia, gomma lasso e undo di PencilKit
// continuano a funzionare, e l'assegnazione del disegno registra l'undo
// nativo da sola.
// GLI APPUNTI DELL'INCHIOSTRO — copia/taglia/incolla del lasso.
//
// I tratti si conservano con la loro trasformazione: la disposizione
// reciproca è già dentro la geometria, e all'incollaggio basta traslare
// il gruppo. Vivono quanto la sessione e valgono fra pagine e fra note,
// che è il caso d'uso vero (ricopiare uno schema da una pagina all'altra).
enum InkClipboard {
    private(set) static var strokes: [PKStroke] = []
    static var isEmpty: Bool { strokes.isEmpty }

    static func store(_ newStrokes: [PKStroke]) {
        strokes = newStrokes
    }
}

final class LiveInkCaptureOverlay: UIView {
    weak var container: PagedCanvasContainer?
    var onStrokeBegan: (() -> Void)?
    // Operazione di lasso conclusa (spostamento o eliminazione): il
    // chiamante riporta lo strumento a quello di prima, come la gomma.
    var onLassoFinished: (() -> Void)?
    // Passata di gomma conclusa. È un evento di INTERAZIONE — il dito si
    // è alzato — e va tenuto separato dal salvataggio: stava agganciato
    // a `onPageDataChanged`, che da quando il salvataggio è differito
    // arriva tre secondi dopo (e più ancora se si continua a cancellare,
    // per via della guardia sulla penna giù). Risultato: lo strumento
    // non tornava alla penna finché non ci si fermava del tutto.
    var onEraseFinished: (() -> Void)?

    // Cosa fa la Pencil quando tocca: scrive, oppure cancella (gomma
    // NOSTRA, vedi InkEraser — lavora sulla geometria, quindi cancella
    // anche i tratti di matita disegnati da PencilKit).
    enum Mode {
        case draw
        case erase(radius: CGFloat, partial: Bool)
        case lasso
    }
    var mode: Mode = .draw

    // Configurazione dello strumento corrente, impostata da applyToolState.
    var inkColor: UIColor = .black
    var baseWidth: CGFloat = 3
    // La penna modula lo spessore con la pressione, l'evidenziatore no.
    var pressureSensitive = true
    // L'inchiostro con cui il tratto finito entra nel PKDrawing. Conta
    // più di quanto sembri: `.marker` è l'unico che si FONDE con ciò che
    // sta sotto, ed è quello che fa passare l'evidenziatore sotto alla
    // scrittura invece che sopra.
    var inkType: PKInkingTool.InkType = .pen

    private var activePage: NotePageView?
    // Vero mentre un tratto (o una passata di gomma) è in corso: il
    // salvataggio non deve mai cadere in mezzo a un gesto.
    var isDrawing: Bool { activePage != nil }
    private var points: [PKStrokePoint] = []
    private var startTime: TimeInterval = 0
    // Regione (in coordinate di pagina) toccata dall'ultimo aggiornamento
    // del tratto vivo: i punti PREDETTI vanno ricancellati al giro dopo,
    // perché erano una scommessa e i punti veri possono essere altrove.
    private var previousTailRect: CGRect = .null
    // Gomma: disegno di lavoro su cui si accumulano i passaggi; va nel
    // canvas UNA volta sola al sollevamento — un solo undo per passata,
    // una sola serializzazione.
    private var eraseWorkingStrokes: [PKStroke]?
    private var eraseStrokesAtPassStart: [PKStroke] = []
    private var eraseChanged = false

    // Cerchio che segue la gomma, come quello che c'era con PencilKit.
    private lazy var eraserCursor: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = UIColor.label.withAlphaComponent(0.1)
        view.layer.borderWidth = 1.5
        view.layer.borderColor = UIColor.label.withAlphaComponent(0.6).cgColor
        view.isHidden = true
        addSubview(view)
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Tocchi

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activePage == nil, let touch = touches.first else { return }
        // Solo la Pencil disegna (stessa regola di drawingPolicy
        // .pencilOnly): il dito resta libero di scorrere il foglio, il
        // pan della scroll view lo riceve comunque perché è un gesto
        // dell'antenato.
        guard touch.type == .pencil else { return }
        guard let container,
              let page = container.pageViews.first(where: { $0.frame.contains(touch.location(in: container.contentHost)) })
        else { return }
        onStrokeBegan?()
        activePage = page
        startTime = touch.timestamp
        points = []
        previousTailRect = .null
        if case .erase = mode {
            // Anche la gomma mette la pagina sul motore sincrono: il
            // feedback per campione (specie con la gomma precisa, che
            // ridisegna tratti divisi) non deve passare dalle tessere.
            container.setActiveWritingPage(page)
            eraseStrokesAtPassStart = page.strokes
            eraseWorkingStrokes = page.strokes
            eraseChanged = false
            applyErase(touch, event: event)
        } else if case .lasso = mode {
            lassoBegan(touch, on: page)
        } else {
            // La pagina toccata entra in modalità scrittura (motore
            // sincrono); quella attiva prima travasa nelle tessere.
            container.setActiveWritingPage(page)
            page.liveStrokeView.isHidden = false
            let added = append(touch, event: event)
            updateLive(with: event, appended: added)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activePage != nil, let touch = touches.first else { return }
        if case .erase = mode {
            applyErase(touch, event: event)
        } else if case .lasso = mode {
            lassoMoved(touch)
        } else {
            let added = append(touch, event: event)
            updateLive(with: event, appended: added)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, activePage != nil else { return }
        if case .erase = mode {
            applyErase(touch, event: event)
            commitErase()
        } else if case .lasso = mode {
            lassoEnded(touch)
            // Senza questo, il guard su activePage scartava OGNI tocco
            // successivo: era il motivo per cui la selezione non si
            // poteva spostare.
            activePage = nil
        } else {
            _ = append(touch, event: event, keepLast: true)
            commitStroke()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let page = activePage else { return }
        if case .erase = mode {
            // Passata annullata dal sistema: si ripristina lo stato di
            // partenza, mai committato.
            page.setStrokes(eraseStrokesAtPassStart)
            eraseWorkingStrokes = nil
            eraserCursor.isHidden = true
        }
        if case .lasso = mode { clearLassoSelection() }
        activePage = nil
        points = []
        page.liveStrokeView.clearContents()
        page.liveStrokeView.isHidden = true
    }

    // MARK: - Gomma

    private func applyErase(_ touch: UITouch, event: UIEvent?) {
        guard case .erase(let radius, let partial) = mode,
              let page = activePage,
              var working = eraseWorkingStrokes else { return }

        // Cerchio-cursore, in coordinate dell'overlay.
        let cursorCenter = touch.location(in: self)
        let diameter = radius * 2
        eraserCursor.layer.cornerRadius = radius
        eraserCursor.frame = CGRect(x: cursorCenter.x - radius, y: cursorCenter.y - radius, width: diameter, height: diameter)
        eraserCursor.isHidden = false
        bringSubviewToFront(eraserCursor)

        var changed = false
        var dirty = CGRect.null
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            let point = sample.location(in: page)
            if let result = InkEraser.erase(working, at: point, radius: radius, partial: partial) {
                working = result.strokes
                dirty = dirty.union(result.dirtyRect)
                changed = true
            }
        }
        guard changed else { return }
        eraseWorkingStrokes = working
        eraseChanged = true
        // Feedback in diretta, ridisegnando solo la zona toccata:
        // l'inchiostro sparisce sotto la gomma. Il salvataggio e l'undo
        // arrivano in un colpo solo al sollevamento.
        page.setStrokes(working, invalidating: dirty)
    }

    private func commitErase() {
        eraserCursor.isHidden = true
        guard let page = activePage else { return }
        activePage = nil
        defer { eraseWorkingStrokes = nil }
        guard let working = eraseWorkingStrokes, eraseChanged else { return }
        // Un commit per passata: un undo, una serializzazione.
        container?.commitStrokes(working, previous: eraseStrokesAtPassStart, on: page)
        onEraseFinished?()
    }

    // Aggiunge i campioni del tocco e ritorna il rettangolo che coprono,
    // in coordinate di pagina: è la base dell'invalidazione mirata.
    //
    // I campioni più vicini di InkSmoothing.minPointDistance all'ultimo
    // punto accettato si scartano: sono il tremolio, non il gesto.
    // `keepLast` forza l'ultimo campione (il sollevamento): senza, il
    // tratto si fermerebbe a mezza distanza dalla punta — e un punto
    // fermo (che produce campioni tutti coincidenti) non arriverebbe
    // mai ai 2 punti minimi per fare un tratto.
    private func append(_ touch: UITouch, event: UIEvent?, keepLast: Bool = false) -> CGRect {
        guard let page = activePage else { return .null }
        var box = CGRect.null
        // I coalesced contengono ANCHE il tocco principale.
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        let minDistance = InkSmoothing.minPointDistance
        for (index, sample) in samples.enumerated() {
            let point = strokePoint(from: sample, in: page)
            let isForced = keepLast && index == samples.count - 1
            if !isForced, minDistance > 0, let last = points.last {
                let dx = point.location.x - last.location.x
                let dy = point.location.y - last.location.y
                if dx * dx + dy * dy < minDistance * minDistance { continue }
            }
            points.append(point)
            box = box.union(CGRect(origin: point.location, size: .zero))
        }
        return box
    }

    private func updateLive(with event: UIEvent?, appended: CGRect) {
        guard let page = activePage else { return }
        // ATTENZIONE — qui ci va il tratto INTERO, non la sua coda.
        //
        // Provato (2026-08-19) a passare solo gli ultimi ~64 punti,
        // contando sul fatto che la vista accumuli sul proprio layer e
        // che `draw(_:)` ripulisca solo la regione sporca. NON È
        // GARANTITO: CoreAnimation può ridisegnare l'INTERO layer quando
        // vuole (regione sporca complessa, backing store rigenerato,
        // `contentScaleFactor` cambiato dallo zoom), e in quel momento
        // `draw(_:)` riceve i bounds interi — con la sola coda in mano,
        // il resto del tratto viene cancellato e sparisce sotto la penna.
        // Riprodotto sul dispositivo: un tratto lungo scompare.
        //
        // L'accumulo vero si fa possedendo la bitmap (contesto nostro,
        // riversato in draw), non appoggiandosi alla conservazione del
        // backing store di UIKit.
        let live = page.liveStrokeView
        live.stroke = makeStroke(from: points)

        // La coda da ridisegnare: gli ULTIMI OTTO punti veri, non solo i
        // nuovi — una B-spline cubica flette i segmenti vicini quando
        // arriva un punto di controllo nuovo, e invalidare solo i punti
        // appena aggiunti lasciava pixel fantasma lungo la curva (che
        // "sparivano" al sollevamento, sembrando un movimento del tratto).
        var tail = appended
        for point in points.suffix(8) {
            tail = tail.union(CGRect(origin: point.location, size: .zero))
        }
        let dirty = tail.union(previousTailRect)
        previousTailRect = tail
        guard !dirty.isNull else { return }
        let inflation = max(baseWidth * 2 + 8, 24)
        live.setNeedsDisplay(dirty.insetBy(dx: -inflation, dy: -inflation))
    }

    private func commitStroke() {
        guard let page = activePage else { return }
        activePage = nil
        defer {
            points = []
            previousTailRect = .null
        }
        let live = page.liveStrokeView
        guard let stroke = makeStroke(from: points) else {
            live.clearContents()
            live.isHidden = true
            return
        }
        // Il commit passa dal contenitore: salvataggio, crescita pagine
        // e undo in un punto solo. Col percorso append il tratto entra
        // nella vista recente SINCRONA nella stessa transazione in cui
        // il live qui sotto si spegne: il distacco è di nuovo senza
        // asincronia, come nel motore a bitmap — niente lampi, niente
        // "ricomposizioni". La migrazione nelle tessere avviene dopo, a
        // si lascia la pagina (NotePageView.endWriting).
        container?.commitStrokes(page.strokes + [stroke], on: page, invalidating: stroke.renderBounds.insetBy(dx: -32, dy: -32), appended: stroke)
        let cleared = live.stroke?.renderBounds ?? stroke.renderBounds
        live.stroke = nil
        live.setNeedsDisplay(cleared.insetBy(dx: -32, dy: -32))
    }

    private func makeStroke(from points: [PKStrokePoint]) -> PKStroke? {
        guard points.count >= 2 else { return nil }
        return PKStroke(
            ink: PKInk(inkType, color: inkColor),
            path: PKStrokePath(controlPoints: points, creationDate: Date())
        )
    }

    // Lo spessore si scrive nella grandezza che la legge misurata di
    // PencilKit (larghezza = 2·size − 4) riporta alla larghezza voluta:
    // così il tratto resta identico comunque lo si renda.
    private func strokePoint(from touch: UITouch, in page: NotePageView) -> PKStrokePoint {
        let location = touch.location(in: page)
        let maxForce = touch.maximumPossibleForce > 0 ? touch.maximumPossibleForce : 1
        let force = touch.type == .pencil ? min(touch.force / maxForce, 1) : 0.5
        // La curva pressione→spessore è centralizzata in InkPressure ed
        // è regolabile dai cursori di taratura nel popover della penna.
        let width = pressureSensitive ? InkPressure.width(base: baseWidth, force: force) : baseWidth
        // La grandezza scritta nel punto segue la legge misurata della
        // penna (larghezza = 2·size − 4).
        let size = max(1, (width + 4) / 2)
        return PKStrokePoint(
            location: location,
            timeOffset: max(0, touch.timestamp - startTime),
            size: CGSize(width: size, height: size),
            opacity: 1,
            force: force,
            azimuth: touch.type == .pencil ? touch.azimuthAngle(in: self) : 0,
            altitude: touch.type == .pencil ? touch.altitudeAngle : .pi / 2
        )
    }

    // MARK: - Lasso (nostro)

    // Selezione a mano libera: si disegna un recinto, i tratti con almeno
    // un punto dentro sono selezionati, e la selezione si trascina o si
    // elimina. Tutto su CAShapeLayer (leggeri: il path lo compone
    // CoreAnimation, niente backing store da pagina intera).
    private var lassoPage: NotePageView?
    private var lassoPoints: [CGPoint] = []
    private var selectionPage: NotePageView?
    private var selectedIndices: [Int] = []
    private var selectionBaseStrokes: [PKStroke] = []
    private var isMovingSelection = false
    // C'era una selezione quando il dito è sceso? Distingue il tocco che
    // POSA la selezione da quello che INCOLLA.
    private var hadSelectionAtTouchDown = false
    private var moveStart: CGPoint = .zero
    private var moveTranslation: CGPoint = .zero

    private lazy var lassoLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        layer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.8).cgColor
        layer.lineWidth = 1.5
        layer.lineDashPattern = [6, 4]
        self.layer.addSublayer(layer)
        return layer
    }()

    private lazy var selectionLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.8).cgColor
        layer.lineWidth = 1.5
        layer.lineDashPattern = [6, 4]
        self.layer.addSublayer(layer)
        return layer
    }()

    // Le azioni sulla selezione, in una barretta sopra il recinto.
    // L'ordine va dal meno al più distruttivo, e il cestino resta
    // l'unico rosso: è la sola azione che non si può rifare guardando.
    private func makeChip(_ symbol: String, tint: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)),
            for: .normal
        )
        button.tintColor = tint
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private lazy var duplicateChip = makeChip("plus.square.on.square", tint: .label, action: #selector(duplicateSelection))
    private lazy var copyChip = makeChip("doc.on.doc", tint: .label, action: #selector(copySelection))
    private lazy var cutChip = makeChip("scissors", tint: .label, action: #selector(cutSelection))
    private lazy var deleteChip = makeChip("trash", tint: .systemRed, action: #selector(deleteSelection))

    private static let chipWidth: CGFloat = 40
    private static let chipHeight: CGFloat = 32

    private lazy var selectionBar: UIView = {
        let bar = UIView()
        bar.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        bar.layer.cornerRadius = Self.chipHeight / 2
        bar.layer.borderWidth = 1
        bar.layer.borderColor = UIColor.separator.cgColor
        bar.isHidden = true
        let chips = [duplicateChip, copyChip, cutChip, deleteChip]
        for (index, chip) in chips.enumerated() {
            chip.frame = CGRect(
                x: CGFloat(index) * Self.chipWidth, y: 0,
                width: Self.chipWidth, height: Self.chipHeight
            )
            bar.addSubview(chip)
        }
        bar.frame = CGRect(
            x: 0, y: 0,
            width: CGFloat(chips.count) * Self.chipWidth, height: Self.chipHeight
        )
        addSubview(bar)
        return bar
    }()

    private var selectionBounds: CGRect {
        guard let page = selectionPage else { return .null }
        return selectedIndices.reduce(CGRect.null) { partial, index in
            guard page.strokes.indices.contains(index) else { return partial }
            return partial.union(page.strokes[index].renderBounds)
        }
    }

    func clearLassoSelection() {
        lassoPage = nil
        lassoPoints = []
        selectionPage = nil
        selectedIndices = []
        selectionBaseStrokes = []
        isMovingSelection = false
        lassoLayer.path = nil
        selectionLayer.path = nil
        selectionBar.isHidden = true
    }

    private func lassoBegan(_ touch: UITouch, on page: NotePageView) {
        let pagePoint = touch.location(in: page)
        // Presa DENTRO la selezione esistente: si sposta. Fuori: nuovo recinto.
        if page === selectionPage, !selectedIndices.isEmpty,
           selectionBounds.insetBy(dx: -24, dy: -24).contains(pagePoint) {
            isMovingSelection = true
            moveStart = pagePoint
            moveTranslation = .zero
            selectionBaseStrokes = page.strokes
        } else {
            // `clearLassoSelection` cancella la selezione: se c'era, il
            // rilascio deve saperlo per distinguere "posa" da "incolla".
            hadSelectionAtTouchDown = selectionPage != nil && !selectedIndices.isEmpty
            clearLassoSelection()
            lassoPage = page
            lassoPoints = [pagePoint]
        }
    }

    private func lassoMoved(_ touch: UITouch) {
        if isMovingSelection, let page = selectionPage {
            let point = touch.location(in: page)
            let oldBounds = selectionBounds
            moveTranslation = CGPoint(x: point.x - moveStart.x, y: point.y - moveStart.y)
            var preview = selectionBaseStrokes
            for index in selectedIndices where preview.indices.contains(index) {
                var stroke = selectionBaseStrokes[index]
                stroke.transform = stroke.transform.concatenating(
                    CGAffineTransform(translationX: moveTranslation.x, y: moveTranslation.y)
                )
                preview[index] = stroke
            }
            page.setStrokes(preview, invalidating: oldBounds.union(selectionBounds).insetBy(dx: -40, dy: -40))
            updateSelectionChrome()
        } else if let page = lassoPage {
            lassoPoints.append(touch.location(in: page))
            let path = CGMutablePath()
            guard let first = lassoPoints.first else { return }
            path.move(to: CGPoint(x: first.x + page.frame.minX, y: first.y + page.frame.minY))
            for point in lassoPoints.dropFirst() {
                path.addLine(to: CGPoint(x: point.x + page.frame.minX, y: point.y + page.frame.minY))
            }
            lassoLayer.path = path
        }
    }

    private func lassoEnded(_ touch: UITouch) {
        if isMovingSelection, let page = selectionPage {
            isMovingSelection = false
            guard moveTranslation != .zero else { return }
            // La pagina mostra già l'anteprima: si committa quella, con lo
            // stato pre-spostamento come "prima" per l'annullamento.
            container?.commitStrokes(page.strokes, previous: selectionBaseStrokes, on: page)
            clearLassoSelection()
            // Spostamento fatto = operazione conclusa: si torna allo
            // strumento di prima, come dopo un tratto di gomma.
            onLassoFinished?()
            return
        }
        // Un TOCCO (non un recinto) col lasso incolla lì, se negli
        // appunti c'è qualcosa: nessun pulsante in più da mostrare, e il
        // punto in cui si incolla lo decide il dito.
        //
        // MA SOLO SE NON C'È GIÀ UNA SELEZIONE. Altrimenti il tocco
        // serve a posarla, e senza questa condizione si finiva in una
        // catena: incolli, la copia resta selezionata, tocchi altrove per
        // deselezionare e ne incolli un'altra, che resta selezionata, e
        // così via. Ora il primo tocco depone, il secondo incolla.
        let box = lassoPoints.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let isTap = lassoPoints.count < 3 || (box.width < 12 && box.height < 12)
        if isTap, hadSelectionAtTouchDown {
            lassoLayer.path = nil
            lassoPage = nil
            lassoPoints = []
            clearLassoSelection()
            return
        }
        if isTap, !InkClipboard.isEmpty, let page = lassoPage, let point = lassoPoints.first {
            lassoLayer.path = nil
            lassoPage = nil
            lassoPoints = []
            pasteClipboard(on: page, at: point)
            return
        }
        guard let page = lassoPage, lassoPoints.count >= 3 else {
            lassoLayer.path = nil
            lassoPage = nil
            lassoPoints = []
            return
        }
        // Chiusura del recinto e prova di appartenenza: un tratto è
        // selezionato se un suo punto di controllo (portato nello spazio
        // della pagina dalla trasformazione) cade dentro il poligono.
        let polygon = CGMutablePath()
        polygon.move(to: lassoPoints[0])
        for point in lassoPoints.dropFirst() { polygon.addLine(to: point) }
        polygon.closeSubpath()

        var indices: [Int] = []
        let polygonBox = polygon.boundingBox
        for (index, stroke) in page.strokes.enumerated() {
            guard polygonBox.intersects(stroke.renderBounds) else { continue }
            // CGPath.contains costa: si campiona a passo, al massimo una
            // ventina di punti per tratto — era questo a rendere lento il
            // rilascio del recinto.
            let path = stroke.path
            let step = max(1, path.count / 20)
            for i in stride(from: 0, to: path.count, by: step) {
                let location = path[i].location.applying(stroke.transform)
                if polygon.contains(location) {
                    indices.append(index)
                    break
                }
            }
        }
        lassoLayer.path = nil
        lassoPage = nil
        lassoPoints = []
        guard !indices.isEmpty else { return }
        selectionPage = page
        selectedIndices = indices
        selectionBaseStrokes = page.strokes
        updateSelectionChrome()
    }

    private func updateSelectionChrome() {
        guard let page = selectionPage else { return }
        let bounds = selectionBounds
        guard !bounds.isNull else { clearLassoSelection(); return }
        let overlayRect = CGRect(
            x: bounds.minX + page.frame.minX,
            y: bounds.minY + page.frame.minY,
            width: bounds.width,
            height: bounds.height
        ).insetBy(dx: -10, dy: -10)
        selectionLayer.path = UIBezierPath(roundedRect: overlayRect, cornerRadius: DesignRadius.md).cgPath
        selectionBar.isHidden = false
        // Sopra la selezione, allineata a destra. Se lassù non ci sta
        // (selezione a filo del bordo alto), scende sotto invece di
        // finire fuori schermo.
        let width = selectionBar.frame.width
        let height = selectionBar.frame.height
        let above = overlayRect.minY - height - 6
        selectionBar.frame = CGRect(
            x: max(0, overlayRect.maxX - width),
            y: above >= 0 ? above : overlayRect.maxY + 6,
            width: width, height: height
        )
        bringSubviewToFront(selectionBar)
    }

    // I tratti selezionati, nell'ordine in cui stanno sulla pagina.
    private var selectedStrokes: [PKStroke] {
        guard let page = selectionPage else { return [] }
        return selectedIndices.sorted().compactMap { index in
            page.strokes.indices.contains(index) ? page.strokes[index] : nil
        }
    }

    @objc private func deleteSelection() {
        removeSelection()
    }

    // Copiare NON conclude l'operazione: la selezione resta viva, così si
    // può copiare e poi spostare o duplicare senza rifare il recinto.
    @objc private func copySelection() {
        let picked = selectedStrokes
        guard !picked.isEmpty else { return }
        InkClipboard.store(picked)
    }

    @objc private func cutSelection() {
        let picked = selectedStrokes
        guard !picked.isEmpty else { return }
        InkClipboard.store(picked)
        removeSelection()
    }

    // Duplica sul posto con uno scarto visibile, e la copia diventa la
    // nuova selezione: si può trascinarla subito dove serve.
    @objc private func duplicateSelection() {
        guard let page = selectionPage else { return }
        let picked = selectedStrokes
        guard !picked.isEmpty else { return }
        let offset = CGAffineTransform(translationX: 24, y: 24)
        insert(picked.map { stroke in
            var copy = stroke
            copy.transform = copy.transform.concatenating(offset)
            return copy
        }, on: page)
    }

    // Rimozione condivisa da cestino e forbici.
    private func removeSelection() {
        guard let page = selectionPage, !selectedIndices.isEmpty else { return }
        let dirty = selectionBounds.insetBy(dx: -40, dy: -40)
        let keep = page.strokes.enumerated()
            .filter { !selectedIndices.contains($0.offset) }
            .map(\.element)
        container?.commitStrokes(keep, previous: page.strokes, on: page, invalidating: dirty)
        clearLassoSelection()
        onLassoFinished?()
    }

    // Incolla il contenuto degli appunti CENTRATO sul punto toccato.
    private func pasteClipboard(on page: NotePageView, at point: CGPoint) {
        let clip = InkClipboard.strokes
        guard !clip.isEmpty else { return }
        let bounds = clip.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard !bounds.isNull else { return }
        let shift = CGAffineTransform(
            translationX: point.x - bounds.midX,
            y: point.y - bounds.midY
        )
        insert(clip.map { stroke in
            var copy = stroke
            copy.transform = copy.transform.concatenating(shift)
            return copy
        }, on: page)
    }

    // Aggiunge tratti in coda e li lascia SELEZIONATI: è ciò che rende
    // duplica e incolla immediatamente utili, perché la cosa appena
    // creata è già presa in mano.
    private func insert(_ newStrokes: [PKStroke], on page: NotePageView) {
        guard !newStrokes.isEmpty else { return }
        let previous = page.strokes
        let merged = previous + newStrokes
        let dirty = newStrokes
            .reduce(CGRect.null) { $0.union($1.renderBounds) }
            .insetBy(dx: -40, dy: -40)
        container?.commitStrokes(merged, previous: previous, on: page, invalidating: dirty)
        selectionPage = page
        selectedIndices = Array(previous.count..<merged.count)
        selectionBaseStrokes = merged
        updateSelectionChrome()
    }
}

// Contenitore: una sola UIScrollView che fa pan e zoom del contentHost
// (dove vivono le pagine), col contenuto centrato tramite contentInset.
final class PagedCanvasContainer: UIScrollView, UIScrollViewDelegate {
    let contentHost = UIView()
    let overlayLayer = PassthroughOverlayView()
    let interactionOverlay = UIView()
    let liveInkOverlay = LiveInkCaptureOverlay()
    private(set) var pageViews: [NotePageView] = []
    private let pageGap: CGFloat = 20
    private(set) var pageWidth: CGFloat
    private var lastFitWidth: CGFloat = 0
    private var userDidZoom = false
    // Dimensione del contenuto a zoom 1: la geometria si ricalcola solo
    // quando questa cambia, non a ogni aggiornamento della vista.
    private var contentLayoutSize: CGSize = .zero
    weak var lastActivePageView: NotePageView?
    // La pagina in modalità scrittura (motore sincrono); cambiando
    // pagina la precedente travasa i tratti nelle tessere.
    private weak var activeWritingPage: NotePageView?

    func setActiveWritingPage(_ page: NotePageView) {
        guard activeWritingPage !== page else { return }
        activeWritingPage?.endWriting()
        activeWritingPage = page
        page.beginWriting()
        // Il travaso su disco NON va fatto qui in linea: questa funzione
        // la chiama `touchesBegan`, e serializzare la pagina precedente
        // (più la scrittura SwiftData e il giro di SwiftUI che ne segue)
        // prima ancora di disegnare il primo campione ritardava la
        // comparsa del tratto al cambio pagina. Si programma per subito
        // dopo, quando il tocco è già stato servito.
        Task { @MainActor [weak self] in self?.flushPendingSaves() }
    }
    // Segnalibro automatico: pagina da cui ripartire alla prima
    // apertura, applicata appena il layout ha dimensioni reali.
    var pendingInitialPage: Int?
    private lazy var defaultPanTouchTypes = panGestureRecognizer.allowedTouchTypes

    // Mentre la Pencil disegna col motore nostro, il foglio non deve
    // scorrerle sotto la punta: il pan resta al dito. Con gli altri
    // strumenti la Pencil torna anche a scorrere (puntatore, trackpad...).
    func setPencilPanBlocked(_ blocked: Bool) {
        panGestureRecognizer.allowedTouchTypes = blocked
            ? [UITouch.TouchType.direct.rawValue as NSNumber]
            : defaultPanTouchTypes
    }

    init(pageWidth: CGFloat) {
        self.pageWidth = pageWidth
        super.init(frame: .zero)
        // UNA sola scroll view fa pan e zoom insieme, come ogni visore
        // PDF/foto. Prima erano due annidate (esterna=zoom, interna=pan):
        // a zoom alto si muovevano entrambe e la navigazione risultava
        // "macchinosa", perché due sistemi di scorrimento indipendenti
        // rispondevano allo stesso dito.
        minimumZoomScale = 0.25
        maximumZoomScale = 4
        bouncesZoom = true
        backgroundColor = .clear
        delegate = self
        // Toccare il bordo alto dello schermo NON deve riportare a
        // inizio nota: su un canvas di scrittura il gesto di sistema
        // scatta per sbaglio (si tocca vicino alla barra strumenti) e
        // butta via la posizione di lettura.
        scrollsToTop = false
        addSubview(contentHost)

        // Il salvataggio è differito (vedi scheduleSave): l'app che va in
        // background è l'ultimo momento in cui si può scrivere su disco
        // con certezza, quindi lì si travasa subito.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(flushOnBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(flushOnBackground),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        // La cattura del tratto sta sotto l'overlay di testo/media: un
        // tocco su una casella di testo va alla casella, come oggi.
        liveInkOverlay.container = self
        contentHost.addSubview(liveInkOverlay)

        overlayLayer.backgroundColor = .clear
        overlayLayer.isUserInteractionEnabled = true
        contentHost.addSubview(overlayLayer)

        interactionOverlay.backgroundColor = .clear
        interactionOverlay.isUserInteractionEnabled = false
        contentHost.addSubview(interactionOverlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Zoom "aiutato": il foglio riempie la larghezza dello schermo,
        // ricalcolato quando la larghezza cambia davvero (es. pannello
        // laterale aperto/chiuso), finché l'utente non zooma a mano.
        if !userDidZoom, bounds.width > 0, pageWidth > 0, bounds.width != lastFitWidth {
            lastFitWidth = bounds.width
            let fit = bounds.width / pageWidth
            minimumZoomScale = min(0.25, fit)
            zoomScale = min(max(fit, minimumZoomScale), maximumZoomScale)
        }

        centerContent()

        // Riparti dall'ultima pagina vista: applicabile solo quando le
        // pagine hanno un layout reale (contentSize pronto).
        if let target = pendingInitialPage, bounds.height > 0,
           contentSize.height > 0, pageViews.indices.contains(target) {
            pendingInitialPage = nil
            scrollToPage(target, animated: false)
        }
    }

    // Applica la dimensione logica del contenuto rispettando lo zoom in
    // corso: si imposta `bounds` (che la trasformazione non tocca) e si
    // riporta l'origine a (0,0) col centro, invece di scrivere `frame`.
    private func applyContentLayoutSize() {
        let scale = zoomScale
        contentHost.bounds = CGRect(origin: .zero, size: contentLayoutSize)
        contentHost.center = CGPoint(
            x: contentLayoutSize.width * scale / 2,
            y: contentLayoutSize.height * scale / 2
        )
        overlayLayer.frame = contentHost.bounds
        interactionOverlay.frame = contentHost.bounds
        liveInkOverlay.frame = contentHost.bounds
        contentSize = CGSize(
            width: contentLayoutSize.width * scale,
            height: contentLayoutSize.height * scale
        )
        centerContent()
    }

    // Centratura canonica: quando il contenuto è più piccolo del viewport
    // lo si centra con gli inset, non spostando il contenuto.
    private func centerContent() {
        let scaledWidth = contentHost.frame.width
        let scaledHeight = contentHost.frame.height
        let insetX = max(0, (bounds.width - scaledWidth) / 2)
        let insetY = max(0, (bounds.height - scaledHeight) / 2)
        let newInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        if contentInset != newInset {
            contentInset = newInset
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentHost }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateResidency()
    }

    // Quali pagine restano materializzate: quelle che toccano lo schermo
    // più una schermata sopra e una sotto (per non vedere il bianco
    // durante lo scorrimento normale). Il confronto con l'intervallo
    // precedente rende il controllo gratuito quando non cambia niente.
    private var residentRange: Range<Int> = 0..<0
    func updateResidency() {
        guard !pageViews.isEmpty else { return }
        let visible = visibleContentRect
        // DUE schermate per lato: le pagine si materializzano ben prima
        // di entrare nell'occhio, e il costo del disegno sincrono resta
        // lontano dal punto che si sta guardando.
        let window = visible.insetBy(dx: 0, dy: -visible.height * 2)
        var lower = Int.max
        var upper = Int.min
        for (index, page) in pageViews.enumerated() where page.frame.intersects(window) {
            lower = min(lower, index)
            upper = max(upper, index)
        }
        guard lower <= upper else { return }
        let range = lower..<(upper + 1)
        guard range != residentRange else { return }
        residentRange = range
        for (index, page) in pageViews.enumerated() {
            page.setResident(range.contains(index))
        }
    }

    // ZOOM MAGNETICO — due posizioni notevoli, come sui visori di
    // documenti: la pagina che riempie la larghezza, e la pagina intera
    // in altezza. Sono i due punti in cui uno vuole davvero fermarsi, e
    // centrarli a mano con due dita è un esercizio di pazienza.
    //
    // L'aggancio scatta SOLO se il gesto è finito già vicino (7%): fuori
    // da lì lo zoom resta completamente libero, che è la ragione per cui
    // una calamita del genere non dà fastidio.
    private static let snapTolerance: CGFloat = 0.13

    // La pagina che si sta guardando: l'ancora verticale è la sua, non
    // quella della prima pagina del documento (le pagine PDF importate
    // hanno altezze diverse fra loro).
    private var zoomAnchors: [CGFloat] {
        guard pageWidth > 0 else { return [] }
        // La finestra è quella VISIBILE, non `bounds` meno gli inset di
        // contenuto: `centerContent` mette inset verticali proprio quando
        // il contenuto ci sta tutto in altezza, cioè vicino all'ancora
        // verticale. Sottraendoli, l'ancora si rimpiccioliva man mano che
        // ci si avvicinava — un bersaglio che scappa, ed è il motivo per
        // cui in verticale non agganciava.
        let viewport = safeAreaLayoutGuide.layoutFrame.size
        let visibleWidth = viewport.width
        let visibleHeight = viewport.height
        var anchors: [CGFloat] = []
        if visibleWidth > 0 { anchors.append(visibleWidth / pageWidth) }
        let index = currentPageIndex()
        if pageViews.indices.contains(index) {
            let height = pageViews[index].frame.height
            if height > 0, visibleHeight > 0 { anchors.append(visibleHeight / height) }
        }
        return anchors.filter { $0 >= minimumZoomScale && $0 <= maximumZoomScale }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        userDidZoom = true

        // Si sceglie l'ancora più vicina IN PROPORZIONE, non in valore
        // assoluto: a zoom 3 uno scarto di 0,1 è impercettibile, a zoom
        // 0,4 è un salto.
        let target = zoomAnchors
            .filter { abs(scale - $0) / $0 < Self.snapTolerance }
            .min { abs(scale - $0) < abs(scale - $1) }

        if let target, abs(target - scale) > 0.001 {
            // `setZoomScale` conserva il centro di ciò che si sta
            // guardando: l'aggancio non fa saltare la vista al centro
            // della pagina, resta dove è finito il gesto.
            setZoomScale(target, animated: true)
        }

        // Ridisegna sfondi e pattern alla risoluzione dello zoom raggiunto:
        // è ciò che toglie la sfocatura quando si ingrandisce. Si usa la
        // scala di DESTINAZIONE, così non si rasterizza due volte.
        let finalScale = target ?? scale
        for page in pageViews {
            page.applyRenderScale(finalScale)
        }
    }

    // Ricostruisce lo stack secondo le pagine correnti: aggiunge/rimuove
    // NotePageView per arrivare al conteggio giusto, riposiziona tutto in
    // verticale con uno spazio tra una pagina e l'altra, applica pattern e
    // scala del pattern a ogni pagina (la mancata propagazione era uno dei
    // bug del primo tentativo).
    func sync(pages: [(id: AnyHashable, drawingData: Data?, pdfPageData: Data?)], defaultHeight: CGFloat, template: NoteTemplate, patternScale: CGFloat) -> [NotePageView] {
        while pageViews.count < pages.count {
            let page = NotePageView(pageWidth: pageWidth, pageHeight: defaultHeight)
            pageViews.append(page)
            contentHost.insertSubview(page, belowSubview: overlayLayer)
        }
        while pageViews.count > pages.count {
            let removed = pageViews.removeLast()
            // Prima di buttare la vista, i suoi tratti non ancora scritti
            // vanno su disco (se la loro pagina esiste ancora).
            flushPendingSave(of: removed)
            if lastActivePageView === removed { lastActivePageView = nil }
            removed.removeFromSuperview()
        }

        var y: CGFloat = 0
        for (index, pageData) in pages.enumerated() {
            let view = pageViews[index]
            // La vista sta cambiando pagina (le pagine si sono spostate:
            // undo di un import, riordino): l'inchiostro non salvato
            // appartiene alla pagina di PRIMA e va scritto adesso, con la
            // SUA identità — poi la vista riparte pulita per la nuova.
            if view.pageID != pageData.id {
                flushPendingSave(of: view)
                view.pageID = pageData.id
                view.appliedDrawingData = nil
                view.setStrokes([])
            }
            view.backgroundView.template = template
            view.backgroundView.patternScale = patternScale
            view.setPDFPage(pageData.pdfPageData)
            let height = view.naturalHeight(pageWidth: pageWidth, fallback: defaultHeight)
            view.frame = CGRect(x: 0, y: y, width: pageWidth, height: height)
            if let drawingData = pageData.drawingData,
               drawingData != view.appliedDrawingData {
                view.loadDrawingData(drawingData)
                view.appliedDrawingData = drawingData
            }
            y += height + pageGap
        }

        // ATTENZIONE: contentHost è la vista che lo scroll view trasforma
        // per lo zoom. Riassegnarle il frame NON scalato (come si faceva
        // qui a ogni sync, cioè a ogni tratto) cancella la trasformazione:
        // era il motivo per cui lo zoom "tornava indietro" da solo mentre
        // si scriveva. Si tocca la geometria solo quando la dimensione
        // logica del contenuto cambia davvero, e in modo compatibile con
        // la trasformazione (bounds + center, mai frame).
        let unscaled = CGSize(width: pageWidth, height: max(y - pageGap, defaultHeight))
        let geometryChanged = contentLayoutSize != unscaled
        if geometryChanged {
            contentLayoutSize = unscaled
            applyContentLayoutSize()
        }
        // Le pagine nuove partono già alla risoluzione dello zoom corrente
        // (quelle fuori finestra la memorizzano e basta).
        for page in pageViews {
            page.applyRenderScale(zoomScale)
        }
        // Il reset serve SOLO quando le pagine si sono mosse: azzerarlo
        // a ogni sync annullava la guardia di `updateResidency` e
        // rifaceva il giro su tutte le pagine a ogni aggiornamento di
        // SwiftUI — cioè, prima del salvataggio differito, a ogni tratto.
        if geometryChanged { residentRange = 0..<0 }
        updateResidency()
        // Le pagine vengono inserite subito sotto overlayLayer, quindi
        // finirebbero SOPRA la cattura del tratto: va rialzata.
        contentHost.insertSubview(liveInkOverlay, belowSubview: overlayLayer)
        return pageViews
    }

    // MARK: - Pagine (indice corrente, salto, miniature, undo/redo)

    func pageCount() -> Int { max(1, pageViews.count) }

    // La pagina su cui agiscono le operazioni: l'ultima su cui si è
    // scritto, altrimenti quella a schermo. Senza il "l'ultima su cui si
    // è scritto", scorrendo di poco dopo aver scritto si cancellerebbe
    // la pagina sbagliata.
    var activeInkPage: NotePageView? {
        if let lastActivePageView, pageViews.contains(where: { $0 === lastActivePageView }),
           lastActivePageView.frame.intersects(visibleContentRect) {
            return lastActivePageView
        }
        guard pageViews.indices.contains(currentPageIndex()) else { return pageViews.first }
        return pageViews[currentPageIndex()]
    }

    // MARK: - Commit e undo (nostri: niente PencilKit)

    // Storia di annullamento dell'inchiostro, tutta nostra. Assegnare i
    // tratti da codice non registra NIENTE da nessuna parte (lezione già
    // pagata col canvas): ogni commit passa da qui, che salva, fa
    // crescere le pagine se serve e registra l'annullamento con il
    // ripristino annidato.
    //
    // È lo STESSO manager del DrawingController (glielo assegna
    // PagedNoteCanvasView appena creato il contenitore): testo, immagini
    // e pagine si registrano lì, e una cronologia sola tiene l'ordine
    // vero delle modifiche invece di due pile che si ignorano.
    var inkUndoManager = UndoManager()
    // Impostati dal coordinatore: portano il dato a SwiftData e chiedono
    // pagine nuove quando si scrive vicino al fondo. La chiave è
    // l'IDENTITÀ della pagina (via NotePageView.pageID), non l'indice:
    // vedi il commento su pageID.
    var onPageDataChanged: ((AnyHashable, Data) -> Void)?
    var onNeedsMorePages: (() -> Void)?

    func commitStrokes(_ strokes: [PKStroke], previous explicitPrevious: [PKStroke]? = nil, on page: NotePageView, invalidating rect: CGRect? = nil, appended: PKStroke? = nil) {
        let previous = explicitPrevious ?? page.strokes
        applyStrokes(strokes, on: page, invalidating: rect, appended: appended)
        inkUndoManager.registerUndo(withTarget: self) { container in
            container.undoableApply(previous, on: page)
        }
    }

    private func undoableApply(_ strokes: [PKStroke], on page: NotePageView) {
        let redo = page.strokes
        applyStrokes(strokes, on: page)
        inkUndoManager.registerUndo(withTarget: self) { container in
            container.undoableApply(redo, on: page)
        }
    }

    private func applyStrokes(_ strokes: [PKStroke], on page: NotePageView, invalidating rect: CGRect? = nil, appended: PKStroke? = nil) {
        // Il commit di penna passa dal percorso append (vista recente
        // sincrona: distacco senza asincronia); tutto il resto — gomma,
        // lasso, undo — riscrive le tessere per intero.
        if let appended, let rect {
            page.appendCommittedStroke(appended, invalidating: rect)
        } else {
            page.setStrokes(strokes, invalidating: rect)
        }
        lastActivePageView = page
        // La serializzazione NON sta più qui. Serializzare l'intera
        // pagina a ogni tratto (più la scrittura SwiftData che ne segue,
        // più l'invalidazione di SwiftUI che ne segue ancora) era lo
        // scatto che si sentiva al distacco della penna, e cresceva con
        // l'inchiostro già sulla pagina. La verità è `page.strokes` in
        // memoria — undo compreso; il disco può arrivare un attimo dopo.
        scheduleSave(of: page)
        // Vicino al fondo dell'ultima pagina: se ne chiede una nuova,
        // così scrivere resta continuo, senza un muro.
        if pageViews.last === page, page.frame.height > 0,
           page.inkBounds.maxY > page.frame.height - 120 {
            onNeedsMorePages?()
        }
    }

    @objc private func flushOnBackground() { flushPendingSaves(force: true) }

    // MARK: - Salvataggio differito

    // Pagine con tratti non ancora serializzati. Riferimenti forti, ma
    // la finestra è di qualche centinaio di millisecondi e al travaso si
    // tengono solo quelle ancora vive.
    private var pendingSaves: [NotePageView] = []
    private var saveTask: Task<Void, Never>?

    // Quanto si aspetta prima di scrivere su disco. NON è una preferenza:
    // `PKDrawing.dataRepresentation()` riserializza l'INTERA pagina, e il
    // costo cresce senza fermarsi col numero di tratti — misurato sul
    // dispositivo: 12 ms a 90 tratti, 30 a 167, 44 a 299, **60 a 750**.
    // Con 400 ms quella fitta cadeva a ogni pausa di scrittura, cioè
    // proprio mentre si appoggia il tratto dopo. Tre secondi la spostano
    // nelle pause vere. La cura vera è non riserializzare tutto (storage
    // per tratto); questo è il palliativo che non tocca il disegno.
    private static let saveDelay = Duration.seconds(3)

    private func scheduleSave(of page: NotePageView) {
        if !pendingSaves.contains(where: { $0 === page }) { pendingSaves.append(page) }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flushPendingSaves()
        }
    }

    // Travaso immediato: si chiama quando si cambia pagina, quando l'app
    // va in background e quando l'editor sparisce. Fuori da questi
    // momenti ci pensa il timer.
    func flushPendingSaves(force: Bool = false) {
        // Penna giù: si rimanda. Una fitta da 60 ms in mezzo a un tratto
        // è esattamente ciò che si sta cercando di evitare. `force` la
        // impone quando non c'è alternativa (app che va in background,
        // vista che sparisce): lì perdere i dati sarebbe peggio.
        if !force, liveInkOverlay.isDrawing {
            saveTask?.cancel()
            saveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.flushPendingSaves()
            }
            return
        }
        saveTask?.cancel()
        saveTask = nil
        guard !pendingSaves.isEmpty else { return }
        let pages = pendingSaves
        pendingSaves.removeAll()
        for page in pages {
            guard let id = page.pageID else { continue }
            let data = PKDrawing(strokes: page.strokes).dataRepresentation()
            page.appliedDrawingData = data
            onPageDataChanged?(id, data)
        }
    }

    // Travasa SUBITO i tratti non salvati di una singola vista, con
    // l'identità della pagina che sta mostrando ora: lo chiama sync()
    // prima di riassegnare la vista a un'altra pagina o di rimuoverla.
    private func flushPendingSave(of page: NotePageView) {
        guard let index = pendingSaves.firstIndex(where: { $0 === page }) else { return }
        pendingSaves.remove(at: index)
        guard let id = page.pageID else { return }
        let data = PKDrawing(strokes: page.strokes).dataRepresentation()
        page.appliedDrawingData = data
        onPageDataChanged?(id, data)
    }

    func currentPageIndex() -> Int {
        let visible = visibleContentRect
        let visibleMidY = visible.midY
        for (index, view) in pageViews.enumerated() where view.frame.minY <= visibleMidY && visibleMidY <= view.frame.maxY {
            return index
        }
        guard !pageViews.isEmpty else { return 0 }
        return max(0, min(pageViews.count - 1, pageViews.firstIndex { $0.frame.maxY > visible.minY } ?? 0))
    }

    func scrollToPage(_ index: Int, animated: Bool) {
        guard pageViews.indices.contains(index) else { return }
        // contentOffset è in coordinate ZOOMATE: la posizione di pagina
        // (coordinate contenuto) va moltiplicata per lo zoom corrente.
        let targetY = max(0, pageViews[index].frame.minY - 16) * zoomScale
        let maxY = max(0, contentSize.height - bounds.height)
        setContentOffset(CGPoint(x: contentOffset.x, y: min(targetY, maxY)), animated: animated)
    }

    func pageThumbnail(index: Int) -> UIImage? {
        guard pageViews.indices.contains(index) else { return nil }
        let pageView = pageViews[index]
        let rect = pageView.frame
        guard rect.width > 0, rect.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        // Si disegna DAI DATI (pagina PDF + tratti), non fotografando i
        // layer: le pagine fuori dalla finestra di residenza hanno i layer
        // volutamente vuoti, e le loro miniature uscirebbero bianche.
        return renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: rect.size))

            if let pdfPage = pageView.pdfPage {
                let box = pdfPage.bounds(for: .mediaBox)
                if box.width > 0, box.height > 0 {
                    cg.saveGState()
                    cg.translateBy(x: 0, y: rect.height)
                    cg.scaleBy(x: 1, y: -1)
                    let scale = rect.width / box.width
                    cg.scaleBy(x: scale, y: scale)
                    cg.translateBy(x: -box.minX, y: -box.minY)
                    pdfPage.draw(with: .mediaBox, to: cg)
                    cg.restoreGState()
                }
            }

            // Caselle di testo e media, dall'overlay condiviso (che non
            // dipende dalla residenza delle pagine).
            cg.saveGState()
            cg.translateBy(x: -rect.origin.x, y: -rect.origin.y)
            overlayLayer.layer.render(in: cg)
            cg.restoreGState()

            if !pageView.strokes.isEmpty {
                cg.saveGState()
                InkRenderer.draw(pageView.strokes, in: cg, scale: 1)
                cg.restoreGState()
            }
        }
    }

    var visibleContentRect: CGRect {
        // Da coordinate zoomate a coordinate contenuto.
        CGRect(
            x: contentOffset.x / zoomScale,
            y: contentOffset.y / zoomScale,
            width: bounds.width / zoomScale,
            height: bounds.height / zoomScale
        )
    }

    // UndoManager della finestra: registra i tratti di TUTTI i canvas
    // pagina (e le modifiche testo), quindi "indietro" annulla l'ultima
    // azione ovunque sia avvenuta — lo stesso modello di Notability.
    func undo() { inkUndoManager.undo() }
    func redo() { inkUndoManager.redo() }

    // Un PDF vero con una pagina per ogni NotePage, non un unico foglio lungo.
    // Export PDF vero: le pagine PDF importate vengono ridisegnate
    // VETTORIALMENTE (testo selezionabile, niente sgranatura), non
    // rasterizzate insieme al resto; sopra ci vanno testo/media e infine
    // l'inchiostro. `includePattern` decide se stampare anche la nostra
    // filigrana (quadretti/righe): di default no, così l'export è pulito.
    func renderAllPagesPDF(includePattern: Bool) -> Data? {
        guard let first = pageViews.first else { return nil }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.frame.size))
        return renderer.pdfData { ctx in
            for view in pageViews {
                let pageSize = view.frame.size
                ctx.beginPage(withBounds: CGRect(origin: .zero, size: pageSize), pageInfo: [:])
                let cg = ctx.cgContext

                // Sfondo bianco: senza, le aree non coperte restano
                // trasparenti e alcuni lettori le mostrano nere.
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(CGRect(origin: .zero, size: pageSize))

                if let pdfPage = view.pdfPage {
                    let box = pdfPage.bounds(for: .mediaBox)
                    if box.width > 0, box.height > 0 {
                        cg.saveGState()
                        // Il PDF ha origine in basso a sinistra, il contesto
                        // UIKit in alto a sinistra: va ribaltato.
                        cg.translateBy(x: 0, y: pageSize.height)
                        cg.scaleBy(x: 1, y: -1)
                        let scale = pageSize.width / box.width
                        cg.scaleBy(x: scale, y: scale)
                        cg.translateBy(x: -box.minX, y: -box.minY)
                        pdfPage.draw(with: .mediaBox, to: cg)
                        cg.restoreGState()
                    }
                } else if includePattern {
                    cg.saveGState()
                    view.backgroundView.layer.render(in: cg)
                    cg.restoreGState()
                }

                // Caselle di testo, immagini e PDF trascinabili: vivono
                // nell'overlay condiviso, quindi si trasla e il contesto
                // ritaglia da sé ciò che esce dalla pagina.
                cg.saveGState()
                cg.translateBy(x: -view.frame.minX, y: -view.frame.minY)
                overlayLayer.layer.render(in: cg)
                cg.restoreGState()

                // Inchiostro in VETTORIALE vero: il PDF esce con la
                // geometria dei tratti, non con una loro foto.
                if !view.strokes.isEmpty {
                    cg.saveGState()
                    InkRenderer.draw(view.strokes, in: cg, scale: 4)
                    cg.restoreGState()
                }
            }
        }
    }
}

// Bridge SwiftUI per una nota a pagine reali in scorrimento continuo
// (tutto tranne la lavagna infinita, che resta su DrawingCanvasView).
struct PagedNoteCanvasView: UIViewRepresentable {
    var pages: [NotePage]
    // Pagina da cui ripartire all'apertura (segnalibro automatico).
    var initialPage: Int = 0
    @Binding var textBoxes: [NoteTextBox]
    var media: [NoteMedia]
    var tool: PenTool
    var color: Color
    var inkWidth: CGFloat
    // Penna a pressione o a spessore costante: scelta dell'utente dalla
    // barra, vale sia per il tratto definitivo sia per l'anteprima.
    var pressureSensitiveInk: Bool = true
    var eraserType: PKEraserTool.EraserType
    var eraserWidth: CGFloat
    var template: NoteTemplate
    var patternScale: CGFloat
    var pageWidth: CGFloat
    var defaultPageHeight: CGFloat
    var magicAction: MagicAction?
    var controller: DrawingController
    var onDeleteMedia: (NoteMedia) -> Void
    var onEditMedia: (NoteMedia) -> Void
    var onMagicCapture: (MagicAction, CGRect, UIImage) -> Void
    var onEraseStrokeCompleted: () -> Void
    var onLassoFinished: () -> Void
    var onPencilDoubleTap: () -> Void
    var onPageDrawingChanged: (NotePage, Data?) -> Void
    var onNeedMorePages: () -> Void

    func makeUIView(context: Context) -> PagedCanvasContainer {
        let container = PagedCanvasContainer(pageWidth: pageWidth)
        // Prima di qualunque commit: da qui in poi i tratti si registrano
        // nella cronologia del documento, insieme a testo e immagini.
        container.inkUndoManager = controller.history
        if initialPage > 0 {
            container.pendingInitialPage = initialPage
        }
        context.coordinator.parent = self
        context.coordinator.applyPages(to: container)
        context.coordinator.applyToolState(to: container)

        let circlePan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleCirclePan(_:)))
        circlePan.delegate = context.coordinator
        container.interactionOverlay.addGestureRecognizer(circlePan)
        context.coordinator.circlePanRecognizer = circlePan

        let pointerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePointerPan(_:)))
        pointerPan.delegate = context.coordinator
        pointerPan.minimumNumberOfTouches = 1
        pointerPan.maximumNumberOfTouches = 1
        container.interactionOverlay.addGestureRecognizer(pointerPan)
        context.coordinator.pointerPanRecognizer = pointerPan

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        container.overlayLayer.addGestureRecognizer(tap)
        context.coordinator.tapRecognizer = tap

        let magicActive = magicAction != nil
        container.interactionOverlay.isUserInteractionEnabled = magicActive || tool == .pointer
        circlePan.isEnabled = magicActive
        pointerPan.isEnabled = (tool == .pointer) && !magicActive
        // Il pan interno riconosce i gesti INSIEME al cerchio della penna
        // magica (delegate simultaneo): senza congelarlo, cerchiare
        // faceva anche scorrere il foglio.
        container.isScrollEnabled = !magicActive
        container.overlayLayer.passthroughEmptyAreas = !(tool == .text)
        tap.isEnabled = (tool == .text) && !magicActive

        controller.pagedContainer = container
        context.coordinator.syncTextBoxes(in: container.overlayLayer)
        context.coordinator.syncMedia(in: container.overlayLayer)
        return container
    }

    func updateUIView(_ container: PagedCanvasContainer, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyPages(to: container)
        context.coordinator.applyToolState(to: container)

        let magicActive = magicAction != nil
        container.interactionOverlay.isUserInteractionEnabled = magicActive || tool == .pointer
        if container.interactionOverlay.isUserInteractionEnabled {
            container.contentHost.bringSubviewToFront(container.interactionOverlay)
        }
        context.coordinator.circlePanRecognizer?.isEnabled = magicActive
        context.coordinator.pointerPanRecognizer?.isEnabled = (tool == .pointer) && !magicActive
        // Vedi makeUIView: congelato mentre la penna magica è armata,
        // altrimenti cerchiare fa anche scorrere il foglio.
        container.isScrollEnabled = !magicActive
        container.overlayLayer.passthroughEmptyAreas = !(tool == .text)
        context.coordinator.tapRecognizer?.isEnabled = (tool == .text) && !magicActive

        context.coordinator.syncTextBoxes(in: container.overlayLayer)
        context.coordinator.syncMedia(in: container.overlayLayer)
    }

    // L'editor sparisce (si torna all'elenco, si apre un'altra nota):
    // qui si scrive su disco ciò che il salvataggio differito aveva
    // ancora in mano.
    static func dismantleUIView(_ container: PagedCanvasContainer, coordinator: Coordinator) {
        container.flushPendingSaves(force: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UITextViewDelegate, UIPencilInteractionDelegate {
        var parent: PagedNoteCanvasView
        weak var tapRecognizer: UITapGestureRecognizer?
        weak var circlePanRecognizer: UIPanGestureRecognizer?
        weak var pointerPanRecognizer: UIPanGestureRecognizer?
        weak var container: PagedCanvasContainer?
        private var pencilInteractionInstalled = false

        private var circleStartPoint: CGPoint?
        private var circlePreviewLayer: CAShapeLayer?
        private var textViewsByID: [UUID: BoxTextView] = [:]
        private var lastDragLocation: [UUID: CGPoint] = [:]
        private var mediaViewsByID: [PersistentIdentifier: MediaBoxView] = [:]
        private var mediaDragLocation: [PersistentIdentifier: CGPoint] = [:]

        init(_ parent: PagedNoteCanvasView) { self.parent = parent }

        // MARK: - Sincronizzazione pagine

        func applyPages(to container: PagedCanvasContainer) {
            self.container = container
            // Iniziare un tratto deseleziona i media.
            container.liveInkOverlay.onStrokeBegan = { [weak self] in self?.select(nil) }
            container.liveInkOverlay.onLassoFinished = { [weak self] in self?.parent.onLassoFinished() }
            // Il commit del contenitore porta i dati a SwiftData e chiede
            // pagine nuove quando si scrive vicino al fondo. La chiave è
            // il PersistentIdentifier della pagina: per INDICE, un
            // riordino tra il tratto e il salvataggio differito scriveva
            // sulla pagina sbagliata.
            container.onPageDataChanged = { [weak self] id, data in
                guard let self,
                      let pageID = id.base as? PersistentIdentifier,
                      let page = self.parent.pages.first(where: { $0.persistentModelID == pageID }),
                      !page.isDeleted else { return }
                self.parent.onPageDrawingChanged(page, data)
            }
            container.liveInkOverlay.onEraseFinished = { [weak self] in
                guard let self, self.parent.tool == .eraser else { return }
                self.parent.onEraseStrokeCompleted()
            }
            container.onNeedsMorePages = { [weak self] in self?.parent.onNeedMorePages() }
            if !pencilInteractionInstalled {
                let interaction = UIPencilInteraction()
                interaction.delegate = self
                container.addInteraction(interaction)
                pencilInteractionInstalled = true
            }
            let pageData = parent.pages.map { (id: AnyHashable($0.persistentModelID), drawingData: $0.drawingData, pdfPageData: $0.pdfPageData) }
            _ = container.sync(pages: pageData, defaultHeight: parent.defaultPageHeight, template: parent.template, patternScale: parent.patternScale)
        }

        func applyToolState(to container: PagedCanvasContainer) {
            let magicActive = parent.magicAction != nil

            // UN SOLO MOTORE, il nostro: penna, evidenziatore, gomma e
            // lasso. PencilKit non partecipa più all'interazione.
            let overlayActive = (parent.tool.isInk || parent.tool == .eraser || parent.tool == .lasso) && !magicActive
            container.liveInkOverlay.isUserInteractionEnabled = overlayActive
            if overlayActive {
                switch parent.tool {
                case .eraser:
                    // SOLO gomma a oggetti. La parziale è stata riprovata
                    // (2026-08-14, pagina attiva sincrona) e non funziona
                    // ancora: rispenta per decisione dell'utente, il
                    // codice di divisione resta per quando si riprenderà.
                    container.liveInkOverlay.mode = .erase(
                        radius: parent.eraserWidth / 2,
                        partial: false
                    )
                case .lasso:
                    container.liveInkOverlay.mode = .lasso
                default:
                    container.liveInkOverlay.mode = .draw
                    let base = UIColor(parent.color)
                    container.liveInkOverlay.inkColor = parent.tool == .marker
                        ? base.withAlphaComponent(PenTool.markerLivePreviewOpacity)
                        : base
                    container.liveInkOverlay.baseWidth = parent.inkWidth
                    // L'evidenziatore non varia con la forza; la penna sì,
                    // ma solo se l'utente ha lasciato accesa la pressione.
                    container.liveInkOverlay.pressureSensitive = parent.tool != .marker && parent.pressureSensitiveInk
                    container.liveInkOverlay.inkType = parent.tool.inkType(pressure: parent.pressureSensitiveInk) ?? .pen
                }
            }
            if parent.tool != .lasso {
                container.liveInkOverlay.clearLassoSelection()
            }
            container.setPencilPanBlocked(overlayActive)

            for pageView in container.pageViews {
                // Fuori dalla scrittura la vista del tratto vivo libera il
                // suo backing store (una pagina intera alla scala dello
                // zoom): non deve restare allocato per niente.
                if !overlayActive || parent.tool != .pen && parent.tool != .marker {
                    pageView.liveStrokeView.clearContents()
                    pageView.liveStrokeView.isHidden = true
                }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: - Apple Pencil

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            parent.onPencilDoubleTap()
        }

        // MARK: - Testo (tocca per aggiungere una casella)

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let overlay = gesture.view as? PassthroughOverlayView else { return }
            let point = gesture.location(in: overlay)
            addTextBox(at: point, in: overlay)
        }

        // L'overlay corrente, per i ripristini della cronologia: undo e
        // redo arrivano quando il gesto è finito da un pezzo e nessuno
        // passa più l'overlay come parametro.
        private weak var overlayView: UIView?
        // Le caselle com'erano quando è iniziata una sessione di editing
        // del testo: la registrazione è per sessione, non per tasto.
        private var editingBoxesSnapshot: [NoteTextBox]?
        // Il frame del media all'inizio di un trascinamento: al rilascio
        // serve il "prima" per registrare lo spostamento.
        private var mediaDragStartFrame: [PersistentIdentifier: CGRect] = [:]

        // MARK: - Cronologia (caselle di testo)
        //
        // Le caselle sono VALORI ([NoteTextBox]): la cronologia lavora su
        // fotografie intere dell'array — semplice e senza riferimenti che
        // possono morire. Il ripristino DEVE riscrivere anche frame e
        // testo delle viste esistenti: syncTextBoxes aggiunge e rimuove
        // per ID, e da solo lascerebbe la vista dov'era (trappola nota).
        private func applyTextBoxes(_ boxes: [NoteTextBox]) {
            parent.textBoxes = boxes
            for box in boxes {
                guard let view = textViewsByID[box.id] else { continue }
                if view.text != box.text { view.text = box.text }
                view.frame = CGRect(x: box.x, y: box.y, width: box.width, height: max(box.height ?? 40, 40))
            }
            if let overlay = overlayView {
                syncTextBoxes(in: overlay)
            }
        }

        private func recordTextBoxes(_ name: String, before: [NoteTextBox]) {
            let after = parent.textBoxes
            guard after != before else { return }
            parent.controller.recordChange(name, from: before, to: after) { [weak self] boxes in
                self?.applyTextBoxes(boxes)
            }
        }

        func syncTextBoxes(in overlay: UIView) {
            overlayView = overlay
            let currentIDs = Set(parent.textBoxes.map(\.id))
            for (id, view) in textViewsByID where !currentIDs.contains(id) {
                view.removeFromSuperview()
                textViewsByID.removeValue(forKey: id)
            }
            for box in parent.textBoxes where textViewsByID[box.id] == nil {
                let textView = makeTextView(for: box)
                overlay.addSubview(textView)
                textViewsByID[box.id] = textView
            }
        }

        private func addTextBox(at point: CGPoint, in overlay: UIView) {
            let before = parent.textBoxes
            let box = NoteTextBox(x: Double(point.x), y: Double(point.y))
            parent.textBoxes.append(box)
            recordTextBoxes("Casella di testo", before: before)
            let textView = makeTextView(for: box)
            overlay.addSubview(textView)
            textViewsByID[box.id] = textView
            textView.becomeFirstResponder()
        }

        private func makeTextView(for box: NoteTextBox) -> BoxTextView {
            let textView = BoxTextView()
            textView.boxID = box.id
            textView.text = box.text
            textView.font = .preferredFont(forTextStyle: .body)
            textView.backgroundColor = .clear
            textView.isScrollEnabled = false
            textView.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            textView.delegate = self
            textView.frame = CGRect(x: box.x, y: box.y, width: box.width, height: 40)
            textView.sizeToFit()
            textView.frame.size.width = box.width

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleTextBoxLongPress(_:)))
            longPress.minimumPressDuration = 0.35
            textView.addGestureRecognizer(longPress)

            // La "x" e la maniglia erano collegate solo sulla lavagna: qui
            // sulle note il tocco non faceva nulla.
            let resizePan = UIPanGestureRecognizer(target: self, action: #selector(handleTextBoxResizePan(_:)))
            textView.resizeHandle.isUserInteractionEnabled = true
            textView.resizeHandle.addGestureRecognizer(resizePan)
            textView.deleteButton.addTarget(self, action: #selector(handleTextBoxDelete(_:)), for: .touchUpInside)

            return textView
        }

        @objc private func handleTextBoxResizePan(_ gesture: UIPanGestureRecognizer) {
            guard let textView = gesture.view?.superview as? BoxTextView else { return }
            let translation = gesture.translation(in: textView)
            switch gesture.state {
            case .changed:
                textView.frame.size.width = max(textView.frame.width + translation.x, 120)
                textView.frame.size.height = max(textView.frame.height + translation.y, 40)
                gesture.setTranslation(.zero, in: textView)
            case .ended, .cancelled:
                textView.isScrollEnabled = true
                guard let index = parent.textBoxes.firstIndex(where: { $0.id == textView.boxID }) else { return }
                let before = parent.textBoxes
                parent.textBoxes[index].width = Double(textView.frame.width)
                parent.textBoxes[index].height = Double(textView.frame.height)
                recordTextBoxes("Ridimensionamento casella", before: before)
            default:
                break
            }
        }

        @objc private func handleTextBoxDelete(_ sender: UIButton) {
            guard let textView = sender.superview as? BoxTextView else { return }
            let before = parent.textBoxes
            parent.textBoxes.removeAll { $0.id == textView.boxID }
            textView.removeFromSuperview()
            textViewsByID.removeValue(forKey: textView.boxID)
            recordTextBoxes("Eliminazione casella", before: before)
        }

        @objc private func handleTextBoxLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let textView = gesture.view as? BoxTextView, let overlay = textView.superview else { return }
            let location = gesture.location(in: overlay)
            switch gesture.state {
            case .began:
                textView.alpha = 0.7
                lastDragLocation[textView.boxID] = location
            case .changed:
                guard let last = lastDragLocation[textView.boxID] else { return }
                textView.center.x += location.x - last.x
                textView.center.y += location.y - last.y
                lastDragLocation[textView.boxID] = location
            case .ended, .cancelled:
                textView.alpha = 1
                lastDragLocation.removeValue(forKey: textView.boxID)
                updateBoxPosition(id: textView.boxID, x: textView.frame.origin.x, y: textView.frame.origin.y)
            default:
                break
            }
        }

        private func updateBoxPosition(id: UUID, x: CGFloat, y: CGFloat) {
            guard let index = parent.textBoxes.firstIndex(where: { $0.id == id }) else { return }
            let before = parent.textBoxes
            parent.textBoxes[index].x = Double(x)
            parent.textBoxes[index].y = Double(y)
            recordTextBoxes("Spostamento casella", before: before)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            // La cronologia registra la SESSIONE di scrittura, non ogni
            // tasto: la fotografia si scatta qui e si confronta alla fine.
            editingBoxesSnapshot = parent.textBoxes
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let textView = textView as? BoxTextView else { return }
            textView.sizeToFit()
            textView.frame.size.width = max(120, textView.frame.width)
            guard let index = parent.textBoxes.firstIndex(where: { $0.id == textView.boxID }) else { return }
            parent.textBoxes[index].text = textView.text
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard let textView = textView as? BoxTextView else { return }
            if textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parent.textBoxes.removeAll { $0.id == textView.boxID }
                textView.removeFromSuperview()
                textViewsByID.removeValue(forKey: textView.boxID)
            }
            // Chiusura della sessione di scrittura: un solo record, che
            // copre anche l'auto-eliminazione della casella svuotata.
            if let snapshot = editingBoxesSnapshot {
                editingBoxesSnapshot = nil
                recordTextBoxes("Modifica testo", before: snapshot)
            }
        }

        // MARK: - Penna magica (cerchia per attivare un'azione)

        @objc func handleCirclePan(_ gesture: UIPanGestureRecognizer) {
            guard let overlay = gesture.view, let action = parent.magicAction else { return }
            let point = gesture.location(in: overlay)

            switch gesture.state {
            case .began:
                circleStartPoint = point
                let layer = CAShapeLayer()
                layer.strokeColor = UIColor(action.color).cgColor
                layer.fillColor = UIColor(action.color).withAlphaComponent(0.08).cgColor
                layer.lineWidth = 2
                layer.lineDashPattern = [6, 4]
                overlay.layer.addSublayer(layer)
                circlePreviewLayer = layer

            case .changed:
                guard let start = circleStartPoint else { return }
                let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
                circlePreviewLayer?.path = UIBezierPath(roundedRect: rect, cornerRadius: DesignRadius.lg).cgPath

            case .ended, .cancelled:
                circlePreviewLayer?.removeFromSuperlayer()
                circlePreviewLayer = nil
                defer { circleStartPoint = nil }
                guard let start = circleStartPoint else { return }
                var rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
                guard rect.width > 24, rect.height > 24 else { return }
                rect = rect.insetBy(dx: -8, dy: -8)
                captureMagicRegion(rect, action: action)

            default:
                break
            }
        }

        // Il cerchio ricade quasi sempre in un'unica pagina: prendo quella
        // che lo contiene di più. Come per la lavagna: layer.render prende
        // sfondo/PDF/testo, PKDrawing.image l'inchiostro (che layer.render
        // non compone — era il bug del "funziona solo su sfondo PDF").
        private func captureMagicRegion(_ rect: CGRect, action: MagicAction) {
            guard let container, let pageView = container.pageViews.max(by: { a, b in
                let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
                return ia.width * ia.height < ib.width * ib.height
            }) else { return }

            let localRect = CGRect(
                x: rect.minX - pageView.frame.minX,
                y: rect.minY - pageView.frame.minY,
                width: rect.width,
                height: rect.height
            )
            let scale = container.window?.screen.scale ?? container.traitCollection.displayScale
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
            let image = renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: rect.size))
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: -localRect.minX, y: -localRect.minY)
                pageView.layer.render(in: ctx.cgContext)
                ctx.cgContext.restoreGState()
            }
            parent.onMagicCapture(action, rect, image)
        }

        // MARK: - Dimensione gomma (solo indicatore visivo)

        // MARK: - Strumento puntatore (scorri anche con la Pencil)

        @objc func handlePointerPan(_ gesture: UIPanGestureRecognizer) {
            guard let overlay = gesture.view, let scrollView = container else { return }
            switch gesture.state {
            case .changed:
                let translation = gesture.translation(in: overlay)
                var offset = scrollView.contentOffset
                offset.x -= translation.x
                offset.y -= translation.y
                let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
                let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                offset.x = min(max(offset.x, -scrollView.contentInset.left), maxX)
                offset.y = min(max(offset.y, 0), maxY)
                scrollView.contentOffset = offset
                gesture.setTranslation(.zero, in: overlay)
            default:
                break
            }
        }

        // MARK: - Immagini e PDF

        // MARK: - Cronologia (media)
        //
        // I media sono oggetti SwiftData, non valori: il ripristino passa
        // per l'ID persistente. Se l'oggetto non esiste più (eliminato e
        // poi ricreato da un altro undo, quindi con identità nuova), il
        // ripristino è un no-op: meglio un passo di cronologia a vuoto
        // che scrivere su un oggetto morto.
        private func applyMediaFrame(id: PersistentIdentifier, frame: CGRect) {
            guard let item = parent.media.first(where: { $0.persistentModelID == id }) else { return }
            item.x = frame.origin.x
            item.y = frame.origin.y
            item.width = frame.width
            item.height = frame.height
            mediaViewsByID[id]?.frame = frame
        }

        private func recordMediaFrame(_ name: String, id: PersistentIdentifier, from old: CGRect, to new: CGRect) {
            guard old != new else { return }
            parent.controller.record(name, undo: { [weak self] in
                self?.applyMediaFrame(id: id, frame: old)
            }, redo: { [weak self] in
                self?.applyMediaFrame(id: id, frame: new)
            })
        }

        func syncMedia(in overlay: UIView) {
            let currentIDs = Set(parent.media.map(\.persistentModelID))
            for (id, view) in mediaViewsByID where !currentIDs.contains(id) {
                view.removeFromSuperview()
                mediaViewsByID.removeValue(forKey: id)
            }
            // Una formula ricomposta ha gli stessi id ma contenuto nuovo:
            // senza questo confronto la vista resterebbe quella vecchia e
            // la modifica sembrerebbe non aver fatto niente.
            for item in parent.media {
                guard let box = mediaViewsByID[item.persistentModelID],
                      box.contentVersion != contentVersion(of: item) else { continue }
                box.removeFromSuperview()
                mediaViewsByID.removeValue(forKey: item.persistentModelID)
            }
            for item in parent.media where mediaViewsByID[item.persistentModelID] == nil {
                let box = makeMediaView(for: item)
                overlay.addSubview(box)
                mediaViewsByID[item.persistentModelID] = box
            }
        }

        private func contentVersion(of item: NoteMedia) -> Int {
            item.data.count &* 31 &+ (item.sourceText?.hashValue ?? 0)
        }

        private func makeMediaView(for item: NoteMedia) -> MediaBoxView {
            let box = MediaBoxView(frame: CGRect(x: item.x, y: item.y, width: item.width, height: item.height))
            box.mediaID = item.persistentModelID
            box.contentVersion = contentVersion(of: item)

            switch item.kind {
            case .image, .formula:
                if item.kind == .formula { box.makeTransparent() }
                let imageView = UIImageView(image: UIImage(data: item.data))
                imageView.contentMode = .scaleAspectFit
                imageView.frame = box.contentContainer.bounds
                imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                box.contentContainer.addSubview(imageView)
            case .pdf:
                let pdfView = PDFView(frame: box.contentContainer.bounds)
                pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                pdfView.autoScales = true
                pdfView.document = PDFDocument(data: item.data)
                box.contentContainer.addSubview(pdfView)
            }

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleMediaLongPress(_:)))
            longPress.minimumPressDuration = 0.35
            box.addGestureRecognizer(longPress)

            // Un tocco seleziona (e mostra i comandi), un altro deseleziona:
            // stesso patto della casella di testo, che a riposo resta pulita.
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleMediaTap(_:)))
            box.addGestureRecognizer(tap)

            let resizePan = UIPanGestureRecognizer(target: self, action: #selector(handleMediaResizePan(_:)))
            box.resizeHandle.isUserInteractionEnabled = true
            box.resizeHandle.addGestureRecognizer(resizePan)

            box.canEdit = item.sourceText != nil
            box.deleteButton.addTarget(self, action: #selector(handleMediaDelete(_:)), for: .touchUpInside)
            box.editButton.addTarget(self, action: #selector(handleMediaEdit(_:)), for: .touchUpInside)
            return box
        }

        @objc private func handleMediaTap(_ gesture: UITapGestureRecognizer) {
            guard let box = gesture.view as? MediaBoxView else { return }
            select(box.isSelected ? nil : box)
        }

        // Una sola selezione per volta, come per il fuoco di una casella
        // di testo: due riquadri blu insieme non vorrebbero dire niente.
        func select(_ box: MediaBoxView?) {
            for view in mediaViewsByID.values where view !== box {
                if view.isSelected { view.setSelected(false) }
            }
            box?.setSelected(true)
            // Il selezionato passa davanti: altrimenti la maniglia finisce
            // sotto a un media sovrapposto e non si riesce ad afferrarla.
            if let box { box.superview?.bringSubviewToFront(box) }
        }

        @objc private func handleMediaResizePan(_ gesture: UIPanGestureRecognizer) {
            guard let box = gesture.view?.superview as? MediaBoxView, let mediaID = box.mediaID else { return }
            let translation = gesture.translation(in: box)
            switch gesture.state {
            case .changed:
                box.frame.size.width = max(box.frame.width + translation.x, 60)
                box.frame.size.height = max(box.frame.height + translation.y, 30)
                gesture.setTranslation(.zero, in: box)
            case .ended, .cancelled:
                guard let item = parent.media.first(where: { $0.persistentModelID == mediaID }) else { return }
                let old = CGRect(x: item.x, y: item.y, width: item.width, height: item.height)
                item.width = Double(box.frame.width)
                item.height = Double(box.frame.height)
                recordMediaFrame("Ridimensionamento", id: mediaID,
                                 from: old,
                                 to: CGRect(x: item.x, y: item.y, width: item.width, height: item.height))
            default:
                break
            }
        }

        @objc private func handleMediaEdit(_ sender: UIButton) {
            guard let box = sender.superview as? MediaBoxView,
                  let mediaID = box.mediaID,
                  let item = parent.media.first(where: { $0.persistentModelID == mediaID }) else { return }
            parent.onEditMedia(item)
        }

        @objc private func handleMediaLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let box = gesture.view as? MediaBoxView, let mediaID = box.mediaID, let overlay = box.superview else { return }
            let location = gesture.location(in: overlay)
            switch gesture.state {
            case .began:
                box.alpha = 0.85
                mediaDragLocation[mediaID] = location
                mediaDragStartFrame[mediaID] = box.frame
            case .changed:
                guard let last = mediaDragLocation[mediaID] else { return }
                box.center.x += location.x - last.x
                box.center.y += location.y - last.y
                mediaDragLocation[mediaID] = location
            case .ended, .cancelled:
                box.alpha = 1
                mediaDragLocation.removeValue(forKey: mediaID)
                let startFrame = mediaDragStartFrame.removeValue(forKey: mediaID)
                if let item = parent.media.first(where: { $0.persistentModelID == mediaID }) {
                    item.x = Double(box.frame.origin.x)
                    item.y = Double(box.frame.origin.y)
                    if let startFrame {
                        recordMediaFrame("Spostamento", id: mediaID, from: startFrame, to: box.frame)
                    }
                }
            default:
                break
            }
        }

        @objc private func handleMediaDelete(_ sender: UIButton) {
            guard let box = sender.superview as? MediaBoxView,
                  let mediaID = box.mediaID,
                  let item = parent.media.first(where: { $0.persistentModelID == mediaID }) else { return }
            parent.onDeleteMedia(item)
            box.removeFromSuperview()
            mediaViewsByID.removeValue(forKey: mediaID)
        }

    }
}
