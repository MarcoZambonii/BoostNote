import SwiftUI

// Foglio di condivisione di sistema, per "scaricare" un file (salvarlo in
// File, AirDrop, ecc.) invece di poterlo solo aggiungere a una nota.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
