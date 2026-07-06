import SwiftUI
import Charts
import AppKit

struct StatisticsView: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var today = StatisticsStore.shared.today()
    @State private var week = StatisticsStore.shared.recent(7)
    @State private var totals = StatisticsStore.shared.totals(7)
    @State private var streak = StatisticsStore.shared.currentStreak()
    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.t("stats.title")).font(.headline)
                Spacer()
                Button { reload() } label: { Label(L.t("stats.refresh"), systemImage: "arrow.clockwise") }
                    .help(L.t("stats.refreshHelp"))
                Button { exportCSV() } label: { Label(L.t("stats.exportCSV"), systemImage: "square.and.arrow.up") }
                    .help(L.t("stats.exportHelp"))
                Button(role: .destructive) { showResetConfirm = true } label: {
                    Label(L.t("stats.reset"), systemImage: "trash")
                }
                .help(L.t("stats.resetHelp"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(streak >= 1 ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(streak >= 1 ? L.t("stats.streakTitle", streak) : L.t("stats.streakStart"))
                                .font(.title3.bold())
                            Text(streak >= 1 ? L.t("stats.streakKeep") : L.t("stats.streakHint"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color.orange.opacity(streak >= 1 ? 0.12 : 0.06)))

                    Text(L.t("stats.todayOverview")).font(.headline)
                    HStack(spacing: 10) {
                        StatCard(title: L.t("stats.workTime"), value: L.t("stats.minShort", today.activeMinutes), symbol: "clock.fill", tint: .blue)
                        StatCard(title: L.t("stats.breaks"), value: "\(today.breaks)", symbol: "hand.tap.fill", tint: .pink)
                        StatCard(title: L.t("stats.skips"), value: "\(today.skips)", symbol: "forward.end.fill", tint: .orange)
                        StatCard(title: L.t("stats.cycles"), value: "\(today.cycles)", symbol: "leaf.fill", tint: .green)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                        Text(L.t("stats.weekTotals", totals.activeMinutes, totals.breaks, totals.skips))
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)

                    Text(L.t("stats.chartWork")).font(.subheadline).foregroundStyle(.secondary)
                    Chart(week) { day in
                        BarMark(
                            x: .value(L.t("chart.date"), String(day.date.suffix(5))),
                            y: .value(L.t("chart.workMin"), day.activeMinutes)
                        )
                        .foregroundStyle(Color.blue.gradient)
                        .cornerRadius(4)
                    }
                    .frame(height: 150)

                    Text(L.t("stats.chartBreaks")).font(.subheadline).foregroundStyle(.secondary)
                    Chart(week) { day in
                        BarMark(
                            x: .value(L.t("chart.date"), String(day.date.suffix(5))),
                            y: .value(L.t("chart.breakCount"), day.breaks)
                        )
                        .foregroundStyle(Color.pink.gradient)
                        .cornerRadius(4)
                    }
                    .frame(height: 130)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        .onAppear(perform: reload)
        // The window is reused (closing hides it), so onAppear fires only on the very first open;
        // reload whenever the window is re-presented so the snapshot never shows stale days.
        .onReceive(NotificationCenter.default.publisher(for: .hbStatsWindowShown)) { _ in reload() }
        .alert(L.t("stats.resetConfirmTitle"), isPresented: $showResetConfirm) {
            Button(L.t("btn.cancel"), role: .cancel) {}
            Button(L.t("stats.reset"), role: .destructive) {
                StatisticsStore.shared.resetAll()
                reload()
            }
        } message: {
            Text(L.t("stats.resetConfirmMsg"))
        }
    }

    private func reload() {
        today = StatisticsStore.shared.today()
        week = StatisticsStore.shared.recent(7)
        totals = StatisticsStore.shared.totals(7)
        streak = StatisticsStore.shared.currentStreak()
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L.t("stats.csvFilename")
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? StatisticsStore.shared.exportCSV().data(using: .utf8)?.write(to: url)
        }
    }
}
