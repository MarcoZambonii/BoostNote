import SwiftUI
import SwiftData
import PencilKit
import PhotosUI

struct NoteEditorView: View {
    @Bindable var note: Note
    var onBack: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @State private var selectedTool: PenTool = .pen
    @State private var penColor: Color = .black
    @State private var penWidth: CGFloat = 4
    @State private var markerColor: Color = .yellow
    @State private var markerWidth: CGFloat = 14
    @State private var pencilColor: Color = .black
    @State private var pencilWidth: CGFloat = 3
    @State private var eraserType: PKEraserTool.EraserType = .bitmap
    @State private var eraserWidth: CGFloat = 30
    @State private var toolBeforeEraser: PenTool?
    @State private var magicAction: MagicAction?
    @State private var toolbarDock: ToolbarDock = .top
    @State private var dragPreviewDock: ToolbarDock?
    @StateObject private var drawingController = DrawingController()

    @State private var showingPhotosPicker = false
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var showingPDFImporter = false
    @State private var pendingPDFData: Data?

    @State private var showingToolsPicker = false
    // Calcolatrice/Ricerca/Documento vivono in un pannello laterale
    // persistente, non in un foglio modale: restano aperti mentre si
    // continua a scrivere, e si chiudono con un pulsante esplicito.
    @State private var sidePanelTool: NoteTool?
    @State private var researchModel = ArxivSearchModel()
    @State private var showingSettings = false
    @State private var showingSearch = false

    @State private var magicResult: MagicResult?

    // "Pagine": segmenti virtuali di altezza `pageHeight` calcolati sull'unico
    // scorrimento continuo del foglio — non pagine reali separate.
    private var pageHeight: CGFloat { note.pageSize.height }

    // Colore/spessore dello strumento a inchiostro attualmente attivo.
    private var activeColor: Color {
        switch selectedTool {
        case .marker: markerColor
        case .pencil: pencilColor
        default: penColor
        }
    }

