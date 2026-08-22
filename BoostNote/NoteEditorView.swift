import SwiftUI
import SwiftData
import PencilKit
import PhotosUI
import PDFKit

// Conversione Color <-> stringa esadecimale per salvare le preferenze
// strumento in AppStorage (Color non è direttamente persistibile).
extension Color {
    var hexString: String? {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return nil }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// Lettore PDF di sola lettura per il pannello "Documento": consultazione
// a fianco della nota, non tocca il contenuto della nota stessa.
struct PDFKitPreviewView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayDirection = .vertical
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.dataRepresentation() != data {
            uiView.document = PDFDocument(data: data)
        }
    }
}

// Lato del foglio su cui vive il pannello Strumenti. Chi scrive con la
// destra tiene la mano proprio dove stava il pannello: poterlo mandare a
// sinistra è la ragione per cui esiste questa scelta.
enum SidePanelSide: String {
    case leading, trailing

    var opposite: SidePanelSide { self == .leading ? .trailing : .leading }
    var label: String { self == .leading ? "sinistra" : "destra" }
    // Segno con cui una traslazione orizzontale allarga il pannello: a
    // destra si allarga tirando verso sinistra, a sinistra il contrario.
    var widthSign: CGFloat { self == .leading ? 1 : -1 }
}

struct NoteEditorView: View {
    @Bindable var note: Note
    var onBack: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @State private var selectedTool: PenTool = .pen
    // Un colore e uno spessore PER STRUMENTO: tornando all'evidenziatore
    // si ritrova il giallo spesso lasciato lì, non l'ultimo colore usato
    // con la penna.
    @State private var inkColors: [PenTool: Color] = [:]
    @State private var inkWidths: [PenTool: CGFloat] = [:]
    @State private var eraserType: PKEraserTool.EraserType = .bitmap
    @State private var eraserWidth: CGFloat = 30

    // Colori e spessori scelti dall'utente sopravvivono alla chiusura
    // della nota: senza, a ogni apertura si ripartiva dai default e
    // andava rifatta la stessa configurazione ogni volta. Un'unica
    // stringa JSON invece di due proprietà per strumento, così
    // aggiungerne uno non tocca la persistenza.
    @AppStorage("tool.inkSettings") private var storedInkSettings = ""
    @AppStorage("tool.eraserType") private var storedEraserType = "bitmap"
    @AppStorage("tool.eraserWidth") private var storedEraserWidth = 30.0
    // Anche lo STRUMENTO selezionato sopravvive: riaprendo l'app si
    // riparte da dove si era rimasti, non sempre dalla penna.
    @AppStorage("tool.selected") private var storedSelectedTool = PenTool.pen.rawValue
    @State private var toolBeforeEraser: PenTool?
    @State private var toolBeforeLasso: PenTool?
    @State private var magicAction: MagicAction?
    @State private var isMagicProcessing = false
    // Su iPhone la barra parte in basso, a portata di pollice: in alto
    // condividerebbe la riga con back e controlli, e su 400pt di
    // larghezza non ci sta niente.
    @State private var toolbarDock: ToolbarDock = DeviceLayout.isPhone ? .bottom : .top
    @State private var dragPreviewDock: ToolbarDock?
    @StateObject private var drawingController = DrawingController()

    @State private var showingPhotosPicker = false
    @State private var photosPickerItem: PhotosPickerItem?
    // UN SOLO fileImporter con destinazione esplicita: due .fileImporter
    // in catena sulla stessa vista sono un bug noto di SwiftUI — solo
    // l'ultimo si presenta, il primo (l'import PDF della barra) non si
    // apriva MAI. Era questo il motivo per cui "non faceva niente".
    enum PDFPickerTarget { case notePages, documentPanel }
    @State private var pdfPickerTarget: PDFPickerTarget = .notePages
    @State private var showingPDFPicker = false

    // Il pannello "Documento" è un lettore PDF di consultazione a fianco
    // della nota (per leggere le slide mentre si scrive): scegliere un
    // PDF qui NON lo importa nella nota, resta solo nel pannello.
    @State private var documentPreviewData: Data?
    @State private var documentPreviewName: String = ""

    @State private var showingToolsPicker = false
    // Strumenti ridotti alla sola intestazione: restano nella pila e non
    // perdono lo stato, ma smettono di occupare il pannello.
    @State private var collapsedTools: Set<String> = []
    // TUTTI gli strumenti vivono nel pannello laterale persistente (non
    // più widget flottanti sul foglio): resta aperto mentre si scrive e
    // si chiude con un pulsante esplicito.
    // Strumenti aperti nel pannello destro: una PILA (calcolatrice e
    // grafico insieme), letta e scritta sulla NOTA — vedi Note.sidePanelTools.
    // Il pannello si può nascondere SENZA smontarne il contenuto: le view
    // restano nella gerarchia con larghezza zero, così quello che hai
    // scritto nella calcolatrice o cercato su Wolfram è ancora lì quando
    // lo riapri. Solo la X su uno strumento lo rimuove davvero.
    @State private var isSidePanelHidden = false
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var sidePanelDragOffset: CGFloat = 0
    // Lato e larghezza del pannello sopravvivono alla nota: sono una
    // preferenza di postazione (mano con cui si scrive, quanto foglio si
    // vuole tenere libero), non una proprietà del documento.
    @AppStorage("sidePanel.side") private var storedPanelSide = SidePanelSide.trailing.rawValue
    @AppStorage("sidePanel.width") private var storedPanelWidth = 380.0
    // Larghezza mentre si trascina la maniglia di ridimensionamento:
    // scrivere in AppStorage a ogni frame farebbe un salvataggio per
    // movimento del dito.
    @State private var liveResizeWidth: CGFloat?
    @State private var researchModel = PaperSearchModel()
    // Stato con cui la penna magica precompila i pannelli Grafici/Wolfram.
    @State private var panelGraphExpression = "x^2 - 9"
    @State private var panelWolframPrefill: String?
    @State private var showingSettings = false
    @State private var showingSearch = false
    @State private var showingWebeepDocPicker = false
    // Dove finisce il PDF scelto da WeBeep: pannello di lettura oppure
    // pagine della nota (import dalla float bar). Stesso schema del
    // fileImporter, per lo stesso motivo.
    @State private var webeepPickerTarget: PDFPickerTarget = .documentPanel

