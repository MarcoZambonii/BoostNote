import SwiftUI
import SwiftData
import PencilKit
import PDFKit
import Combine

// Espone undo/redo/export/pagine alla toolbar, che vive fuori dalla
// UIViewRepresentable. Un'unica classe/canvas copre sia la lavagna
// infinita (tela libera) sia la nota normale (stesso scorrimento
// continuo, ma con divisori di pagina visivi e larghezza fissa).
final class DrawingController: ObservableObject {
    fileprivate weak var canvasView: InfiniteCanvasView?

    func undo() { canvasView?.undoManager?.undo() }
    func redo() { canvasView?.undoManager?.redo() }

    // Rettangolo di contenuto attualmente visibile, per inserire nuovi
    // widget/media nella pagina che si sta guardando e non sempre in cima.
    var visibleContentRect: CGRect? {
        guard let canvasView else { return nil }
        return CGRect(origin: canvasView.contentOffset, size: canvasView.bounds.size)
    }

    // MARK: - Pagine
    // Il foglio resta un unico scorrimento continuo: le "pagine" sono
    // segmenti virtuali di altezza `pageHeight`, non oggetti separati.

    func pageCount(pageHeight: CGFloat) -> Int {
        guard let canvasView, pageHeight > 0 else { return 1 }
        return max(1, Int(ceil(canvasView.contentSize.height / pageHeight)))
    }

    func currentPageIndex(pageHeight: CGFloat) -> Int {
        guard let canvasView, pageHeight > 0 else { return 0 }
        return max(0, Int(round(canvasView.contentOffset.y / pageHeight)))
    }

    func scrollToPage(_ index: Int, pageHeight: CGFloat, animated: Bool = true) {
        guard let canvasView else { return }
        let targetY = max(0, CGFloat(index)) * pageHeight
        let maxY = max(0, canvasView.contentSize.height - canvasView.bounds.height)
        let clampedY = min(targetY, maxY)
        canvasView.setContentOffset(CGPoint(x: canvasView.contentOffset.x, y: clampedY), animated: animated)
    }

