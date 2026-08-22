import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// Flusso "Crea nuovo studio": nome e materia → materiali sorgente (note,
// WeBeep, PDF caricati a mano) → moduli da generare con le loro opzioni →
// estrazione del testo e generazione, con stato visibile nel dettaglio.
struct StudioCreateFlowView: View {
    @Environment(\.modelContext) private var context
    var onCancel: () -> Void
    var onCreated: (Study) -> Void

    @State private var name = ""
    @State private var subject = ""
    @State private var sources: [StudySourceMaterial] = []

    // "Crea da questo Vault": materia e materiali arrivano già pronti
    // dalla card del corso. State(initialValue:) nell'init, non
    // onAppear: il prefill non deve mai sovrascrivere modifiche.
    // `prefillTopics`: arriva dall'analisi dei progressi ("genera sugli
    // argomenti deboli"). Non si può applicare qui — gli argomenti
    // disponibili si conoscono solo dopo la @Query sui documenti — quindi
    // resta in attesa e viene consumato UNA volta sola quando l'elenco
    // esiste, senza poter più toccare scelte fatte a mano.
    init(prefillFolder: StudyFolder? = nil, prefillTopics: [String] = [], prefillKinds: Set<StudyModuleKind>? = nil, onCancel: @escaping () -> Void, onCreated: @escaping (Study) -> Void) {
        self.onCancel = onCancel
        self.onCreated = onCreated
        if !prefillTopics.isEmpty {
            _pendingFocusTopics = State(initialValue: prefillTopics)
        }
        if let prefillKinds {
            _selectedKinds = State(initialValue: prefillKinds)
        }
        guard let folder = prefillFolder else { return }
        _subject = State(initialValue: folder.name)
        if !prefillTopics.isEmpty {
            _name = State(initialValue: "Recupero \(folder.name)")
        }
        _sources = State(initialValue: folder.vaultDocuments.sorted { $0.addedAt < $1.addedAt }.map { document in
            StudySourceMaterial(
                kind: .vault,
                title: document.title,
                subtitle: folder.name,
                isExamPaper: document.isExamPaper,
                vaultDocumentID: document.id
            )
        })
    }
    @State private var selectedKinds: Set<StudyModuleKind> = [.summary, .exercises]

    // Opzioni per il modulo esercizi (ignorate dagli altri moduli).
    @State private var difficulty: ExerciseDifficulty? = nil
    @State private var verifyExercises = true
    // Un numero solo: gli esercizi sono tutti da risolvere. Erano due
    // (teorici + pratici) e il default sommava a 2 per argomento: si
    // parte da lì per non cambiare sotto i piedi quanto esce.
    @State private var exerciseCount = 2

    // Si memorizzano gli argomenti ESCLUSI, non quelli scelti: così
    // aggiungere un documento include automaticamente i suoi argomenti,
    // invece di lasciarli fuori perché la selezione era stata fatta
    // prima che esistessero.
    @State private var excludedTopics: Set<String> = []
    @State private var pendingFocusTopics: [String]?

    @Query private var vaultDocuments: [VaultDocument]

    @State private var showingNotePicker = false
    @State private var showingWebeepPicker = false
    @State private var showingVaultPicker = false
    @State private var showingQuotaInfo = false
    @State private var showingPDFImporter = false

    // Contenuto dei PDF scelti, tenuto qui perché l'accesso al file
    // dell'utente vale solo dentro la callback del file importer.
    @State private var pdfPayloads: [UUID: Data] = [:]
    @State private var preparation: StudyMaterialPreparation.Progress?

