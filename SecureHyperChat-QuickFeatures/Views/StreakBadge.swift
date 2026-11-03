import SwiftUI

/// #5: 🔥 + number. Hidden below `StreakService.minimumShown`.
struct StreakBadge: View {
    let days: Int
    var compact = false

    var body: some View {
        if days >= StreakService.minimumShown {
            HStack(spacing: 2) {
                Text("🔥")
                Text("\(days)")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(compact ? .caption : .footnote)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(days)-day streak")
        }
    }
}