    @State private var magicResult: MagicResult?
    // Errore d'import PDF (file illeggibile, non-PDF): prima spariva in
    // silenzio e "importa" sembrava non fare niente.
    @State private var pdfImportError: String?
    // Formula sul foglio aperta per la correzione del suo LaTeX.
    @State private var editingFormula: NoteMedia?
    // Immagine e sorgente della formula PRIMA della modifica: il "prima"
    // per la cronologia si fotografa all'apertura dello sheet.
    @State private var formulaBeforeEdit: (data: Data, sourceText: String?)?

    // "Pagine": segmenti virtuali di altezza `pageHeight` calcolati sull'unico
    // scorrimento continuo del foglio — non pagine reali separate.
    private var pageHeight: CGFloat { note.pageSize.height }

    // Colore/spessore dello strumento a inchiostro attualmente attivo.
    private var activeColor: Color {
        inkColors[selectedTool] ?? selectedTool.defaultColor
    }

    private var activeInkWidth: CGFloat {
        inkWidths[selectedTool] ?? selectedTool.defaultWidth
    }

    // Strumenti aperti su QUESTA nota.
    private var sidePanelTools: [NoteTool] {
        note.sidePanelTools.compactMap(NoteTool.init(rawValue:))
    }

    private var panelSide: SidePanelSide {
        SidePanelSide(rawValue: storedPanelSide) ?? .trailing
    }

    // Larghezza del contenitore, letta dal GeometryReader del body: serve
    // al pannello su iPhone, dove non c'è spazio per foglio e strumenti
    // affiancati e il pannello occupa tutta la larghezza.
    @State private var editorContainerWidth: CGFloat = 0

    // Larghezza scelta dall'utente (o quella in corso di trascinamento).
    private var panelWidth: CGFloat {
        if DeviceLayout.isPhone { return editorContainerWidth }
        return liveResizeWidth ?? CGFloat(storedPanelWidth)
    }

    private var currentPanelWidth: CGFloat {
        isSidePanelHidden ? sidePanelDragOffset : (panelWidth + sidePanelDragOffset)
    }

    // Estremi del ridimensionamento: sotto i 280pt gli strumenti (Desmos,
    // Wolfram, PDF) diventano illeggibili; oltre i due terzi del foglio
    // non resta abbastanza pagina per scriverci.
    private func clampPanelWidth(_ width: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let upper = max(280, min(760, containerWidth * 0.66))
        return min(max(width, 280), upper)
    }

    private func openSidePanel(_ tool: NoteTool) {
        isSidePanelHidden = false
        var tools = note.sidePanelTools
        if let index = tools.firstIndex(of: tool.rawValue) {
            // Già aperto: lo si porta in cima invece di duplicarlo.
            tools.remove(at: index)
        }
        tools.insert(tool.rawValue, at: 0)
        note.sidePanelTools = tools
    }

