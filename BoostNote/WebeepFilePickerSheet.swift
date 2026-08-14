import SwiftUI

// Selettore di un PDF direttamente dai corsi WeBeep, per il pannello
// Documento: corso → file, scarica e consegna i byte al chiamante.
// Niente download manuale e re-import dai File: il percorso più comune
// (leggere le slide del corso mentre si scrive) diventa due tocchi.
struct WebeepFilePickerSheet: View {
    var onPicked: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var courses: [WebeepCourse] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var token: String? { WebeepService.savedToken }

    var body: some View {
        NavigationStack {
            Group {
                if token == nil {
                    ContentUnavailableView(
                        "WeBeep non collegato",
                        systemImage: "link.badge.plus",
                        description: Text("Collega WeBeep dal Profilo, poi torna qui.")
                    )
                } else if isLoading {
                    ProgressView("Carico i corsi…")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Errore",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    List(courses) { course in
                        NavigationLink {
                            WebeepCourseFilesView(course: course, onPicked: pick)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(WebeepService.stripMultilang(course.fullname))
                                    .font(.system(size: 15, weight: .medium))
                                    .lineLimit(2)
                                if let short = course.shortname, !short.isEmpty {
                                    Text(short)
                                        .font(.system(size: 12))
                                        .foregroundStyle(DesignColor.textTertiary)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("PDF da WeBeep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task { await loadCourses() }
    }

    private func pick(_ data: Data, _ name: String) {
        onPicked(data, name)
        dismiss()
    }

    private func loadCourses() async {
        guard let token else { isLoading = false; return }
        guard let info = await WebeepService.siteInfo(token: token) else {
            errorMessage = "WeBeep non risponde: controlla la connessione o ricollega l'account dal Profilo."
            isLoading = false
            return
        }
        courses = await WebeepService.courses(token: token, userID: info.userid)
        if courses.isEmpty {
            errorMessage = "Nessun corso trovato sull'account."
        }
        isLoading = false
    }
}

// Secondo livello: i PDF di un corso, raggruppati per sezione.
private struct WebeepCourseFilesView: View {
    let course: WebeepCourse
    var onPicked: (Data, String) -> Void

    @State private var sections: [WebeepSection] = []
    @State private var isLoading = true
    @State private var downloadingFileID: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Carico i file…")
            } else if pdfSections.isEmpty {
                ContentUnavailableView(
                    "Nessun PDF",
                    systemImage: "doc.questionmark",
                    description: Text("In questo corso non ci sono PDF scaricabili.")
                )
            } else {
                List {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(DesignColor.danger)
                    }
                    ForEach(pdfSections) { section in
                        Section(WebeepService.stripMultilang(section.name ?? "Sezione")) {
                            ForEach(pdfFiles(in: section)) { file in
                                Button {
                                    Task { await download(file) }
                                } label: {
                                    HStack(spacing: DesignSpace.s3) {
                                        Image(systemName: "doc.richtext")
                                            .foregroundStyle(DesignColor.brandPrimary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(file.filename)
                                                .font(.system(size: 14))
                                                .foregroundStyle(DesignColor.textPrimary)
                                                .lineLimit(2)
                                            if let sub = file.subfolderName {
                                                Text(sub)
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(DesignColor.textTertiary)
                                            }
                                        }
                                        Spacer()
                                        if downloadingFileID == file.id {
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                                }
                                .disabled(downloadingFileID != nil)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(WebeepService.stripMultilang(course.shortname ?? course.fullname))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let token = WebeepService.savedToken else { isLoading = false; return }
            sections = await WebeepService.contents(token: token, courseID: course.id)
            isLoading = false
        }
    }

    private func isPDF(_ file: WebeepFile) -> Bool {
        file.mimetype == "application/pdf" || file.filename.lowercased().hasSuffix(".pdf")
    }

    private func pdfFiles(in section: WebeepSection) -> [WebeepFile] {
        section.files.filter(isPDF)
    }

    private var pdfSections: [WebeepSection] {
        sections.filter { !pdfFiles(in: $0).isEmpty }
    }

    private func download(_ file: WebeepFile) async {
        guard let token = WebeepService.savedToken else { return }
        downloadingFileID = file.id
        errorMessage = nil
        defer { downloadingFileID = nil }
        do {
            let data = try await WebeepService.downloadFile(file, token: token)
            onPicked(data, file.filename)
        } catch {
            errorMessage = "Download non riuscito: \(error.localizedDescription)"
        }
    }
}
