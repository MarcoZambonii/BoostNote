import SwiftUI
import SwiftData
import PencilKit
import PDFKit
import Combine

// Espone undo/redo/export/pagine alla toolbar, che vive fuori dalle
// UIViewRepresentable. Copre entrambe le modalità: lavagna infinita
// (InfiniteCanvasView, tela libera) e nota a pagine reali
// (PagedCanvasContainer, in PagedNoteCanvasView.swift) — solo una delle
// due è mai attaccata per una data nota.
final class DrawingController: ObservableObject {
    fileprivate weak var canvasView: InfiniteCanvasView?
    weak var pagedContainer: PagedCanvasContainer?

    // Cronologia UNICA del documento (note a pagine): inchiostro,
    // caselle di testo, immagini e formule, pagine importate finiscono
    // tutte qui, in ordine di tempo. Prima l'annullamento conosceva solo
    // i tratti: cancellare un'immagine o spostare una casella era
    // definitivo, e la freccia indietro tornava all'ultimo tratto come se
    // in mezzo non fosse successo niente.
    //
    // Il contenitore delle pagine usa QUESTO manager per i propri commit
    // (glielo passa PagedNoteCanvasView), così l'ordine è uno solo.
    // La lavagna infinita resta su PencilKit e sul suo undo manager.
    let history = UndoManager()