    private func closeSidePanel(_ tool: NoteTool) {
        note.sidePanelTools = note.sidePanelTools.filter { $0 != tool.rawValue }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if panelSide == .leading {
                    panelColumn(containerWidth: geometry.size.width)
                }

                canvasArea
                    .background(DesignColor.surfacePage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if panelSide == .trailing {
                    panelColumn(containerWidth: geometry.size.width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { editorContainerWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in
                editorContainerWidth = width
            }
        }
        .alert("Titolo della nota", isPresented: $showingRename) {
            TextField("Titolo", text: $renameText)
            Button("Annulla", role: .cancel) { }
            Button("Salva") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { note.title = trimmed }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea()
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: sidePanelTools)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: isSidePanelHidden)
        .overlay(alignment: panelSide == .leading ? .leading : .trailing) {
            // Maniglia per aprire/chiudere con uno swipe quando il
            // pannello è nascosto ma ha ancora contenuti dentro.
            if !sidePanelTools.isEmpty && isSidePanelHidden {
                sidePanelHandle
            }
        }
        .onAppear {
            // Nota creata prima del modello a pagine reali (o mai aperta
            // da quando è tornato): genera le pagine dai campi legacy.
            // Poi garantisce sempre una pagina vuota in fondo, così lo
            // scorrimento continua oltre l'ultimo contenuto (Notability).
            note.migrateLegacyContentToPages(in: context)
            note.ensureTrailingBlankPage(in: context)
            restoreToolPreferences()
        }
        .onDisappear {
            // Segnalibro automatico: alla prossima apertura si riparte da qui.
            note.lastViewedPage = drawingController.currentPageIndex(pageHeight: pageHeight)
            saveToolPreferences()
            // L'assicurazione: il pacchetto .boostnote nella cartella
            // d'archivio (se configurata). Snapshot sul main, scrittura
            // in background — la chiusura non aspetta.
            NoteArchiveService.archive(note)
        }
        .onChange(of: note.title) { note.updatedAt = .now }
        .onChange(of: note.drawingData) { note.updatedAt = .now }
        .onChange(of: note.textBoxesData) { note.updatedAt = .now }
        .onChange(of: selectedTool) { oldValue, newValue in
            if newValue == .eraser, oldValue != .eraser {
                toolBeforeEraser = oldValue
            }
            if newValue == .lasso, oldValue != .lasso {
                toolBeforeLasso = oldValue
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
        .alert("Import non riuscito", isPresented: Binding(
            get: { pdfImportError != nil },
            set: { if !$0 { pdfImportError = nil } }
        )) {
            Button("OK", role: .cancel) { pdfImportError = nil }
        } message: {
            Text(pdfImportError ?? "")
        }
        .fileImporter(isPresented: $showingPDFPicker, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                pdfImportError = "Non riesco a leggere \"\(url.lastPathComponent)\". Se il file sta su un cloud, aprilo prima nell'app File per scaricarlo."
                return
            }
            switch pdfPickerTarget {
            case .notePages:
                // Import diretto come pagine in coda alla nota aperta: si
                // continua a scrivere prima e dopo. Su lavagna diventa lo
                // sfondo del foglio.
                appendPDFPagesRecorded(data)
            case .documentPanel:
                documentPreviewData = data
                documentPreviewName = url.deletingPathExtension().lastPathComponent
            }
        }
        .sheet(isPresented: $showingSettings) {
            NoteSettingsSheet(note: note, drawingController: drawingController) { index in
                drawingController.scrollToPage(index, pageHeight: pageHeight)
            }
        }
        .sheet(item: $magicResult) { result in
            MagicResultSheet(
                result: result,
                onInsert: { toPanel in
                    insertMagicResult(result, toPanel: toPanel)
                },
                onRetry: { editedText in
                    // L'utente ha corretto a mano il testo riconosciuto:
                    // riesegue la stessa azione sul testo corretto,
                    // saltando il riconoscimento.
                    isMagicProcessing = true
                    Task {
                        defer { isMagicProcessing = false }
                        if let newResult = await processMagic(
                            action: result.action,
                            text: editedText,
                            latexAlreadyConverted: false,
                            rect: result.captureRect,
                            via: "corretto a mano"
                        ) {
                            magicResult = newResult
                        }
                    }
                }
            )
        }
        .sheet(item: $editingFormula) { media in
            FormulaEditSheet(media: media) {
                note.updatedAt = .now
                // La vista si aggiorna da sola (syncMedia confronta la
                // versione del contenuto): qui resta solo da registrare.
                if let before = formulaBeforeEdit,
                   before.data != media.data || before.sourceText != media.sourceText {
                    let id = media.persistentModelID
                    let after = (data: media.data, sourceText: media.sourceText)
                    drawingController.record("Modifica formula", undo: { [self] in
                        applyFormulaContent(id: id, data: before.data, sourceText: before.sourceText)
                    }, redo: { [self] in
                        applyFormulaContent(id: id, data: after.data, sourceText: after.sourceText)
                    })
                }
                formulaBeforeEdit = nil
            }
        }
        .sheet(isPresented: $showingWebeepDocPicker) {
            // Il pannello Documento ne mostra UNO: lì la spunta multipla
            // non avrebbe senso. In coda alle pagine invece sì.
            WebeepFilePickerSheet(
                selectionMode: webeepPickerTarget == .documentPanel ? .single : .multiple
            ) { data, name in
                switch webeepPickerTarget {
                case .notePages:
                    // Import diretto come pagine in coda, come dai File.
                    appendPDFPagesRecorded(data)
                case .documentPanel:
                    documentPreviewData = data
                    documentPreviewName = name
                }
            }
        }
    }


    // MARK: - Pannello laterale (Calcolatrice / Ricerca / Documento)

    // Colonna del pannello con la sua maniglia di ridimensionamento, dal
    // lato giusto: la maniglia sta sempre sul bordo che confina col
    // foglio, che è quello che si trascina per allargare o stringere.
    @ViewBuilder
    private func panelColumn(containerWidth: CGFloat) -> some View {
        if !sidePanelTools.isEmpty {
            if panelSide == .trailing {
                resizeGrip(containerWidth: containerWidth)
            }
            sidePanelStack
                // Larghezza a zero invece di rimuovere la view: è ciò
                // che permette al contenuto di sopravvivere alla
                // chiusura del pannello.
                .frame(width: max(0, currentPanelWidth))
                .clipped()
                // `.clipped()` ritaglia il DISEGNO ma NON i tocchi: il
                // pannello restava largo come area sensibile anche da
                // chiuso, e si mangiava tutta la fascia laterale del
                // foglio — non ci si poteva né scrivere né toccare.
                // Queste due righe sono la correzione vera.
                .contentShape(Rectangle())
                .allowsHitTesting(currentPanelWidth > 1)
            if panelSide == .leading {
                resizeGrip(containerWidth: containerWidth)
            }
        }
    }

    // Bordo trascinabile tra foglio e pannello. Da pannello nascosto
    // resta un semplice divisore invisibile: non c'è niente da
    // ridimensionare e una zona sensibile lì si mangerebbe i tratti.
    @ViewBuilder
    private func resizeGrip(containerWidth: CGFloat) -> some View {
        if isSidePanelHidden || DeviceLayout.isPhone {
            // Su iPhone il pannello è a tutta larghezza: non c'è nessun
            // confine col foglio da trascinare.
            Divider().opacity(0)
        } else {
            ZStack {
                Rectangle()
                    .fill(DesignColor.borderDefault)
                    .frame(width: 1)
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    .fill(DesignColor.textTertiary.opacity(liveResizeWidth == nil ? 0.35 : 0.8))
                    .frame(width: 4, height: 42)
            }
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let base = liveResizeWidth ?? CGFloat(storedPanelWidth)
                        let proposed = base + value.translation.width * panelSide.widthSign
                        liveResizeWidth = clampPanelWidth(proposed, containerWidth: containerWidth)
                    }
                    .onEnded { _ in
                        if let liveResizeWidth {
                            storedPanelWidth = Double(liveResizeWidth)
                        }
                        liveResizeWidth = nil
                    }
            )
            .accessibilityLabel("Larghezza del pannello strumenti")
        }
    }

