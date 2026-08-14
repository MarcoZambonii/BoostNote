import SwiftUI

struct NoteSettingsSheet: View {
    @Bindable var note: Note
    var drawingController: DrawingController
    var onJumpToPage: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var exportedPDFURL: URL?
    // Le miniature renderizzano OGNI pagina: su note lunghe è pesantissimo,
    // quindi si generano solo se richieste esplicitamente.
    @State private var showingAllPages = false
    @State private var exportIncludesPattern = false

    private let thumbColumns = [GridItem(.adaptive(minimum: 90, maximum: 130), spacing: DesignSpace.s3)]

    var body: some View {
        NavigationStack {
            Form {
                if !note.isWhiteboard {
                    Section("Pagine") {
                        if showingAllPages {
                            LazyVGrid(columns: thumbColumns, spacing: DesignSpace.s3) {
                                ForEach(0..<pageCount, id: \.self) { index in
                                    Button {
                                        onJumpToPage(index)
                                        dismiss()
                                    } label: {
                                        VStack(spacing: 4) {
                                            pageThumbnailImage(index)
                                                .frame(height: 110)
                                                .frame(maxWidth: .infinity)
                                                .background(Color.white, in: RoundedRectangle(cornerRadius: DesignRadius.sm))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: DesignRadius.sm)
                                                        .stroke(DesignColor.borderDefault, lineWidth: 1)
                                                )
                                            Text("\(index + 1)")
                                                .font(.system(size: 11))
                                                .foregroundStyle(DesignColor.textTertiary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, DesignSpace.s2)
                        } else {
                            Button {
                                showingAllPages = true
                            } label: {
                                Label("Vedi tutte le pagine (\(pageCount))", systemImage: "square.grid.2x2")
                            }
                            Text("Le anteprime vengono renderizzate una per una: su note lunghe può volerci qualche istante.")
                                .font(.caption)
                                .foregroundStyle(DesignColor.textTertiary)
                        }
                    }
                }

                Section("Esporta") {
                    Toggle("Includi Filigrana", isOn: $exportIncludesPattern)
                        .onChange(of: exportIncludesPattern) { exportedPDFURL = nil }
                    Button {
                        exportedPDFURL = renderAndSavePDF()
                    } label: {
                        Label("Genera PDF", systemImage: "doc.badge.arrow.up")
                    }
                    if let exportedPDFURL {
                        ShareLink(item: exportedPDFURL) {
                            Label("Condividi / salva su File", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section("Dimensione pagina") {
                    Picker("Dimensione", selection: $note.pageSize) {
                        ForEach(PageSize.allCases, id: \.self) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Pattern") {
                    // Finché la nota ha uno sfondo PDF importato, quello
                    // copre il pattern: cambiarlo qui non aveva alcun
                    // effetto visibile e non c'era modo di tornare
                    // indietro. Ora si vede il perché e si può rimuovere.
                    if note.pdfBackgroundData != nil {
                        VStack(alignment: .leading, spacing: DesignSpace.s2) {
                            Text("Questa nota ha un PDF importato come sfondo: il pattern resta nascosto finché non lo rimuovi.")
                                .font(.caption)
                                .foregroundStyle(DesignColor.textSecondary)
                            Button(role: .destructive) {
                                note.pdfBackgroundData = nil
                                note.updatedAt = .now
                            } label: {
                                Label("Rimuovi sfondo PDF", systemImage: "doc.badge.minus")
                            }
                        }
                    }

                    Picker("Pattern", selection: $note.template) {
                        ForEach(NoteTemplate.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(note.pdfBackgroundData != nil)

                    if note.template != .blank {
                        VStack(alignment: .leading, spacing: 4) {
                            // In millimetri veri: il passo base del pattern è
                            // 24 pt = 6,35 mm, moltiplicato per la scala.
                            Text("Dimensione pattern — \(RealUnits.mmLabel(fromPoints: 24 * note.patternScale))")
                                .font(.caption)
                                .foregroundStyle(DesignColor.textSecondary)
                            Slider(value: $note.patternScale, in: 0.5...2.0, step: 0.1)
                        }
                        .disabled(note.pdfBackgroundData != nil)
                    }
                }
            }
            .navigationTitle("Impostazioni foglio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var pageCount: Int {
        drawingController.pageCount(pageHeight: note.pageSize.height)
    }

    @ViewBuilder
    private func pageThumbnailImage(_ index: Int) -> some View {
        if let image = drawingController.pageThumbnail(index: index, pageWidth: note.pageSize.width, pageHeight: note.pageSize.height) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Color.white
        }
    }

    private func renderAndSavePDF() -> URL? {
        guard let data = drawingController.renderPDF(
            pageWidth: note.pageSize.width,
            pageHeight: note.pageSize.height,
            isWhiteboard: note.isWhiteboard,
            includePattern: exportIncludesPattern
        ) else { return nil }
        let name = note.title.trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name.isEmpty ? "Nota" : name).pdf")
        try? data.write(to: url)
        return url
    }
}