    // Specchio per la barra: le frecce si spengono quando non c'è niente
    // da annullare, invece di offrire un gesto che non farebbe nulla.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var historyObservers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSUndoManagerCheckpoint,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup
        ]
        historyObservers = names.map { name in
            // Consegna asincrona sulla coda principale: le registrazioni
            // avvengono in mezzo al tocco, e scrivere una @Published lì
            // vorrebbe dire cambiare stato durante un aggiornamento di
            // vista.
            center.addObserver(forName: name, object: history, queue: .main) { [weak self] _ in
                guard let self else { return }
                if canUndo != history.canUndo { canUndo = history.canUndo }
                if canRedo != history.canRedo { canRedo = history.canRedo }
            }
        }
    }

    deinit {
        historyObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Registrazione delle modifiche non-inchiostro
    //
    // Un'azione GIÀ eseguita, con come disfarla e come rifarla. Il
    // ripristino si registra dentro l'annullamento (e viceversa): è lo
    // stesso schema annidato dei tratti, l'unico che dà anche il "ripeti".

    func record(_ name: String, undo undoBlock: @escaping () -> Void, redo redoBlock: @escaping () -> Void) {
        guard pagedContainer != nil else { return }
        history.registerUndo(withTarget: self) { controller in
            undoBlock()
            controller.record(name, undo: redoBlock, redo: undoBlock)
        }
        history.setActionName(name)
    }

    // Modifica di un valore (posizione di una casella, elenco delle
    // caselle, misure di un'immagine): basta l'"prima" e il "dopo".
    func recordChange<Value>(_ name: String, from previous: Value, to current: Value, apply: @escaping (Value) -> Void) {
        record(name, undo: { apply(previous) }, redo: { apply(current) })
    }

    func undo() {
        if pagedContainer != nil { history.undo(); return }
        canvasView?.undoManager?.undo()
    }

    func redo() {
        if pagedContainer != nil { history.redo(); return }
        canvasView?.undoManager?.redo()
    }

    // MARK: - Cancellazioni in blocco
    //
    // Passare la gomma a mano su una pagina intera è lungo e si finisce
    // per portarsi via anche quello che si voleva tenere. Queste due
    // operazioni lavorano sui tratti, non sui pixel, quindi sono esatte.

    // Via tutto l'inchiostro della pagina che si sta guardando (le altre
    // pagine restano). Registrato nell'undo manager: si torna indietro.
    func clearCurrentPage() {
        if let pagedContainer, let page = pagedContainer.activeInkPage {
            pagedContainer.commitStrokes([], on: page)
            return
        }
        applyToCurrentDrawing { _ in PKDrawing() }
    }

    // Via SOLO le evidenziature, lasciando intatti appunti e disegni.
    // È l'operazione che serve davvero rileggendo: si evidenzia molto
    // durante il primo studio e poi si vuole ripulire senza rifare gli
    // appunti. La gomma normale non sa distinguerli.
    func clearHighlighterOnCurrentPage() {
        if let pagedContainer, let page = pagedContainer.activeInkPage {
            pagedContainer.commitStrokes(page.strokes.filter { !Self.isHighlighter($0) }, on: page)
            return
        }
        applyToCurrentDrawing { drawing in
            PKDrawing(strokes: drawing.strokes.filter { !Self.isHighlighter($0) })
        }
    }

    // Ora che l'evidenziatore è una PENNA con inchiostro trasparente, il
    // tipo di inchiostro non lo distingue più dalla scrittura: a
    // separarli è l'OPACITÀ, perché le penne normali scrivono con colore
    // pieno. Confrontare il tipo, com'era prima, qui cancellerebbe tutto
    // ciò che hai scritto a penna.
    //
    // I due tipi storici restano riconosciuti: le evidenziature tracciate
    // prima dei vari cambi di inchiostro sono ancora nelle note già
    // scritte, e senza, "togli le evidenziature" sembrerebbe rotto
    // proprio sulle note più vecchie.
    private static func isHighlighter(_ stroke: PKStroke) -> Bool {
        if stroke.ink.inkType == .marker || stroke.ink.inkType == .watercolor { return true }
        return stroke.ink.color.cgColor.alpha < 0.95
    }

    // C'è inchiostro da cancellare? Serve a disattivare i pulsanti
    // invece di offrire un'azione che non farebbe niente.
    func currentPageHasInk() -> Bool {
        !(currentCanvas()?.drawing.strokes.isEmpty ?? true)
    }

    func currentPageHasHighlighter() -> Bool {
        currentCanvas()?.drawing.strokes.contains(where: Self.isHighlighter) ?? false
    }

    // Solo lavagna infinita: le note a pagine non hanno più canvas.
    private func currentCanvas() -> PKCanvasView? {
        canvasView
    }

    private func applyToCurrentDrawing(_ transform: (PKDrawing) -> PKDrawing) {
        guard let canvas = currentCanvas() else { return }
        let updated = transform(canvas.drawing)
        guard updated.strokes.count != canvas.drawing.strokes.count else { return }
        setDrawingRegisteringUndo(updated, on: canvas)
    }

    // PencilKit registra l'annullamento solo per i tratti disegnati
    // dall'utente: assegnare `drawing` da codice NON lascia niente
    // nell'undo manager. Verificato cancellando una pagina e premendo
    // annulla — l'inchiostro non tornava. Quindi l'azione va registrata
    // a mano.
    //
    // Registrandone una nuova DENTRO il blocco di annullamento si
    // ottiene anche il ripristino: annulla rimette il disegno vecchio e
    // registra come "annullamento dell'annullamento" quello nuovo.
    private func setDrawingRegisteringUndo(_ drawing: PKDrawing, on canvas: PKCanvasView) {
        let previous = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: canvas) { [weak self] target in
            self?.setDrawingRegisteringUndo(previous, on: target)
        }
        canvas.drawing = drawing
    }

    // Rettangolo di contenuto attualmente visibile, per inserire nuovi
    // media nella pagina che si sta guardando e non sempre in cima.
    var visibleContentRect: CGRect? {
        if let pagedContainer { return pagedContainer.visibleContentRect }
        guard let canvasView else { return nil }
        return CGRect(origin: canvasView.contentOffset, size: canvasView.bounds.size)
    }

    // MARK: - Pagine
    // Sulla nota a pagine reali ogni pagina è un NotePage indipendente;
    // sulla lavagna infinita le pagine non si usano (tela libera).

    func pageCount(pageHeight: CGFloat) -> Int {
        if let pagedContainer { return pagedContainer.pageCount() }
        guard let canvasView, pageHeight > 0 else { return 1 }
        return max(1, Int(ceil(canvasView.contentSize.height / pageHeight)))
    }

    func currentPageIndex(pageHeight: CGFloat) -> Int {
        if let pagedContainer { return pagedContainer.currentPageIndex() }
        guard let canvasView, pageHeight > 0 else { return 0 }
        return max(0, Int(round(canvasView.contentOffset.y / pageHeight)))
    }

    func scrollToPage(_ index: Int, pageHeight: CGFloat, animated: Bool = true) {
        if let pagedContainer { pagedContainer.scrollToPage(index, animated: animated); return }
        guard let canvasView else { return }
        let targetY = max(0, CGFloat(index)) * pageHeight
        let maxY = max(0, canvasView.contentSize.height - canvasView.bounds.height)
        let clampedY = min(targetY, maxY)
        canvasView.setContentOffset(CGPoint(x: canvasView.contentOffset.x, y: clampedY), animated: animated)
    }

    func pageThumbnail(index: Int, pageWidth: CGFloat, pageHeight: CGFloat) -> UIImage? {
        if let pagedContainer { return pagedContainer.pageThumbnail(index: index) }
        guard let canvasView, pageWidth > 0, pageHeight > 0 else { return nil }
        let rect = CGRect(x: 0, y: CGFloat(index) * pageHeight, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: -rect.origin.x, y: -rect.origin.y)
            canvasView.layer.render(in: ctx.cgContext)
        }
    }

    // Esporta il foglio in PDF per le impostazioni nota: una pagina reale
    // per ogni NotePage sulla nota paginata, un'unica pagina ritagliata
    // sull'area disegnata per la lavagna infinita.
    func renderPDF(pageWidth: CGFloat, pageHeight: CGFloat, isWhiteboard: Bool, includePattern: Bool = false) -> Data? {
        if let pagedContainer { return pagedContainer.renderAllPagesPDF(includePattern: includePattern) }
        guard let canvasView else { return nil }

        // La filigrana quadretti/righe si esclude nascondendola per il
        // tempo del rendering: qui il foglio è un unico layer.
        let patternWasHidden = canvasView.backgroundView.isHidden
        canvasView.backgroundView.isHidden = !includePattern
        defer { canvasView.backgroundView.isHidden = patternWasHidden }

        var contentBounds = canvasView.drawing.bounds
        for subview in canvasView.subviews where subview !== canvasView.backgroundView {
            contentBounds = contentBounds.union(subview.frame)
        }
        contentBounds = contentBounds.isNull || contentBounds.isInfinite
            ? CGRect(x: 0, y: 0, width: 800, height: 600)
            : contentBounds.insetBy(dx: -40, dy: -40)
        guard contentBounds.width > 0, contentBounds.height > 0 else { return nil }
        let renderer = UIGraphicsPDFRenderer(bounds: contentBounds)
        return renderer.pdfData { context in
            context.beginPage()
            context.cgContext.translateBy(x: -contentBounds.minX, y: -contentBounds.minY)
            canvasView.layer.render(in: context.cgContext)
        }
    }
}