    func pageThumbnail(index: Int, pageWidth: CGFloat, pageHeight: CGFloat) -> UIImage? {
        guard let canvasView, pageWidth > 0, pageHeight > 0 else { return nil }
        let rect = CGRect(x: 0, y: CGFloat(index) * pageHeight, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: -rect.origin.x, y: -rect.origin.y)
            canvasView.layer.render(in: ctx.cgContext)
        }
    }

    // Esporta il foglio in PDF per le impostazioni nota: una pagina reale
    // per ogni segmento di `pageHeight` sulla nota normale, un'unica
    // pagina ritagliata sull'area disegnata per la lavagna infinita.
    func renderPDF(pageWidth: CGFloat, pageHeight: CGFloat, isWhiteboard: Bool) -> Data? {
        guard let canvasView else { return nil }

        if isWhiteboard {
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

        guard pageWidth > 0, pageHeight > 0 else { return nil }
        let pages = pageCount(pageHeight: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        return renderer.pdfData { context in
            for index in 0..<pages {
                context.beginPage()
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 0, y: -CGFloat(index) * pageHeight)
                canvasView.layer.render(in: context.cgContext)
                context.cgContext.restoreGState()
            }
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
}

// Contenitore trascinabile per un'immagine o un PDF inserito sul foglio,
// con una piccola "x" per rimuoverlo.
final class MediaBoxView: UIView {
    var mediaID: PersistentIdentifier?
    let contentContainer = UIView()
    let deleteButton = UIButton(type: .system)

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

        deleteButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        deleteButton.tintColor = .systemRed
        deleteButton.backgroundColor = .systemBackground
        deleteButton.layer.cornerRadius = 11
        deleteButton.frame = CGRect(x: frame.width - 22, y: -11, width: 22, height: 22)
        deleteButton.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        addSubview(deleteButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
}

// Contenitore trascinabile per un widget interattivo (grafico, to-do,
// pomodoro, wolfram). Il "chrome" visivo (titolo, "x", ombra, angoli) lo
// disegna interamente la card SwiftUI dentro (WidgetCard) — questa view è
// solo un contenitore trasparente trascinabile con una pressione prolungata.
final class WidgetBoxView: UIView {
    var widgetID: PersistentIdentifier?
    let contentContainer = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentContainer.frame = bounds
        contentContainer.backgroundColor = .clear
        contentContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(contentContainer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
}

struct DrawingCanvasView: UIViewRepresentable {
    @Binding var drawingData: Data?
    @Binding var textBoxes: [NoteTextBox]
    var media: [NoteMedia]
    var widgets: [NoteWidget]
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
    var onDeleteWidget: (NoteWidget) -> Void
    var onWidgetUpdate: () -> Void
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

        // Doppio tap sulla Apple Pencil: passa da strumento a gomma e viceversa.
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        canvasView.addInteraction(pencilInteraction)

        controller.canvasView = canvasView
        context.coordinator.syncTextBoxes(in: canvasView)
        context.coordinator.syncMedia(in: canvasView)
        context.coordinator.syncWidgets(in: canvasView)
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
        canvasView.backgroundView.template = template
        canvasView.backgroundView.patternScale = patternScale
        canvasView.backgroundView.pageHeight = isWhiteboard ? 0 : pageHeight
        canvasView.updatePageWidth(pageWidth)
        canvasView.setPDFBackground(pdfBackgroundData)
        context.coordinator.syncTextBoxes(in: canvasView)
        context.coordinator.syncMedia(in: canvasView)
        context.coordinator.syncWidgets(in: canvasView)
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
        private var widgetViewsByID: [PersistentIdentifier: WidgetBoxView] = [:]
        private var widgetDragLocation: [PersistentIdentifier: CGPoint] = [:]

        init(_ parent: DrawingCanvasView) { self.parent = parent }

        func pkTool(for tool: PenTool, color: Color, inkWidth: CGFloat, eraserType: PKEraserTool.EraserType, eraserWidth: CGFloat) -> PKTool {
            let uiColor = UIColor(color)
            switch tool {
            case .pen:
                return PKInkingTool(.pen, color: uiColor, width: inkWidth)
            case .marker:
                return PKInkingTool(.marker, color: uiColor.withAlphaComponent(0.5), width: inkWidth)
            case .pencil:
                return PKInkingTool(.pencil, color: uiColor, width: inkWidth)
            case .eraser:
                return PKEraserTool(eraserType, width: eraserWidth)
            case .lasso:
                return PKLassoTool()
            case .text, .pointer:
                // Nessun tratto: drawingGestureRecognizer è disattivato per questi strumenti.
                return PKInkingTool(.pen, color: .clear, width: 0.01)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
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
            guard let canvasView = gesture.view as? InfiniteCanvasView, let action = parent.magicAction else { return }
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
                circlePreviewLayer?.path = UIBezierPath(roundedRect: rect, cornerRadius: 12).cgPath
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
            guard let canvasView = gesture.view as? InfiniteCanvasView else { return }
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
            let image = canvasView.drawing.image(from: rect, scale: UIScreen.main.scale)
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
            textView.isScrollEnabled = false
            textView.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            textView.delegate = self
            textView.frame = CGRect(x: box.x, y: box.y, width: box.width, height: 40)
            textView.sizeToFit()
            textView.frame.size.width = box.width

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleTextBoxLongPress(_:)))
            longPress.minimumPressDuration = 0.35
            textView.addGestureRecognizer(longPress)

            return textView
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
            for item in parent.media where mediaViewsByID[item.persistentModelID] == nil {
                let box = makeMediaView(for: item)
                canvasView.addSubview(box)
                mediaViewsByID[item.persistentModelID] = box
            }
        }

        private func makeMediaView(for item: NoteMedia) -> MediaBoxView {
            let box = MediaBoxView(frame: CGRect(x: item.x, y: item.y, width: item.width, height: item.height))
            box.mediaID = item.persistentModelID

            switch item.kind {
            case .image:
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
            box.deleteButton.addTarget(self, action: #selector(handleMediaDelete(_:)), for: .touchUpInside)

            return box
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

        // MARK: - Widget interattivi

        func syncWidgets(in canvasView: InfiniteCanvasView) {
            let currentIDs = Set(parent.widgets.map(\.persistentModelID))
            for (id, view) in widgetViewsByID where !currentIDs.contains(id) {
                view.removeFromSuperview()
                widgetViewsByID.removeValue(forKey: id)
            }
            for item in parent.widgets where widgetViewsByID[item.persistentModelID] == nil {
                let box = makeWidgetView(for: item)
                canvasView.addSubview(box)
                widgetViewsByID[item.persistentModelID] = box
            }
        }

        private func makeWidgetView(for item: NoteWidget) -> WidgetBoxView {
            let box = WidgetBoxView(frame: CGRect(x: item.x, y: item.y, width: item.width, height: item.height))
            box.widgetID = item.persistentModelID

            let content = NoteWidgetContentView(
                widget: item,
                onUpdate: { [weak self] in self?.parent.onWidgetUpdate() },
                onDelete: { [weak self] in self?.deleteWidget(withID: item.persistentModelID) }
            )
            let hosting = UIHostingController(rootView: content)
            hosting.view.backgroundColor = .clear
            hosting.view.frame = box.contentContainer.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            box.contentContainer.addSubview(hosting.view)

            // Trascinabile con una pressione prolungata su tutta la card
            // (0.35s lascia priorità ai tap/bottoni SwiftUI dentro).
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleWidgetLongPress(_:)))
            longPress.minimumPressDuration = 0.35
            box.addGestureRecognizer(longPress)

            return box
        }

        @objc private func handleWidgetLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let box = gesture.view as? WidgetBoxView,
                  let widgetID = box.widgetID,
                  let canvasView = box.superview as? InfiniteCanvasView else { return }
            let location = gesture.location(in: canvasView)
            switch gesture.state {
            case .began:
                box.alpha = 0.85
                widgetDragLocation[widgetID] = location
            case .changed:
                guard let last = widgetDragLocation[widgetID] else { return }
                box.center.x += location.x - last.x
                box.center.y += location.y - last.y
                widgetDragLocation[widgetID] = location
                canvasView.growIfNeeded(near: box.frame.maxY)
            case .ended, .cancelled:
                box.alpha = 1
                widgetDragLocation.removeValue(forKey: widgetID)
                if let item = parent.widgets.first(where: { $0.persistentModelID == widgetID }) {
                    item.x = Double(box.frame.origin.x)
                    item.y = Double(box.frame.origin.y)
                }
            default:
                break
            }
        }

        private func deleteWidget(withID widgetID: PersistentIdentifier) {
            guard let item = parent.widgets.first(where: { $0.persistentModelID == widgetID }) else { return }
            parent.onDeleteWidget(item)
            widgetViewsByID[widgetID]?.removeFromSuperview()
            widgetViewsByID.removeValue(forKey: widgetID)
        }
    }
}
