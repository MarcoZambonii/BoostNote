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
    @State private var selectedKinds: Set<StudyModuleKind> = [.summary, .exercises]

    // Opzioni per il modulo esercizi (ignorate dagli altri moduli).
    @State private var difficulty: ExerciseDifficulty? = nil
    @State private var includeTheoretical = true
    @State private var includePractical = true
    @State private var verifyExercises = true
    @State private var theoreticalCount = 1
    @State private var practicalCount = 1

    @State private var showingNotePicker = false
    @State private var showingWebeepPicker = false
    @State private var showingPDFImporter = false

    // Contenuto dei PDF scelti, tenuto qui perché l'accesso al file
    // dell'utente vale solo dentro la callback del file importer.
    @State private var pdfPayloads: [UUID: Data] = [:]
    @State private var preparation: StudyMaterialPreparation.Progress?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpace.s3) {
                Button(action: onCancel) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Torna a Studio")
                .disabled(preparation != nil)

                Text("Crea nuovo studio")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)
                Spacer()
            }
            .padding(.horizontal, DesignSpace.s6 + 4)
            .frame(height: 56)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DesignColor.borderDefault).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpace.s8) {
                    nameSection
                    materialsSection
                    modulesSection
                }
                .padding(DesignSpace.s6)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            generateBar
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
            for url in urls {
                // Il contenuto va letto ORA: l'accesso security-scoped
                // all'URL scelto dall'utente non sopravvive a questa
                // callback, e alla generazione il file non sarebbe più
                // leggibile.
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }

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
            .font(.system(size: 15, weight: .medium))
            .padding(DesignSpace.s3)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
    }

    private var subjectField: some View {
        TextField("Materia (es. Analisi 1)", text: $subject)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .padding(DesignSpace.s3)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
    }

    @ViewBuilder
    private var materialButtons: some View {
        materialButton(title: "Dalle note", icon: "note.text") { showingNotePicker = true }
        materialButton(title: "Da WeBeep", icon: "building.columns.fill") { showingWebeepPicker = true }
        materialButton(title: "Carica PDF", icon: "doc.badge.plus") { showingPDFImporter = true }
    }

    private var materialsSection: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            sectionHeader(number: 2, title: "Scegli i materiali di partenza")
            Text("Note, slide e dispense generano teoria (riassunti, domande, flashcard); i temi d'esame alimentano gli esercizi pratici.")
                .font(.system(size: 13))
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
        }
    }

    private func sourceRow(_ source: StudySourceMaterial) -> some View {
        HStack(spacing: DesignSpace.s3) {
            Image(systemName: source.kind.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(DesignColor.brandPrimary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignColor.textPrimary)
                    .lineLimit(1)
                if let subtitle = source.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
            Spacer()

            // Toggle "tema d'esame": decide se il materiale alimenta gli
            // esercizi pratici invece della teoria.
            Button {
                toggleExamPaper(source)
            } label: {
                Text("Tema d'esame")
                    .fixedSize()
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(source.isExamPaper ? DesignColor.toolWolfram : DesignColor.textTertiary)
                    .padding(.horizontal, DesignSpace.s2 + 2)
                    .padding(.vertical, 5)
                    .background(
                        source.isExamPaper ? DesignColor.toolWolframBg : DesignColor.surfacePage,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(source.isExamPaper ? DesignColor.toolWolfram.opacity(0.4) : DesignColor.borderDefault, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                sources.removeAll { $0.id == source.id }
                pdfPayloads.removeValue(forKey: source.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DesignColor.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rimuovi \(source.title)")
        }
        .padding(.horizontal, DesignSpace.s3 + 2)
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
                    .overlay(Image(systemName: kind.systemImage).font(.system(size: 16, weight: .medium)).foregroundStyle(kind.color))
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(kind.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textTertiary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
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
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: DesignSpace.s2)], alignment: .leading, spacing: DesignSpace.s2) {
                difficultyChip(nil, label: "Mista")
                ForEach(ExerciseDifficulty.allCases, id: \.self) { level in
                    difficultyChip(level, label: level.label)
                }
            }

            // Un'unica riga per categoria: interruttore + quanti
            // argomenti coprire. Tenerli separati costringeva a spegnere
            // in un punto e contare in un altro.
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                categoryRow(
                    title: "Teorici",
                    detail: "Dagli argomenti di note e dispense",
                    isOn: $includeTheoretical,
                    count: $theoreticalCount
                )
                Divider()
                categoryRow(
                    title: "Pratici",
                    detail: "Dagli argomenti dei temi d'esame",
                    isOn: $includePractical,
                    count: $practicalCount
                )
                Text("Gli **argomenti li individua l'app** leggendo i materiali, e li copre tutti. Questo numero dice quanti esercizi fare **per ciascun argomento**: alzalo per insistere di più su ogni cosa.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if theoreticalCount + practicalCount > 3 {
                    Label("Con molti argomenti nei materiali il totale cresce in fretta: oltre 15 esercizi la generazione riduce da sola il numero per argomento, per coprirli comunque tutti.", systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.toolWolfram)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Toggle(isOn: $verifyExercises) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Verifica gli esercizi").font(.system(size: 13, weight: .medium))
                    Text("Ogni esercizio viene risolto una seconda volta in modo indipendente; se le due soluzioni non coincidono viene scartato. Usa una chiamata in più.")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
            .toggleStyle(.switch)
            .tint(DesignColor.success)
        }
        .padding(DesignSpace.s4)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }

    private func categoryRow(title: String, detail: String, isOn: Binding<Bool>, count: Binding<Int>) -> some View {
        HStack(spacing: DesignSpace.s3) {
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
                .tint(DesignColor.brandPrimary)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn.wrappedValue ? DesignColor.textPrimary : DesignColor.textTertiary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignColor.textTertiary)
            }

            Spacer(minLength: DesignSpace.s3)

            HStack(spacing: DesignSpace.s2) {
                Text("\(count.wrappedValue)")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(isOn.wrappedValue ? DesignColor.brandPrimary : DesignColor.textTertiary)
                    .frame(minWidth: 22)
                Text("per argomento")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignColor.textTertiary)
                Stepper(value: count, in: 0...3) { EmptyView() }
                    .labelsHidden()
                    .fixedSize()
            }
            .opacity(isOn.wrappedValue ? 1 : 0.4)
            .disabled(!isOn.wrappedValue)
        }
    }

    private func difficultyChip(_ level: ExerciseDifficulty?, label: String) -> some View {
        let isSelected = difficulty == level
        return Button {
            difficulty = level
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? DesignColor.textOnBrand : DesignColor.textSecondary)
                .padding(.horizontal, DesignSpace.s3 + 2)
                .padding(.vertical, 7)
                .background(
                    isSelected ? DesignColor.brandPrimary : DesignColor.surfacePage,
                    in: Capsule()
                )
                .overlay(Capsule().stroke(isSelected ? Color.clear : DesignColor.borderDefault, lineWidth: 1))
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
        VStack(alignment: .trailing, spacing: DesignSpace.s2) {
            // L'estrazione (OCR della scrittura a mano, PDF scansionati,
            // download WeBeep) può durare parecchi secondi: senza questo
            // sembrerebbe che l'app si sia piantata.
            if let preparation {
                HStack(spacing: DesignSpace.s2) {
                    ProgressView().controlSize(.small)
                    Text("Leggo i materiali — \(preparation.current) di \(preparation.total): \(preparation.title)")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textSecondary)
                        .lineLimit(1)
                    Spacer()
                }
            }

            if !missingRequirements.isEmpty {
                Label("Manca ancora: \(missingRequirements.joined(separator: ", ")).", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                createStudy()
            } label: {
                HStack(spacing: DesignSpace.s2) {
                    Image(systemName: "sparkles")
                    Text("Genera studio")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignColor.textOnBrand)
                .padding(.horizontal, DesignSpace.s5)
                .padding(.vertical, DesignSpace.s3)
                .background(
                    canGenerate ? DesignColor.brandPrimary : DesignColor.gray300,
                    in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canGenerate || preparation != nil)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, DesignSpace.s6)
        .padding(.vertical, DesignSpace.s4)
        .background(DesignColor.surfacePage)
        .overlay(alignment: .top) {
            Rectangle().fill(DesignColor.borderDefault).frame(height: 1)
        }
    }

    private func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func createStudy() {
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
        options.includeTheoretical = includeTheoretical
        options.includePractical = includePractical
        options.verifyExercises = verifyExercises
        options.theoreticalCount = includeTheoretical ? theoreticalCount : 0
        options.practicalCount = includePractical ? practicalCount : 0

        // L'ordine dei moduli segue l'ordine di dichiarazione dei tipi.
        for (index, kind) in StudyModuleKind.allCases.filter({ selectedKinds.contains($0) }).enumerated() {
            let module = StudyModule(kind: kind, order: index, options: options, study: study)
            context.insert(module)
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
            await StudioGenerationService.generateModules(for: study, in: context)
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
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DesignColor.textOnBrand)
                .frame(width: 24, height: 24)
                .background(DesignColor.brandPrimary, in: Circle())
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
        }
    }

    private func materialButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(DesignColor.brandPrimary)
            .padding(.horizontal, DesignSpace.s4)
            .padding(.vertical, DesignSpace.s2 + 2)
            .background(DesignColor.brandPrimarySubtle, in: Capsule())
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
        NavigationStack {
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
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Cerca nota")
            .navigationTitle("Scegli le note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aggiungi (\(selectedIDs.count))") {
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
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
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
    @State private var selected: [String: StudySourceMaterial] = [:]  // per fileurl

    var body: some View {
        NavigationStack {
            Group {
                if token == nil {
                    VStack(spacing: DesignSpace.s3) {
                        Image(systemName: "building.columns")
                            .font(.system(size: 32))
                            .foregroundStyle(DesignColor.textTertiary)
                        Text("WeBeep non è collegato")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Accedi dall'ambiente WeBeep nella barra laterale, poi torna qui per scegliere i materiali del corso.")
                            .font(.system(size: 13))
                            .foregroundStyle(DesignColor.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let course = selectedCourse {
                    fileList(course)
                } else {
                    courseList
                }
            }
            .navigationTitle(selectedCourse.map { WebeepService.stripMultilang($0.fullname) } ?? "Materiali da WeBeep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selectedCourse != nil {
                        Button("Corsi") {
                            selectedCourse = nil
                            sections = []
                        }
                    } else {
                        Button("Annulla") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aggiungi (\(selected.count))") {
                        onAdd(Array(selected.values))
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .task { await loadCourses() }
        }
    }

    private var courseList: some View {
        Group {
            if isLoading && courses.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                .font(.system(size: 12, weight: .semibold))
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
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignColor.toolWolfram)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(DesignColor.toolWolframBg, in: Capsule())
                }
            }
        }
    }

    private func loadCourses() async {
        guard let token else { return }
        isLoading = true
        defer { isLoading = false }
        guard let info = await WebeepService.siteInfo(token: token) else {
            WebeepService.signOut()
            self.token = nil
            return
        }
        courses = await WebeepService.courses(token: token, userID: info.userid)
    }

    private func loadSections(_ course: WebeepCourse) async {
        guard let token else { return }
        isLoading = true
        defer { isLoading = false }
        sections = await WebeepService.contents(token: token, courseID: course.id)
    }
}