// PKCanvasView è già una UIScrollView: la usiamo per ottenere uno
// scorrimento "infinito" facendo crescere contentSize man mano che si
// disegna o si scrive vicino al bordo inferiore. La larghezza segue la
// dimensione pagina scelta (A3/A4/A5), centrata se più stretta dello schermo.
final class InfiniteCanvasView: PKCanvasView {
    let backgroundView = TemplateBackgroundView()
    private let pdfBackgroundView = PDFView()
    private var lastPDFData: Data?
    private var pdfContentHeight: CGFloat = 0
    private let growthChunk: CGFloat = 1400
    private let growthThreshold: CGFloat = 500
    private let initialHeight: CGFloat = 2200
    private var pageWidth: CGFloat

    // Lavagna infinita: invece di una pagina larga fissa che scorre solo
    // in verticale, usa una tela quadrata molto grande, pannabile in tutte
    // le direzioni, con il punto di partenza al centro. Non è matematicamente
    // infinita (i limiti restano coordinate concrete), ma alle dimensioni
    // in gioco è indistinguibile da uno spazio libero illimitato.
    let isFreeform: Bool
    private let freeformExtent: CGFloat = 6000
    private var hasCenteredFreeformOffset = false

    // Vetro trasparente sopra tutto il resto, usato SOLO per la penna
    // magica e lo strumento puntatore. PKCanvasView cattura internamente i
    // tocchi di Pencil per il proprio motore di disegno anche quando
    // drawingGestureRecognizer è disattivato — un gesto aggiunto
    // direttamente su canvasView può non riceverli mai. Un subview
    // dedicato, sempre in cima e reso interattivo solo quando serve,
    // intercetta il tocco prima che PencilKit lo veda.
    let interactionOverlay = UIView()

    init(pageWidth: CGFloat, isFreeform: Bool = false) {
        self.pageWidth = pageWidth
        self.isFreeform = isFreeform
        super.init(frame: .zero)
        // Il canvas è zoomato da un UIScrollView esterno (ZoomableCanvasContainer),
        // non da sé stesso: la sua backing store resta renderizzata alla scala
        // nativa dello schermo anche quando lo zoom esterno la ingrandisce, e
        // il tratto appare sfuocato. 2x è il compromesso: nitido a zoom
        // normale/medio senza il costo di memoria di 4x (su una tela
        // 6000×6000 il backing store cresce col quadrato del fattore —
        // era una delle cause della lentezza generale dell'app).
        contentScaleFactor = UIScreen.main.scale * 2
        if isFreeform {
            contentSize = CGSize(width: freeformExtent, height: freeformExtent)
        } else {
            contentSize = CGSize(width: pageWidth, height: initialHeight)
        }
        insertSubview(backgroundView, at: 0)
        backgroundView.frame = CGRect(origin: .zero, size: contentSize)
        pdfBackgroundView.isUserInteractionEnabled = false
        pdfBackgroundView.autoScales = false
        pdfBackgroundView.displayDirection = .vertical
        pdfBackgroundView.displaysPageBreaks = false
        pdfBackgroundView.backgroundColor = .white

        interactionOverlay.backgroundColor = .clear
        interactionOverlay.isUserInteractionEnabled = false
        addSubview(interactionOverlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()

        // bounds.origin di una UIScrollView è sempre il contentOffset:
        // questo tiene il vetro perfettamente ancorato al viewport visibile.
        if interactionOverlay.frame != bounds {
            interactionOverlay.frame = bounds
        }

        if isFreeform {
            // Il foglio bianco riempie l'intera tela, non solo la larghezza pagina.
            if backgroundView.frame.size != contentSize {
                backgroundView.frame = CGRect(origin: .zero, size: contentSize)
            }
            // Al primo layout utile, parte centrata così si può pannare
            // liberamente in ogni direzione fin da subito.
            if !hasCenteredFreeformOffset, bounds.width > 0, bounds.height > 0 {
                hasCenteredFreeformOffset = true
                contentOffset = CGPoint(
                    x: (contentSize.width - bounds.width) / 2,
                    y: (contentSize.height - bounds.height) / 2
                )
            }
            return
        }

        if contentSize.width != pageWidth {
            contentSize.width = pageWidth
            backgroundView.frame = CGRect(origin: .zero, size: contentSize)
        }
        let sideInset = max(0, (bounds.width - pageWidth) / 2)
        if contentInset.left != sideInset || contentInset.right != sideInset {
            contentInset = UIEdgeInsets(top: 0, left: sideInset, bottom: 0, right: sideInset)
        }
    }

    func updatePageWidth(_ width: CGFloat) {
        guard !isFreeform, pageWidth != width else { return }
        pageWidth = width
        setNeedsLayout()
        if lastPDFData != nil { setPDFBackground(lastPDFData) }
    }

    // Se impostato, il PDF diventa lo sfondo del foglio (pagine vere su cui
    // annotare) al posto del pattern quadretti/righe/crocette.
    func setPDFBackground(_ data: Data?) {
        guard data != lastPDFData else { return }
        lastPDFData = data

        guard let data, let document = PDFDocument(data: data), document.pageCount > 0,
              let firstPage = document.page(at: 0) else {
            pdfBackgroundView.removeFromSuperview()
            pdfBackgroundView.document = nil
            pdfContentHeight = 0
            backgroundView.isHidden = false
            return
        }

        let mediaWidth = firstPage.bounds(for: .mediaBox).width
        guard mediaWidth > 0 else { return }
        let scale = pageWidth / mediaWidth
        var totalHeight: CGFloat = 0
        for i in 0..<document.pageCount {
            if let page = document.page(at: i) {
                totalHeight += page.bounds(for: .mediaBox).height * scale
            }
        }

        pdfBackgroundView.document = document
        pdfBackgroundView.scaleFactor = scale
        pdfBackgroundView.frame = CGRect(x: 0, y: 0, width: pageWidth, height: totalHeight)
        if pdfBackgroundView.superview == nil {
            insertSubview(pdfBackgroundView, aboveSubview: backgroundView)
        }
        backgroundView.isHidden = true
        pdfContentHeight = totalHeight
        if contentSize.height < totalHeight {
            contentSize.height = totalHeight
        }
    }

    func growIfNeeded(near maxY: CGFloat) {
        // La lavagna infinita ha già una tela enorme e fissa: niente da far crescere.
        guard !isFreeform else { return }
        guard maxY > contentSize.height - growthThreshold else { return }
        contentSize.height += growthChunk
        backgroundView.frame = CGRect(origin: .zero, size: contentSize)
    }
}

// Avvolge InfiniteCanvasView in uno UIScrollView esterno dedicato solo
// allo zoom (pinch): quello interno resta l'unico responsabile dello
// scroll/disegno, così i due non si contendono i gesture a un dito.
// Default = riempimento schermo (zoomScale 1), zoomabile da lì.
final class ZoomableCanvasContainer: UIScrollView, UIScrollViewDelegate {
    let canvasView: InfiniteCanvasView
    private let isFreeform: Bool
    private let initialPageWidth: CGFloat
    private var lastFitWidth: CGFloat = 0
    private var userDidZoom = false

