import SwiftUI

// MARK: - Banner

/// Slides in when the network needs attention: sign in, offline, or restricted.
struct NetworkBanner: View {
    let model: BrowserModel
    private let net = NetworkMonitor.shared
    private let offline = OfflineStore.shared

    private var showing: Bool {
        guard model.bannerDismissed != net.quality else { return false }
        return net.quality == .captive || net.quality == .offline || net.quality == .restricted
    }

    private var topInset: CGFloat {
        if Preferences.shared.tabLayout == .top { return Metrics.barHeight + 42 + 10 }
        return model.sidebarVisible ? 18 : Metrics.barHeight + 12
    }

    var body: some View {
        VStack {
            if showing { banner.transition(.move(edge: .top).combined(with: .opacity)) }
            Spacer(minLength: 0)
        }
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(showing)
        .animation(.smooth(duration: 0.3), value: showing)
    }

    private var banner: some View {
        HStack(spacing: 12) {
            Image(systemName: net.quality.symbol).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.callout.weight(.semibold))
                Text(subline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: 360, alignment: .leading)
            actions
            Button { model.bannerDismissed = net.quality } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 22)).help("Dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    private var tint: Color { net.quality == .restricted ? .orange : net.quality == .captive ? .yellow : .red }

    private var headline: String {
        switch net.quality {
        case .captive: "This Wi-Fi needs you to sign in"
        case .offline: "You’re offline"
        default: "This network is restricted"
        }
    }

    private var subline: String {
        switch net.quality {
        case .captive: "Airplane, hotel and café networks hold traffic until you accept their terms."
        case .offline: offline.items.isEmpty ? "Pages you haven’t saved can’t load." : "\(offline.items.count) saved page\(offline.items.count == 1 ? "" : "s") are still readable."
        default: net.detail
        }
    }

    @ViewBuilder private var actions: some View {
        switch net.quality {
        case .captive:
            Button("Sign In") { model.openPortal() }.buttonStyle(.borderedProminent).controlSize(.small)
        case .offline:
            if !offline.items.isEmpty { Button("Saved Pages") { model.sheet = .offline }.controlSize(.small) }
            Button("Diagnose") { model.sheet = .doctor }.controlSize(.small)
        default:
            Button("Diagnose") { model.sheet = .doctor }.buttonStyle(.borderedProminent).controlSize(.small)
            if FlightMode.shared.level == .off { Button("Lite Mode") { FlightMode.shared.level = .lite }.controlSize(.small) }
        }
    }
}

// MARK: - Toolbar button + popover

struct FlightButton: View {
    let model: BrowserModel
    @State private var open = false
    private let net = NetworkMonitor.shared
    private let flight = FlightMode.shared

    var body: some View {
        Button { open.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: flight.isActive ? "airplane.circle.fill" : "airplane")
                    .foregroundStyle(color)
                if net.quality != .good && net.quality != .unknown {
                    Circle().fill(color).frame(width: 6, height: 6).offset(x: 3, y: -2)
                }
            }
        }
        .buttonStyle(IconButtonStyle())
        .help("Flight mode and network")
        .popover(isPresented: $open, arrowEdge: .bottom) { FlightPopover(model: model, dismiss: { open = false }) }
    }

    private var color: Color {
        switch net.quality {
        case .offline: .red
        case .captive: .yellow
        case .restricted, .slow: .orange
        default: flight.isActive ? .green : .primary
        }
    }
}