    var body: some View {
        // Sheet con testata di sola chiusura: qui la conferma NON sta in
        // alto come verbo. Generare è la fine di un modulo che si
        // compila dall'alto in basso, e il tasto sta dove si arriva —
        // in fondo, grande, con accanto il costo in chiamate.
        // La ✕ resta ferma finché la preparazione dei materiali è in corso.
        BoostSheet(
            title: "Crea nuovo studio",
            mode: .read,
            onDismiss: {
                guard preparation == nil else { return }
                onCancel()
            }
        ) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSpace.s8) {
                        nameSection
                        materialsSection
                        modulesSection
                    }
                    .padding(DesignSpace.s6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                generateBar
            }
        }
        .sheet(isPresented: $showingVaultPicker) {
            VaultSourcePicker(alreadyPicked: Set(sources.compactMap(\.vaultDocumentID))) { picked in
                sources.append(contentsOf: picked)
                // La materia si compila da sola con il nome del corso del
                // Vault, se l'utente non l'ha già scritta: cartella = corso.
                if subject.trimmingCharacters(in: .whitespaces).isEmpty,
                   let folderName = picked.first?.subtitle {
                    subject = folderName
                }
            }
        }
        .sheet(isPresented: $showingNotePicker) {
            StudioNotePickerSheet(alreadySelectedNoteIDs: Set(sources.compactMap(\.noteID))) { picked in
                sources.append(contentsOf: picked)
            }
        }
        .sheet(isPresented: $showingWebeepPicker) {
            StudioWebeepPickerSheet { picked in
                sources.append(contentsOf: picked)
            }
        }
        .fileImporter(isPresented: $showingPDFImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var unreadable: [String] = []
            for url in urls {
                // Il contenuto va letto ORA: l'accesso security-scoped
                // all'URL scelto dall'utente non sopravvive a questa
                // callback, e alla generazione il file non sarebbe più
                // leggibile.
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    // Va DETTO: prima il file spariva in silenzio e
                    // sembrava di averlo aggiunto.
                    unreadable.append(url.lastPathComponent)
                    continue
                }

                let title = url.deletingPathExtension().lastPathComponent
                let source = StudySourceMaterial(
                    kind: .file,
                    title: title,
                    subtitle: byteLabel(data.count),
                    isExamPaper: Self.looksLikeExamPaper(title)
                )
                pdfPayloads[source.id] = data
                sources.append(source)
            }
            if !unreadable.isEmpty {
                BoostToastCenter.shared.show("Non riesco a leggere: \(unreadable.joined(separator: ", ")).", role: .danger)
            }
        }
    }

    // MARK: - Sezioni

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            sectionHeader(number: 1, title: "Dai un nome allo studio")
            // ViewThatFits: affiancati quando c'è spazio (iPad landscape),
            // impilati quando l'area di dettaglio è stretta (portrait con
            // le due sidebar aperte).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSpace.s3) {
                    nameField
                    subjectField.frame(maxWidth: 240)
                }
                VStack(spacing: DesignSpace.s3) {
                    nameField
                    subjectField
                }
            }
        }
    }

    private var nameField: some View {
        TextField("Nome (es. Ripasso Analisi 1 — primo parziale)", text: $name)
            .textFieldStyle(.plain)
            .font(DesignFont.body)
            .padding(DesignSpace.s3)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
    }

    private var subjectField: some View {
        TextField("Materia (es. Analisi 1)", text: $subject)
            .textFieldStyle(.plain)
            .font(DesignFont.body)
            .padding(DesignSpace.s3)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
    }

    // Gerarchia dichiarata: il Vault è LA fonte (pieno, grande), tutto il
    // resto sta dietro un "Aggiungi file" secondario. Non è solo estetica
    // — un file preso qui viene letto adesso e pagato in quota ogni volta,
    // mentre dal Vault il testo è già lì: la via giusta deve anche
    // sembrare la via principale.
    @ViewBuilder
    private var materialButtons: some View {
        Button {
            showingVaultPicker = true
        } label: {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: "archivebox")
                    .font(.system(size: DesignIcon.md))
                Text("Scegli dal Vault")
                    .font(DesignFont.cardTitle)
            }
            .foregroundStyle(DesignColor.textOnBrand)
            .padding(.horizontal, DesignSpace.s5)
            .padding(.vertical, DesignSpace.s3)
            .background(DesignColor.brandPrimary, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)

        Menu {
            Button {
                showingNotePicker = true
            } label: {
                Label("Dalle note", systemImage: "note.text")
            }
            Button {
                showingWebeepPicker = true
            } label: {
                Label("Da WeBeep", systemImage: "building.columns.fill")
            }
            Button {
                showingPDFImporter = true
            } label: {
                Label("Aggiungi PDF", systemImage: "doc.badge.plus")
            }
            Text("Questi file vengono letti ora e consumano quota. Mettendoli invece nel Vault, la lettura si paga una volta sola.")
        } label: {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: "plus")
                    .font(.system(size: DesignIcon.md))
                Text("Aggiungi file")
                    .font(DesignFont.action)
            }
            .foregroundStyle(DesignColor.textSecondary)
            .padding(.horizontal, DesignSpace.s4)
            .padding(.vertical, DesignSpace.s3)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous).strokeBorder(DesignColor.borderDefault, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var materialsSection: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            sectionHeader(number: 2, title: "Scegli i materiali di partenza")
            Text("Il Vault del corso è già letto: sceglierne i documenti non costa nessuna rilettura. Puoi comunque aggiungere un file al volo, ma verrà letto adesso.")
                .font(DesignFont.label)
                .foregroundStyle(DesignColor.textTertiary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSpace.s3) {
                    materialButtons
                }
                VStack(alignment: .leading, spacing: DesignSpace.s2) {
                    materialButtons
                }
            }

            if !sources.isEmpty {
                VStack(spacing: 1) {
                    ForEach(sources) { source in
                        sourceRow(source)
                    }
                }
                .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
            }

            topicsSection
        }
    }

    // Gli argomenti che il Vault ha già riconosciuto nei documenti
    // scelti, in ordine di corso e senza duplicati.
    private var availableTopics: [String] {
        let ids = Set(sources.compactMap(\.vaultDocumentID))
        guard !ids.isEmpty else { return [] }
        var seen: Set<String> = []
        var raw: [String] = []
        for document in vaultDocuments where ids.contains(document.id) {
            for topic in document.allTopics where seen.insert(topic.lowercased()).inserted {
                raw.append(topic)
            }
        }
        // Consolidamento sull'UNIONE dei documenti scelti, non documento
        // per documento: una sigla ("PL") può trovare la sua forma estesa
        // in una dispensa diversa da quella dove è stata usata.
        return TopicVocabulary.consolidated(raw)
    }

    private var selectedTopics: [String] {
        availableTopics.filter { !excludedTopics.contains(TopicKey.key($0)) }
    }

    // Restringere il campo serve alla PROFONDITÀ: con trenta argomenti e
    // il tetto di 15 esercizi tocca mezzo esercizio a testa, mentre su
    // due argomenti se ne fanno otto seri. In più gli argomenti scelti
    // diventano il vocabolario del campo "topic", che è ciò su cui
    // l'analisi dei progressi raggruppa: senza, ogni generazione se lo
    // inventa con parole sue e le statistiche si frantumano.
    @ViewBuilder
    private var topicsSection: some View {
        let topics = availableTopics
        if !topics.isEmpty {
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                if let focus = pendingFocusTopics, !focus.isEmpty {
                    Label("Argomenti preselezionati dai tuoi risultati: sono quelli dove sbagli di più. Puoi cambiarli.", systemImage: "target")
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.insight)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: DesignSpace.s2) {
                    Text("ARGOMENTI DAL VAULT")
                        .font(DesignFont.micro)
                        .tracking(0.6)
                        .foregroundStyle(DesignColor.textTertiary)
                    Text("\(selectedTopics.count)/\(topics.count)")
                        .font(DesignFont.caption.monospacedDigit())
                        .foregroundStyle(DesignColor.brandPrimary)
                    Spacer()
                    if !excludedTopics.isEmpty {
                        Button("Tutti") { excludedTopics.removeAll() }
                            .font(DesignFont.action)
                            .buttonStyle(.plain)
                            .foregroundStyle(DesignColor.brandPrimary)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: DesignSpace.s2)], alignment: .leading, spacing: DesignSpace.s2) {
                    ForEach(topics, id: \.self) { topic in
                        topicChip(topic)
                    }
                }
                Text(selectedTopics.count == topics.count
                     ? "Tutti gli argomenti del materiale scelto. Toglierne qualcuno concentra la generazione sui rimanenti: meno argomenti, più esercizi per ciascuno."
                     : "La generazione userà solo questi argomenti — e solo le parti di materiale che li trattano.")
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignSpace.s4)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
            .task(id: topics) {
                // Consumo una tantum: l'indice arriva dopo il primo
                // disegno, e da qui in poi la selezione è dell'utente.
                guard let focus = pendingFocusTopics, !focus.isEmpty else { return }
                let wanted = Set(focus.map { TopicKey.key($0) })
                let matching = topics.filter { wanted.contains(TopicKey.key($0)) }
                // Nessuna corrispondenza: si consuma comunque il prefill,
                // altrimenti il banner "Argomenti preselezionati" resta
                // acceso davanti a una selezione che non è mai avvenuta.
                guard !matching.isEmpty else {
                    pendingFocusTopics = nil
                    return
                }
                excludedTopics = Set(topics.map { TopicKey.key($0) }).subtracting(wanted)
                pendingFocusTopics = nil
            }
        }
    }

    private func topicChip(_ topic: String) -> some View {
        let isOn = !excludedTopics.contains(TopicKey.key(topic))
        return Button {
            if isOn {
                // L'ultimo argomento non si può togliere: senza nessun
                // argomento non resterebbe niente da generare.
                if selectedTopics.count > 1 { excludedTopics.insert(TopicKey.key(topic)) }
            } else {
                excludedTopics.remove(TopicKey.key(topic))
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: DesignIcon.sm))
                Text(topic)
                    .font(DesignFont.action)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(isOn ? DesignColor.brandPrimary : DesignColor.textTertiary)
            .padding(.horizontal, DesignSpace.s3)
            .padding(.vertical, DesignSpace.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isOn ? DesignColor.brandPrimarySubtle : DesignColor.surfacePage,
                in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func sourceRow(_ source: StudySourceMaterial) -> some View {
        HStack(spacing: DesignSpace.s3) {
            Image(systemName: source.kind.systemImage)
                .font(.system(size: DesignIcon.md))
                .foregroundStyle(DesignColor.brandPrimary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title)
                    .font(DesignFont.body)
                    .foregroundStyle(DesignColor.textPrimary)
                    .lineLimit(1)
                if let subtitle = source.subtitle {
                    Text(subtitle)
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
            Spacer()

            // Toggle "tema d'esame": decide se il materiale dà la forma
            // agli esercizi da risolvere invece di alimentare la teoria.
            Button {
                toggleExamPaper(source)
            } label: {
                Text("Tema d'esame")
                    .fixedSize()
                    .font(DesignFont.caption)
                    .foregroundStyle(source.isExamPaper ? DesignColor.attention : DesignColor.textTertiary)
                    .padding(.horizontal, DesignSpace.s3)
                    .padding(.vertical, DesignSpace.s1)
                    .background(
                        source.isExamPaper ? DesignColor.attentionBg : DesignColor.surfacePage,
                        in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous).stroke(source.isExamPaper ? DesignColor.attention.opacity(0.4) : DesignColor.borderDefault, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                sources.removeAll { $0.id == source.id }
                pdfPayloads.removeValue(forKey: source.id)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(DesignColor.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Togli \(source.title)")
        }
        .padding(.horizontal, DesignSpace.s4)
        .padding(.vertical, DesignSpace.s3)
    }

    private var modulesSection: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            sectionHeader(number: 3, title: "Cosa vuoi generare?")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: DesignSpace.s4)], spacing: DesignSpace.s4) {
                ForEach(StudyModuleKind.allCases, id: \.self) { kind in
                    moduleCard(kind)
                }
            }

            if selectedKinds.contains(.exercises) {
                exerciseOptions
            }
        }
    }

    private func moduleCard(_ kind: StudyModuleKind) -> some View {
        let isSelected = selectedKinds.contains(kind)
        return Button {
            if isSelected { selectedKinds.remove(kind) } else { selectedKinds.insert(kind) }
        } label: {
            HStack(spacing: DesignSpace.s3) {
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .fill(kind.color.opacity(0.12))
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: kind.systemImage).font(.system(size: DesignIcon.md)).foregroundStyle(kind.color))
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.label)
                        .font(DesignFont.cardTitle)
                        .foregroundStyle(DesignColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(kind.subtitle)
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: DesignIcon.lg))
                    .foregroundStyle(isSelected ? DesignColor.brandPrimary : DesignColor.borderDefault)
            }
            .padding(DesignSpace.s4)
            .background(
                isSelected ? DesignColor.brandPrimarySubtle : DesignColor.surfaceSunken,
                in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                    .stroke(isSelected ? DesignColor.brandPrimary.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var exerciseOptions: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            Text("OPZIONI ESERCIZI")
                .font(DesignFont.micro)
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: DesignSpace.s2)], alignment: .leading, spacing: DesignSpace.s2) {
                difficultyChip(nil, label: "Mista")
                ForEach(ExerciseDifficulty.allCases, id: \.self) { level in
                    difficultyChip(level, label: level.label)
                }
            }

            // Una riga sola. Prima erano due categorie con due
            // interruttori e due contatori, ma "teorico" e "pratico"
            // dicevano da DOVE veniva l'esercizio, non che cosa chiedeva:
            // l'etichetta non corrispondeva a quello che si leggeva nella
            // traccia. Ora gli esercizi sono tutti da risolvere e la parte
            // concettuale sta nei punti di ripasso, quindi qui si sceglie
            // solo quanta profondità dare a ogni argomento.
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                HStack(spacing: DesignSpace.s3) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Quanti esercizi")
                            .font(DesignFont.body)
                            .foregroundStyle(DesignColor.textPrimary)
                        Text("Tracce da risolvere, inventate sui temi d'esame")
                            .font(DesignFont.caption)
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                    Spacer(minLength: DesignSpace.s3)
                    HStack(spacing: DesignSpace.s2) {
                        Text("\(exerciseCount)")
                            .font(DesignFont.cardTitle)
                            .foregroundStyle(DesignColor.brandPrimary)
                            .frame(minWidth: 22)
                        Text("per argomento")
                            .font(DesignFont.caption)
                            .foregroundStyle(DesignColor.textTertiary)
                        Stepper(value: $exerciseCount, in: 1...3) { EmptyView() }
                            .labelsHidden()
                            .fixedSize()
                    }
                }
                Text("Gli **argomenti li individua l'app** leggendo i materiali, e li copre tutti. Questo numero dice quanti esercizi fare **per ciascun argomento**: alzalo per insistere di più su ogni cosa.")
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if exerciseCount > 2 {
                    Label("Con molti argomenti nei materiali il totale cresce in fretta: oltre 15 esercizi la generazione riduce da sola il numero per argomento, per coprirli comunque tutti.", systemImage: "info.circle")
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Toggle(isOn: $verifyExercises) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Verifica gli esercizi").font(DesignFont.label)
                    Text("Ogni esercizio viene risolto una seconda volta in modo indipendente; se le due soluzioni non coincidono viene scartato. Usa una chiamata in più.")
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
            .toggleStyle(.switch)
            .tint(DesignColor.success)
        }
        .padding(DesignSpace.s4)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }


    private func difficultyChip(_ level: ExerciseDifficulty?, label: String) -> some View {
        let isSelected = difficulty == level
        return Button {
            difficulty = level
        } label: {
            Text(label)
                .font(DesignFont.action)
                .foregroundStyle(isSelected ? DesignColor.textOnBrand : DesignColor.textSecondary)
                .padding(.horizontal, DesignSpace.s4)
                .padding(.vertical, DesignSpace.s2)
                .background(
                    isSelected ? DesignColor.brandPrimary : DesignColor.surfacePage,
                    in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous).stroke(isSelected ? Color.clear : DesignColor.borderDefault, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Barra di generazione

    // Cosa manca ancora per poter generare. Prima bastavano nome e
    // moduli, ma senza materiali o senza provider la generazione produce
    // solo moduli falliti: tanto vale impedirla e dire cosa serve.
    private var missingRequirements: [String] {
        var missing: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("un nome") }
        if sources.isEmpty { missing.append("almeno un materiale") }
        if selectedKinds.isEmpty { missing.append("almeno un modulo da generare") }
        if !AIService.isConfigured { missing.append("un provider AI configurato nel Profilo") }
        return missing
    }

    private var canGenerate: Bool { missingRequirements.isEmpty }

    private var generateBar: some View {
        // UNA riga sola: a sinistra cosa sta succedendo (lettura in corso,
        // cosa manca, quanto costerà), a destra la quota e il tasto.
        // Impilate su due righe con lo spazio in mezzo, quelle stesse
        // informazioni facevano una fascia alta il doppio del necessario.
        HStack(alignment: .center, spacing: DesignSpace.s3) {
            statusLine
                .frame(maxWidth: .infinity, alignment: .leading)

            // Il pannello quota vive dietro la ⓘ, come chiesto: non
            // in faccia, ma a un tocco quando si sta per spendere.
            if AIService.selectedProvider == .gemini {
                Button {
                    showingQuotaInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: DesignIcon.md))
                        .foregroundStyle(DesignColor.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingQuotaInfo, arrowEdge: .bottom) {
                    GeminiQuotaPanel()
                        .padding(DesignSpace.s4)
                        // 420pt non stanno in un popover su iPhone:
                        // lì diventa uno sheet a larghezza piena.
                        .frame(width: DeviceLayout.isPhone ? nil : 420)
                        .presentationCompactAdaptation(DeviceLayout.isPhone ? .sheet : .popover)
                        .presentationDetents([.medium, .large])
                }
            }

            BoostButton(
                "Genera studio",
                icon: "sparkles",
                tone: .primary,
                isLoading: preparation != nil
            ) {
                createStudy()
            }
            .disabled(!canGenerate || preparation != nil)
        }
        .padding(.horizontal, DesignSpace.s6)
        .frame(minHeight: DesignSize.bottomBar)
        .background(DesignColor.surfacePage)
        .overlay(alignment: .top) {
            Rectangle().fill(DesignColor.borderDefault).frame(height: 1)
        }
    }

    // Una riga sola, quella che conta di più in questo momento.
    @ViewBuilder
    private var statusLine: some View {
        if let preparation {
            // L'estrazione (OCR della scrittura a mano, PDF scansionati,
            // download WeBeep) può durare parecchi secondi: senza questo
            // sembrerebbe che l'app si sia piantata.
            HStack(spacing: DesignSpace.s2) {
                ProgressView().controlSize(.small)
                Text("Leggo i materiali — \(preparation.current) di \(preparation.total): \(preparation.title)\(preparation.detail.map { " (\($0))" } ?? "")")
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textSecondary)
                    .lineLimit(1)
            }
        } else if !missingRequirements.isEmpty {
            Label("Manca ancora: \(missingRequirements.joined(separator: ", ")).", systemImage: "info.circle")
                .font(DesignFont.caption)
                .foregroundStyle(DesignColor.textTertiary)
                .lineLimit(2)
        } else if AIService.selectedProvider == .gemini {
            Text(callEstimateLabel)
                .font(DesignFont.caption)
                .foregroundStyle(DesignColor.textTertiary)
                .lineLimit(1)
        }
    }

    // Quante chiamate costerà questa generazione: una per modulo, più
    // una per la verifica degli esercizi. Il riassunto dal Vault è a
    // mappa (una per blocco), quindi lì il conto si alza — e va detto
    // PRIMA di spendere, non dopo.
    private var callEstimateLabel: String {
        var calls = selectedKinds.count
        if selectedKinds.contains(.exercises), verifyExercises { calls += 1 }
        var summaryBlocks = 0
        if selectedKinds.contains(.summary) {
            let vaultIDs = Set(sources.compactMap(\.vaultDocumentID))
            if !vaultIDs.isEmpty {
                let descriptor = FetchDescriptor<VaultDocument>()
                let documents = ((try? context.fetch(descriptor)) ?? []).filter { vaultIDs.contains($0.id) }
                summaryBlocks = documents.reduce(0) { partial, document in
                    guard !document.isExamPaper else { return partial }
                    return partial + document.sortedChunks.filter { $0.natureRaw != "exercises" }.count
                }
                // Nessun chunk indicizzato: resta una chiamata sola.
                if summaryBlocks > 1 { calls += summaryBlocks - 1 }
            }
        }
        let suffix = summaryBlocks > 1 ? " (il riassunto copre il materiale in \(summaryBlocks) parti)" : ""
        return "\(calls) chiamat\(calls == 1 ? "a" : "e") per questa generazione\(suffix)"
    }

    private func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func createStudy() {
        // La guardia contro il doppio tocco va messa QUI, in modo
        // sincrono: `preparation` diventava non-nil solo al primo
        // onProgress dentro il Task, e nella finestra tra i due tocchi
        // si creavano DUE studi con doppia preparazione e doppia quota.
        guard preparation == nil else { return }
        preparation = StudyMaterialPreparation.Progress(
            current: 0,
            total: sources.count,
            title: "Preparo i materiali…",
            detail: nil
        )
        let study = Study(name: name.trimmingCharacters(in: .whitespaces))
        // La "materia" È la cartella: si crea (o si riusa) subito, invece
        // di salvare un campo testo che una migrazione trasformerà in
        // cartella al riavvio successivo — comportamento invisibile e
        // sorprendente.
        let subjectName = subject.trimmingCharacters(in: .whitespaces)
        if !subjectName.isEmpty {
            let descriptor = FetchDescriptor<StudyFolder>()
            let existing = (try? context.fetch(descriptor)) ?? []
            if let folder = existing.first(where: { $0.name.localizedCaseInsensitiveCompare(subjectName) == .orderedSame }) {
                study.folder = folder
            } else {
                let folder = StudyFolder(name: subjectName)
                context.insert(folder)
                study.folder = folder
            }
        }
        study.sources = sources
        context.insert(study)

        var options = StudyModuleOptions()
        options.difficulty = difficulty
        options.verifyExercises = verifyExercises
        options.exerciseCount = exerciseCount
        // Si registrano solo se sono un sottoinsieme vero: "tutti" resta
        // vuoto, così il significato non cambia se domani si aggiunge
        // materiale al Vault.
        let topics = availableTopics
        options.selectedTopics = selectedTopics.count == topics.count ? [] : selectedTopics

        // L'ordine dei moduli segue l'ordine di dichiarazione dei tipi.
        // Aggancio dal lato GENITORE (modules.append): impostare solo
        // module.study può non notificare l'osservazione di `modules` —
        // trappola documentata su Note.attach in Models.swift.
        for (index, kind) in StudyModuleKind.allCases.filter({ selectedKinds.contains($0) }).enumerated() {
            let module = StudyModule(kind: kind, order: index, options: options)
            context.insert(module)
            study.modules.append(module)
        }

        let pickedSources = sources
        let payloads = pdfPayloads

        // Prima si preparano i materiali (download WeBeep, OCR, estrazione
        // PDF), poi si genera: senza testo la generazione ripiegherebbe
        // senza testo. L'estrazione può durare, quindi si resta su questa
        // schermata con l'avanzamento visibile invece di navigare via.
        Task { @MainActor in
            await StudyMaterialPreparation.prepare(
                sources: pickedSources,
                pdfPayloads: payloads,
                for: study,
                in: context,
                onProgress: { preparation = $0 }
            )
            preparation = nil
            onCreated(study)
            // Via registro, non fire-and-forget: la generazione diventa
            // annullabile dalla card del modulo.
            StudioGenerationService.startGeneration(for: study, in: context)
        }
    }

    private func toggleExamPaper(_ source: StudySourceMaterial) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].isExamPaper.toggle()
    }

    // Euristica per pre-marcare i temi d'esame al volo (l'utente può
    // sempre correggere con il toggle sulla riga).
    static func looksLikeExamPaper(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return ["tema", "esame", "appello", "prova", "tde", "exam"].contains { lowered.contains($0) }
    }

    private func sectionHeader(number: Int, title: String) -> some View {
        HStack(spacing: DesignSpace.s2 + 2) {
            Text("\(number)")
                .font(DesignFont.micro)
                .foregroundStyle(DesignColor.textOnBrand)
                .frame(width: 24, height: 24)
                .background(DesignColor.brandPrimary, in: Circle())
            Text(title)
                .font(DesignFont.cardTitle)
                .foregroundStyle(DesignColor.textPrimary)
        }
    }

    private func materialButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: icon)
                    .font(.system(size: DesignIcon.md))
                Text(title)
                    .font(DesignFont.cardTitle)
            }
            .foregroundStyle(DesignColor.brandPrimary)
            .padding(.horizontal, DesignSpace.s4)
            .padding(.vertical, DesignSpace.s3)
            .background(DesignColor.brandPrimarySubtle, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// Orizzontale se ci sta, verticale altrimenti: usato per coppie di
// controlli che in portrait (con le due sidebar aperte) non hanno spazio.
struct AdaptiveHVStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DesignSpace.s4) { content }
            VStack(alignment: .leading, spacing: DesignSpace.s3) { content }
        }
    }
}