    init(pageWidth: CGFloat, isFreeform: Bool = false) {
        canvasView = InfiniteCanvasView(pageWidth: pageWidth, isFreeform: isFreeform)
        self.isFreeform = isFreeform
        self.initialPageWidth = pageWidth
        super.init(frame: .zero)
        // Sulla lavagna infinita si parte più zoomati indietro per
        // orientarsi subito nello spazio libero attorno al punto di partenza.
        minimumZoomScale = isFreeform ? 0.15 : 0.5
        maximumZoomScale = 4
        bouncesZoom = true
        backgroundColor = .clear
        delegate = self
        // Solo il gesto a due dita aziona lo zoom: un dito resta libero
        // per lo scroll gestito dal canvas interno.
        panGestureRecognizer.minimumNumberOfTouches = 2
        addSubview(canvasView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if canvasView.frame.size != bounds.size {
            canvasView.frame = CGRect(origin: .zero, size: bounds.size)
        }
        if contentSize != bounds.size {
            contentSize = bounds.size
        }

        // Zoom "aiutato": il foglio riempie la larghezza dello schermo
        // invece di aprirsi (o restare) con margini vuoti. Si ricalcola
        // ogni volta che la larghezza disponibile cambia davvero — per
        // esempio quando la sidebar si apre/chiude — ma solo finché
        // l'utente non ha zoomato a mano, per non contraddirlo.
        if !isFreeform, !userDidZoom, bounds.width > 0, initialPageWidth > 0, bounds.width != lastFitWidth {
            lastFitWidth = bounds.width
            let fit = bounds.width / initialPageWidth
            minimumZoomScale = min(minimumZoomScale, fit)
            zoomScale = min(max(fit, minimumZoomScale), maximumZoomScale)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvasView }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        userDidZoom = true
    }
}

// UITextView che ricorda a quale NoteTextBox corrisponde.
final class BoxTextView: UITextView {
    var boxID = UUID()
    // Maniglia in basso a destra per ridimensionare a mano, e "x" per
    // eliminare direttamente — prima l'unico modo per rimuovere una
    // casella era svuotarla di testo e uscire dall'editing.
    let resizeHandle = UIView()
    let deleteButton = UIButton(type: .system)

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupAccessories()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setupAccessories() {
        resizeHandle.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        resizeHandle.layer.cornerRadius = 7
        resizeHandle.layer.borderWidth = 1
        resizeHandle.layer.borderColor = UIColor.separator.cgColor
        let grip = UIImageView(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"))
        grip.tintColor = .secondaryLabel
        grip.contentMode = .center
        grip.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.centerXAnchor.constraint(equalTo: resizeHandle.centerXAnchor),
            grip.centerYAnchor.constraint(equalTo: resizeHandle.centerYAnchor)
        ])
        addSubview(resizeHandle)

        // "x" neutra e discreta, in linea col resto del design (stesso
        // stile del pulsante di chiusura del pannello), e DENTRO i bordi
        // della casella: mezza fuori, i tocchi sulla parte esterna non
        // arrivavano mai al bottone (hit-test fuori bounds = niente).
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        deleteButton.configuration = config
        deleteButton.tintColor = .secondaryLabel
        deleteButton.backgroundColor = UIColor.tertiarySystemFill
        deleteButton.layer.cornerRadius = 11
        addSubview(deleteButton)

        // Il "chrome" (bordo, x, maniglia) compare solo quando la casella
        // è selezionata (in editing); a riposo il testo resta pulito sul
        // foglio, senza ornamenti.
        setChrome(visible: false)
        layoutAccessories()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutAccessories()
    }

