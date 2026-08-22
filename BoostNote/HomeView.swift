import SwiftUI
import SwiftData
import PencilKit
import UniformTypeIdentifiers

// Schermata Home, sul modello del mock dell'utente (2026-08-16):
// saluto + azioni compatte in alto a destra (Nota / Cartella / PDF),
// "Riprendi da dove eri" con le ultime note (miniatura vera, cartella
// colorata, tempo relativo) e "Da ripassare" — i ponti verso lo Studio:
// le flashcard pronte e gli esercizi sbagliati di recente.
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("profileName") private var profileName = ""
    @Binding var selectedNote: Note?
    // Ponti verso lo Studio: la Home non possiede quella navigazione,
    // la chiede alla radice.
    var onOpenStudyModule: (Study, StudyModule) -> Void = { _, _ in }
    var onOpenProgress: () -> Void = {}

    @Query(sort: \Note.updatedAt, order: .reverse) private var allNotes: [Note]
    @Query(sort: \Study.updatedAt, order: .reverse) private var studies: [Study]
    @Query(sort: \ExerciseAttempt.date, order: .reverse) private var attempts: [ExerciseAttempt]

    @State private var showingNoteCreate = false
    @State private var showingPDFImporter = false
    @State private var showingNewFolderSheet = false
    @State private var showingWebeepPDFPicker = false
    
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let base = hour < 12 ? "Buongiorno" : (hour < 18 ? "Buon pomeriggio" : "Buonasera")
        let trimmedName = profileName.trimmingCharacters(in: .whitespaces)
        return trimmedName.isEmpty ? base : "\(base), \(trimmedName)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpace.s8) {
                header

                if !allNotes.isEmpty {
                    resumeSection
                }

                reviewSection

                if allNotes.isEmpty {
                    emptyState
                }
            }
            .padding(DesignSpace.s6)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DesignColor.surfacePage)
        .navigationTitle("")
        .sheet(isPresented: $showingNoteCreate) {
            NoteCreateSheet(preselectedFolder: nil) { note in
                selectedNote = note
            }
        }
        .sheet(isPresented: $showingNewFolderSheet) {
            FolderEditSheet(mode: .new(parent: nil)) { name, color, mode in
                guard case .new(let parent) = mode else { return }
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                context.insert(Folder(name: trimmed, parent: parent, color: color))
            }
        }
        .sheet(isPresented: $showingWebeepPDFPicker) {
            WebeepFilePickerSheet { data, name in
                importPDFNote(data: data, title: (name as NSString).deletingPathExtension)
            }
        }
        .fileImporter(isPresented: $showingPDFImporter, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                BoostToastCenter.shared.show("Non riesco a leggere \"\(url.lastPathComponent)\": se sta su un cloud, aprilo prima nell'app File.", role: .danger)
                return
            }
            importPDFNote(data: data, title: url.deletingPathExtension().lastPathComponent)
        }
    }

    // Una nota nuova con il PDF come pagine, qualunque sia la fonte.
    // `appendPages` ritorna false quando i byte non sono un PDF valido:
    // ignorarlo (com'era) creava una nota vuota senza spiegazioni — il
    // motivo per cui quel Bool esiste (vedi Models.swift).
    private func importPDFNote(data: Data, title: String) {
        let note = Note(title: title.isEmpty ? "Nuova nota" : title, folder: nil)
        context.insert(note)
        guard note.appendPages(fromPDF: data, in: context) else {
            context.delete(note)
            BoostToastCenter.shared.show("\"\(title)\" non è un PDF leggibile.", role: .danger)
            return
        }
        selectedNote = note
    }

    // MARK: - Testata

    // Saluto a sinistra, azioni COMPATTE a destra: le tre card grandi
    // spingevano in basso il contenuto vero (le note e i ripassi).
    @ViewBuilder
    private var header: some View {
        // Saluto e azioni sulla stessa riga solo se ci stanno DAVVERO.
        //
        // Prima la scelta era su `horizontalSizeClass`, ed è il segnale
        // sbagliato: descrive il dispositivo, non la colonna in cui vive
        // questa intestazione. Un iPad in verticale con la barra laterale
        // aperta resta `.regular` pur lasciando al contenuto una larghezza
        // da iPhone — si prendeva il ramo affiancato, i tre pulsanti non si
        // comprimono, e l'unico elemento comprimibile (il testo del saluto)
        // finiva a UN CARATTERE PER RIGA. Stesso sintomo che il commento
        // qui sopra descriveva per i pulsanti su iPhone: la causa era la
        // stessa, la diagnosi no.
        //
        // `ViewThatFits` misura lo spazio disponibile invece di dedurlo dal
        // dispositivo: prova la riga singola e, se non entra, impila. Perché
        // funzioni il saluto NON deve essere comprimibile (vedi il
        // `fixedSize` in `greetingBlock`), altrimenti la prima variante
        // "entra" sempre schiacciandolo.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DesignSpace.s4) {
                greetingBlock
                Spacer(minLength: DesignSpace.s4)
                headerActions
            }
            VStack(alignment: .leading, spacing: DesignSpace.s4) {
                greetingBlock
                // Le tre azioni insieme superano i ~400pt di un iPhone:
                // la riga scorre invece di schiacciare i pulsanti.
                ScrollView(.horizontal, showsIndicators: false) {
                    headerActions
                }
                .scrollClipDisabled()
            }
        }
    }

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(DesignFont.screenTitle)
                .foregroundStyle(DesignColor.textPrimary)
                // Non comprimibile: è ciò che permette a `ViewThatFits` di
                // accorgersi che la riga singola non entra, invece di farla
                // entrare a forza mandando a capo ogni lettera.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(Date.now.formatted(date: .long, time: .omitted))
                .font(DesignFont.body)
                .foregroundStyle(DesignColor.textTertiary)
        }
    }

    // Design system dei colori (2026-08-16): UNA sola azione
    // blu per schermata — è quella che il blu deve indicare.
    // Le organizzative (cartella, import) sono neutre bordate.
    private var headerActions: some View {
        HStack(spacing: DesignSpace.s2) {
            headerAction(title: "Nuova nota", icon: "square.and.pencil", tint: DesignColor.brandPrimary) { showingNoteCreate = true }
            headerAction(title: "Nuova cartella", icon: "folder.badge.plus", tint: nil) { showingNewFolderSheet = true }
            // Il PDF entra da TUTTE le fonti dell'app, non solo dai
            // file: stesso paio di porte del Vault e dello Studio.
            Menu {
                Button {
                    showingPDFImporter = true
                } label: {
                    Label("Dai file", systemImage: "folder")
                }
                Button {
                    showingWebeepPDFPicker = true
                } label: {
                    Label("Da WeBeep", systemImage: "graduationcap")
                }
            } label: {
                headerActionLabel(title: "Importa PDF", icon: "doc.badge.plus", tint: nil)
            }
            .buttonStyle(.plain)
        }
    }

    // Stesso vestito dei pulsanti della testata Studio ("Nuovo Vault").
    // tint nil = azione secondaria: neutra, col bordo — presente ma non
    // protagonista (il blu resta l'unica guida della schermata).
    private func headerAction(title: String, icon: String, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            headerActionLabel(title: title, icon: icon, tint: tint)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func headerActionLabel(title: String, icon: String, tint: Color?) -> some View {
        let label = Label(title, systemImage: icon)
            .font(DesignFont.action)
            // Mai a capo: se lo spazio manca, il pulsante non si spezza
            // lettera per lettera (successo su iPhone).
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, DesignSpace.s3)
            .padding(.vertical, DesignSpace.s2)
        if let tint {
            label
                .foregroundStyle(tint)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
        } else {
            label
                .foregroundStyle(DesignColor.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                        .strokeBorder(DesignColor.borderDefault, lineWidth: 1)
                )
        }
    }

    // MARK: - Riprendi da dove eri

    private var resumeSection: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            Text("RIPRENDI DA DOVE ERI")
                .font(DesignFont.micro)
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)

            VStack(spacing: 0) {
                ForEach(Array(allNotes.prefix(4).enumerated()), id: \.element.persistentModelID) { index, note in
                    Button {
                        selectedNote = note
                    } label: {
                        resumeRow(note)
                    }
                    .buttonStyle(.plain)
                    if index < min(allNotes.count, 4) - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func resumeRow(_ note: Note) -> some View {
        HStack(spacing: DesignSpace.s4) {
            NoteThumbnail(note: note)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 5) {
                Text(note.title.isEmpty ? "Senza titolo" : note.title)
                    .font(DesignFont.cardTitle)
                    .foregroundStyle(DesignColor.textPrimary)
                    .lineLimit(1)
                HStack(spacing: DesignSpace.s2) {
                    if let folder = note.folder {
                        folderChip(folder)
                    }
                    Text(relativeTime(note.updatedAt))
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: DesignIcon.sm))
                .foregroundStyle(DesignColor.textTertiary)
        }
        .padding(.vertical, DesignSpace.s3)
        .contentShape(Rectangle())
    }

    private func folderChip(_ folder: Folder) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                .fill(folder.folderColor.color)
                .frame(width: 9, height: 9)
            Text(folder.name)
                .font(DesignFont.caption)
                .foregroundStyle(folder.folderColor.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(folder.folderColor.color.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.unitsStyle = .short
        // "Modificata ieri" suona da persona; "modificata 2 gg fa" da log.
        // Il formatter di sistema fa già il lavoro giusto.
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    // MARK: - Da ripassare

    // I ponti verso lo Studio, mostrati SOLO quando i dati esistono
    // davvero: niente card finte con numeri inventati.
    private var flashcardSuggestion: (study: Study, module: StudyModule, count: Int)? {
        for study in studies {
            for module in study.sortedModules where module.kind == .flashcards && module.status == .ready {
                let count = module.decodeContent(FlashcardsContent.self)?.cards.count ?? 0
                if count > 0 { return (study, module, count) }
            }
        }
        return nil
    }

    private var recentWrongCount: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        return attempts.prefix(while: { $0.date >= weekAgo }).filter { !$0.isCorrect }.count
    }

    @ViewBuilder
    private var reviewSection: some View {
        let flashcards = flashcardSuggestion
        let wrong = recentWrongCount
        if flashcards != nil || wrong > 0 {
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                Text("DA RIPASSARE")
                    .font(DesignFont.micro)
                    .tracking(0.6)
                    .foregroundStyle(DesignColor.textTertiary)

                if let flashcards {
                    reviewCard(
                        icon: "rectangle.on.rectangle",
                        tint: DesignColor.review,
                        title: "\(flashcards.count) carte da rivedere",
                        subtitle: flashcards.study.name,
                        buttonLabel: "Ripassa"
                    ) {
                        onOpenStudyModule(flashcards.study, flashcards.module)
                    }
                }

                if wrong > 0 {
                    reviewCard(
                        icon: "pencil.line",
                        tint: DesignColor.attention,
                        title: "\(wrong) esercizi sbagliati di recente",
                        subtitle: "riprova sugli argomenti deboli degli ultimi 7 giorni",
                        buttonLabel: "Riprova"
                    ) {
                        onOpenProgress()
                    }
                }
            }
        }
    }

    private func reviewCard(icon: String, tint: Color, title: String, subtitle: String, buttonLabel: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: DesignSpace.s4) {
            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                .fill(tint.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: DesignIcon.md))
                        .foregroundStyle(tint)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignFont.cardTitle)
                    .foregroundStyle(DesignColor.textPrimary)
                Text(subtitle)
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignSpace.s3)
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(buttonLabel)
                        .font(DesignFont.cardTitle)
                    Image(systemName: "chevron.right")
                        .font(.system(size: DesignIcon.sm))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, DesignSpace.s4)
                .padding(.vertical, DesignSpace.s2 + 2)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(DesignSpace.s4)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }

    private var emptyState: some View {
        BoostState(
            kind: .empty,
            icon: "square.and.pencil",
            title: "Ancora nessuna nota",
            message: "Crea una nota o aggiungi un PDF su cui scrivere: i pulsanti sono qui sopra."
        )
        .padding(.vertical, DesignSpace.s8)
    }
}

