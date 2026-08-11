import SwiftUI

// Guscio visivo per gli ambienti non ancora implementati (Studio,
// Ricerca, Integrazioni). Segnaposto in stile Claude Design, in attesa
// delle funzionalità vere (flashcard, ricerca paper, Obsidian/Drive/PolimiApp).
struct ComingSoonScreen: View {
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        VStack(spacing: DesignSpace.s4) {
            Spacer()
            RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                .fill(DesignColor.brandPrimarySubtle)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: systemImage)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(DesignColor.brandPrimary)
                )
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(DesignColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignColor.surfacePage)
    }
}