    private func layoutAccessories() {
        let handleSize: CGFloat = 20
        resizeHandle.frame = CGRect(x: bounds.width - handleSize - 2, y: bounds.height - handleSize - 2, width: handleSize, height: handleSize)
        deleteButton.frame = CGRect(x: bounds.width - 24, y: 2, width: 22, height: 22)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { setChrome(visible: true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setChrome(visible: false) }
        return resigned
    }

    private func setChrome(visible: Bool) {
        resizeHandle.isHidden = !visible
        deleteButton.isHidden = !visible
        layer.borderWidth = visible ? 1.5 : 0
        layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
        layer.cornerRadius = visible ? 6 : 0
    }
}

// Contenitore trascinabile per un'immagine, un PDF o una formula
// composta. Si comporta esattamente come una casella di testo: a riposo
// resta pulito sul foglio, e solo quando è selezionato mostra il suo
// "chrome" (bordo, x, maniglia di ridimensionamento, matita).
final class MediaBoxView: UIView {
    var mediaID: PersistentIdentifier?
    let contentContainer = UIView()
    let deleteButton = UIButton(type: .system)
    let editButton = UIButton(type: .system)
    let resizeHandle = UIView()
    private(set) var isSelected = false
    // Impronta del contenuto mostrato: se cambia (formula ricomposta) la
    // vista va ricostruita.
    var contentVersion = 0

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentContainer.layer.cornerRadius = 8
        contentContainer.clipsToBounds = true
        contentContainer.layer.borderWidth = 1
        contentContainer.layer.borderColor = UIColor.separator.cgColor
        contentContainer.backgroundColor = .secondarySystemBackground
        addSubview(contentContainer)

        // Stessi comandi della casella di testo, stesso stile: "x" neutra
        // e maniglia col grip, entrambe DENTRO i bordi (fuori, l'hit-test
        // non arriverebbe mai al pulsante).
        deleteButton.configuration = Self.chromeConfiguration(symbol: "xmark")
        styleChromeButton(deleteButton)
        addSubview(deleteButton)

        editButton.configuration = Self.chromeConfiguration(symbol: "pencil")
        styleChromeButton(editButton)
        editButton.isHidden = true
        addSubview(editButton)

        resizeHandle.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        resizeHandle.layer.cornerRadius = 7
        resizeHandle.layer.borderWidth = 1
        resizeHandle.layer.borderColor = UIColor.separator.cgColor
        let grip = UIImageView(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"))
        grip.tintColor = .secondaryLabel
        grip.contentMode = .center
        grip.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.centerXAnchor.constraint(equalTo: resizeHandle.centerXAnchor),
            grip.centerYAnchor.constraint(equalTo: resizeHandle.centerYAnchor)
        ])
        addSubview(resizeHandle)

        setSelected(false)
        layoutAccessories()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private static func chromeConfiguration(symbol: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        return config
    }

    private func styleChromeButton(_ button: UIButton) {
        button.tintColor = .secondaryLabel
        button.backgroundColor = UIColor.tertiarySystemFill
        button.layer.cornerRadius = 11
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutAccessories()
    }

    private func layoutAccessories() {
        let handleSize: CGFloat = 20
        resizeHandle.frame = CGRect(
            x: bounds.width - handleSize - 2,
            y: bounds.height - handleSize - 2,
            width: handleSize,
            height: handleSize
        )
        // I tre comandi occupano tre angoli diversi: su una formula
        // stretta, affiancati si coprirebbero a vicenda.
        deleteButton.frame = CGRect(x: max(2, bounds.width - 24), y: 2, width: 22, height: 22)
        editButton.frame = CGRect(x: 2, y: max(2, bounds.height - 24), width: 22, height: 22)
    }

    // Il chrome vive sul contenitore, non sul contenuto: così una formula
    // trasparente resta trasparente anche da selezionata.
    func setSelected(_ selected: Bool) {
        isSelected = selected
        deleteButton.isHidden = !selected
        editButton.isHidden = !selected || !canEdit
        resizeHandle.isHidden = !selected
        layer.borderWidth = selected ? 1.5 : 0
        layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
        layer.cornerRadius = selected ? 6 : 0
    }

    // Solo ciò che ha un sorgente (le formule) si può riaprire e correggere.
    var canEdit = false {
        didSet { editButton.isHidden = !isSelected || !canEdit }
    }

    // Per una formula composta la scheda grigia col bordo non ha senso:
    // deve stare sul foglio come se fosse stata scritta a mano.
    func makeTransparent() {
        contentContainer.backgroundColor = .clear
        contentContainer.layer.borderWidth = 0
    }
}


struct DrawingCanvasView: UIViewRepresentable {
    @Binding var drawingData: Data?
    @Binding var textBoxes: [NoteTextBox]
    var media: [NoteMedia]
    var tool: PenTool
    var color: Color
    var inkWidth: CGFloat
    var eraserType: PKEraserTool.EraserType
    var eraserWidth: CGFloat
    var template: NoteTemplate
    var patternScale: CGFloat
    var pageWidth: CGFloat
    var pageHeight: CGFloat
    var pdfBackgroundData: Data?
    var isWhiteboard: Bool
    var magicAction: MagicAction?
    var controller: DrawingController
    var onDeleteMedia: (NoteMedia) -> Void
    var onEditMedia: (NoteMedia) -> Void
    var onMagicCapture: (MagicAction, CGRect, UIImage) -> Void
    var onEraseStrokeCompleted: () -> Void
    var onPencilDoubleTap: () -> Void

