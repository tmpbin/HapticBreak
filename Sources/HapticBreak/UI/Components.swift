import SwiftUI

// Generic UI atoms. The countdown ring is split into layers under UI/Ring/ (RingModel · RingAnimator · RingViews).

/// Primary action button (icon + text, stacked vertically). Monochrome and restrained by default; only
/// the primary action (`prominent`) carries the status accent color.
struct ActionButton: View {
    var title: String
    var symbol: String
    var prominent: Bool = false
    var accent: Color = .accentColor
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? accent : Theme.neutralLabel)
            .background(prominent ? accent.opacity(0.12) : Theme.neutralFill)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Small interval-selection pill. Selected = single accent color, unselected = neutral, avoiding
/// multiple colors side by side.
struct Chip: View {
    var text: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor : Theme.neutralFill)
                .foregroundStyle(selected ? Color.white : Theme.neutralLabel)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Small footer button.
struct FooterButton: View {
    var title: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// Statistics card.
struct StatCard: View {
    var title: String
    var value: String
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(tint)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
