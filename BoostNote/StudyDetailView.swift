import SwiftUI
import SwiftData

// Dettaglio di uno studio: materiali sorgente, card dei moduli generati
// (con stato di generazione) e apertura dei singoli moduli.
struct StudyDetailView: View {
    @Environment(\.modelContext) private var context
    let study: Study
    // Modulo aperto a tutta area (player esercizi, flashcard, ecc.):
    // arriva dall'albero nella barra laterale, così toccare "Flashcard"
    // lì apre direttamente il mazzo.
    @Binding var openModule: StudyModule?
    var onBack: () -> Void
    var onDelete: () -> Void

    @State private var showingTrustSheet = false
    @State private var showingDeleteConfirmation = false
    // Avvisi dei moduli aperti nel dettaglio (vedi infoDisclosure).
    @State private var expandedInfo: Set<UUID> = []

    var body: some View {
        Group {
            if let openModule, openModule.status == .ready {
                moduleViewer(openModule)
            } else {
                overview
            }
        }
        .sheet(isPresented: $showingTrustSheet) {
            StudioTrustSheet(study: study)
        }
        .alert("Eliminare lo studio?", isPresented: $showingDeleteConfirmation) {
            Button("Elimina", role: .destructive, action: onDelete)
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("“\(study.name)”, i suoi moduli generati e i tentativi registrati nell'analisi dei progressi verranno eliminati.")
        }
        // L'esito della verifica è scritto una volta sola, alla
        // generazione: senza un ricontrollo, un contenuto marcato "non
        // verificato" da un confronto troppo severo resterebbe tale per
        // sempre. Il lavoro pesante gira fuori dal MainActor (vedi
        // reverifyCitations): qui si aspetta e basta.
        .task(id: study.id) {
            await StudioGenerationService.reverifyCitations(in: study)
        }
    }

    // MARK: - Panoramica

