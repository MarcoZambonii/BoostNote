import SwiftUI
import PhotosUI

// Schermata Profilo: dati utente, sincronizzazioni (iCloud/Obsidian),
// WeBeep/PolimiApp, chiave Wolfram Alpha, About.
struct ProfileView: View {
    @AppStorage("profileName") private var name = ""
    @AppStorage("profileSurname") private var surname = ""
    @AppStorage("profilePhotoData") private var photoDataBase64 = ""

    @AppStorage("syncICloud") private var syncICloud = false
    @AppStorage("syncObsidian") private var syncObsidian = false

    @AppStorage("wolframAlphaAppID") private var wolframAppID = ""
    @State private var wolframDraft = ""

    @AppStorage("anthropicAPIKey") private var anthropicAPIKey = ""
    @State private var anthropicDraft = ""

    @State private var photosPickerItem: PhotosPickerItem?

    @State private var webeepToken: String? = WebeepService.savedToken
    @State private var webeepSiteInfo: WebeepSiteInfo?
    @State private var showingWebeepAuth = false
    @State private var isConnectingWebeep = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpace.s8) {
                profileSection
                syncSection
                webeepSection
                wolframSection
                anthropicSection
                aboutSection
            }
            .padding(DesignSpace.s6)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            wolframDraft = wolframAppID
            anthropicDraft = anthropicAPIKey
        }
        .task {
            if let token = webeepToken { await loadWebeepSiteInfo(token: token) }
        }
        .background(DesignColor.surfacePage)
        .navigationTitle("Profilo")
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
        webeepSiteInfo = await WebeepService.siteInfo(token: token)
        isConnectingWebeep = false
        if webeepSiteInfo == nil {
            // Il token salvato non funziona più (scaduto o revocato).
            WebeepService.signOut()
            webeepToken = nil
        }
    }

    private var photoImage: Image? {
        guard let data = Data(base64Encoded: photoDataBase64), let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
    }

    private var profileSection: some View {
        sectionCard(title: "Profilo") {
            HStack(spacing: DesignSpace.s4) {
                PhotosPicker(selection: $photosPickerItem, matching: .images) {
                    ZStack {
                        Circle().fill(DesignColor.surfaceSunken).frame(width: 64, height: 64)
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
                            photoDataBase64 = data.base64EncodedString()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: DesignSpace.s2) {
                    TextField("Nome", text: $name)
                        .textFieldStyle(.plain)
                        .padding(DesignSpace.s2)
                        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.sm))
                    TextField("Cognome", text: $surname)
                        .textFieldStyle(.plain)
                        .padding(DesignSpace.s2)
                        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.sm))
                }
            }
        }
    }

    private var syncSection: some View {
        sectionCard(title: "Sincronizzazioni") {
            VStack(spacing: DesignSpace.s3) {
                Toggle(isOn: $syncICloud) {
                    Label("iCloud", systemImage: "icloud")
                }
                Text("Richiede la capability iCloud/CloudKit attiva sul progetto Xcode per sincronizzare davvero tra dispositivi.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textTertiary)

                Divider()

                Toggle(isOn: $syncObsidian) {
                    Label("Obsidian", systemImage: "note.text")
                }
                Text("Collegamento a un vault Obsidian — non ancora disponibile, in arrivo.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textTertiary)
            }
        }
    }

    private var webeepSection: some View {
        sectionCard(title: "WeBeep / PolimiApp") {
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                Text("WeBeep gira su Moodle: il login avviene sulla vera pagina Polimi in un browser incorporato, l'app non vede mai la password. Integrazione non ufficiale — può smettere di funzionare se Polimi cambia configurazione.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textTertiary)

                if let webeepSiteInfo {
                    Label("Connesso come \(webeepSiteInfo.fullname)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignColor.success)
                    Text("Sfoglia corsi e file dalla scheda WeBeep nella barra laterale.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textTertiary)
                    Button("Disconnetti", role: .destructive) {
                        WebeepService.signOut()
                        webeepToken = nil
                        self.webeepSiteInfo = nil
                    }
                    .buttonStyle(.bordered)
                } else if isConnectingWebeep {
                    ProgressView("Verifica connessione…")
                } else {
                    Button("Accedi con WeBeep") {
                        showingWebeepAuth = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var wolframSection: some View {
        sectionCard(title: "Wolfram Alpha") {
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                Text("Usata dalla penna magica (azione \"Wolfram\") per risolvere le espressioni cerchiate, e dal widget Wolfram inserito nelle note.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textTertiary)
                HStack {
                    TextField("AppID", text: $wolframDraft)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(DesignSpace.s3)
                        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md))
                    Button("Salva") {
                        wolframAppID = wolframDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !wolframAppID.isEmpty {
                    Label("Chiave salvata", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignColor.success)
                }
            }
        }
    }

    private var anthropicSection: some View {
        sectionCard(title: "Anthropic (Claude)") {
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                Text("Usata dalla penna magica (azione \"Spiega\") per spiegare un'espressione cerchiata. Crea una chiave su console.anthropic.com.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textTertiary)
                HStack {
                    SecureField("Chiave API", text: $anthropicDraft)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(DesignSpace.s3)
                        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md))
                    Button("Salva") {
                        anthropicAPIKey = anthropicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !anthropicAPIKey.isEmpty {
                    Label("Chiave salvata", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignColor.success)
                }
            }
        }
    }

    private var aboutSection: some View {
        sectionCard(title: "About") {
            VStack(alignment: .leading, spacing: DesignSpace.s1) {
                Text("BoostNote").font(.system(size: 14, weight: .semibold))
                Text("Versione 0.1 — app di note per iPad con Apple Pencil.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func sectionCard(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)
            content()
                .padding(DesignSpace.s4)
                .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
        }
    }
}
