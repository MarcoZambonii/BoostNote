import SwiftUI

struct NoteSettingsSheet: View {
    @Bindable var note: Note
    var drawingController: DrawingController
    var onJumpToPage: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var exportedPDFURL: URL?

    private let thumbColumns = [GridItem(.adaptive(minimum: 90, maximum: 130), spacing: DesignSpace.s3)]

    var body: some View {
        NavigationStack {
            Form {
                if !note.isWhiteboard {
                    Section("Pagine") {
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
                    }
                }

                Section("Esporta") {
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
                    Picker("Pattern", selection: $note.template) {
                        ForEach(NoteTemplate.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if note.template != .blank {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Dimensione pattern — \(String(format: "%.1f", note.patternScale))×")
                                .font(.caption)
                                .foregroundStyle(DesignColor.textSecondary)
                            Slider(value: $note.patternScale, in: 0.5...2.0, step: 0.1)
                        }
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
        guard let data = drawingController.renderPDF(pageWidth: note.pageSize.width, pageHeight: note.pageSize.height, isWhiteboard: note.isWhiteboard) else { return nil }
        let name = note.title.trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name.isEmpty ? "Nota" : name).pdf")
        try? data.write(to: url)
        return url
    }
}