    private var overview: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpace.s3) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Torna a Studio")

                VStack(alignment: .leading, spacing: 1) {
                    Text(study.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)
                    Text(study.subjectOrPlaceholder + " · creato il " + study.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textTertiary)
                }
                Spacer()
                Button {
                    showingTrustSheet = true
                } label: {
                    Label("Come funziona", systemImage: "info.circle")
                        .fixedSize()
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignColor.brandPrimary)
                }
                .buttonStyle(.plain)

                Menu {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Elimina studio", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(DesignColor.textSecondary)
                }
            }
            .padding(.horizontal, DesignSpace.s6 + 4)
            .frame(height: 56)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DesignColor.borderDefault).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpace.s6) {
                    if !study.materials.isEmpty {
                        VStack(alignment: .leading, spacing: DesignSpace.s2) {
                            Text("MATERIALI")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(DesignColor.textTertiary)
                            VStack(spacing: 1) {
                                ForEach(study.materials) { material in
                                    materialRow(material)
                                }
                            }
                            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
                        }
                    } else if !study.sources.isEmpty {
                        VStack(alignment: .leading, spacing: DesignSpace.s2) {
                            Text("MATERIALI")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(DesignColor.textTertiary)
                            FlowChips(items: study.sources.map { source in
                                (source.title, source.isExamPaper ? DesignColor.attention : DesignColor.textSecondary)
                            })
                        }
                    }

                    // Righe a TUTTA larghezza, non griglia: i moduli sono
                    // 2-4 e le loro righe di stato sono diventate ricche
                    // (provider, scarti, avvisi col dettaglio a scomparsa).
                    // In colonne da ~300pt il testo andava a capo parola
                    // per parola e le card diventavano strisce — con
                    // altezze diverse che sfalsavano l'intera griglia.
                    VStack(spacing: DesignSpace.s4) {
                        ForEach(study.sortedModules) { module in
                            moduleCard(module)
                        }
                    }
                }
                .padding(DesignSpace.s6)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // Quanto testo è stato davvero letto da ogni materiale: è ciò che
    // distingue "ho generato dalle tue dispense" da "ho generato dal
    // titolo delle tue dispense", e va detto prima di leggere i moduli.
    private func materialRow(_ material: StudyMaterial) -> some View {
        HStack(spacing: DesignSpace.s3) {
            Image(systemName: material.kind.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(material.hasText ? DesignColor.brandPrimary : DesignColor.textTertiary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(material.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignColor.textPrimary)
                    .lineLimit(1)
                if let error = material.extractionError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.attention)
                } else {
                    Text("\(material.extractedText.count) caratteri letti")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
            Spacer()
            if material.isExamPaper {
                Text("Tema d'esame")
                    .fixedSize()
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignColor.attention)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(DesignColor.attentionBg, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
            }
        }
        .padding(.horizontal, DesignSpace.s3 + 2)
        .padding(.vertical, DesignSpace.s3)
    }

    private func moduleCard(_ module: StudyModule) -> some View {
        let kind = module.kind
        // La card NON è più un Button: un Button dentro la label di un
        // altro Button non riceve i tocchi in modo affidabile — "Annulla"
        // e la freccia Rigenera apparivano ma il tocco lo mangiava la
        // card. L'onTapGesture sul contenitore, al contrario, cede per
        // costruzione la precedenza ai Button veri che contiene.
        return VStack(alignment: .leading, spacing: DesignSpace.s3) {
            innerCard(module, kind: kind)
        }
        .contentShape(RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
        .onTapGesture {
            if module.status == .ready { openModule = module }
        }
        .contextMenu {
            Button {
                regenerate(module)
            } label: {
                Label("Rigenera", systemImage: "arrow.clockwise")
            }
            if module.status == .generating {
                // Doppia via per l'annullamento: il bottone inline sulla
                // card e questa voce — se una delle due non fosse
                // raggiungibile, l'altra resta.
                Button(role: .destructive) {
                    StudioGenerationService.cancelGeneration(for: study.id)
                } label: {
                    Label("Annulla generazione", systemImage: "xmark.circle")
                }
            }
        }
    }

    private func innerCard(_ module: StudyModule, kind: StudyModuleKind?) -> some View {
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                // Il dettaglio espanso dell'avviso sta QUI SOTTO, a tutta
                // larghezza — non nella colonna del titolo, che dentro la
                // griglia è larga ~110pt: lì il testo andava a capo una
                // parola per riga e gonfiava la card in una striscia.
                headerRow(module, kind: kind)
                if expandedInfo.contains(module.id), module.status == .ready, let info = module.generationError {
                    Text(info)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.attention)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DesignSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }

    private func headerRow(_ module: StudyModule, kind: StudyModuleKind?) -> some View {
                HStack(spacing: DesignSpace.s3) {
                    RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                        .fill((kind?.color ?? DesignColor.textSecondary).opacity(0.12))
                        .frame(width: 38, height: 38)
                        .overlay(
                            Image(systemName: kind?.systemImage ?? "questionmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(kind?.color ?? DesignColor.textSecondary)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind?.label ?? module.kindRaw)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignColor.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        statusLine(module)
                    }
                    Spacer()
                    if module.status == .ready || module.status == .failed {
                        // Rigenera esplicito: prima era solo nel menu
                        // contestuale (tieni premuto) e non si scopriva.
                        // Sui moduli falliti è l'azione principale.
                        Button {
                            regenerate(module)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(DesignColor.textSecondary)
                                .frame(width: 30, height: 30)
                                .background(DesignColor.surfacePage, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rigenera modulo")

                        if module.status == .ready {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DesignColor.textTertiary)
                        }
                    }
                }
    }

    @ViewBuilder
    private func statusLine(_ module: StudyModule) -> some View {
        switch module.status {
        case .pending:
            Text("In coda…")
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textTertiary)
        case .generating:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    // Il testo vivo dice DOVE si è nella catena ("Provo
                    // gemini-flash-latest (3/5)…"): la stessa attesa,
                    // ma leggibile invece che cieca.
                    Text(GenerationProgress.shared.text[module.id] ?? "Generazione in corso…")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Annulla") {
                        StudioGenerationService.cancelGeneration(for: study.id)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignColor.danger)
                    .buttonStyle(.plain)
                }
                // Avviso messo PRIMA di partire (vedi generateModules):
                // se la quota buona è finita, meglio saperlo adesso che
                // scoprire esercizi più semplici a generazione conclusa.
                if let notice = module.generationError, !notice.isEmpty {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.textSecondary)
                        .lineLimit(3)
                }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Text("Generazione non riuscita")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignColor.danger)
                if let reason = module.generationError {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.textSecondary)
                        .lineLimit(4)
                }
                Text("Tocca la freccia circolare per riprovare.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignColor.textTertiary)
            }
        case .ready:
            VStack(alignment: .leading, spacing: 2) {
                Text(readySummary(module))
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textTertiary)
                // Con quale provider è stato generato questo contenuto.
                if module.generatedByRaw != "none" && module.generatedByRaw != "mock" {
                    Label("Generato con \(module.generatedByRaw)", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignColor.success)
                    // La verifica che scarta è più credibile di una che
                    // approva sempre: si dice quanto ha buttato.
                    if module.discardedCount > 0 {
                        Label("\(module.discardedCount) scartati dalla verifica", systemImage: "checkmark.shield")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                    if !module.reportedIDs.isEmpty {
                        Label("\(module.reportedIDs.count) segnalati da te", systemImage: "flag.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DesignColor.danger)
                    }
                    // Copertura parziale: la generazione è riuscita ma non
                    // ha visto tutto il materiale.
                    if let notice = module.generationError {
                        infoDisclosure(notice, icon: "scissors", moduleID: module.id)
                    }
                } else if let error = module.generationError {
                    infoDisclosure(error, icon: "exclamationmark.triangle", moduleID: module.id)
                }
            }
        }
    }

    // Avviso in due tempi (richiesta utente): chiuso mostra solo il succo
    // — la prima proposizione, tagliata al primo ":" o "." — e un tocco
    // apre tutto. Le note sono diventate dettagliate (pagine usate,
    // argomenti rimasti fuori, cosa fare) e per intero schiacciavano la
    // card; ma erano nate per essere lette, non per essere troncate coi
    // puntini. Così la card resta leggera e l'informazione resta intera.
    private func infoDisclosure(_ text: String, icon: String, moduleID: UUID) -> some View {
        let isExpanded = expandedInfo.contains(moduleID)
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                if isExpanded { expandedInfo.remove(moduleID) } else { expandedInfo.insert(moduleID) }
            }
        } label: {
            // Qui SEMPRE e solo il succo su una riga: il testo completo
            // compare sotto la riga della card, a tutta larghezza —
            // dentro questa colonna stretta andrebbe a capo una parola
            // per riga (visto succedere in orizzontale).
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(briefInfo(text))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(DesignColor.attention)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint(isExpanded ? "Comprimi" : "Mostra tutti i dettagli")
    }

    // La prima proposizione dell'avviso: fino al primo ":" o "." — le
    // note sono scritte apposta col succo davanti ("Il materiale supera
    // lo spazio di una generazione: …").
    private func briefInfo(_ text: String) -> String {
        guard let cut = text.firstIndex(where: { $0 == ":" || $0 == "." }) else { return text }
        let head = String(text[..<cut])
        return head.count < text.count ? head + "…" : head
    }

    private func readySummary(_ module: StudyModule) -> String {
        switch module.kind {
        case .summary:
            let count = module.decodeContent(SummaryContent.self)?.sections.count ?? 0
            return "\(count) sezioni"
        case .exercises:
            let exercises = module.decodeContent(ExerciseSetContent.self)?.exercises ?? []
            let verified = exercises.filter { $0.verification == .agreed }.count
            // La ripartizione teorici/pratici non si mostra più: sono
            // tutti da risolvere. Al suo posto un numero che dice
            // qualcosa che non si sa già — quanti hanno retto la seconda
            // risoluzione.
            return verified == 0
                ? "\(exercises.count) esercizi"
                : "\(exercises.count) esercizi, \(verified) verificati"
        case .reviewPoints:
            let count = module.decodeContent(ReviewPointsContent.self)?.points.count ?? 0
            return count == 1 ? "1 domanda" : "\(count) domande"
        case .flashcards:
            let count = module.decodeContent(FlashcardsContent.self)?.cards.count ?? 0
            return "\(count) carte"
        case nil:
            return "Tipo di modulo sconosciuto"
        }
    }

    private func regenerate(_ module: StudyModule) {
        // Se un giro è già in corso il registro ignorerebbe l'avvio, ma
        // il modulo resterebbe segnato .pending senza nessuno a
        // generarlo: la guardia va messa PRIMA di toccare lo stato.
        guard !StudioGenerationService.isGenerating(study.id) else { return }
        module.status = .pending
        StudioGenerationService.startGeneration(for: study, in: context)
    }

    // MARK: - Viewer dei moduli

    @ViewBuilder
    private func moduleViewer(_ module: StudyModule) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpace.s3) {
                Button {
                    openModule = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text(study.name)
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(DesignColor.textSecondary)
                }
                .buttonStyle(.plain)

                Spacer()
                if let kind = module.kind {
                    Label(kind.label, systemImage: kind.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(kind.color)
                }
            }
            .padding(.horizontal, DesignSpace.s6 + 4)
            .frame(height: 56)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DesignColor.borderDefault).frame(height: 1)
            }

            switch module.kind {
            case .summary:
                SummaryModuleView(content: module.decodeContent(SummaryContent.self) ?? SummaryContent(), module: module)
            case .exercises:
                ExercisesModuleView(
                    content: module.decodeContent(ExerciseSetContent.self) ?? ExerciseSetContent(),
                    study: study,
                    module: module
                )
            case .reviewPoints:
                ReviewPointsModuleView(
                    content: module.decodeContent(ReviewPointsContent.self) ?? ReviewPointsContent(),
                    module: module,
                    study: study
                )
            case .flashcards:
                FlashcardsModuleView(content: module.decodeContent(FlashcardsContent.self) ?? FlashcardsContent())
            case nil:
                ContentUnavailableView("Modulo non riconosciuto", systemImage: "questionmark")
            }
        }
    }
}

