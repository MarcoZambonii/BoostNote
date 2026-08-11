import Foundation

enum AppEnvironment: String, CaseIterable {
    case home, studio, ricerca, webeep

    // Righe di navigazione generiche nella barra laterale. WeBeep ha una
    // riga dedicata con il proprio indicatore di stato, quindi resta
    // fuori da questo elenco pur essendo un ambiente a tutti gli effetti.
    static let navItems: [AppEnvironment] = [.home, .studio, .ricerca]

    var label: String {
        switch self {
        case .home: "Home"
        case .studio: "Studio"
        case .ricerca: "Research Paper"
        case .webeep: "WeBeep"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .studio: "graduationcap"
        case .ricerca: "magnifyingglass"
        case .webeep: "building.columns.fill"
        }
    }
}
