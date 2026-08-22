import SwiftUI
import PhotosUI

// Schermata Profilo: dati utente, sincronizzazioni (iCloud/Obsidian),
// WeBeep/PolimiApp, chiave Wolfram Alpha, About.
struct ProfileView: View {
    // Presente quando il Profilo è un popup (iPad): la testata porta il
    // suo "Chiudi". Su iPhone resta un foglio e ci pensa il sistema.
    var onClose: (() -> Void)?

    @AppStorage("profileName") private var name = ""
    @AppStorage("profileSurname") private var surname = ""
    // SOLO per migrare: la foto stava qui come base64, ma sopra i 4 MB
    // CFPreferences protesta ("Attempting to store >= 4194304 bytes...
    // This is a bug") — una foto della libreria li supera facilmente.
    // Ora vive su disco (ProfilePhotoStore); questa chiave si svuota
    // alla prima apertura e resta solo per chi ha il vecchio valore.
    @AppStorage("profilePhotoData") private var photoDataBase64 = ""
    @State private var profilePhoto: UIImage?

    // Le chiavi salvate NON vengono mai rimesse nei campi di testo: una
    // chiave si aggiunge, si sostituisce o si rimuove, ma non si rilegge
    // dallo schermo. Prima i campi venivano precompilati col valore
    // salvato — comodo, ma significava lasciare la credenziale visibile
    // a chiunque avesse l'iPad in mano aperto sul Profilo.
    @State private var wolframSaved = AIService.wolframAppID != nil
    @State private var wolframDraft = ""
    @State private var wolframEditing = false

    @State private var anthropicSaved = AIService.claudeKey != nil
    @State private var anthropicDraft = ""
    @State private var anthropicEditing = false

    @AppStorage("aiProviderKind") private var aiProviderRaw = AIProviderKind.appleLocal.rawValue
    @AppStorage("geminiModelTier_reading") private var readingTierRaw = AIPurpose.reading.defaultTier.rawValue
    @AppStorage("geminiModelTier_generation") private var generationTierRaw = AIPurpose.generation.defaultTier.rawValue
    @State private var geminiDraft = ""
    @State private var geminiEditing = false
    @State private var geminiSaved = AIService.geminiKey != nil

    @State private var photosPickerItem: PhotosPickerItem?

    @Environment(\.modelContext) private var modelContext
    @State private var archiveConfigured = NoteArchiveService.isConfigured
    // UN SOLO fileImporter con destinazione esplicita: due .fileImporter
    // in catena sulla stessa vista sono un bug noto di SwiftUI — si
    // presenta solo l'ultimo, e il primo non apre MAI (stessa trappola
    // già pagata sull'import PDF in NoteEditorView: "Scegli cartella"
    // non faceva niente per questo).
    enum ArchivePickerTarget { case folder, restore }
    @State private var archivePickerTarget: ArchivePickerTarget = .folder
    @State private var showingArchivePicker = false
    @State private var archiveMessage: String?

    @State private var webeepToken: String? = WebeepService.savedToken
    @State private var webeepSiteInfo: WebeepSiteInfo?
    @State private var showingWebeepAuth = false
    @State private var isConnectingWebeep = false
    // WeBeep non risponde ma il token è (per quanto ne sappiamo) ancora
    // buono: stato separato dal "non collegato", perché la cura è
    // riprovare, non ri-autenticarsi.
    @State private var webeepUnreachable = false

    var body: some View {
        VStack(spacing: 0) {
            if onClose != nil {
                HStack {
                    Text("Profilo")
                        .font(.system(size: 20, weight: .ultraLight))
                        .foregroundStyle(DesignColor.textPrimary)
                    Spacer()
                    Button("Chiudi") { onClose?() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignColor.brandPrimary)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 14)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(DesignColor.borderSubtle).frame(height: 1)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profileSection
                    archiveSection
                    syncSection
                    webeepSection
                    aiSection
                    wolframSection
                    developmentSection
                    aboutSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            loadProfilePhoto()
            if let token = webeepToken { await loadWebeepSiteInfo(token: token) }
        }
        .background(DesignColor.surfacePage)
        // Niente titolo di sistema: il nome della schermata lo dà la
        // testata qui dentro, insieme al "Chiudi". Con tutti e due si
        // leggeva "Profilo" due volte, una sopra l'altra.
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showingWebeepAuth) {
            WebeepAuthView(
                onToken: { token in
                    WebeepService.save(token: token)
                    webeepToken = token
                    showingWebeepAuth = false
                    Task { await loadWebeepSiteInfo(token: token) }
                },
                onCancel: { showingWebeepAuth = false }
            )
            .ignoresSafeArea()
        }
    }