// MARK: - Componenti di verifica

// Mostra la citazione a supporto di un contenuto generato, con l'esito
// del confronto automatico col testo originale. È il modo in cui
// l'utente verifica "in un colpo d'occhio" invece di fidarsi: il
// passaggio si apre in linea, senza uscire dal contenuto.
struct CitationDisclosure: View {
    let citation: SourceCitation?
    // Cosa RAPPRESENTA la citazione, che cambia il senso di un mancato
    // ritrovamento. Su un riassunto o un punto di ripasso la citazione è
    // l'affermazione stessa: se non si ritrova, il contenuto è inventato
    // ed è un allarme. Su un esercizio NUOVO la citazione è solo il
    // passaggio a cui il modello si è ispirato — lì un mancato
    // ritrovamento significa "ha rielaborato invece di copiare", che è
    // esattamente ciò che gli abbiamo chiesto di fare.
    var meaning: Meaning = .claim

    enum Meaning {
        case claim        // il contenuto afferma questo passaggio
        case inspiration  // il contenuto si è ispirato a questo passaggio
    }

    @State private var expanded = false

    private var label: String {
        switch (meaning, citation?.verified ?? false) {
        // Su un esercizio nuovo NON si può dire "trovato nei materiali":
        // sembrerebbe che l'esercizio stesso sia stato copiato, mentre a
        // essere stato trovato è il passaggio da cui nasce. Sono due cose
        // diverse e vanno nominate diversamente.
        // "Fonte verificata" e non "Verificato" sugli esercizi inventati:
        // a essere verificato è il passaggio da cui nascono, non
        // l'esercizio, che è farina del modello.
        case (.inspiration, true): "Fonte verificata"
        case (.inspiration, false): "Fonte non verificata"
        case (.claim, true): "Verificato"
        case (.claim, false): "Non verificato"
        }
    }

    private var explanation: String {
        if meaning == .inspiration && citation?.verified == true {
            return "L'esercizio è nuovo — dati e contesto li ha scritti il modello — ma nasce da questo passaggio, che esiste davvero nei tuoi materiali."
        }
        // Con un `return` esplicito sopra, lo switch non è più l'ultima
        // espressione del getter: servono i return anche qui.
        switch meaning {
        case .claim:
            return "Questo passaggio non è stato ritrovato alla lettera nei tuoi materiali: verifica sul documento originale prima di fidarti."
        case .inspiration:
            return "Il modello non ha copiato un passaggio alla lettera: l'esercizio è farina sua, ispirata a questo materiale. Normale per un esercizio nuovo, ma i dati non sono verificati da un confronto col testo."
        }
    }

    private var tint: Color {
        if citation?.verified == true { return DesignColor.success }
        return meaning == .inspiration ? DesignColor.textSecondary : DesignColor.attention
    }

    private var tintBackground: Color {
        if citation?.verified == true { return DesignColor.successBg }
        return meaning == .inspiration ? DesignColor.surfaceSunken : DesignColor.attentionBg
    }

    var body: some View {
        if let citation {
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: citation.verified ? "checkmark.seal.fill" : (meaning == .inspiration ? "wand.and.stars" : "questionmark.circle"))
                            .font(.system(size: 11, weight: .semibold))
                        Text(label)
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, DesignSpace.s2 + 2)
                    .padding(.vertical, 4)
                    .background(tintBackground, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meaning == .inspiration ? "Passaggio di riferimento:" : "Passaggio citato:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignColor.textTertiary)
                        StudioRichText(text: citation.text, size: 12)
                        if let source = citation.sourceTitle {
                            Text("— \(source)")
                                .font(.system(size: 11))
                                .foregroundStyle(DesignColor.textTertiary)
                        }
                        if !citation.verified || meaning == .inspiration {
                            Text(explanation)
                                .font(.system(size: 11))
                                .foregroundStyle(tint)
                        }
                    }
                    .padding(DesignSpace.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                            .stroke(DesignColor.borderSubtle, lineWidth: 1)
                    )
                }
            }
        }
    }
}

