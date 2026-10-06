import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            FlightSettings().tabItem { Label("Flight", systemImage: "airplane") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Form {
            Picker("Search engine", selection: $prefs.searchEngineID) {
                ForEach(SearchEngine.all) { Text($0.name).tag($0.id) }
            }
            Toggle("Show search suggestions", isOn: $prefs.searchSuggestions)
            Picker("Tabs", selection: $prefs.tabLayout) {
                ForEach(TabLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Reopen last session at launch", isOn: $prefs.restoreSession)
            Toggle("Float playing video when I leave its tab", isOn: $prefs.autoFloatVideo)
            Section("Performance") {
                Picker("Put inactive tabs to sleep", selection: $prefs.sleepAfterMinutes) {
                    Text("Never").tag(0)
                    Text("After 1 minute").tag(1)
                    Text("After 3 minutes").tag(3)
                    Text("After 5 minutes").tag(5)
                    Text("After 10 minutes").tag(10)
                    Text("After 30 minutes").tag(30)
                    Text("After 1 hour").tag(60)
                }
                Picker("Memory budget for web pages", selection: $prefs.memoryBudgetMB) {
                    Text("Automatic (\(MemoryManager.format(MemoryManager.budgetBytes)))").tag(0)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("4 GB").tag(4096)
                    Text("8 GB").tag(8192)
                }
                Toggle("Stop videos from playing by themselves", isOn: $prefs.stopAutoplay)
                Text("Sleeping tabs use no memory and wake instantly where you left off. Playing audio is never interrupted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Make Searchy the Default Browser") { DefaultBrowser.request() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FlightSettings: View {
    @Bindable private var flight = FlightMode.shared
    private let offline = OfflineStore.shared

    var body: some View {
        Form {
            Picker("Data saver", selection: $flight.level) {
                ForEach(LiteLevel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(flight.level.detail).font(.caption).foregroundStyle(.secondary)
            Toggle("Switch to Lite automatically on slow, metered or restricted networks", isOn: $flight.auto)
            Toggle("Show saved copies of pages when offline", isOn: $flight.preferOffline)
            Section("Saved pages") {
                LabeledContent("Stored", value: "\(offline.items.count) pages · \(ByteCountFormatter.string(fromByteCount: Int64(offline.totalBytes), countStyle: .file))")
                Button("Delete All Saved Pages") { offline.removeAll() }.disabled(offline.items.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    @Bindable private var prefs = Preferences.shared
    private let hidden = HiddenElementStore.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            Toggle("Block ads and trackers before they load", isOn: $prefs.blockAds)
                .onChange(of: prefs.blockAds) { _, _ in
                    Task { await ContentBlocker.shared.rebuildAds() }
                }
            Section("Hidden elements") {
                if hidden.rules.isEmpty {
                    Text("Nothing hidden. Press ⇧⌘H on any page and click what you don’t want to see.").foregroundStyle(.secondary)
                } else {
                    ForEach(hidden.rules.keys.sorted(), id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Text("\(hidden.rules[host]?.count ?? 0)").foregroundStyle(.secondary)
                            Button("Show again") { hidden.removeAll(host: host) }
                        }
                    }
                }
            }
            Section("Search") {
                Toggle("Remember page text so I can search what I’ve read", isOn: $prefs.indexPages)
                Text("Stored only on this Mac. Pages with sign-in forms and Private tabs are never included.").font(.caption).foregroundStyle(.secondary)
                Button("Clear Page Text Index") { ContentIndex.shared.clear() }
            }
            Section("Data") {
                Button("Clear History…") { confirmClear = true }
                    .confirmationDialog("Clear all browsing history?", isPresented: $confirmClear) {
                        Button("Clear History", role: .destructive) { HistoryStore.shared.clear() }
                    }
                Button("Clear Website Data (cookies, cache)…") {
                    Task { await WKWebsiteDataStoreCleaner.clearDefault() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

import WebKit
enum WKWebsiteDataStoreCleaner {
    @MainActor static func clearDefault() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        FaviconStore.shared.clear()
    }
}

enum DefaultBrowser {
    @MainActor static func request() {
        let workspace = NSWorkspace.shared
        let app = Bundle.main.bundleURL
        Task {
            for scheme in ["http", "https"] { try? await workspace.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) }
        }
    }
}