struct FlightPopover: View {
    let model: BrowserModel
    var dismiss: () -> Void
    @Bindable private var flight = FlightMode.shared
    private let net = NetworkMonitor.shared
    private let offline = OfflineStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: net.quality.symbol).font(.title3).foregroundStyle(statusColor)
                    .frame(width: 38, height: 38).background(Circle().fill(statusColor.opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(net.quality.title).font(.headline)
                    Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Data saver").font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    ForEach(LiteLevel.allCases) { level in
                        Button { flight.level = level } label: {
                            Label(level.title, systemImage: level.symbol).font(.callout)
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(flight.level == level ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                                .foregroundStyle(flight.level == level ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(flight.level.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if flight.autoEngaged && flight.level == .off {
                    Label("Lite mode is on automatically for this connection.", systemImage: "leaf.fill").font(.caption).foregroundStyle(.green)
                }
                Toggle("Switch on automatically when the network is slow", isOn: $flight.auto).toggleStyle(.checkbox).font(.callout)
                Toggle("Show saved copies when offline", isOn: $flight.preferOffline).toggleStyle(.checkbox).font(.callout)
            }

            Divider()
            VStack(spacing: 2) {
                row("Save This Page for Offline", "arrow.down.circle", enabled: model.selectedTab?.isBlank == false) {
                    Task { await model.selectedTab?.saveForOffline() }; dismiss()
                }
                row("Prepare for Flight…", "airplane.departure") { model.sheet = .flightPrep; dismiss() }
                row("Saved Pages — \(offline.items.count) · \(ByteCountFormatter.string(fromByteCount: Int64(offline.totalBytes), countStyle: .file))", "tray.full") {
                    model.sheet = .offline; dismiss()
                }
                row("Network Doctor…", "stethoscope") { model.sheet = .doctor; dismiss() }
                if net.quality == .captive { row("Sign In to This Wi-Fi", "person.badge.key") { model.openPortal(); dismiss() } }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var statusColor: Color {
        switch net.quality {
        case .offline: .red
        case .captive: .yellow
        case .restricted, .slow: .orange
        default: .green
        }
    }

    private var statusLine: String {
        var parts: [String] = []
        if net.interfaceName != "—" { parts.append(net.interfaceName) }
        if let rtt = net.rttMs { parts.append("\(rtt) ms") }
        if net.isConstrained { parts.append("Low Data Mode") }
        if net.isExpensive { parts.append("metered") }
        return parts.isEmpty ? net.detail : parts.joined(separator: " · ")
    }

    private func row(_ title: String, _ symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(!enabled)
    }
}

// MARK: - Offline library

struct OfflineSheet: View {
    let model: BrowserModel
    private let store = OfflineStore.shared
    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss

    private var visible: [OfflineItem] { filter.isEmpty ? store.items : store.search(filter, limit: 300) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved Pages").font(.title3.weight(.semibold))
                    Text("\(store.items.count) pages · \(ByteCountFormatter.string(fromByteCount: Int64(store.totalBytes), countStyle: .file)) — readable with no connection")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search saved pages", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            if visible.isEmpty {
                ContentUnavailableView {
                    Label(filter.isEmpty ? "Nothing saved yet" : "No matches", systemImage: "tray")
                } description: {
                    Text(filter.isEmpty ? "Save pages before you lose your connection, or let Searchy do it for you." : "")
                } actions: {
                    if filter.isEmpty { Button("Prepare for Flight…") { model.sheet = .flightPrep }.buttonStyle(.borderedProminent) }
                }
            } else {
                List(visible) { item in
                    HStack(spacing: 11) {
                        icon(item).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).lineLimit(1)
                            Text("\(item.host) · \(item.savedAt.formatted(.relative(presentation: .named))) · \(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { store.remove(item.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { open(item, newTab: false) }
                    .contextMenu {
                        Button("Open") { open(item, newTab: false) }
                        Button("Open in New Tab") { open(item, newTab: true) }
                        Button("Delete", role: .destructive) { store.remove(item.id) }
                    }
                }
            }

            Divider()
            HStack {
                Button("Save Current Page") { Task { await model.selectedTab?.saveForOffline() } }
                    .disabled(model.selectedTab?.isBlank != false)
                Button("Prepare for Flight…") { model.sheet = .flightPrep }
                Spacer()
                Button("Delete All", role: .destructive) { store.removeAll() }.disabled(store.items.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 640, height: 560)
    }

    @ViewBuilder private func icon(_ item: OfflineItem) -> some View {
        if let image = FaviconStore.shared.cached(host: item.host) {
            Image(nsImage: image).resizable().interpolation(.high).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "doc.richtext").foregroundStyle(.secondary)
        }
    }

    private func open(_ item: OfflineItem, newTab: Bool) {
        let tab = newTab || model.selectedTab == nil ? model.newTab() : model.selectedTab!
        tab.loadOfflineCopy(item)
        dismiss()
    }
}

// MARK: - Prepare for flight

struct FlightPrepSheet: View {
    let model: BrowserModel
    private let prep = FlightPrep.shared
    @State private var includeFavorites = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "airplane.departure").font(.system(size: 40, weight: .light)).foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Prepare for Flight").font(.title2.weight(.semibold))
                Text("Saves your open tabs, pinned tabs and favorites so you can read them with no connection — with their pictures and styling.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if prep.isRunning || prep.finished {
                VStack(spacing: 8) {
                    ProgressView(value: prep.fraction).progressViewStyle(.linear)
                    if prep.isRunning {
                        Text("Saving \(prep.current)… \(prep.done + prep.failed) of \(prep.total)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Saved \(prep.done) page\(prep.done == 1 ? "" : "s")" + (prep.failed > 0 ? " · \(prep.failed) couldn’t be saved" : ""),
                              systemImage: prep.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.callout).foregroundStyle(prep.failed == 0 ? .green : .orange)
                    }
                }
            } else {
                Toggle("Include my favorites", isOn: $includeFavorites).toggleStyle(.checkbox)
            }
            HStack {
                if prep.isRunning {
                    Button("Stop") { prep.cancel() }
                } else if prep.finished {
                    Button("View Saved Pages") { model.sheet = .offline }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save Pages") { prep.start(model: model, includeFavorites: includeFavorites) }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28).frame(width: 440)
    }
}

// MARK: - Network Doctor

struct NetworkDoctorSheet: View {
    let model: BrowserModel
    private let doctor = NetworkDoctor.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Network Doctor").font(.title3.weight(.semibold))
                    Text("Finds out why a network is slow, blocked or strange.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(doctor.isRunning ? "Running…" : doctor.hasRun ? "Run Again" : "Run Checks") { doctor.run() }.disabled(doctor.isRunning)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(doctor.checks) { check in
                        HStack(alignment: .top, spacing: 12) {
                            stateIcon(check.state).frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.title).font(.body.weight(.medium))
                                if !check.detail.isEmpty { Text(check.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        Divider().padding(.leading, 50)
                    }

                    if !doctor.findings.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("What to do").font(.headline)
                            ForEach(doctor.findings) { f in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: f.fix == nil ? "checkmark.seal.fill" : "lightbulb.fill").foregroundStyle(f.fix == nil ? .green : .yellow)
                                    Text(f.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    if f.fix != nil { Button(f.fixTitle) { apply(f.fix!) }.controlSize(.small) }
                                }
                            }
                        }
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                        .padding(16)
                    }
                }
            }
        }
        .frame(width: 600, height: 560)
        .onAppear { if !doctor.hasRun { doctor.run() } }
    }

    @ViewBuilder private func stateIcon(_ state: NetworkDoctor.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func apply(_ fix: NetworkDoctor.Fix) {
        switch fix {
        case .signIn: dismiss(); model.openPortal()
        case .lite: FlightMode.shared.level = .lite; model.toast("Lite mode on", symbol: "leaf.fill")
        case .textOnly: FlightMode.shared.level = .textOnly; model.toast("Text-only mode on", symbol: "text.alignleft")
        case .saveOffline: model.sheet = .flightPrep
        case .routes: model.toast("Per-tab routes live in the tab’s menu → Network Route", symbol: "network")
        }
    }
}