// L'ultima rete, quella umana: segnala un contenuto sbagliato. Non manda
// niente da nessuna parte (local-first) — marca il contenuto e serve a
// ricordare all'utente cosa non tornava quando rigenererà.
struct ReportButton: View {
    let isReported: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isReported ? "flag.fill" : "flag")
                    .font(.system(size: 11, weight: .semibold))
                Text(isReported ? "Segnalato" : "Segnala errore")
                    .font(.system(size: 11, weight: .semibold))
            }
            .fixedSize()
            .foregroundStyle(isReported ? DesignColor.danger : DesignColor.textTertiary)
            .padding(.horizontal, DesignSpace.s2 + 2)
            .padding(.vertical, 4)
            .background(isReported ? DesignColor.dangerBg : Color.clear, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// Chips a capo automatico per i materiali (layout semplice su più righe).
private struct FlowChips: View {
    let items: [(String, Color)]

    var body: some View {
        // LazyVGrid adattivo: non è un vero flow layout ma va a capo da
        // solo e resta leggibile senza un Layout custom.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: DesignSpace.s2)], alignment: .leading, spacing: DesignSpace.s2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item.0)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(item.1)
                    .lineLimit(1)
                    .padding(.horizontal, DesignSpace.s2 + 2)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
            }
        }
    }
}

// MARK: - Riassunto

private struct SummaryModuleView: View {
    let content: SummaryContent
    let module: StudyModule

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpace.s5) {
                ForEach(content.sections) { section in
                    VStack(alignment: .leading, spacing: DesignSpace.s2) {
                        StudioRichText(text: section.title, size: 16, weight: .semibold, color: DesignColor.textPrimary)
                        StudioRichText(text: section.body)
                        HStack(spacing: DesignSpace.s2) {
                            CitationDisclosure(citation: section.quote)
                            Spacer()
                            ReportButton(isReported: module.isReported(section.id)) {
                                if module.isReported(section.id) {
                                    module.clearReport(section.id)
                                } else {
                                    module.report(section.id, reason: "")
                                }
                            }
                        }
                    }
                    .padding(DesignSpace.s5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                            .stroke(module.isReported(section.id) ? DesignColor.danger.opacity(0.5) : Color.clear, lineWidth: 1)
                    )
                }
            }
            .padding(DesignSpace.s6)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Esercizi
// Player un esercizio alla volta: soluzione guidata rivelata passo passo,
// poi autovalutazione (giusto/sbagliato) che registra un ExerciseAttempt
// — la sorgente dei dati per "Analisi dei progressi".
private struct ExercisesModuleView: View {
    @Environment(\.modelContext) private var context
    let content: ExerciseSetContent
    let study: Study
    let module: StudyModule

    // Scrive nel payload l'esito della compilazione della figura ("" =
    // fallita, non ritentare): la prossima apertura non ricompila.
    private func persistFigure(_ svg: String, for exerciseID: UUID) {
        guard var updated = module.decodeContent(ExerciseSetContent.self),
              let index = updated.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard updated.exercises[index].figureSVG != svg else { return }
        updated.exercises[index].figureSVG = svg
        module.encodeContent(updated)
    }

    // Verifica Wolfram, eseguita su richiesta alla rivelazione della
    // risposta: è un oracolo ESTERNO al modello, quindi vale molto più di
    // un'autovalutazione dell'AI. Chiave dal Keychain via AIService, che
    // è l'unico punto di accesso (era una @AppStorage in chiaro,
    // quintuplicata in giro per l'app).
    private var wolframAppID: String { AIService.wolframAppID ?? "" }
    // Risultati Wolfram PER ESERCIZIO: con un solo valore condiviso, la
    // verifica di un esercizio restava visibile passando al successivo,
    // facendo sembrare verificato un risultato che non lo era.
    // Esercizio per cui è aperta la sheet di segnalazione, e stato della
    // rigenerazione mirata che ne può seguire.
    @State private var reportingExercise: StudyExercise?
    @State private var regeneratingID: UUID?
    @State private var regenerationError: String?

    @State private var wolframResults: [UUID: WolframCheck] = [:]
    @State private var wolframCheckingID: UUID?
    @State private var expandedWolframIDs: Set<UUID> = []

    // Esito della verifica esterna: il risultato che risponde alla
    // domanda, e il resto dei passaggi che Wolfram restituisce.
    struct WolframCheck {
        var headline: String
        var detail: [WolframPod] = []
    }

    @State private var index = 0
    @State private var revealedSteps = 0
    @State private var showAnswer = false
    @State private var startedAt = Date.now
    @State private var sessionCorrect = 0
    @State private var sessionTotal = 0
    @State private var finished = false
    // Esito già registrato per ciascun esercizio in questa sessione: serve
    // a marcare la striscia degli indici e a non contare due volte lo
    // stesso esercizio se ci si torna sopra.
    @State private var outcomes: [UUID: Bool] = [:]

    private var exercises: [StudyExercise] { content.exercises }

    var body: some View {
        VStack(spacing: 0) {
            progressBar

            if exercises.isEmpty {
                ContentUnavailableView("Nessun esercizio", systemImage: "pencil.slash")
            } else if finished {
                sessionSummary
            } else {
                exerciseIndexStrip
                player
            }
        }
        .sheet(item: $reportingExercise) { exercise in
            ExerciseReportSheet(
                exercisePrompt: exercise.prompt,
                onReportOnly: { reason in
                    module.report(exercise.id, reason: reason)
                },
                onRegenerate: { reason in
                    module.report(exercise.id, reason: reason)
                    Task { await regenerate(exercise: exercise, feedback: reason) }
                }
            )
        }
        .alert("Rigenerazione non riuscita", isPresented: Binding(
            get: { regenerationError != nil },
            set: { if !$0 { regenerationError = nil } }
        )) {
            Button("OK", role: .cancel) { regenerationError = nil }
        } message: {
            Text(regenerationError ?? "")
        }
    }