    @ViewBuilder
    // Pila degli strumenti aperti: ognuno con la propria X, che è
    // l'UNICO modo di rimuoverlo davvero. Nascondere il pannello (swipe o
    // maniglia) non tocca il contenuto.
    private var sidePanelStack: some View {
        VStack(spacing: 0) {
            // Su iPhone il pannello parte dal bordo fisico dello schermo
            // (l'editor ignora la safe area): l'intestazione scende sotto
            // la Dynamic Island come i controlli del foglio.
            if DeviceLayout.isPhone {
                Color.clear.frame(height: phoneTopInset)
            }
            HStack(spacing: DesignSpace.s2) {
                Button {
                    withAnimation { isSidePanelHidden = true }
                } label: {
                    Image(systemName: panelSide == .leading ? "chevron.left" : "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DesignColor.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                        .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Nascondi pannello")

                Text(sidePanelTools.count == 1 ? "1 strumento" : "\(sidePanelTools.count) strumenti")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignColor.textSecondary)
                Spacer()

                // La porta per aggiungere uno strumento sta QUI, sopra la
                // pila: prima era solo nella barra della penna, dove chi
                // guardava il pannello non la cercava.
                Button {
                    showingToolsPicker = true
                } label: {
                    Text("Aggiungi")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                                .strokeBorder(DesignColor.borderDefault, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Aggiungi strumento")

                // Il pannello passa dall'altro lato del foglio: chi scrive
                // con la destra ci appoggia sopra la mano.
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        storedPanelSide = panelSide.opposite.rawValue
                    }
                } label: {
                    Image(systemName: panelSide == .leading
                          ? "rectangle.trailinghalf.inset.filled"
                          : "rectangle.leadinghalf.inset.filled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignColor.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sposta il pannello a \(panelSide.opposite.label)")
            }
            .padding(.horizontal, DesignSpace.s3)
            .padding(.vertical, DesignSpace.s2)
            .contentShape(Rectangle())
            // Lo swipe vive SOLO qui: sull'intero pannello competeva con
            // i pulsanti interni e rendeva i tocchi inaffidabili.
            .gesture(panelDragGesture)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sidePanelTools, id: \.rawValue) { tool in
                        sidePanelSection(for: tool)
                    }
                }
            }
        }
        // Larghezza NATURALE pari a quella scelta: la `.frame` esterna
        // (che anima l'apertura) ritaglia, questa tiene il contenuto alla
        // sua misura invece di comprimerlo mentre il pannello si chiude.
        .frame(width: panelWidth, alignment: .leading)
        .background(DesignColor.surfaceSunken)
    }

    // Ogni strumento è una card a sé: con più pannelli aperti, dei
    // semplici divisori non facevano capire dove finiva uno e iniziava
    // l'altro. L'intestazione colorata del tipo fa da appiglio visivo.
    private func sidePanelSection(for tool: NoteTool) -> some View {
        let isCollapsed = collapsedTools.contains(tool.rawValue)
        return VStack(spacing: 0) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: tool.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignColor.brandPrimary)
                    .frame(width: 26, height: 26)
                    .background(DesignColor.brandPrimarySubtle, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                Text(tool.label)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)

                // Due tasti gemelli: riduci e chiudi. Erano uno solo, e
                // per togliere di mezzo uno strumento senza perderne lo
                // stato bisognava chiuderlo e riaprirlo.
                cardButton(isCollapsed ? "chevron.down" : "chevron.up", label: isCollapsed ? "Espandi \(tool.label)" : "Riduci \(tool.label)") {
                    withAnimation(.snappy(duration: 0.2)) {
                        if isCollapsed { collapsedTools.remove(tool.rawValue) } else { collapsedTools.insert(tool.rawValue) }
                    }
                }
                cardButton("xmark", label: "Rimuovi \(tool.label)") {
                    withAnimation { closeSidePanel(tool) }
                }
            }
            .padding(.leading, DesignSpace.s3)
            .padding(.trailing, DesignSpace.s2 + 2)
            .padding(.vertical, DesignSpace.s2 + 2)

            if !isCollapsed {
                Rectangle().fill(DesignColor.borderSubtle).frame(height: 1)
            }

            if !isCollapsed {
            Group {
                switch tool {
                case .calculator: CalculatorContentView()
                case .research: ResearchContentView(model: researchModel)
                case .document: documentPanelContent
                case .graphing: GraphPanelContent(expression: $panelGraphExpression)
                case .todo: TodoPanelContent(note: note)
                case .pomodoro: PomodoroPanelContent()
                case .wolfram:
                    WolframPanelContent(prefill: panelWolframPrefill)
                        .id(panelWolframPrefill)
                }
            }
            .padding(DesignSpace.s3)
            }
        }
        .background(DesignColor.surfacePage)
        .clipShape(RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                .stroke(DesignColor.borderSubtle, lineWidth: 1)
        )
        .padding(.horizontal, DesignSpace.s3)
        .padding(.vertical, DesignSpace.s2 - 2)
    }

    private func cardButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DesignColor.textSecondary)
                .frame(width: 26, height: 26)
                .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                // Area sensibile più larga del disegno: 26pt di grafica
                // sono belli ma sotto il minimo comodo per il dito.
                .contentShape(Rectangle().inset(by: -7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // Maniglia sul bordo destro quando il pannello è nascosto: si tira
    // verso sinistra per riaprirlo.
    // Maniglia per riaprire il pannello nascosto. È un PULSANTE, non una
    // zona sensibile al trascinamento: la versione precedente estendeva
    // l'area di 18pt per lato e ci agganciava un DragGesture, che sul
    // bordo destro del foglio si mangiava i tratti della penna — lì non
    // si riusciva più né a scrivere né a toccare. Lo swipe per chiudere
    // resta sull'intestazione del pannello, dove non c'è nulla da
    // disegnare.
    private var sidePanelHandle: some View {
        // Gli angoli tondi stanno sul lato interno (verso il foglio),
        // qualunque sia il bordo su cui il pannello è agganciato.
        let shape = panelSide == .leading
            ? UnevenRoundedRectangle(bottomTrailingRadius: DesignRadius.md, topTrailingRadius: DesignRadius.md)
            : UnevenRoundedRectangle(topLeadingRadius: DesignRadius.md, bottomLeadingRadius: DesignRadius.md)
        return Button {
            withAnimation { isSidePanelHidden = false }
        } label: {
            Image(systemName: panelSide == .leading ? "chevron.right" : "chevron.left")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DesignColor.textSecondary)
                .frame(width: 22, height: 44)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(DesignColor.borderDefault.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 6, x: panelSide == .leading ? 2 : -2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mostra pannello strumenti")
    }

    // Swipe orizzontale per aprire/chiudere, col pannello che segue il
    // dito: verso il foglio apre, verso il proprio bordo chiude — su
    // entrambi i lati, da cui il segno che ribalta la traslazione.
    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let travel = value.translation.width * panelSide.widthSign
                if isSidePanelHidden {
                    sidePanelDragOffset = min(panelWidth, max(0, travel))
                } else {
                    sidePanelDragOffset = min(0, max(-panelWidth, travel))
                }
            }
            .onEnded { value in
                let travel = value.translation.width * panelSide.widthSign
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    if abs(travel) > 80 {
                        isSidePanelHidden = travel < 0
                    }
                    sidePanelDragOffset = 0
                }
            }
    }

    // Lettore PDF di sola consultazione, per leggere slide/dispense a
    // fianco mentre si scrive: sceglierne uno qui NON lo tocca mai come
    // contenuto della nota (per quello c'è il pulsante PDF della barra).
    @ViewBuilder
    private var documentPanelContent: some View {
        if let documentPreviewData {
            VStack(spacing: 0) {
                HStack(spacing: DesignSpace.s2) {
                    Text(documentPreviewName.isEmpty ? "Documento" : documentPreviewName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignColor.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Menu("Cambia") {
                        Button {
                            pdfPickerTarget = .documentPanel
                            showingPDFPicker = true
                        } label: {
                            Label("Da file", systemImage: "folder")
                        }
                        Button {
                            webeepPickerTarget = .documentPanel
                            showingWebeepDocPicker = true
                        } label: {
                            Label("Da WeBeep", systemImage: "graduationcap")
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    Button {
                        self.documentPreviewData = nil
                        documentPreviewName = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                }
                .padding(.horizontal, DesignSpace.s4)
                .padding(.vertical, DesignSpace.s3)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(DesignColor.borderSubtle).frame(height: 1)
                }

                PDFKitPreviewView(data: documentPreviewData)
                    .frame(maxWidth: .infinity)
                    // Altezza ESPLICITA, stessa lezione di Desmos: la card
                    // vive nella ScrollView del pannello, dove "riempi
                    // tutto" collassa a zero — il PDF si apriva in un
                    // riquadro invisibile.
                    .frame(height: 620)
            }
        } else {
            VStack(spacing: DesignSpace.s4) {
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(DesignColor.textTertiary)
                Text("Apri un PDF qui per leggerlo a fianco mentre scrivi — resta nel pannello, non entra nella nota.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSpace.s5)
                // Le due provenienze reali dei PDF: i File dell'iPad e i
                // corsi WeBeep — quest'ultima senza passare dal download
                // manuale e re-import.
                HStack(spacing: DesignSpace.s3) {
                    Button {
                        pdfPickerTarget = .documentPanel
                        showingPDFPicker = true
                    } label: {
                        Label("Da file", systemImage: "folder")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, DesignSpace.s4)
                            .padding(.vertical, DesignSpace.s3)
                            .background(DesignColor.brandPrimary, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        webeepPickerTarget = .documentPanel
                        showingWebeepDocPicker = true
                    } label: {
                        Label("Da WeBeep", systemImage: "graduationcap")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignColor.brandPrimary)
                            .padding(.horizontal, DesignSpace.s4)
                            .padding(.vertical, DesignSpace.s3)
                            .background(DesignColor.brandPrimarySubtle, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Foglio

    private var canvasArea: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Il testo è opzionale: si aggiunge con lo strumento "Aa".
                // Immagini e PDF si inseriscono dalla barra e restano
                // trascinabili sul foglio; gli strumenti vivono nel
                // pannello laterale, non più come widget sul foglio.
                PagedNoteCanvasView(
                        pages: note.sortedPages,
                        initialPage: note.lastViewedPage,
                        textBoxes: $note.textBoxes,
                        media: note.media,
                        tool: selectedTool,
                        color: activeColor,
                        inkWidth: activeInkWidth,
                        eraserType: eraserType,
                        eraserWidth: eraserWidth,
                        template: note.template,
                        patternScale: note.patternScale,
                        pageWidth: note.pageSize.width,
                        defaultPageHeight: pageHeight,
                        magicAction: magicAction,
                        controller: drawingController,
                        onDeleteMedia: deleteMedia,
                        onEditMedia: { item in formulaBeforeEdit = (item.data, item.sourceText); editingFormula = item },
                        onMagicCapture: handleMagicCapture,
                        onEraseStrokeCompleted: handleEraseStrokeCompleted,
                        onLassoFinished: handleLassoFinished,
                        onPencilDoubleTap: handlePencilDoubleTap,
                        onPageDrawingChanged: { page, data in
                            page.drawingData = data
                            note.updatedAt = .now
                            // Appena l'ultima pagina riceve inchiostro, ne
                            // spunta una vuota sotto: si può sempre
                            // continuare a scrivere senza sbattere contro
                            // un muro.
                            //
                            // Solo se è cambiata l'ULTIMA pagina, però:
                            // il controllo deserializza il disegno per
                            // sapere se ha inchiostro, e su una pagina
                            // che nessuno ha toccato la risposta è la
                            // stessa dell'ultima volta.
                            guard note.sortedPages.last === page else { return }
                            note.ensureTrailingBlankPage(in: context)
                        },
                        onNeedMorePages: {
                            note.appendBlankPage(in: context)
                        }
                )

                // Placeholder "aggancio" ai 4 lati, visibili solo mentre si
                // trascina la barra — non intercettano tocchi.
                dockPlaceholders
                    .allowsHitTesting(false)

                toolbar(geometry: geometry)

                // Fissa in alto a sinistra: back + titolo della nota.
                HStack(spacing: 8) {
                    backButton
                }
                .padding(8)
                .padding(.top, phoneTopInset)
                .safeAreaPadding(.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Fissa in alto a destra indipendentemente da dove è
                // agganciata la barra della penna (che invece si sposta).
                topRightToolbar
                    .padding(8)
                    .padding(.top, phoneTopInset)
                    .safeAreaPadding(.top)
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
            inkColors: $inkColors,
            inkWidths: $inkWidths,
            eraserType: $eraserType,
            eraserWidth: $eraserWidth,
            magicAction: $magicAction,
            isMagicProcessing: isMagicProcessing,
            dock: $toolbarDock,
            dragPreviewDock: $dragPreviewDock,
            containerSize: geometry.size,
            onInsertImage: { showingPhotosPicker = true },
            onInsertPDF: { pdfPickerTarget = .notePages; showingPDFPicker = true },
            onInsertPDFFromWebeep: { webeepPickerTarget = .notePages; showingWebeepDocPicker = true },

        )
        .padding(.bottom, 8)
        // In alto la barra condivide la riga con i controlli agli angoli:
        // si centra nello spazio LIBERO tra il pulsante indietro e la
        // barra a destra, invece che sull'intera larghezza. Centrandola
        // sullo schermo, in verticale finiva sotto i pulsanti d'angolo e
        // se li rubava a vicenda.
        .padding(.leading, toolbarDock == .top ? 64 : 8)
        .padding(.trailing, toolbarDock == .top ? 216 : 8)
        .padding(.top, toolbarDock == .top ? 8 + phoneTopInset : 8)
        .safeAreaPadding(.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: toolbarDock.alignment)
    }

    // L'editor ignora la safe area (il foglio deve arrivare ai bordi), e
    // su iPad andava bene anche per i controlli. Su iPhone però la
    // Dynamic Island copriva undo/strumenti: i controlli fissi in alto
    // scendono sotto di lei.
    private var phoneTopInset: CGFloat { DeviceLayout.isPhone ? 48 : 0 }

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

    // Il titolo non compare più sul foglio mentre scrivi: si rinomina
    // dal menu della barra in alto a destra.

    // Barra fissa in alto a destra (non si sposta con la floatbar della
    // penna): annulla/ripeti, strumenti/widget, ricerca, impostazioni.
    private var topRightToolbar: some View {
        HStack(spacing: 2) {
            // "Avanti/indietro" come azione (annulla/ripeti), non come
            // scorrimento tra pagine — quello resta nelle miniature delle
            // impostazioni foglio.
            Button(action: drawingController.undo) {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .disabled(drawingController.pagedContainer != nil && !drawingController.canUndo)
            .opacity(drawingController.pagedContainer != nil && !drawingController.canUndo ? 0.35 : 1)
            .accessibilityLabel("Annulla")

            Button(action: drawingController.redo) {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .disabled(drawingController.pagedContainer != nil && !drawingController.canRedo)
            .opacity(drawingController.pagedContainer != nil && !drawingController.canRedo ? 0.35 : 1)
            .accessibilityLabel("Ripeti")

            Divider().frame(height: 20)

            Button {
                showingToolsPicker = true
            } label: {
                Image(systemName: "square.grid.2x2.fill")
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Strumenti")
            .popover(isPresented: $showingToolsPicker) {
                ToolsPickerSheet { tool in
                    showingToolsPicker = false
                    openSidePanel(tool)
                }
                // Su iPad (anche in Split View) resta il popover a
                // cascata; su iPhone un popover largo 680pt non esiste:
                // meglio lo sheet coi detent. I detent sugli altri
                // dispositivi vengono semplicemente ignorati.
                .presentationCompactAdaptation(DeviceLayout.isPhone ? .sheet : .popover)
                .presentationDetents([.medium, .large])
            }

            Button {
                showingSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
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
                .presentationCompactAdaptation(DeviceLayout.isPhone ? .sheet : .popover)
                .presentationDetents([.medium, .large])
            }

            Menu {
                Button {
                    renameText = note.title
                    showingRename = true
                } label: {
                    Label("Rinomina nota", systemImage: "textformat")
                }
                Button {
                    showingSettings = true
                } label: {
                    Label("Impostazioni foglio", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Impostazioni e rinomina")
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(DesignColor.textPrimary)
        .buttonStyle(.plain)
        // Ogni voce diventa un bersaglio quadrato pieno invece della sola
        // icona: prima l'area sensibile era grande quanto il glifo e
        // mancare il tocco era la norma.
        .padding(.horizontal, DesignSpace.s2)
        .frame(height: headerRowHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous).stroke(DesignColor.borderDefault.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 3)
    }

    // Inizio verticale della pagina attualmente visibile, per inserire i
    // nuovi elementi lì invece che sempre in cima al foglio.
    private var currentPageTop: Double {
        Double(drawingController.visibleContentRect?.minY ?? 0) + 60
    }

    private func insertTextBox(_ text: String, at rect: CGRect) {
        let before = note.textBoxes
        var box = NoteTextBox(x: rect.minX, y: rect.maxY + 12)
        box.text = text
        note.textBoxes.append(box)
        note.updatedAt = .now
        // Aggiunta/rimozione pura: il sync per ID del canvas basta, non
        // serve riscrivere frame di caselle esistenti.
        drawingController.recordChange("Casella di testo", from: before, to: note.textBoxes) { boxes in
            note.textBoxes = boxes
            note.updatedAt = .now
        }
    }

    // Scatola col riferimento VIVO a un media: quando undo/redo lo
    // eliminano e lo ricreano, l'oggetto SwiftData rinasce con un'altra
    // identità, e i passi successivi della cronologia devono seguire
    // quella nuova — un riferimento diretto punterebbe a un morto.
    private final class MediaRef {
        var item: NoteMedia
        init(_ item: NoteMedia) { self.item = item }
    }

    // Ciò che serve per far rinascere un media identico (tranne l'identità).
    private struct MediaSnapshot {
        let x: Double, y: Double, width: Double, height: Double
        let kind: NoteMediaKind
        let data: Data
        let sourceText: String?

        init(_ item: NoteMedia) {
            x = item.x; y = item.y; width = item.width; height = item.height
            kind = item.kind; data = item.data; sourceText = item.sourceText
        }

        func make() -> NoteMedia {
            NoteMedia(x: x, y: y, width: width, height: height, kind: kind, data: data, sourceText: sourceText)
        }
    }

    // L'aggancio dei media passa dal lato GENITORE (media.append), mai
    // solo da item.note: la mutazione fatta sul solo lato figlio può non
    // notificare l'osservazione di `media` — trappola documentata su
    // Note.attach in Models.swift.
    private func recordMediaLifecycle(_ name: String, ref: MediaRef, snapshot: MediaSnapshot, inserted: Bool) {
        let remove = { [context] in
            context.delete(ref.item)
            note.updatedAt = .now
        }
        let restore = { [context] in
            let reborn = snapshot.make()
            context.insert(reborn)
            note.media.append(reborn)
            ref.item = reborn
            note.updatedAt = .now
        }
        drawingController.record(name, undo: inserted ? remove : restore, redo: inserted ? restore : remove)
    }

    private func insertMedia(kind: NoteMediaKind, data: Data) {
        let offset = Double(note.media.count % 6) * 24
        let item = NoteMedia(x: 60 + offset, y: currentPageTop + offset, kind: kind, data: data)
        context.insert(item)
        note.media.append(item)
        note.updatedAt = .now
        recordMediaLifecycle("Inserimento", ref: MediaRef(item), snapshot: MediaSnapshot(item), inserted: true)
    }

    private func deleteMedia(_ item: NoteMedia) {
        let snapshot = MediaSnapshot(item)
        let ref = MediaRef(item)
        context.delete(item)
        note.updatedAt = .now
        recordMediaLifecycle("Eliminazione", ref: ref, snapshot: snapshot, inserted: false)
    }

    // Ripristino del contenuto di una formula (undo/redo): per ID
    // persistente, come i frame dei media — su un oggetto morto è no-op.
    private func applyFormulaContent(id: PersistentIdentifier, data: Data, sourceText: String?) {
        guard let item = note.media.first(where: { $0.persistentModelID == id }) else { return }
        item.data = data
        item.sourceText = sourceText
        note.updatedAt = .now
    }

    // Scatola per le pagine importate da un PDF: come MediaRef, segue le
    // identità nuove quando un redo le ricrea.
    private final class PagesRef {
        var pages: [NotePage] = []
    }

    // Import di un PDF come pagine della nota, registrato in cronologia.
    // L'annulla elimina ESATTAMENTE le pagine aggiunte da questo import
    // (diff sugli ID persistenti), il ripeti le ricrea dagli stessi byte.
    private func appendPDFPagesRecorded(_ data: Data) {
        let before = Set(note.pages.map(\.persistentModelID))
        guard note.appendPages(fromPDF: data, in: context) else {
            // È il caso per cui appendPages ritorna un Bool: byte che non
            // sono un PDF (per esempio una pagina di errore scaricata al
            // posto del file). Prima veniva ignorato e sembrava che
            // l'import non facesse niente.
            pdfImportError = "Il file non è un PDF leggibile: è danneggiato, o non è un vero PDF."
            return
        }
        note.updatedAt = .now
        let ref = PagesRef()
        ref.pages = note.pages.filter { !before.contains($0.persistentModelID) }
        guard !ref.pages.isEmpty else { return }
        drawingController.record("Import PDF", undo: { [context] in
            ref.pages.forEach(context.delete)
            note.updatedAt = .now
        }, redo: { [context] in
            let existing = Set(note.pages.map(\.persistentModelID))
            note.appendPages(fromPDF: data, in: context)
            ref.pages = note.pages.filter { !existing.contains($0.persistentModelID) }
            note.updatedAt = .now
        })
    }

    // Scrive colori/spessori scelti alla chiusura della nota (un solo
    // punto di salvataggio: otto onChange separati mandavano in timeout
    // il type-checker di SwiftUI).
    private func saveToolPreferences() {
        var colors: [String: String] = [:]
        var widths: [String: Double] = [:]
        for tool in PenTool.inkTools {
            if let hex = (inkColors[tool] ?? tool.defaultColor).hexString {
                colors[tool.rawValue] = hex
            }
            widths[tool.rawValue] = Double(inkWidths[tool] ?? tool.defaultWidth)
        }
        if let data = try? JSONEncoder().encode(StoredInkSettings(colors: colors, widths: widths)),
           let string = String(data: data, encoding: .utf8) {
            storedInkSettings = string
        }
        storedEraserType = eraserType == .vector ? "vector" : "bitmap"
        storedEraserWidth = eraserWidth
        storedSelectedTool = selectedTool.rawValue
    }

    // Rilegge colori/spessori salvati all'apertura della nota. Uno
    // strumento mai configurato prende i propri default: è anche il
    // caso di chi aggiorna l'app e si ritrova i nuovi inchiostri.
    private func restoreToolPreferences() {
        let stored = storedInkSettings.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(StoredInkSettings.self, from: $0) }
        for tool in PenTool.inkTools {
            if let hex = stored?.colors[tool.rawValue], let color = Color(hexString: hex) {
                inkColors[tool] = color
            } else {
                inkColors[tool] = tool.defaultColor
            }
            // Uno spessore salvato può stare fuori dall'intervallo valido
            // dell'inchiostro (per esempio una matita a 1, da prima che
            // gli intervalli venissero presi da PencilKit): si riporta
            // dentro, altrimenti lo slider mostrerebbe un numero che il
            // tratto non rispetta.
            let range = tool.widthRange
            let width = stored?.widths[tool.rawValue].map { CGFloat($0) } ?? tool.defaultWidth
            inkWidths[tool] = min(max(width, range.lowerBound), range.upperBound)
        }
        eraserType = storedEraserType == "vector" ? .vector : .bitmap
        eraserWidth = storedEraserWidth
        if let tool = PenTool(rawValue: storedSelectedTool) {
            selectedTool = tool
        }
    }

    // MARK: - Strumenti temporanei (gomma, Apple Pencil)

    // Dopo un tratto di gomma, torna automaticamente allo strumento
    // usato prima (penna/matita/evidenziatore), come richiesto.
    private func handleEraseStrokeCompleted() {
        guard selectedTool == .eraser, let previous = toolBeforeEraser else { return }
        selectedTool = previous
        toolBeforeEraser = nil
    }

    // Dopo uno spostamento (o un'eliminazione) col lasso, torna allo
    // strumento di prima: stessa meccanica della gomma.
    private func handleLassoFinished() {
        guard selectedTool == .lasso, let previous = toolBeforeLasso else { return }
        selectedTool = previous
        toolBeforeLasso = nil
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
        // Un uso e via: senza, restava attiva e un tocco successivo
        // veniva letto come un altro cerchio invece che tornare a disegnare.
        magicAction = nil
        isMagicProcessing = true
        Task {
            defer { isMagicProcessing = false }
            // Riconoscimento: se il provider AI selezionato legge le
            // immagini (Gemini/Claude), l'inchiostro va DIRETTO al modello
            // — molto più affidabile di Vision OCR sulla notazione
            // matematica (frazioni, esponenti, integrali). Vision resta il
            // fallback istantaneo/offline e l'unico col modello Apple locale.
            var recognizedText: String?
            var aiRecognized = false
            var cloudFailureReason: String?
            let transcriptionPrompt = action == .latex
                ? "Trascrivi la matematica scritta a mano in questa immagine in codice LaTeX valido. Rispondi SOLO con il codice LaTeX, senza delimitatori $ né spiegazioni."
                : "Trascrivi esattamente ciò che è scritto a mano in questa immagine. Se contiene notazione matematica, trascrivila in testo lineare comprensibile da Wolfram Alpha (esempi: 'integrate x^2 dx from 0 to 1', 'solve x^2+3x-2=0'); se è una semplice funzione di x, scrivila come espressione (es. 'x^2 - 9'). Rispondi SOLO con la trascrizione, senza commenti né virgolette."
            switch await AIService.generate(prompt: transcriptionPrompt, image: image) {
            case .success(let text):
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    recognizedText = cleaned
                    aiRecognized = true
                }
            case .failure(let error):
                // Il motivo del fallback (quota finita, chiave non valida,
                // rete...) va mostrato, non inghiottito.
                if AIService.selectedProvider != .appleLocal {
                    cloudFailureReason = error.message
                }
            }
            if recognizedText == nil {
                recognizedText = await MagicPenService.recognizeText(in: image)
            }
            let via: String
            if aiRecognized {
                via = "\(AIService.selectedProvider.label) · cloud"
            } else if let cloudFailureReason {
                via = "Vision · locale (\(AIService.selectedProvider.label): \(cloudFailureReason))"
            } else {
                via = "Vision · locale"
            }

            guard let text = recognizedText, !text.isEmpty else {
                var result = MagicResult(action: action, recognizedText: nil, captureRect: rect)
                result.recognizedVia = via
                result.errorMessage = "Non sono riuscito a riconoscere la scrittura. Prova a scrivere più in stampatello e cerchia di nuovo."
                magicResult = result
                return
            }

            if let result = await processMagic(action: action, text: text, latexAlreadyConverted: aiRecognized && action == .latex, rect: rect, via: via) {
                magicResult = result
            }
        }
    }

    // Esegue l'azione della penna magica su un testo già riconosciuto (o
    // corretto a mano dall'utente nel foglio dei risultati). Restituisce
    // nil per le azioni senza foglio (Cerca apre il browser e basta).
    private func processMagic(action: MagicAction, text: String, latexAlreadyConverted: Bool, rect: CGRect, via: String?) async -> MagicResult? {
        var result = MagicResult(action: action, recognizedText: text, captureRect: rect)
        result.recognizedVia = via

        switch action {
        case .wolfram:
            // Dal Keychain via AIService, l'unico punto di accesso (era
            // una lettura a mano di UserDefaults con la chiave duplicata).
            let appID = AIService.wolframAppID ?? ""
            if appID.isEmpty {
                result.errorMessage = "Aggiungi la tua chiave Wolfram Alpha nel Profilo per usare questa funzione."
            } else {
                switch await MagicPenService.queryWolfram(text: text, appID: appID) {
                case .success(let wolframResult):
                    result.resultText = wolframResult.text
                    result.resultImageURLs = wolframResult.imageURLs
                case .failure(let reason):
                    result.errorMessage = "Wolfram Alpha: \(reason.message)"
                }
            }

        case .draw:
            if (try? MathExpression(text)) != nil {
                result.graphExpression = text
            } else {
                result.errorMessage = "Non sono riuscito a interpretare un'espressione matematica valida da \"\(text)\"."
            }

        case .latex:
            if latexAlreadyConverted {
                // Il modello vision ha già trascritto direttamente in
                // LaTeX: nessuna seconda conversione (che ripartirebbe
                // dal testo lineare, reintroducendo errori).
                result.resultText = text
            } else {
                switch await AIService.generate(prompt: MagicPenService.latexPrompt(for: text), purpose: .reading) {
                case .success(let reply):
                    result.resultText = MagicPenService.cleanLaTeX(reply.text)
                case .failure(let error):
                    result.errorMessage = error.message
                }
            }

        case .explain:
            // Passa da AIService come il resto dell'app: usa il provider
            // che l'utente ha davvero scelto (Apple locale, Gemini o
            // Claude) invece di tentare solo il locale, e riporta il
            // motivo vero dell'errore (quota, chiave, rete).
            switch await AIService.generate(prompt: MagicPenService.explainPrompt(for: text)) {
            case .success(let reply):
                result.resultText = reply.text
            case .failure(let error):
                result.errorMessage = error.message
            }

        case .search:
            if let url = MagicPenService.searchURL(for: text) {
                openURL(url)
            }
            return nil
        }

        return result
    }

    // `toPanel`: il risultato apre lo strumento corrispondente nel
    // pannello laterale (precompilato) — i widget sul foglio non
    // esistono più.
    private func insertMagicResult(_ result: MagicResult, toPanel: Bool = false) {
        switch result.action {
        case .draw:
            if let expression = result.graphExpression {
                panelGraphExpression = expression
                openSidePanel(.graphing)
            }
        case .wolfram where toPanel:
            panelWolframPrefill = result.recognizedText
            openSidePanel(.wolfram)
        case .latex:
            // Sul foglio va la formula COMPOSTA, non il codice sorgente:
            // il LaTeX grezzo si copia col pulsante apposta. Se la
            // composizione fallisce si ripiega sul testo, così l'inserimento
            // non diventa un tocco a vuoto.
            guard let text = result.resultText else { break }
            let rect = result.captureRect
            Task { @MainActor in
                if let image = await LaTeXImageRenderer.image(for: text),
                   let data = image.pngData() {
                    let item = NoteMedia(
                        x: rect.minX,
                        y: rect.maxY + 12,
                        width: Double(image.size.width),
                        height: Double(image.size.height),
                        kind: .formula,
                        data: data,
                        // Il sorgente resta attaccato all'immagine: è ciò
                        // che permette di riaprirla e correggerla.
                        sourceText: text
                    )
                    context.insert(item)
                    note.media.append(item)
                    note.updatedAt = .now
                    recordMediaLifecycle("Formula", ref: MediaRef(item), snapshot: MediaSnapshot(item), inserted: true)
                } else {
                    insertTextBox(text, at: rect)
                }
            }
        case .wolfram, .explain:
            if let text = result.resultText {
                insertTextBox(text, at: result.captureRect)
            }
        case .search:
            break
        }
    }
}