    func makeUIView(context: Context) -> ZoomableCanvasContainer {
        let container = ZoomableCanvasContainer(pageWidth: pageWidth, isFreeform: isWhiteboard)
        let canvasView = container.canvasView
        // Il dito scorre la pagina, solo la Apple Pencil disegna
        // (altrimenti un dito che scorre viene letto come un tratto).
        // Con lo strumento testo però serve che anche il dito possa fare
        // tap (drawingGestureRecognizer resta comunque disattivato sotto,
        // quindi non disegna) — altrimenti PencilKit filtra il tocco
        // prima ancora che arrivi al nostro tap recognizer.
        canvasView.drawingPolicy = tool.disablesDrawing ? .anyInput : .pencilOnly
        canvasView.backgroundColor = .clear
        canvasView.delegate = context.coordinator
        canvasView.backgroundView.template = template
        canvasView.backgroundView.patternScale = patternScale
        canvasView.backgroundView.pageHeight = isWhiteboard ? 0 : pageHeight
        canvasView.setPDFBackground(pdfBackgroundData)
        if let data = drawingData, let drawing = try? PKDrawing(data: data) {
            canvasView.drawing = drawing
        }
        let magicActive = magicAction != nil
        canvasView.tool = context.coordinator.pkTool(for: tool, color: color, inkWidth: inkWidth, eraserType: eraserType, eraserWidth: eraserWidth)
        canvasView.drawingGestureRecognizer.isEnabled = !tool.disablesDrawing && !magicActive

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.isEnabled = (tool == .text)
        canvasView.addGestureRecognizer(tap)
        context.coordinator.tapRecognizer = tap

        // Penna magica e puntatore vivono sul "vetro" trasparente sopra il
        // canvas, non su canvasView stesso: PencilKit intercetta
        // internamente i tocchi di Pencil per il proprio motore di disegno
        // anche a drawingGestureRecognizer disattivato, quindi un gesto
        // aggiunto direttamente su canvasView può non riceverli mai.
        let circlePan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleCirclePan(_:)))
        circlePan.delegate = context.coordinator
        canvasView.interactionOverlay.addGestureRecognizer(circlePan)
        context.coordinator.circlePanRecognizer = circlePan