    private func regenerate(exercise: StudyExercise, feedback: String) async {
        regeneratingID = exercise.id
        defer { regeneratingID = nil }
        let error = await StudioGenerationService.regenerateExercise(
            id: exercise.id,
            in: module,
            study: study,
            feedback: feedback,
            context: context
        )
        if let error {
            regenerationError = error
        } else {
            // Il contenuto è cambiato sotto ai piedi: si riparte dalla
            // rivelazione chiusa, altrimenti si vedrebbe la soluzione
            // guidata del vecchio esercizio sopra il nuovo.
            revealedSteps = 0
            showAnswer = false
            wolframResults[exercise.id] = nil
        }
    }

    // Era una barra di filtri "Tutti / Teorici / Pratici". Su un insieme
    // di una natura sola erano tre pulsanti che dicevano la stessa cosa:
    // resta la sola posizione nel set, che invece serve.
    private var progressBar: some View {
        HStack(spacing: DesignSpace.s2) {
            Spacer()
            if !finished && !exercises.isEmpty {
                Text("\(min(index + 1, exercises.count)) di \(exercises.count)")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textTertiary)
            }
        }
        .padding(.horizontal, DesignSpace.s6)
        .padding(.vertical, DesignSpace.s3)
    }

    // Striscia degli esercizi: si salta dove si vuole invece di essere
    // costretti alla sequenza. Verde/rosso = già autovalutato in questa
    // sessione, così si vede a colpo d'occhio cosa manca.
    private var exerciseIndexStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSpace.s2) {
                ForEach(Array(exercises.enumerated()), id: \.element.id) { position, exercise in
                    let outcome = outcomes[exercise.id]
                    let isCurrent = position == index
                    Button {
                        goTo(position)
                    } label: {
                        Text("\(position + 1)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(chipForeground(isCurrent: isCurrent, outcome: outcome))
                            .frame(width: 32, height: 32)
                            .background(chipBackground(isCurrent: isCurrent, outcome: outcome), in: Circle())
                            .overlay(
                                Circle().stroke(
                                    isCurrent ? DesignColor.brandPrimary : Color.clear,
                                    lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DesignSpace.s6)
            .padding(.bottom, DesignSpace.s2)
        }
    }

    private func chipForeground(isCurrent: Bool, outcome: Bool?) -> Color {
        if let outcome { return outcome ? DesignColor.success : DesignColor.danger }
        return isCurrent ? DesignColor.brandPrimary : DesignColor.textSecondary
    }

    private func chipBackground(isCurrent: Bool, outcome: Bool?) -> Color {
        if let outcome { return outcome ? DesignColor.successBg : DesignColor.dangerBg }
        return isCurrent ? DesignColor.brandPrimarySubtle : DesignColor.surfaceSunken
    }

    // Spostarsi su un altro esercizio azzera la rivelazione: la soluzione
    // guidata riparte chiusa, altrimenti si tornerebbe su un esercizio già
    // "spoilerato" senza volerlo.
    private func goTo(_ position: Int) {
        guard exercises.indices.contains(position) else { return }
        index = position
        revealedSteps = 0
        showAnswer = false
        startedAt = .now
    }

    private var navigationRow: some View {
        HStack(spacing: DesignSpace.s3) {
            Button {
                goTo(index - 1)
            } label: {
                Label("Precedente", systemImage: "chevron.left")
                    .fixedSize()
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(index > 0 ? DesignColor.textSecondary : DesignColor.textTertiary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(index == 0)

            Spacer()

            Button {
                goTo(index + 1)
            } label: {
                Label("Successivo", systemImage: "chevron.right")
                    .fixedSize()
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(index < exercises.count - 1 ? DesignColor.textSecondary : DesignColor.textTertiary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(index >= exercises.count - 1)
        }
    }

    private var player: some View {
        let exercise = exercises[min(index, exercises.count - 1)]
        return ScrollView {
            VStack(alignment: .leading, spacing: DesignSpace.s5) {
                HStack(spacing: DesignSpace.s2) {
                    // Niente più etichetta di categoria: erano tutte
                    // "Teorico"/"Pratico" su esercizi che ormai sono di
                    // una natura sola.
                    chip(exercise.difficulty.label, color: exercise.difficulty.color)
                    // Provenienza: "Nuovo" se la traccia è stata scritta
                    // ispirandosi ai materiali, "Nei materiali: X" se era
                    // già lì. Cambia come si affronta l'esercizio.
                    Label(exercise.originLabel, systemImage: exercise.origin.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(exercise.origin.color)
                        .lineLimit(1)
                        .padding(.horizontal, DesignSpace.s2 + 2)
                        .padding(.vertical, 4)
                        .background(exercise.origin.color.opacity(0.1), in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                    Spacer()
                }

                VStack(alignment: .leading, spacing: DesignSpace.s3) {
                    StudioRichText(text: exercise.prompt, size: 17, color: DesignColor.textPrimary)
                    // La figura della traccia, se il modello l'ha scritta:
                    // compilata con TikZJax alla prima apertura, poi
                    // l'SVG vive nel payload. Se il TeX non compila, la
                    // figura non appare e il fallimento viene ricordato.
                    if let tikz = exercise.figureTikZ, !tikz.isEmpty {
                        TikZFigureView(
                            tikz: tikz,
                            cachedSVG: exercise.figureSVG,
                            onCompiled: { svg in persistFigure(svg, for: exercise.id) },
                            onFailed: { persistFigure("", for: exercise.id) }
                        )
                        // IDENTITÀ LEGATA ALL'ESERCIZIO. Il player mostra
                        // un esercizio alla volta nella STESSA posizione
                        // della gerarchia: senza `.id`, passando da uno
                        // all'altro SwiftUI riusa la vista e con essa il
                        // suo `@State svg`, cioè la figura di prima resta
                        // appesa finché la nuova non è compilata — e su
                        // una figura già in cache può restarci del tutto.
                        // Con l'id la vista viene ricreata, e lo stato
                        // muore con lei.
                        .id(exercise.id)
                    } else if exercise.figureExpected == true {
                        // Assenza DICHIARATA invece che silenziosa: senza
                        // questa riga, "il modello non ha disegnato" e
                        // "qui non serviva un disegno" sono
                        // indistinguibili, e chi legge non sa se gli
                        // manca qualcosa. La traccia resta risolvibile:
                        // è una nota, non un errore.
                        Label("Per questa traccia servirebbe una figura, ma il modello non l'ha generata: disegnala tu prima di risolvere.", systemImage: "scribble.variable")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DesignSpace.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))

                if revealedSteps > 0 {
                    VStack(alignment: .leading, spacing: DesignSpace.s3) {
                        Text("SOLUZIONE GUIDATA")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(DesignColor.textTertiary)
                        ForEach(Array(exercise.steps.prefix(revealedSteps).enumerated()), id: \.offset) { stepIndex, step in
                            HStack(alignment: .top, spacing: DesignSpace.s3) {
                                Text("\(stepIndex + 1)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(DesignColor.toolExplain)
                                    .frame(width: 22, height: 22)
                                    .background(DesignColor.toolExplainBg, in: Circle())
                                StudioRichText(text: step)
                            }
                        }
                    }
                }

                if showAnswer {
                    VStack(alignment: .leading, spacing: DesignSpace.s2) {
                        Text("RISPOSTA")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(DesignColor.success)
                        StudioRichText(text: exercise.answer, color: DesignColor.textPrimary)

                        if let verification = exercise.verification.label, exercise.verification == .agreed {
                            Label(verification, systemImage: "checkmark.seal.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesignColor.success)
                        }

                        wolframCheckRow(exercise)
                    }
                    .padding(DesignSpace.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignColor.successBg, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
                }

                HStack(spacing: DesignSpace.s2) {
                    CitationDisclosure(
                        citation: exercise.quote,
                        meaning: exercise.origin == .invented ? .inspiration : .claim
                    )
                    Spacer()
                    if regeneratingID == exercise.id {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Rigenero…")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesignColor.textTertiary)
                        }
                    } else {
                        ReportButton(isReported: module.isReported(exercise.id)) {
                            if module.isReported(exercise.id) {
                                module.clearReport(exercise.id)
                            } else {
                                reportingExercise = exercise
                            }
                        }
                    }
                }

                Divider()
                navigationRow

                controls(exercise)
            }
            .padding(DesignSpace.s6)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func controls(_ exercise: StudyExercise) -> some View {
        if !showAnswer {
            HStack(spacing: DesignSpace.s3) {
                if revealedSteps < exercise.steps.count {
                    Button {
                        revealedSteps += 1
                    } label: {
                        Label(revealedSteps == 0 ? "Soluzione guidata" : "Passo successivo", systemImage: "lightbulb")
                            .fixedSize()
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignColor.toolExplain)
                            .padding(.horizontal, DesignSpace.s4)
                            .padding(.vertical, DesignSpace.s2 + 2)
                            .background(DesignColor.toolExplainBg, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showAnswer = true
                } label: {
                    Label("Mostra risposta", systemImage: "eye")
                        .fixedSize()
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignColor.brandPrimary)
                        .padding(.horizontal, DesignSpace.s4)
                        .padding(.vertical, DesignSpace.s2 + 2)
                        .background(DesignColor.brandPrimarySubtle, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        } else {
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                Text("Com'è andata?")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignColor.textSecondary)
                HStack(spacing: DesignSpace.s3) {
                    assessButton(correct: false, exercise: exercise)
                    assessButton(correct: true, exercise: exercise)
                }
            }
        }
    }

    private func assessButton(correct: Bool, exercise: StudyExercise) -> some View {
        Button {
            record(correct: correct, exercise: exercise)
        } label: {
            Label(correct ? "Giusto" : "Sbagliato", systemImage: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                .fixedSize()
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(correct ? DesignColor.success : DesignColor.danger)
                .padding(.horizontal, DesignSpace.s5)
                .padding(.vertical, DesignSpace.s3)
                .background(correct ? DesignColor.successBg : DesignColor.dangerBg, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var sessionSummary: some View {
        VStack(spacing: DesignSpace.s4) {
            Spacer()
            Image(systemName: sessionCorrect == sessionTotal ? "trophy.fill" : "flag.checkered")
                .font(.system(size: 40))
                .foregroundStyle(sessionCorrect == sessionTotal ? DesignColor.toolSearch : DesignColor.brandPrimary)
            Text("Sessione completata")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
            Text("\(sessionCorrect) giusti su \(sessionTotal) — i tentativi sono registrati in Analisi dei progressi.")
                .font(.system(size: 14))
                .foregroundStyle(DesignColor.textSecondary)
            Button("Ricomincia") { restartSession() }
                .buttonStyle(.boostFilled)
                .tint(DesignColor.brandPrimary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // Verifica fuori dal modello: se l'esercizio porta un'espressione
    // calcolabile e c'è la chiave Wolfram, si confronta il risultato
    // calcolato con la risposta proposta. Non giudica in automatico
    // (confrontare stringhe matematiche è inaffidabile): mostra il
    // risultato e lascia decidere allo studente.
    @ViewBuilder
    private func wolframCheckRow(_ exercise: StudyExercise) -> some View {
        if let expression = exercise.checkExpression, !expression.isEmpty {
            Divider()
            if let check = wolframResults[exercise.id] {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Verifica indipendente (Wolfram Alpha)", systemImage: "function")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignColor.toolWolfram)
                    // Solo il risultato che risponde alla domanda: prima
                    // si incollavano tutti i pod, e per esempio accanto
                    // all'integrale definito (quello giusto) compariva
                    // anche l'indefinito, che sembra un'altra risposta.
                    StudioRichText(text: check.headline, size: 13, weight: .medium, color: DesignColor.textPrimary)
                        .textSelection(.enabled)
                    Text("Confrontalo con la risposta qui sopra: se non coincide, uno dei due è sbagliato.")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.textTertiary)

                    if !check.detail.isEmpty {
                        if expandedWolframIDs.contains(exercise.id) {
                            ForEach(check.detail) { pod in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(pod.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(DesignColor.textTertiary)
                                    Text(pod.text)
                                        .font(.system(size: 11))
                                        .foregroundStyle(DesignColor.textSecondary)
                                }
                            }
                        }
                        Button {
                            if expandedWolframIDs.contains(exercise.id) {
                                expandedWolframIDs.remove(exercise.id)
                            } else {
                                expandedWolframIDs.insert(exercise.id)
                            }
                        } label: {
                            Text(expandedWolframIDs.contains(exercise.id) ? "Nascondi gli altri passaggi" : "Mostra gli altri passaggi (\(check.detail.count))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesignColor.toolWolfram)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if wolframCheckingID == exercise.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Calcolo indipendente in corso…")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.textTertiary)
                }
            } else if wolframAppID.isEmpty {
                Text("Aggiungi la chiave Wolfram Alpha nel Profilo per verificare questo risultato con un calcolo indipendente.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignColor.textTertiary)
            } else {
                Button {
                    Task { await runWolframCheck(expression, for: exercise.id) }
                } label: {
                    Label("Verifica con Wolfram", systemImage: "function")
                        .fixedSize()
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignColor.toolWolfram)
                        .padding(.horizontal, DesignSpace.s3)
                        .padding(.vertical, 6)
                        .background(DesignColor.toolWolframBg, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func runWolframCheck(_ expression: String, for exerciseID: UUID) async {
        wolframCheckingID = exerciseID
        defer { wolframCheckingID = nil }
        switch await MagicPenService.queryWolfram(text: expression, appID: wolframAppID) {
        case .success(let result):
            if let primary = result.primaryPod {
                let others = result.pods.filter { $0.title != primary.title && !$0.title.lowercased().contains("input") }
                wolframResults[exerciseID] = WolframCheck(headline: primary.text, detail: others)
            } else {
                wolframResults[exerciseID] = WolframCheck(headline: result.text ?? "Wolfram non ha restituito un risultato testuale per questa espressione.")
            }
        case .failure(let reason):
            // Il motivo vero (quota, chiave, rete) invece di un generico
            // "non riuscito": è l'unica cosa che permette di rimediare.
            wolframResults[exerciseID] = WolframCheck(headline: "Verifica non riuscita: \(reason)")
        }
    }

    private func record(correct: Bool, exercise: StudyExercise) {
        let attempt = ExerciseAttempt(
            isCorrect: correct,
            durationSeconds: Date.now.timeIntervalSince(startedAt),
            topic: exercise.topic,
            difficulty: exercise.difficulty,
            category: exercise.category,
            study: study
        )
        context.insert(attempt)

        // Con la navigazione libera si può tornare su un esercizio già
        // valutato: il conteggio della sessione va corretto invece di
        // sommare due volte lo stesso esercizio.
        if let previous = outcomes[exercise.id] {
            if previous != correct {
                sessionCorrect += correct ? 1 : -1
            }
        } else {
            sessionTotal += 1
            if correct { sessionCorrect += 1 }
        }
        outcomes[exercise.id] = correct

        // La sessione finisce quando TUTTI sono stati valutati, non quando
        // si arriva in fondo: si può saltare in giro liberamente.
        if outcomes.count >= exercises.count {
            finished = true
        } else if let next = nextUnansweredPosition() {
            goTo(next)
        }
    }

    // Prossimo esercizio non ancora valutato, partendo da quello dopo
    // l'attuale e riavvolgendo dall'inizio.
    private func nextUnansweredPosition() -> Int? {
        let count = exercises.count
        guard count > 0 else { return nil }
        for offset in 1...count {
            let position = (index + offset) % count
            if outcomes[exercises[position].id] == nil { return position }
        }
        return nil
    }

    private func restartSession() {
        index = 0
        revealedSteps = 0
        showAnswer = false
        startedAt = .now
        sessionCorrect = 0
        sessionTotal = 0
        outcomes = [:]
        finished = false
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, DesignSpace.s2 + 2)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
    }
}

// MARK: - Punti di ripasso
// Ogni punto: concetto + domanda di verifica; la risposta si rivela al tocco.
private struct ReviewPointsModuleView: View {
    @Environment(\.modelContext) private var context
    let content: ReviewPointsContent
    let module: StudyModule
    let study: Study

    @State private var revealedIDs: Set<UUID> = []
    // Autovalutazione già data in questa sessione, per domanda: serve a
    // mostrare quale delle due si è scelta e a non contare due volte la
    // stessa domanda se ci si ripassa sopra.
    @State private var outcomes: [UUID: Bool] = [:]
    // Il tentativo REGISTRATO per ogni domanda in questa sessione:
    // cambiare idea deve sostituirlo, e per sostituirlo bisogna sapere
    // quale record eliminare — prima si inseriva un secondo tentativo
    // lasciando il primo, e l'analisi contava doppio.
    @State private var recordedAttempts: [UUID: ExerciseAttempt] = [:]
    @State private var startedAt = Date.now

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpace.s4) {
                ForEach(Array(content.points.enumerated()), id: \.element.id) { pointIndex, point in
                    pointCard(index: pointIndex, point: point)
                }
            }
            .padding(DesignSpace.s6)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    // Estratta dal body: inline il compilatore non riusciva più a
    // type-checkare l'espressione in tempo ragionevole.
    @ViewBuilder
    private func pointCard(index pointIndex: Int, point: ReviewPoint) -> some View {
        let revealed = revealedIDs.contains(point.id)
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
                        HStack(alignment: .top, spacing: DesignSpace.s3) {
                            Text("\(pointIndex + 1)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(DesignColor.toolExplain)
                                .frame(width: 26, height: 26)
                                .background(DesignColor.toolExplainBg, in: Circle())
                            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                                // PRIMA LA DOMANDA, e prima del resto:
                                // `statement` è l'enunciato su cui verte,
                                // e quando questi erano "punti di ripasso"
                                // stava in cima di diritto — il punto era
                                // quello, la domanda serviva a controllare
                                // di averlo capito. Da quando sono
                                // esercizi il verso è opposto: mostrare
                                // l'enunciato sopra la domanda ne regala
                                // la risposta prima ancora che venga
                                // letta. Ora scende insieme alla
                                // soluzione.
                                StudioRichText(text: point.question, size: 15, color: DesignColor.textPrimary)
                            }
                        }

                        if revealed {
                            StudioRichText(text: point.statement, size: 13, color: DesignColor.textPrimary)
                            StudioRichText(text: point.answer, size: 13)
                                .padding(DesignSpace.s3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(DesignColor.successBg, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                            // Autovalutazione: è ciò che rende questi
                            // esercizi e non schede da leggere. Senza, non
                            // entrano nell'analisi e la teoria resta fuori
                            // dai progressi come se non l'avessi studiata.
                            HStack(spacing: DesignSpace.s2) {
                                selfCheckButton(point: point, correct: true, title: "Sapevo rispondere", icon: "checkmark.circle.fill", color: DesignColor.success)
                                selfCheckButton(point: point, correct: false, title: "Da rivedere", icon: "arrow.counterclockwise.circle.fill", color: DesignColor.attention)
                                Spacer()
                            }
                            .padding(.leading, 26 + DesignSpace.s3)

                            HStack(spacing: DesignSpace.s2) {
                                CitationDisclosure(citation: point.quote)
                                Spacer()
                                ReportButton(isReported: module.isReported(point.id)) {
                                    if module.isReported(point.id) {
                                        module.clearReport(point.id)
                                    } else {
                                        module.report(point.id, reason: "")
                                    }
                                }
                            }
                        } else {
                            Button {
                                revealedIDs.insert(point.id)
                            } label: {
                                Label("Mostra risposta", systemImage: "eye")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DesignColor.brandPrimary)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 26 + DesignSpace.s3)
                        }
                    }
        .padding(DesignSpace.s4)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }

    private func selfCheckButton(point: ReviewPoint, correct: Bool, title: String, icon: String, color: Color) -> some View {
        let chosen = outcomes[point.id]
        let isSelected = chosen == correct
        return Button {
            record(correct: correct, point: point)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? DesignColor.textOnBrand : color)
                .padding(.horizontal, DesignSpace.s3)
                .padding(.vertical, 6)
                .background(isSelected ? color : color.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func record(correct: Bool, point: ReviewPoint) {
        // Cambiare idea SOSTITUISCE il tentativo invece di aggiungerne
        // uno: il record precedente della stessa domanda si elimina,
        // altrimenti due tentativi nella stessa sessione gonfiavano i
        // conteggi dell'analisi (il commento lo prometteva già, il
        // codice inseriva e basta).
        if let previous = outcomes[point.id], previous == correct { return }
        if let previousAttempt = recordedAttempts[point.id] {
            context.delete(previousAttempt)
        }
        let attempt = ExerciseAttempt(
            isCorrect: correct,
            durationSeconds: Date.now.timeIntervalSince(startedAt),
            // Senza argomento il tentativo esiste ma non si somma a
            // niente: i payload generati prima del campo "topic" finiscono
            // qui, e "Senza argomento" lo dice invece di nasconderlo.
            topic: point.topic ?? "Senza argomento",
            // Un esercizio teorico non ha difficoltà: vedi ExerciseAttempt.
            difficulty: nil,
            category: .theoretical,
            study: study
        )
        context.insert(attempt)
        recordedAttempts[point.id] = attempt
        outcomes[point.id] = correct
        startedAt = .now
    }
}

// MARK: - Flashcard
// Ricalca FlashcardsScreen.jsx del design system: contatore, carta che si
// gira al tocco (sfondo brand quando mostra la risposta), frecce circolari.
private struct FlashcardsModuleView: View {
    let content: FlashcardsContent

    @State private var index = 0
    @State private var flipped = false

    var body: some View {
        // Un payload corrotto o di un formato futuro decodifica in un
        // mazzo VUOTO (il viewer usa `?? FlashcardsContent()`): senza
        // questa guardia l'indice andava a -1 e il modulo crashava
        // all'apertura. Stesso trattamento del player esercizi.
        if content.cards.isEmpty {
            ContentUnavailableView(
                "Nessuna carta",
                systemImage: "rectangle.on.rectangle.slash",
                description: Text("Il contenuto di questo modulo non è leggibile: rigeneralo dalla card dello studio.")
            )
        } else {
            deck
        }
    }

    private var deck: some View {
        VStack(spacing: DesignSpace.s6) {
            Spacer()
            Text("\(index + 1) di \(content.cards.count)")
                .font(.system(size: 13))
                .foregroundStyle(DesignColor.textTertiary)

            let card = content.cards[min(index, content.cards.count - 1)]
            Button {
                withAnimation(.easeOut(duration: 0.18)) { flipped.toggle() }
            } label: {
                StudioRichText(
                    text: flipped ? card.back : card.front,
                    size: 18,
                    weight: flipped ? .regular : .semibold,
                    color: DesignColor.textPrimary
                )
                    .padding(DesignSpace.s8)
                    .frame(maxWidth: 440)
                    .frame(minHeight: 220)
                    .background(
                        flipped ? DesignColor.brandPrimarySubtle : DesignColor.surfacePage,
                        in: RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
                            .stroke(DesignColor.borderDefault, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            }
            .buttonStyle(.plain)

            Text("Tocca la carta per girarla")
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textTertiary)

            HStack(spacing: 10) {
                arrowButton(systemImage: "chevron.left") { go(-1) }
                arrowButton(systemImage: "chevron.right") { go(1) }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func go(_ delta: Int) {
        flipped = false
        let count = content.cards.count
        guard count > 0 else { return }
        index = (index + delta + count) % count
    }

    private func arrowButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DesignColor.textSecondary)
                .frame(width: 40, height: 40)
                .background(DesignColor.surfacePage, in: Circle())
                .overlay(Circle().stroke(DesignColor.borderDefault, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