    private func loadWebeepSiteInfo(token: String) async {
        isConnectingWebeep = true
        webeepUnreachable = false
        defer { isConnectingWebeep = false }
        do {
            webeepSiteInfo = try await WebeepService.siteInfo(token: token)
        } catch WebeepServiceError.invalidToken {
            // SOLO qui il token è davvero morto (Moodle l'ha detto):
            // prima QUALSIASI fallimento — anche un timeout in treno —
            // buttava il token dal Keychain e costringeva al ri-login.
            WebeepService.signOut()
            webeepToken = nil
            webeepSiteInfo = nil
        } catch {
            // Rete giù o risposta in una forma nuova: il token si
            // CONSERVA e si dice che WeBeep non è raggiungibile.
            webeepSiteInfo = nil
            webeepUnreachable = true
        }
    }

    private var photoImage: Image? {
        profilePhoto.map { Image(uiImage: $0) }
    }

    private func loadProfilePhoto() {
        if !photoDataBase64.isEmpty {
            // Migrazione una tantum dal vecchio base64 in UserDefaults.
            if let data = Data(base64Encoded: photoDataBase64) {
                profilePhoto = ProfilePhotoStore.save(data)
            }
            photoDataBase64 = ""
        } else if profilePhoto == nil {
            profilePhoto = ProfilePhotoStore.load()
        }
    }