// MARK: - Picker delle note
// Selezione multipla delle note da usare come materiali, con ricerca.
private struct StudioNotePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Note.updatedAt, order: .reverse) private var allNotes: [Note]

    let alreadySelectedNoteIDs: Set<UUID>
    var onAdd: ([StudySourceMaterial]) -> Void

    @State private var searchText = ""
    @State private var selectedIDs: Set<UUID> = []

    private var filteredNotes: [Note] {
        let available = allNotes.filter { !alreadySelectedNoteIDs.contains($0.id) }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return available }
        return available.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.content.localizedCaseInsensitiveContains(trimmed)
                || ($0.folder?.name.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        BoostSheet(
            title: "Scegli le note",
            mode: .commit(verb: "Aggiungi (\(selectedIDs.count))", enabled: !selectedIDs.isEmpty),
            onDismiss: { dismiss() },
            onConfirm: {
                let picked = allNotes.filter { selectedIDs.contains($0.id) }.map { note in
                    StudySourceMaterial(
                        kind: .note,
                        title: note.title.isEmpty ? "Senza titolo" : note.title,
                        subtitle: note.folder?.name,
                        noteID: note.id
                    )
                }
                onAdd(picked)
                dismiss()
            }
        ) {
            VStack(spacing: 0) {
                // Campo di ricerca in testa al contenuto: .searchable vuole
                // una barra di navigazione, che qui non esiste più.
                HStack(spacing: DesignSpace.s2) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: DesignIcon.sm))
                        .foregroundStyle(DesignColor.textTertiary)
                    TextField("Cerca nota", text: $searchText)
                        .font(DesignFont.body)
                        .textFieldStyle(.plain)
                }
                .padding(DesignSpace.s3)
                .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                .padding(DesignSpace.s3)

                List(filteredNotes) { note in
                    let isSelected = selectedIDs.contains(note.id)
                    Button {
                        if isSelected { selectedIDs.remove(note.id) } else { selectedIDs.insert(note.id) }
                    } label: {
                        HStack(spacing: DesignSpace.s3) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? DesignColor.brandPrimary : DesignColor.borderDefault)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title.isEmpty ? "Senza titolo" : note.title)
                                    .foregroundStyle(.primary)
                                if let folder = note.folder {
                                    Text(folder.name)
                                        .font(DesignFont.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Picker da WeBeep
// Riusa WebeepService (token già salvato dal flusso di login esistente):
// corsi → file del corso, selezione multipla. Qui si prendono solo i
// METADATI (titolo/corso) — il download del contenuto avverrà nella
// pipeline di generazione reale.
private struct StudioWebeepPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: ([StudySourceMaterial]) -> Void

    @State private var token: String? = WebeepService.savedToken
    @State private var courses: [WebeepCourse] = []
    @State private var selectedCourse: WebeepCourse?
    @State private var sections: [WebeepSection] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selected: [String: StudySourceMaterial] = [:]  // per fileurl

    var body: some View {
        BoostSheet(
            title: "Materiali da WeBeep",
            mode: .commit(verb: "Aggiungi (\(selected.count))", enabled: !selected.isEmpty),
            onDismiss: { dismiss() },
            onConfirm: {
                onAdd(Array(selected.values))
                dismiss()
            }
        ) {
            Group {
                if token == nil {
                    BoostState(
                        kind: .empty,
                        icon: "building.columns",
                        title: "WeBeep non è collegato",
                        message: "Accedi dall'ambiente WeBeep nella barra laterale, poi torna qui per scegliere i materiali del corso."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    BoostState(
                        kind: .error,
                        title: "WeBeep non risponde",
                        message: loadError,
                        action: AnyView(BoostButton("Riprova", icon: "arrow.clockwise", tone: .primary) {
                            Task {
                                if let course = selectedCourse {
                                    await loadSections(course)
                                } else {
                                    await loadCourses()
                                }
                            }
                        })
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let course = selectedCourse {
                    VStack(spacing: 0) {
                        // Livello corso: la via del ritorno sta nel
                        // contenuto, la testata resta della sheet.
                        HStack(spacing: DesignSpace.s2) {
                            BoostButton("Corsi", icon: "chevron.left", tone: .ghost, size: .compact) {
                                selectedCourse = nil
                                sections = []
                            }
                            Text(WebeepService.stripMultilang(course.fullname))
                                .font(DesignFont.label)
                                .foregroundStyle(DesignColor.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, DesignSpace.s3)
                        .padding(.top, DesignSpace.s2)
                        fileList(course)
                    }
                } else {
                    courseList
                }
            }
            .task { await loadCourses() }
        }
        .presentationDetents([.large])
    }

    private var courseList: some View {
        Group {
            if isLoading && courses.isEmpty {
                BoostState(kind: .loading, title: "Carico i corsi…")
            } else {
                List(courses) { course in
                    Button {
                        selectedCourse = course
                        Task { await loadSections(course) }
                    } label: {
                        HStack {
                            Image(systemName: "graduationcap.fill")
                                .foregroundStyle(DesignColor.brandPrimary)
                            Text(WebeepService.stripMultilang(course.fullname))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: DesignIcon.sm))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func fileList(_ course: WebeepCourse) -> some View {
        Group {
            if isLoading {
                BoostState(kind: .loading, title: "Carico i file…")
            } else {
                List {
                    ForEach(sections) { section in
                        if !section.files.isEmpty {
                            Section(WebeepService.stripMultilang(section.name?.isEmpty == false ? section.name! : "Materiali")) {
                                ForEach(section.files) { file in
                                    fileRow(file, course: course)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func fileRow(_ file: WebeepFile, course: WebeepCourse) -> some View {
        let isSelected = selected[file.fileurl] != nil
        let cleanName = WebeepService.stripMultilang(file.filename)
        return Button {
            if isSelected {
                selected.removeValue(forKey: file.fileurl)
            } else {
                selected[file.fileurl] = StudySourceMaterial(
                    kind: .webeep,
                    title: cleanName,
                    subtitle: WebeepService.stripMultilang(course.fullname),
                    isExamPaper: StudioCreateFlowView.looksLikeExamPaper(cleanName),
                    webeepFileURL: file.fileurl,
                    webeepMimeType: file.mimetype
                )
            }
        } label: {
            HStack(spacing: DesignSpace.s3) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? DesignColor.brandPrimary : DesignColor.borderDefault)
                Text(cleanName)
                    .foregroundStyle(.primary)
                Spacer()
                if StudioCreateFlowView.looksLikeExamPaper(cleanName) {
                    Text("Tema d'esame")
                        .font(DesignFont.micro)
                        .foregroundStyle(DesignColor.attention)
                        .padding(.horizontal, DesignSpace.s2)
                        .padding(.vertical, DesignSpace.s1)
                        .background(DesignColor.attentionBg, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                }
            }
        }
    }

    private func loadCourses() async {
        guard let token else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let info = try await WebeepService.siteInfo(token: token)
            courses = try await WebeepService.courses(token: token, userID: info.userid)
        } catch WebeepServiceError.invalidToken {
            // Solo il token dichiarato morto da Moodle porta al login:
            // un errore di rete NON deve buttare un token valido.
            WebeepService.signOut()
            self.token = nil
        } catch {
            loadError = "Controlla la connessione e riprova: il collegamento a WeBeep resta attivo."
        }
    }

    private func loadSections(_ course: WebeepCourse) async {
        guard let token else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            sections = try await WebeepService.contents(token: token, courseID: course.id)
        } catch WebeepServiceError.invalidToken {
            WebeepService.signOut()
            self.token = nil
        } catch {
            loadError = "Controlla la connessione e riprova: il collegamento a WeBeep resta attivo."
        }
    }
}