// Miniatura VERA della prima pagina della nota: l'inchiostro composto su
// bianco, in piccolo. Il mock la mostrava, e ha ragione: si riconosce la
// propria calligrafia prima ancora di leggere il titolo. Il rendering è
// fuori dal main thread e parte solo quando la riga appare.
private struct NoteThumbnail: View {
    let note: Note

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                .fill(Color.white)
            if let image {
                // Color.clear.overlay + clipped: scaledToFill da solo
                // SBORDA dal riquadro (l'inchiostro finiva sopra la
                // lista) — l'overlay lo costringe nei 64 punti proposti.
                Color.clear
                    .overlay(
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    )
                    .clipped()
            } else {
                // Segnaposto: righe di quaderno, come le card di prima.
                VStack(spacing: 7) {
                    ForEach(0..<4, id: \.self) { _ in
                        Rectangle().fill(DesignColor.borderSubtle).frame(height: 1)
                    }
                }
                .padding(9)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                .stroke(DesignColor.borderDefault, lineWidth: 1)
        )
        .task(id: note.updatedAt) {
            image = await Self.render(note: note)
        }
    }

    private static func render(note: Note) async -> UIImage? {
        // Solo il disegno della prima pagina: è la firma visiva della
        // nota, e tenere leggera questa miniatura conta più della
        // completezza.
        let data = note.pages.isEmpty
            ? note.drawingData
            : note.sortedPages.first?.drawingData
        guard let data else { return nil }
        return await Task.detached(priority: .utility) { () -> UIImage? in
            guard let drawing = try? PKDrawing(data: data) else { return nil }
            let bounds = drawing.bounds
            guard bounds.width > 1, bounds.height > 1 else { return nil }
            let side = max(bounds.width, bounds.height)
            let scale = min(1, 256 / side)
            let ink = drawing.image(from: bounds, scale: scale)
            // Su bianco, come sul foglio: l'immagine di PencilKit ha lo
            // sfondo trasparente (stessa trappola dell'OCR).
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                ink.draw(in: CGRect(origin: .zero, size: size))
            }
        }.value
    }
}