    private var profileSection: some View {
        sectionCard(title: "Profilo") {
            HStack(spacing: DesignSpace.s4) {
                PhotosPicker(selection: $photosPickerItem, matching: .images) {
                    ZStack {
                        Circle().fill(DesignColor.surfacePage).frame(width: 64, height: 64)
                        if let photoImage {
                            photoImage.resizable().scaledToFill().frame(width: 64, height: 64).clipShape(Circle())
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(DesignColor.textTertiary)
                        }
                    }
                }
                .onChange(of: photosPickerItem) { _, newItem in
                    guard let newItem else { return }
                    Task {
                        if let data = try? await newItem.loadTransferable(type: Data.self) {
                            profilePhoto = ProfilePhotoStore.save(data)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    profileField("Nome", text: $name)
                    profileField("Cognome", text: $surname)
                }
            }
        }
    }

    private func profileField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
    }

    // "Sviluppo": le manopole che si toccano di rado e che vanno capite
    // prima di girarle (curva della penna, quota dei modelli). Stavano
    // sparse tra le altre sezioni e sembravano impostazioni quotidiane;
    // raccolte qui restano raggiungibili senza stare in mezzo.
    private var developmentSection: some View {
        sectionCard(title: "Sviluppo") {
            VStack(spacing: DesignSpace.s3) {
                NavigationLink {
                    PenTuningPage()
                } label: {
                    settingsRow(
                        icon: "pencil.tip",
                        title: "Taratura della penna",
                        subtitle: "Pressione, fluidità del tratto"
                    )
                }
                .buttonStyle(.plain)

                Divider()

                NavigationLink {
                    MaterialReadingPage(
                        readingTierRaw: $readingTierRaw,
                        generationTierRaw: $generationTierRaw
                    )
                } label: {
                    settingsRow(
                        icon: "text.viewfinder",
                        title: "Lettura dei materiali",
                        subtitle: "Quota Gemini: modelli Lite o Flash"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func settingsRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: DesignSpace.s3) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(DesignColor.brandPrimary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignColor.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignColor.textSecondary)
        }
        .contentShape(Rectangle())
    }

    // L'assicurazione sulla vita delle note: cartella OneDrive (o
    // qualunque provider di File) dove ogni nota chiusa lascia il suo
    // pacchetto ripristinabile. Vedi NoteArchiveService per le regole.
    private var archiveSection: some View {
        sectionCard(title: "Archivio delle note") {
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                if archiveConfigured {
                    HStack(spacing: DesignSpace.s2) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(DesignColor.success)
                        Text("Attivo su \"\(NoteArchiveService.folderDisplayName ?? "cartella scelta")\"")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("Disattiva") {
                            NoteArchiveService.removeFolder()
                            archiveConfigured = false
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignColor.danger)
                        .buttonStyle(.plain)
                    }
                    Text("Ogni nota, quando la chiudi, lascia nella cartella il suo pacchetto .boostnote: se perdi l'iPad, reimporti i pacchetti e le note tornano modificabili identiche. La scrittura avviene in background e non tocca mai la penna.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textSecondary)
                    HStack(spacing: DesignSpace.s3) {
                        toneButton("Archivia tutte adesso", icon: "arrow.up.doc") {
                            let count = NoteArchiveService.archiveAll(in: modelContext)
                            archiveMessage = "In archiviazione: \(count) note."
                        }
                        toneButton("Ripristina da pacchetto", icon: "arrow.down.doc") {
                            archivePickerTarget = .restore
                            showingArchivePicker = true
                        }
                    }
                    if let archiveMessage {
                        Text(archiveMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(DesignColor.textSecondary)
                    }
                } else {
                    Text("Scegli una cartella su OneDrive (1TB gratuito con l'account Polimi, dall'app File) o su qualunque altro provider: ogni nota chiusa ci lascerà una copia ripristinabile. Il database dell'app resta sul dispositivo — nella cartella vanno solo copie.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textSecondary)
                    HStack(spacing: DesignSpace.s3) {
                        toneButton("Scegli cartella", icon: "folder.badge.plus", tone: .filled) {
                            archivePickerTarget = .folder
                            showingArchivePicker = true
                        }
                        toneButton("Ripristina da pacchetto", icon: "arrow.down.doc") {
                            archivePickerTarget = .restore
                            showingArchivePicker = true
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingArchivePicker,
            allowedContentTypes: archivePickerTarget == .folder ? [.folder] : [NoteArchiveService.packageType],
            allowsMultipleSelection: archivePickerTarget == .restore
        ) { result in
            guard case .success(let urls) = result, let first = urls.first else { return }
            switch archivePickerTarget {
            case .folder:
                if NoteArchiveService.setFolder(first) {
                    archiveConfigured = true
                    let count = NoteArchiveService.archiveAll(in: modelContext)
                    archiveMessage = "Prima archiviazione: \(count) note in coda."
                } else {
                    archiveMessage = "Non riesco a memorizzare l'accesso alla cartella."
                }
            case .restore:
                var restored = 0
                var failed = 0
                for url in urls where url.pathExtension == "boostnote" {
                    do {
                        _ = try NoteArchiveService.restore(from: url, in: modelContext)
                        restored += 1
                    } catch {
                        failed += 1
                    }
                }
                let skipped = urls.count - restored - failed
                var parts = ["Ripristinate \(restored) note."]
                if failed > 0 { parts.append("\(failed) pacchetti illeggibili.") }
                if skipped > 0 { parts.append("\(skipped) file ignorati (non .boostnote).") }
                archiveMessage = parts.joined(separator: " ")
            }
        }
    }

    // Niente interruttori finti: il toggle iCloud non pilotava nulla (il
    // container CloudKit si decide al lancio, in StudioApp) e quello
    // Obsidian accendeva una funzione che non esiste. Qui si DESCRIVE lo
    // stato vero, non si finge di controllarlo.
    private var syncSection: some View {
        sectionCard(title: "Sincronizzazioni") {
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                Label("iCloud", systemImage: "icloud")
                    .font(.system(size: 14, weight: .medium))
                Text("Le note si sincronizzano da sole tra i tuoi dispositivi quando l'iPad è connesso al tuo account iCloud: non c'è nulla da attivare qui. Senza iCloud, tutto resta comunque salvato sul dispositivo.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textSecondary)

                Divider()

                HStack {
                    Label("Obsidian", systemImage: "note.text")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text("In arrivo")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignColor.textTertiary)
                }
                Text("Collegamento a un vault Obsidian — non ancora disponibile.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textSecondary)
            }
        }
    }

    private var webeepSection: some View {
        sectionCard(title: "WeBeep / PolimiApp") {
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                Text("WeBeep gira su Moodle: il login avviene sulla vera pagina Polimi in un browser incorporato, l'app non vede mai la password. Integrazione non ufficiale — può smettere di funzionare se Polimi cambia configurazione.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textSecondary)

                if let webeepSiteInfo {
                    Label("Connesso come \(webeepSiteInfo.fullname)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignColor.success)
                    Text("Sfoglia corsi e file dalla scheda WeBeep nella barra laterale.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textSecondary)
                    Button("Disconnetti") {
                        WebeepService.signOut()
                        webeepToken = nil
                        self.webeepSiteInfo = nil
                    }
                    .buttonStyle(.boostDestructive)
                } else if isConnectingWebeep {
                    ProgressView("Verifica connessione…")
                } else if webeepUnreachable, let token = webeepToken {
                    Label("WeBeep non risponde in questo momento", systemImage: "wifi.exclamationmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignColor.attention)
                    Text("Il collegamento resta attivo: probabilmente è la rete, o WeBeep è giù. Riprova tra poco.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textSecondary)
                    Button("Riprova") {
                        Task { await loadWebeepSiteInfo(token: token) }
                    }
                    .buttonStyle(.boostOutlined)
                } else {
                    Button("Accedi con WeBeep") {
                        showingWebeepAuth = true
                    }
                    .buttonStyle(.boostFilled)
                }
            }
        }
    }

    // Provider per la generazione AI dello Studio. Vincolo dell'app:
    // l'inferenza avviene sempre dal dispositivo con la chiave dell'utente
    // (o col modello Apple locale) — nessun server centralizzato, così
    // l'app resta gratuita a prescindere da quanti utenti ha.
    private var aiSection: some View {
        sectionCard(title: "AI per lo Studio") {
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                Text("Genera riassunti, esercizi, esercizi teorici e flashcard nell'ambiente Studio. Senza provider configurato la generazione si ferma con il motivo, e puoi riprovare dopo averlo impostato.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textSecondary)

                HStack(spacing: 0) {
                    ForEach(AIProviderKind.allCases, id: \.rawValue) { kind in
                        let isOn = aiProviderRaw == kind.rawValue
                        Button {
                            aiProviderRaw = kind.rawValue
                        } label: {
                            Text(kind.label)
                                .font(.system(size: 12.5, weight: isOn ? .semibold : .medium))
                                .foregroundStyle(isOn ? DesignColor.brandPrimary : DesignColor.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    isOn ? DesignColor.brandPrimarySubtle : .clear,
                                    in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))

                if let kind = AIProviderKind(rawValue: aiProviderRaw) {
                    Text(kind.hint)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textSecondary)
                }

                if aiProviderRaw == AIProviderKind.gemini.rawValue {
                    Divider()

                    // La scelta di quale modello usare (quante chiamate al
                    // giorno, non "quanto è bravo") vive in Sviluppo ›
                    // Lettura dei materiali: qui basta la chiave.
                    Label("Quale modello Gemini usare per lettura e generazione si sceglie in Sviluppo › Lettura dei materiali.", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textSecondary)

                    credentialEditor(
                        placeholder: "Chiave API Gemini",
                        isSaved: geminiSaved,
                        isEditing: $geminiEditing,
                        draft: $geminiDraft,
                        onSave: {
                            AIService.saveGeminiKey(geminiDraft)
                            geminiSaved = AIService.geminiKey != nil
                        },
                        onRemove: {
                            AIService.saveGeminiKey("")
                            geminiSaved = false
                        }
                    )
                }

                if aiProviderRaw == AIProviderKind.claude.rawValue {
                    Divider()

                    Text("La stessa chiave la usa la penna magica per l'azione \"Spiega\". Si crea su console.anthropic.com.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textSecondary)

                    credentialEditor(
                        placeholder: "Chiave API Anthropic",
                        isSaved: anthropicSaved,
                        isEditing: $anthropicEditing,
                        draft: $anthropicDraft,
                        onSave: {
                            AIService.saveClaudeKey(anthropicDraft)
                            anthropicSaved = AIService.claudeKey != nil
                        },
                        onRemove: {
                            AIService.saveClaudeKey("")
                            anthropicSaved = false
                        }
                    )
                }
            }
        }
    }

    // Editor di una credenziale che non la lascia mai a schermo: da
    // salvata mostra solo "Chiave salvata" con Sostituisci/Rimuovi, e il
    // campo (vuoto) compare solo mentre si sta inserendo. Il valore
    // salvato non viene MAI riletto nel campo.
    @ViewBuilder
    private func credentialEditor(
        placeholder: String,
        savedLabel: String = "Chiave salvata in Keychain",
        isSaved: Bool,
        isEditing: Binding<Bool>,
        draft: Binding<String>,
        onSave: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) -> some View {
        if isEditing.wrappedValue {
            HStack {
                SecureField(placeholder, text: draft)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(DesignSpace.s3)
                    .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md))
                Button("Salva") {
                    onSave()
                    draft.wrappedValue = ""
                    isEditing.wrappedValue = false
                }
                .buttonStyle(.boostFilled)
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Annulla") {
                    draft.wrappedValue = ""
                    isEditing.wrappedValue = false
                }
                .buttonStyle(.boostOutlined)
            }
        } else if isSaved {
            HStack(spacing: DesignSpace.s3) {
                Label(savedLabel, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignColor.success)
                Spacer()
                Button("Sostituisci") { isEditing.wrappedValue = true }
                    .buttonStyle(.boostOutlined)
                Button("Rimuovi", action: onRemove)
                    .buttonStyle(.boostDestructive)
            }
        } else {
            Button {
                isEditing.wrappedValue = true
            } label: {
                Label("Aggiungi chiave", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.boostFilled)
        }
    }

    private var wolframSection: some View {
        sectionCard(title: "Wolfram Alpha") {
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                Text("Usata dalla penna magica (azione \"Wolfram\") per risolvere le espressioni cerchiate, e dallo strumento Wolfram del pannello laterale della nota.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textSecondary)
                credentialEditor(
                    placeholder: "AppID",
                    isSaved: wolframSaved,
                    isEditing: $wolframEditing,
                    draft: $wolframDraft,
                    onSave: {
                        AIService.saveWolframAppID(wolframDraft)
                        wolframSaved = AIService.wolframAppID != nil
                    },
                    onRemove: {
                        AIService.saveWolframAppID("")
                        wolframSaved = false
                    }
                )
            }
        }
    }

    private var aboutSection: some View {
        sectionCard(title: "About") {
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                VStack(alignment: .leading, spacing: DesignSpace.s1) {
                    Text("BoostNote").font(.system(size: 14, weight: .semibold))
                    Text("Versione 0.1 — app di note per iPad con Apple Pencil.")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignColor.textSecondary)
                }

            }
        }
    }

    private enum ButtonTone { case filled, outlined, destructive }

    private func toneButton(_ title: String, icon: String? = nil, tone: ButtonTone = .outlined, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                }
                Text(title)
            }
        }
        .buttonStyle(tone == .filled ? .boostFilled : (tone == .destructive ? .boostDestructive : .boostOutlined))
    }

    @ViewBuilder
    private func sectionCard(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)
                .padding(.leading, 2)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
        }
    }
}

// Pagina "Scrittura": i cursori su una schermata dedicata, spinta dal
// NavigationStack che contiene il Profilo.
private struct PenTuningPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpace.s6) {
                PenTuningControls()
                    .padding(DesignSpace.s5)
                    .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
            }
            .padding(DesignSpace.s6)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DesignColor.surfacePage)
        .navigationTitle("Scrittura")
    }
}

// Pagina "Lettura dei materiali": quale modello Gemini usare per leggere
// i materiali e per generare i contenuti. La scelta non è "quanto è
// bravo" ma QUANTE chiamate al giorno concede il piano gratuito — il
// Flash ne dà ~20, il Lite ~500 — quindi il contatore di consumo di oggi
// sta sulla stessa pagina, altrimenti si sceglie alla cieca.
private struct MaterialReadingPage: View {
    @Binding var readingTierRaw: String
    @Binding var generationTierRaw: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpace.s5) {
                Text("Lettura e generazione sono separate perché hanno profili opposti: trascrivere pagine costa tante chiamate su un compito semplice, generare ne costa poche ma è lì che serve un modello capace.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textSecondary)

                modelTierPicker(for: .reading, selection: $readingTierRaw)
                modelTierPicker(for: .generation, selection: $generationTierRaw)

                Label("Se la quota di un modello finisce, l'app passa da sola all'altro.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.success)

                Divider()

                GeminiQuotaPanel()
            }
            .padding(DesignSpace.s5)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
            .padding(DesignSpace.s6)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DesignColor.surfacePage)
        .navigationTitle("Lettura dei materiali")
    }