    private var activeInkWidth: CGFloat {
        switch selectedTool {
        case .marker: markerWidth
        case .pencil: pencilWidth
        default: penWidth
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            canvasArea
                .background(DesignColor.surfacePage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let sidePanelTool {
                Divider()
                sidePanel(for: sidePanelTool)
                    .frame(width: 380)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: sidePanelTool)
        .onChange(of: note.title) { note.updatedAt = .now }
        .onChange(of: note.drawingData) { note.updatedAt = .now }
        .onChange(of: note.textBoxesData) { note.updatedAt = .now }
        .onChange(of: selectedTool) { oldValue, newValue in
            if newValue == .eraser, oldValue != .eraser {
                toolBeforeEraser = oldValue
            }
        }
        .photosPicker(isPresented: $showingPhotosPicker, selection: $photosPickerItem, matching: .images)
        .onChange(of: photosPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    insertMedia(kind: .image, data: data)
                }
                photosPickerItem = nil
            }
        }
        .fileImporter(isPresented: $showingPDFImporter, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                pendingPDFData = data
            }
        }
        .confirmationDialog(
            "Come vuoi inserire questo PDF?",
            isPresented: pdfImportDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Come widget spostabile") {
                if let data = pendingPDFData { insertMedia(kind: .pdf, data: data) }
                pendingPDFData = nil
            }
            Button("Come foglio della nota") {
                if let data = pendingPDFData {
                    note.appendPDFPages(from: data)
                    note.updatedAt = .now
                }
                pendingPDFData = nil
            }
            Button("Annulla", role: .cancel) { pendingPDFData = nil }
        }
        .sheet(isPresented: $showingSettings) {
            NoteSettingsSheet(note: note, drawingController: drawingController) { index in
                drawingController.scrollToPage(index, pageHeight: pageHeight)
            }
        }
        .sheet(item: $magicResult) { result in
            MagicResultSheet(result: result) {
                insertMagicResult(result)
            }
        }
    }

    private var pdfImportDialogPresented: Binding<Bool> {
        Binding(get: { pendingPDFData != nil }, set: { if !$0 { pendingPDFData = nil } })
    }

    // MARK: - Pannello laterale (Calcolatrice / Ricerca / Documento)

    @ViewBuilder
    private func sidePanel(for tool: NoteTool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: tool.systemImage)
                    .foregroundStyle(DesignColor.brandPrimary)
                Text(tool.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)
                Spacer()
                Button {
                    sidePanelTool = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignColor.textTertiary)
                        .frame(width: 26, height: 26)
                        .background(DesignColor.surfaceSunken, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chiudi")
            }
            .padding(DesignSpace.s4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DesignColor.borderDefault).frame(height: 1)
            }

            Group {
                switch tool {
                case .calculator:
                    CalculatorContentView()
                case .research:
                    ResearchContentView(model: researchModel)
                case .document:
                    documentPanelContent
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignColor.surfacePage)
    }

    private var documentPanelContent: some View {
        VStack(spacing: DesignSpace.s4) {
            Spacer()
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(DesignColor.textTertiary)
            Text("Importa un PDF come pagina della nota o come widget spostabile.")
                .font(.system(size: 13))
                .foregroundStyle(DesignColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSpace.s5)
            Button {
                showingPDFImporter = true
            } label: {
                Text("Scegli PDF")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSpace.s5)
                    .padding(.vertical, DesignSpace.s3)
                    .background(DesignColor.brandPrimary, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Foglio

    private var canvasArea: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Il testo è opzionale: si aggiunge con lo strumento "Aa".
                // Immagini, PDF e widget si inseriscono dalla barra e
                // restano trascinabili sul foglio.
                DrawingCanvasView(
                    drawingData: $note.drawingData,
                    textBoxes: $note.textBoxes,
                    media: note.media,
                    widgets: note.widgets,
                    tool: selectedTool,
                    color: activeColor,
                    inkWidth: activeInkWidth,
                    eraserType: eraserType,
                    eraserWidth: eraserWidth,
                    template: note.template,
                    patternScale: note.patternScale,
                    pageWidth: note.pageSize.width,
                    pageHeight: pageHeight,
                    pdfBackgroundData: note.pdfBackgroundData,
                    isWhiteboard: note.isWhiteboard,
                    magicAction: magicAction,
                    controller: drawingController,
                    onDeleteMedia: deleteMedia,
                    onDeleteWidget: deleteWidget,
                    onWidgetUpdate: { note.updatedAt = .now },
                    onMagicCapture: handleMagicCapture,
                    onEraseStrokeCompleted: handleEraseStrokeCompleted,
                    onPencilDoubleTap: handlePencilDoubleTap
                )

                // Placeholder "aggancio" ai 4 lati, visibili solo mentre si
                // trascina la barra — non intercettano tocchi.
                dockPlaceholders
                    .allowsHitTesting(false)

                toolbar(geometry: geometry)

                // Fissa in alto a sinistra: back + titolo della nota.
                HStack(spacing: 8) {
                    backButton
                    titlePill
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Fissa in alto a destra indipendentemente da dove è
                // agganciata la barra della penna (che invece si sposta).
                topRightToolbar
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .coordinateSpace(name: "canvasArea")
        }
    }

    // La barra della penna vive solo nei 4 punti medi dei lati; si trascina
    // dalla maniglia e si aggancia al lato più vicino al rilascio.
    private func toolbar(geometry: GeometryProxy) -> some View {
        PenToolbarView(
            selectedTool: $selectedTool,
            penColor: $penColor,
            penWidth: $penWidth,
            markerColor: $markerColor,
            markerWidth: $markerWidth,
            pencilColor: $pencilColor,
            pencilWidth: $pencilWidth,
            eraserType: $eraserType,
            eraserWidth: $eraserWidth,
            magicAction: $magicAction,
            dock: $toolbarDock,
            dragPreviewDock: $dragPreviewDock,
            containerSize: geometry.size,
            onInsertImage: { showingPhotosPicker = true },
            onInsertPDF: { showingPDFImporter = true }
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        // Agganciata sopra, resta sotto la riga fissa titolo/strumenti
        // così le due barre non si sovrappongono mai — il gap è il
        // minimo indispensabile, non uno spazio vuoto sprecato.
        .padding(.top, toolbarDock == .top ? headerRowHeight + 12 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: toolbarDock.alignment)
    }

    // Placeholder fantasma ai 4 lati, mostrati mentre si trascina la barra:
    // quello più vicino al punto di rilascio si evidenzia.
    private var dockPlaceholders: some View {
        ZStack {
            ForEach(ToolbarDock.allCases, id: \.self) { candidate in
                dockPlaceholder(candidate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: candidate.alignment)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .padding(.top, candidate == .top ? headerRowHeight + 12 : 8)
            }
        }
        .opacity(dragPreviewDock != nil ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: dragPreviewDock != nil)
    }

    @ViewBuilder
    private func dockPlaceholder(_ candidate: ToolbarDock) -> some View {
        let isTarget = candidate == dragPreviewDock
        RoundedRectangle(cornerRadius: DesignRadius.pill, style: .continuous)
            .fill(isTarget ? DesignColor.brandPrimarySubtle : DesignColor.surfaceSunken.opacity(0.7))
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.pill, style: .continuous)
                    .strokeBorder(isTarget ? DesignColor.brandPrimary : DesignColor.borderDefault, style: StrokeStyle(lineWidth: isTarget ? 2 : 1, dash: isTarget ? [] : [5, 4]))
            )
            .frame(
                width: candidate.axis == .horizontal ? 220 : 52,
                height: candidate.axis == .horizontal ? 52 : 220
            )
            .scaleEffect(isTarget ? 1.05 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isTarget)
    }

    private let headerRowHeight: CGFloat = 40

    // Torna alla vista generale (cartella o Home) da cui si è aperta la nota.
    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
                .frame(width: headerRowHeight, height: headerRowHeight)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(DesignColor.borderDefault, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Indietro")
    }

    // Stesso stile "pillola" della barra a destra.
    private var titlePill: some View {
        TextField("Titolo", text: $note.title)
            .font(.system(size: 15, weight: .semibold))
            .textFieldStyle(.plain)
            .foregroundStyle(DesignColor.textPrimary)
            .padding(.horizontal, DesignSpace.s3 + 2)
            .frame(height: headerRowHeight)
            .frame(minWidth: 160, maxWidth: 280)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(DesignColor.borderDefault, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    // Barra fissa in alto a destra (non si sposta con la floatbar della
    // penna): annulla/ripeti, strumenti/widget, ricerca, impostazioni.
    private var topRightToolbar: some View {
        HStack(spacing: 10) {
            // "Avanti/indietro" come azione (annulla/ripeti), non come
            // scorrimento tra pagine — quello resta nelle miniature delle
            // impostazioni foglio.
            Button(action: drawingController.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .accessibilityLabel("Annulla")

            Button(action: drawingController.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .accessibilityLabel("Ripeti")

            Divider().frame(height: 20)

            Button {
                showingToolsPicker = true
            } label: {
                Image(systemName: "square.grid.2x2.fill")
            }
            .accessibilityLabel("Strumenti e widget")
            .popover(isPresented: $showingToolsPicker) {
                ToolsPickerSheet { tool in
                    showingToolsPicker = false
                    if let kind = tool.widgetKind {
                        insertWidget(kind: kind)
                    } else {
                        sidePanelTool = tool
                    }
                }
                .presentationCompactAdaptation(.popover)
            }

            Button {
                showingSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Cerca nella nota")
            .popover(isPresented: $showingSearch) {
                NoteSearchSheet(
                    note: note,
                    drawingController: drawingController,
                    pageWidth: note.pageSize.width,
                    pageHeight: pageHeight
                ) { index in
                    drawingController.scrollToPage(index, pageHeight: pageHeight)
                    showingSearch = false
                }
                .presentationCompactAdaptation(.popover)
            }

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Impostazioni foglio")
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(DesignColor.textPrimary)
        .buttonStyle(.plain)
        .padding(.horizontal, DesignSpace.s3 + 2)
        .frame(height: headerRowHeight)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(DesignColor.borderDefault, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    // Inizio verticale della pagina attualmente visibile, per inserire i
    // nuovi elementi lì invece che sempre in cima al foglio.
    private var currentPageTop: Double {
        Double(drawingController.visibleContentRect?.minY ?? 0) + 60
    }

    private func insertMedia(kind: NoteMediaKind, data: Data) {
        let offset = Double(note.media.count % 6) * 24
        let item = NoteMedia(x: 60 + offset, y: currentPageTop + offset, kind: kind, data: data, note: note)
        context.insert(item)
        note.updatedAt = .now
    }

    private func deleteMedia(_ item: NoteMedia) {
        context.delete(item)
        note.updatedAt = .now
    }

    private func insertWidget(kind: NoteWidgetKind) {
        // I widget compaiono come card fluttuanti sulla destra della
        // pagina attualmente visibile, non sempre in cima al foglio.
        let offset = Double(note.widgets.count % 6) * 24
        let size = defaultSize(for: kind)
        let x = max(24, note.pageSize.width - size.width - 32) - offset
        let widget = NoteWidget(x: x, y: currentPageTop + offset, width: size.width, height: size.height, kind: kind, note: note)
        context.insert(widget)
        note.updatedAt = .now
    }

    private func defaultSize(for kind: NoteWidgetKind) -> CGSize {
        switch kind {
        case .graph: CGSize(width: 260, height: 240)
        case .todo: CGSize(width: 240, height: 260)
        case .pomodoro: CGSize(width: 240, height: 220)
        case .wolfram: CGSize(width: 260, height: 180)
        }
    }

    private func deleteWidget(_ item: NoteWidget) {
        context.delete(item)
        note.updatedAt = .now
    }

    // MARK: - Strumenti temporanei (gomma, Apple Pencil)

    // Dopo un tratto di gomma, torna automaticamente allo strumento
    // usato prima (penna/matita/evidenziatore), come richiesto.
    private func handleEraseStrokeCompleted() {
        guard selectedTool == .eraser, let previous = toolBeforeEraser else { return }
        selectedTool = previous
        toolBeforeEraser = nil
    }

    // Doppio tap sulla Apple Pencil: passa tra lo strumento corrente e la gomma.
    private func handlePencilDoubleTap() {
        if selectedTool == .eraser {
            selectedTool = toolBeforeEraser ?? .pen
            toolBeforeEraser = nil
        } else {
            selectedTool = .eraser
        }
    }

    // MARK: - Penna magica

    private func handleMagicCapture(action: MagicAction, rect: CGRect, image: UIImage) {
        Task {
            let recognizedText = await MagicPenService.recognizeText(in: image)
            var result = MagicResult(action: action, recognizedText: recognizedText, captureRect: rect)

            guard let text = recognizedText, !text.isEmpty else {
                result.errorMessage = "Non sono riuscito a riconoscere la scrittura. Prova a scrivere più in stampatello e cerchia di nuovo."
                magicResult = result
                return
            }

            switch action {
            case .wolfram:
                let appID = UserDefaults.standard.string(forKey: "wolframAlphaAppID") ?? ""
                if appID.isEmpty {
                    result.errorMessage = "Aggiungi la tua chiave Wolfram Alpha nel Profilo per usare questa funzione."
                } else {
                    result.resultText = await MagicPenService.queryWolfram(text: text, appID: appID)
                    if result.resultText == nil {
                        result.errorMessage = "Wolfram Alpha non ha risposto. Controlla la connessione o la chiave."
                    }
                }

            case .draw:
                if (try? MathExpression(text)) != nil {
                    result.graphExpression = text
                } else {
                    result.errorMessage = "Non sono riuscito a interpretare un'espressione matematica valida da \"\(text)\"."
                }

            case .latex:
                result.resultText = text

            case .explain:
                // Prova prima il modello Apple locale (gratis, on-device);
                // se non disponibile e c'è una chiave Anthropic salvata,
                // usa Claude via API come alternativa.
                switch await MagicPenService.explainLocally(text: text) {
                case .success(let explanation):
                    result.resultText = explanation
                case .failure(let reason):
                    let apiKey = UserDefaults.standard.string(forKey: "anthropicAPIKey") ?? ""
                    if !apiKey.isEmpty {
                        result.resultText = await MagicPenService.queryClaude(text: text, apiKey: apiKey)
                        if result.resultText == nil {
                            result.errorMessage = "Claude non ha risposto. Controlla la connessione o la chiave."
                        }
                    } else {
                        result.errorMessage = reason.message
                    }
                }

            case .search:
                if let url = MagicPenService.searchURL(for: text) {
                    openURL(url)
                }
                return
            }

            magicResult = result
        }
    }

    private func insertMagicResult(_ result: MagicResult) {
        switch result.action {
        case .draw:
            if let expression = result.graphExpression {
                let widget = NoteWidget(
                    x: result.captureRect.minX,
                    y: result.captureRect.maxY + 12,
                    width: 260, height: 220,
                    kind: .graph, note: note
                )
                widget.encode(GraphWidgetState(expression: expression))
                context.insert(widget)
            }
        case .wolfram, .latex, .explain:
            if let text = result.resultText {
                var box = NoteTextBox(x: result.captureRect.minX, y: result.captureRect.maxY + 12)
                box.text = text
                note.textBoxes.append(box)
            }
        case .search:
            break
        }
        note.updatedAt = .now
    }
}