        // Solo per mostrare il cerchio della dimensione mentre si cancella:
        // non interferisce con la gomma vera, gestita da PencilKit stesso.
        let eraserCursorPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleEraserCursorPan(_:)))
        eraserCursorPan.delegate = context.coordinator
        eraserCursorPan.isEnabled = (tool == .eraser)
        canvasView.addGestureRecognizer(eraserCursorPan)
        context.coordinator.eraserCursorPanRecognizer = eraserCursorPan

        let pointerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePointerPan(_:)))
        pointerPan.delegate = context.coordinator
        pointerPan.minimumNumberOfTouches = 1
        pointerPan.maximumNumberOfTouches = 1
        canvasView.interactionOverlay.addGestureRecognizer(pointerPan)
        context.coordinator.pointerPanRecognizer = pointerPan

        canvasView.interactionOverlay.isUserInteractionEnabled = magicActive || tool == .pointer
        circlePan.isEnabled = magicActive
        pointerPan.isEnabled = (tool == .pointer) && !magicActive
        // Lo scroll del canvas riconosce i gesti INSIEME al cerchio della
        // penna magica: senza congelarlo, cerchiare sposta anche il foglio.
        canvasView.isScrollEnabled = !magicActive

        // Doppio tap sulla Apple Pencil: passa da strumento a gomma e viceversa.
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        canvasView.addInteraction(pencilInteraction)

        controller.canvasView = canvasView
        context.coordinator.syncTextBoxes(in: canvasView)
        context.coordinator.syncMedia(in: canvasView)
        return container
    }

    func updateUIView(_ container: ZoomableCanvasContainer, context: Context) {
        let canvasView = container.canvasView
        context.coordinator.parent = self
        let magicActive = magicAction != nil
        canvasView.drawingPolicy = (tool.disablesDrawing || magicActive) ? .anyInput : .pencilOnly
        canvasView.tool = context.coordinator.pkTool(for: tool, color: color, inkWidth: inkWidth, eraserType: eraserType, eraserWidth: eraserWidth)
        canvasView.drawingGestureRecognizer.isEnabled = !tool.disablesDrawing && !magicActive
        context.coordinator.tapRecognizer?.isEnabled = (tool == .text) && !magicActive
        context.coordinator.eraserCursorPanRecognizer?.isEnabled = (tool == .eraser)
        canvasView.interactionOverlay.isUserInteractionEnabled = magicActive || tool == .pointer
        if canvasView.interactionOverlay.isUserInteractionEnabled {
            canvasView.bringSubviewToFront(canvasView.interactionOverlay)
        }
        context.coordinator.circlePanRecognizer?.isEnabled = magicActive
        context.coordinator.pointerPanRecognizer?.isEnabled = (tool == .pointer) && !magicActive
        // Vedi makeUIView: congelato mentre la penna magica è armata.
        canvasView.isScrollEnabled = !magicActive
        canvasView.backgroundView.template = template
        canvasView.backgroundView.patternScale = patternScale
        canvasView.backgroundView.pageHeight = isWhiteboard ? 0 : pageHeight
        canvasView.updatePageWidth(pageWidth)
        canvasView.setPDFBackground(pdfBackgroundData)
        context.coordinator.syncTextBoxes(in: canvasView)
        context.coordinator.syncMedia(in: canvasView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UITextViewDelegate, UIPencilInteractionDelegate {
        var parent: DrawingCanvasView
        weak var tapRecognizer: UITapGestureRecognizer?
        weak var circlePanRecognizer: UIPanGestureRecognizer?
        weak var eraserCursorPanRecognizer: UIPanGestureRecognizer?
        weak var pointerPanRecognizer: UIPanGestureRecognizer?
        private var circleStartPoint: CGPoint?
        private var circlePreviewLayer: CAShapeLayer?
        private lazy var eraserCursorView: UIView = {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = UIColor.label.withAlphaComponent(0.1)
            view.layer.borderWidth = 1.5
            view.layer.borderColor = UIColor.label.withAlphaComponent(0.6).cgColor
            view.isHidden = true
            return view
        }()
        private var textViewsByID: [UUID: BoxTextView] = [:]
        private var lastDragLocation: [UUID: CGPoint] = [:]
        private var mediaViewsByID: [PersistentIdentifier: MediaBoxView] = [:]
        private var mediaDragLocation: [PersistentIdentifier: CGPoint] = [:]

        init(_ parent: DrawingCanvasView) { self.parent = parent }

        // Definizione condivisa con il canvas paginato: vedi PenTool.
        func pkTool(for tool: PenTool, color: Color, inkWidth: CGFloat, eraserType: PKEraserTool.EraserType, eraserWidth: CGFloat) -> PKTool {
            tool.pkTool(color: color, width: inkWidth, eraserType: eraserType, eraserWidth: eraserWidth)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        // Tornando a scrivere il riquadro di selezione sparisce da solo.
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            select(nil)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawingData = canvasView.drawing.dataRepresentation()
            if let infiniteCanvas = canvasView as? InfiniteCanvasView {
                infiniteCanvas.growIfNeeded(near: canvasView.drawing.bounds.maxY)
            }
            if parent.tool == .eraser {
                parent.onEraseStrokeCompleted()
            }
        }

        // MARK: - Apple Pencil

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            parent.onPencilDoubleTap()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let canvasView = gesture.view as? InfiniteCanvasView else { return }
            let point = gesture.location(in: canvasView)
            canvasView.growIfNeeded(near: point.y)
            addTextBox(at: point, in: canvasView)
        }

        // MARK: - Penna magica (cerchia per attivare un'azione)

        @objc func handleCirclePan(_ gesture: UIPanGestureRecognizer) {
            // circlePan è agganciato a canvasView.interactionOverlay (il
            // "vetro" trasparente sopra il canvas), non a canvasView stesso:
            // gesture.view è quindi l'overlay, non castabile a
            // InfiniteCanvasView — va preso dal controller.
            guard let canvasView = parent.controller.canvasView, let action = parent.magicAction else { return }
            let point = gesture.location(in: canvasView)

            switch gesture.state {
            case .began:
                circleStartPoint = point
                let layer = CAShapeLayer()
                layer.strokeColor = UIColor(action.color).cgColor
                layer.fillColor = UIColor(action.color).withAlphaComponent(0.08).cgColor
                layer.lineWidth = 2
                layer.lineDashPattern = [6, 4]
                canvasView.layer.addSublayer(layer)
                circlePreviewLayer = layer

            case .changed:
                guard let start = circleStartPoint else { return }
                let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
                circlePreviewLayer?.path = UIBezierPath(roundedRect: rect, cornerRadius: DesignRadius.lg).cgPath
                canvasView.growIfNeeded(near: rect.maxY)

            case .ended, .cancelled:
                circlePreviewLayer?.removeFromSuperlayer()
                circlePreviewLayer = nil
                defer { circleStartPoint = nil }
                guard let start = circleStartPoint else { return }
                var rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
                guard rect.width > 24, rect.height > 24 else { return }
                rect = rect.insetBy(dx: -8, dy: -8)
                captureMagicRegion(rect, action: action, in: canvasView)

            default:
                break
            }
        }

        // MARK: - Dimensione gomma (solo indicatore visivo)

        @objc func handleEraserCursorPan(_ gesture: UIPanGestureRecognizer) {
            guard let canvasView = gesture.view as? InfiniteCanvasView else { return }
            switch gesture.state {
            case .began, .changed:
                let size = parent.eraserWidth
                let point = gesture.location(in: canvasView)
                if eraserCursorView.superview == nil { canvasView.addSubview(eraserCursorView) }
                eraserCursorView.layer.cornerRadius = size / 2
                eraserCursorView.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                eraserCursorView.isHidden = false
                canvasView.bringSubviewToFront(eraserCursorView)
            case .ended, .cancelled, .failed:
                eraserCursorView.isHidden = true
            default:
                break
            }
        }

        // MARK: - Strumento puntatore (scorri anche con la Pencil)

        @objc func handlePointerPan(_ gesture: UIPanGestureRecognizer) {
            // Stesso discorso di handleCirclePan: attaccato all'overlay,
            // non a canvasView — va preso dal controller, non da gesture.view.
            guard let canvasView = parent.controller.canvasView else { return }
            switch gesture.state {
            case .changed:
                let translation = gesture.translation(in: canvasView)
                var offset = canvasView.contentOffset
                offset.x -= translation.x
                offset.y -= translation.y
                let maxX = max(0, canvasView.contentSize.width - canvasView.bounds.width)
                let maxY = max(0, canvasView.contentSize.height - canvasView.bounds.height)
                offset.x = min(max(offset.x, 0), maxX)
                offset.y = min(max(offset.y, 0), maxY)
                canvasView.contentOffset = offset
                gesture.setTranslation(.zero, in: canvasView)
            default:
                break
            }
        }

        private func captureMagicRegion(_ rect: CGRect, action: MagicAction, in canvasView: InfiniteCanvasView) {
            // layer.render(in:) cattura bene le view CALayer normali
            // (sfondo, PDF, testo digitato, media) ma NON l'inchiostro
            // PencilKit vero — quello passa da un layer accelerato che
            // layer.render(in:) non compone mai, quindi restava
            // sistematicamente vuoto: sembrava che la penna magica
            // "funzionasse solo sullo sfondo PDF" perché lì c'era
            // comunque del contenuto leggibile, mentre l'inchiostro puro
            // spariva. PKDrawing.image(from:scale:) rasterizza
            // correttamente i tratti — li si disegna sopra al resto.
            let scale = UIScreen.main.scale
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
            let image = renderer.image { ctx in
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
                canvasView.layer.render(in: ctx.cgContext)
                ctx.cgContext.restoreGState()

                let inkImage = canvasView.drawing.image(from: rect, scale: scale)
                inkImage.draw(at: .zero)
            }
            parent.onMagicCapture(action, rect, image)
        }

        // MARK: - Caselle di testo

        func syncTextBoxes(in canvasView: InfiniteCanvasView) {
            let currentIDs = Set(parent.textBoxes.map(\.id))
            for (id, view) in textViewsByID where !currentIDs.contains(id) {
                view.removeFromSuperview()
                textViewsByID.removeValue(forKey: id)
            }
            for box in parent.textBoxes where textViewsByID[box.id] == nil {
                let textView = makeTextView(for: box)
                canvasView.addSubview(textView)
                textViewsByID[box.id] = textView
            }
        }

        private func addTextBox(at point: CGPoint, in canvasView: InfiniteCanvasView) {
            let box = NoteTextBox(x: Double(point.x), y: Double(point.y))
            parent.textBoxes.append(box)
            let textView = makeTextView(for: box)
            canvasView.addSubview(textView)
            textViewsByID[box.id] = textView
            textView.becomeFirstResponder()
        }

        private func makeTextView(for box: NoteTextBox) -> BoxTextView {
            let textView = BoxTextView()
            textView.boxID = box.id
            textView.text = box.text
            textView.font = .preferredFont(forTextStyle: .body)
            textView.backgroundColor = .clear
            textView.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            textView.delegate = self
            if let height = box.height {
                textView.isScrollEnabled = true
                textView.frame = CGRect(x: box.x, y: box.y, width: box.width, height: height)
            } else {
                textView.isScrollEnabled = false
                textView.frame = CGRect(x: box.x, y: box.y, width: box.width, height: 40)
                textView.sizeToFit()
                textView.frame.size.width = box.width
            }

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleTextBoxLongPress(_:)))
            longPress.minimumPressDuration = 0.35
            textView.addGestureRecognizer(longPress)

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
                let minWidth: CGFloat = 120
                let minHeight: CGFloat = 40
                textView.frame.size.width = max(textView.frame.width + translation.x, minWidth)
                textView.frame.size.height = max(textView.frame.height + translation.y, minHeight)
                gesture.setTranslation(.zero, in: textView)
            case .ended, .cancelled:
                textView.isScrollEnabled = true
                guard let index = parent.textBoxes.firstIndex(where: { $0.id == textView.boxID }) else { return }
                parent.textBoxes[index].width = Double(textView.frame.width)
                parent.textBoxes[index].height = Double(textView.frame.height)
            default:
                break
            }
        }

        @objc private func handleTextBoxDelete(_ sender: UIButton) {
            guard let textView = sender.superview as? BoxTextView else { return }
            parent.textBoxes.removeAll { $0.id == textView.boxID }
            textView.removeFromSuperview()
            textViewsByID.removeValue(forKey: textView.boxID)
        }

        @objc private func handleTextBoxLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let textView = gesture.view as? BoxTextView,
                  let canvasView = textView.superview as? InfiniteCanvasView else { return }
            let location = gesture.location(in: canvasView)
            switch gesture.state {
            case .began:
                textView.alpha = 0.7
                lastDragLocation[textView.boxID] = location
            case .changed:
                guard let last = lastDragLocation[textView.boxID] else { return }
                textView.center.x += location.x - last.x
                textView.center.y += location.y - last.y
                lastDragLocation[textView.boxID] = location
                canvasView.growIfNeeded(near: textView.frame.maxY)
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
            parent.textBoxes[index].x = Double(x)
            parent.textBoxes[index].y = Double(y)
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
        }

        // MARK: - Immagini e PDF

        func syncMedia(in canvasView: InfiniteCanvasView) {
            let currentIDs = Set(parent.media.map(\.persistentModelID))
            for (id, view) in mediaViewsByID where !currentIDs.contains(id) {
                view.removeFromSuperview()
                mediaViewsByID.removeValue(forKey: id)
            }
            // Contenuto cambiato a parità di id (formula ricomposta): la
            // vista va rifatta, altrimenti resta quella vecchia.
            for item in parent.media {
                guard let box = mediaViewsByID[item.persistentModelID],
                      box.contentVersion != contentVersion(of: item) else { continue }
                box.removeFromSuperview()
                mediaViewsByID.removeValue(forKey: item.persistentModelID)
            }
            for item in parent.media where mediaViewsByID[item.persistentModelID] == nil {
                let box = makeMediaView(for: item)
                canvasView.addSubview(box)
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

            // Come sulle note: un tocco seleziona e mostra i comandi, un
            // altro deseleziona.
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

        func select(_ box: MediaBoxView?) {
            for view in mediaViewsByID.values where view !== box {
                if view.isSelected { view.setSelected(false) }
            }
            box?.setSelected(true)
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
                item.width = Double(box.frame.width)
                item.height = Double(box.frame.height)
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
            guard let box = gesture.view as? MediaBoxView,
                  let mediaID = box.mediaID,
                  let canvasView = box.superview as? InfiniteCanvasView else { return }
            let location = gesture.location(in: canvasView)
            switch gesture.state {
            case .began:
                box.alpha = 0.85
                mediaDragLocation[mediaID] = location
            case .changed:
                guard let last = mediaDragLocation[mediaID] else { return }
                box.center.x += location.x - last.x
                box.center.y += location.y - last.y
                mediaDragLocation[mediaID] = location
                canvasView.growIfNeeded(near: box.frame.maxY)
            case .ended, .cancelled:
                box.alpha = 1
                mediaDragLocation.removeValue(forKey: mediaID)
                if let item = parent.media.first(where: { $0.persistentModelID == mediaID }) {
                    item.x = Double(box.frame.origin.x)
                    item.y = Double(box.frame.origin.y)
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