    private func modelTierPicker(for purpose: AIPurpose, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DesignSpace.s2) {
            Text(purpose.label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DesignColor.textSecondary)
            Text(purpose.explanation)
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textSecondary)
            BoostSegmented(
                options: GeminiModelTier.allCases.map { ($0.rawValue, $0.label) },
                selection: selection
            )
            if let tier = GeminiModelTier(rawValue: selection.wrappedValue) {
                Text(tier.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignColor.textSecondary)
            }
        }
    }
}

// Cursori della curva pressione→spessore e della fluidità del tratto.
// La verità vive nelle statiche InkPressure/InkSmoothing (persistite in
// UserDefaults): qui solo lo specchio locale per i binding SwiftUI.
private struct PenTuningControls: View {
    @State private var floor = Double(InkPressure.floor)
    @State private var gamma = Double(InkPressure.gamma)
    @State private var smoothing = Double(InkSmoothing.minPointDistance)

    // Anteprima sullo spessore di partenza della penna: qui non c'è una
    // penna selezionata di cui leggere il valore vero.
    private let previewWidth: CGFloat = PenTool.pen.defaultWidth

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            HStack {
                Text("Come risponde la penna alla pressione e quanto viene levigato il tratto.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if floor != InkPressure.defaultFloor || gamma != InkPressure.defaultGamma
                    || smoothing != InkSmoothing.defaultDistance {
                    Button("Ripristina") {
                        floor = InkPressure.defaultFloor
                        gamma = InkPressure.defaultGamma
                        smoothing = InkSmoothing.defaultDistance
                    }
                    .font(.system(size: 12))
                }
            }

            labeledValue("Tratto a tocco leggero", floor.formatted(.percent.precision(.fractionLength(0))))
            Slider(value: $floor, in: 0.15...1.0, step: 0.05)
                .tint(DesignColor.brandPrimary)
            captions("sottile", "pressione ignorata")

            labeledValue("Risposta alla pressione", gamma.formatted(.number.precision(.fractionLength(1))))
            Slider(value: $gamma, in: 0.5...2.5, step: 0.1)
                .tint(DesignColor.brandPrimary)
            captions("reattiva", "graduale")

            labeledValue("Fluidità", smoothing.formatted(.number.precision(.fractionLength(1))))
            Slider(value: $smoothing, in: 0...5, step: 0.5)
                .tint(DesignColor.brandPrimary)
            captions("fedele al polso", "morbida")

            HStack(spacing: DesignSpace.s3) {
                previewStroke("leggero", width: previewWidth * floor)
                previewStroke("deciso", width: previewWidth)
            }
        }
        .onChange(of: floor) { _, newValue in InkPressure.floor = CGFloat(newValue) }
        .onChange(of: gamma) { _, newValue in InkPressure.gamma = CGFloat(newValue) }
        .onChange(of: smoothing) { _, newValue in InkSmoothing.minPointDistance = CGFloat(newValue) }
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(DesignColor.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(DesignColor.textSecondary)
        }
    }

    private func captions(_ leading: String, _ trailing: String) -> some View {
        HStack {
            Text(leading)
            Spacer()
            Text(trailing)
        }
        .font(.system(size: 10))
        .foregroundStyle(DesignColor.textSecondary)
    }

    private func previewStroke(_ label: String, width: CGFloat) -> some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                .fill(DesignColor.textPrimary)
                .frame(height: max(1, min(width, 26)))
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.12), value: width)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DesignColor.textSecondary)
        }
    }
}

// La foto profilo vive su DISCO, non in UserDefaults: una foto della
// libreria supera facilmente i 4 MB e CFPreferences oltre quella soglia
// è dichiaratamente un bug ("Attempting to store >= 4194304 bytes").
// È un avatar: si ridimensiona a 512 pt e si salva come JPEG.
private enum ProfilePhotoStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profile-photo.jpg")
    }

    @discardableResult
    static func save(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 512
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        try? resized.jpegData(compressionQuality: 0.85)?.write(to: url, options: .atomic)
        return resized
    }

    static func load() -> UIImage? {
        (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
    }
}
