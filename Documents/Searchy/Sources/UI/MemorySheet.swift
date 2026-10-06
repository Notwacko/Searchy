import SwiftUI

/// A small task manager: what each open tab costs, with a one-click "Sleep".
struct MemorySheet: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var appBytes: UInt64 = 0
    @State private var sleepingCount = 0

    struct Row: Identifiable {
        let tab: Tab
        let bytes: UInt64
        var id: UUID { tab.id }
    }

    private var tabsTotal: UInt64 { rows.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tab Memory").font(.title3.weight(.semibold))
                    Text("\(MemoryManager.format(appBytes + tabsTotal)) in use · \(sleepingCount) asleep, using nothing")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sleep Background Tabs") {
                    model.sleepIdleTabs(olderThan: 0)
                    Task { try? await Task.sleep(for: .milliseconds(300)); refresh() }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            List {
                HStack(spacing: 10) {
                    Image(systemName: "macwindow").frame(width: 18).foregroundStyle(.secondary)
                    Text("Searchy (the app itself)")
                    Spacer()
                    Text(MemoryManager.format(appBytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                Section("Open tabs") {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            TabIcon(tab: row.tab)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(row.tab.displayTitle).lineLimit(1)
                                    if row.tab === model.selectedTab { Text("in front").font(.caption2).foregroundStyle(.tint) }
                                }
                                MemoryBar(bytes: row.bytes, maxBytes: max(rows.map(\.bytes).max() ?? 1, 1))
                            }
                            Text(MemoryManager.format(row.bytes)).monospacedDigit().frame(width: 70, alignment: .trailing)
                                .foregroundStyle(row.bytes > 300 << 20 ? Color.orange : Color.secondary)
                            Button("Sleep") { row.tab.sleep(force: true); refresh() }
                                .controlSize(.small).disabled(row.tab === model.selectedTab && model.allTabs.count == 1)
                        }
                    }
                    if rows.isEmpty { Text("No tabs are using memory right now.").foregroundStyle(.secondary) }
                }
            }

            Divider()
            Text("Searchy puts background tabs to sleep after \(Preferences.shared.sleepAfterMinutes == 0 ? "…never" : "\(Preferences.shared.sleepAfterMinutes) minutes"), releases heavy ones sooner, and keeps all web pages under \(MemoryManager.format(MemoryManager.budgetBytes)). Asleep tabs keep their place and wake instantly.")
                .font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .frame(width: 600, height: 520)
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() {
        appBytes = MemoryManager.appFootprint
        let all = model.allTabs
        rows = all.filter { $0.webView != nil }.map { Row(tab: $0, bytes: $0.sampleMemory()) }.sorted { $0.bytes > $1.bytes }
        sleepingCount = all.filter { $0.webView == nil && !$0.isBlank }.count
    }
}

private struct MemoryBar: View {
    let bytes: UInt64
    let maxBytes: UInt64

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(bytes > 300 << 20 ? Color.orange : Color.accentColor)
                    .frame(width: max(3, g.size.width * CGFloat(Double(bytes) / Double(maxBytes))))
            }
        }
        .frame(height: 4)
    }
}
