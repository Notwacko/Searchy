import SwiftUI
import Network
import UniformTypeIdentifiers

/// Manage network routes (proxies, SSH tunnels, WireGuard) and try them out.
struct RoutesSheet: View {
    let model: BrowserModel
    private let store = RouteStore.shared
    private let tunnels = TunnelManager.shared
    @State private var selection: UUID?
    @State private var draft = RouteProfile(name: "New route", kind: .socks5)
    @State private var password = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var isNew = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section("Built in") {
                        row(.direct)
                        row(.inspect)
                    }
                    Section("Your routes") {
                        ForEach(store.profiles) { row($0) }
                        if store.profiles.isEmpty { Text("None yet").font(.callout).foregroundStyle(.secondary) }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                Button { startNew() } label: { Label("Add Route", systemImage: "plus") }
                    .buttonStyle(.plain).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 220)
            Divider()
            editor.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 520)
        .onChange(of: selection) { _, id in load(id) }
        .toolbar { }
    }

    private func row(_ r: RouteProfile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: r.symbol).frame(width: 18).foregroundStyle(color(r))
            Text(r.name).lineLimit(1)
            Spacer()
            if r.needsTunnel { Circle().fill(tunnels.isRunning(r) ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7) }
            let n = model.allTabs.filter { $0.route.id == r.id && !$0.isSleeping }.count
            if n > 0 { Text("\(n)").font(.caption2).foregroundStyle(.secondary) }
        }
        .tag(r.id)
    }

    @ViewBuilder private var editor: some View {
        let builtIn = draft.kind == .direct || draft.kind == .inspect
        VStack(alignment: .leading, spacing: 16) {
            if builtIn {
                Image(systemName: draft.symbol).font(.system(size: 34)).foregroundStyle(color(draft))
                Text(draft.name).font(.title2.weight(.semibold))
                Text(draft.kind == .direct ? "Tabs on this route connect straight to the internet, using your normal sign-ins."
                     : "Tabs on this route are read by the Traffic Lab — you can intercept, edit and replay their requests. They get their own cookie jar.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                testBar
            } else {
                Text(isNew ? "New Route" : "Edit Route").font(.title3.weight(.semibold))
                Form {
                    TextField("Name", text: $draft.name)
                    Picker("Type", selection: $draft.kind) {
                        Text("SOCKS5 proxy").tag(RouteKind.socks5)
                        Text("HTTP(S) proxy").tag(RouteKind.httpConnect)
                        Text("SSH tunnel").tag(RouteKind.ssh)
                        Text("WireGuard").tag(RouteKind.wireguard)
                    }
                    switch draft.kind {
                    case .socks5, .httpConnect:
                        TextField("Server", text: $draft.host)
                        TextField("Port", value: $draft.port, format: .number.grouping(.never))
                        if draft.kind == .httpConnect { Toggle("Connect to the proxy over TLS (looks like normal HTTPS)", isOn: $draft.useTLS) }
                        TextField("Username (optional)", text: $draft.username)
                        SecureField("Password (optional)", text: $password)
                    case .ssh:
                        TextField("Server", text: $draft.host)
                        TextField("Port", value: $draft.port, format: .number.grouping(.never))
                        TextField("User", text: $draft.sshUser)
                        HStack {
                            TextField("Key file (optional)", text: $draft.identityPath)
                            Button("Choose…") { chooseFile { draft.identityPath = $0 } }
                        }
                        Text("Searchy runs `ssh -D` for you. Use key or ssh-agent login. Handy for a home Mac mini; if a network blocks port 22, point at an SSH server listening on 443.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .wireguard:
                        HStack {
                            TextField("WireGuard .conf", text: $draft.configPath)
                            Button("Choose…") { chooseFile { draft.configPath = $0 } }
                        }
                        Text(TunnelManager.find("wireproxy") == nil
                             ? "Needs the free `wireproxy` tool (brew install wireproxy). It runs the WireGuard tunnel without any system VPN."
                             : "Runs your WireGuard tunnel privately for just the tabs on this route.")
                            .font(.caption).foregroundStyle(.secondary)
                    default: EmptyView()
                    }
                }
                .formStyle(.grouped)
                testBar
                HStack {
                    if !isNew { Button("Delete", role: .destructive) { delete() } }
                    Spacer()
                    Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(draft.name.isEmpty)
                }
            }
            Spacer(minLength: 0)
            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .padding(20)
    }

    private var testBar: some View {
        HStack(spacing: 10) {
            Button { test() } label: { Label(testing ? "Testing…" : "Test Route", systemImage: "scope") }.disabled(testing)
            if let testResult { Text(testResult).font(.callout).foregroundStyle(testResult.hasPrefix("✓") ? .green : .orange).textSelection(.enabled) }
        }
    }

    // MARK: Actions

    private func color(_ r: RouteProfile) -> Color {
        switch r.kind { case .direct: .secondary; case .inspect: .orange; case .socks5, .httpConnect: .blue; case .ssh, .wireguard: .green }
    }

    private func startNew() {
        selection = nil
        draft = RouteProfile(name: "New route", kind: .socks5, port: 1080)
        password = ""; testResult = nil; isNew = true
    }

    private func load(_ id: UUID?) {
        testResult = nil
        guard let id, let p = store.all.first(where: { $0.id == id }) else { return }
        draft = p; isNew = false
        password = RouteSecrets.password(for: p.id) ?? ""
    }

    private func save() {
        if isNew { store.add(draft) } else { store.update(draft) }
        RouteSecrets.setPassword(password, for: draft.id)
        WebEngine.shared.forgetRoute(draft.id)       // so tabs pick up the new settings
        isNew = false; selection = draft.id
    }

    private func delete() {
        for tab in model.allTabs where tab.routeID == draft.id { tab.setRoute(.direct) }
        TunnelManager.shared.stop(draft)
        store.remove(draft.id)
        startNew()
    }

    private func chooseFile(_ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { done(url.path) }
    }

    private func test() {
        testing = true; testResult = nil
        let route = draft
        let pw = password
        Task {
            defer { testing = false }
            do {
                var box: ProxyConfigurationBox?
                switch route.kind {
                case .direct: box = nil
                case .inspect:
                    guard let port = await TrafficLab.shared.ensureRunning(), let ep = NWEndpoint.Port(rawValue: port) else { throw URLError(.cannotConnectToHost) }
                    box = ProxyConfigurationBox(value: ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: ep)))
                case .ssh, .wireguard:
                    let port = try await TunnelManager.shared.ensureRunning(route)
                    box = ProxyConfigurationBox(value: ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)))
                case .socks5, .httpConnect:
                    guard let ep = NWEndpoint.Port(rawValue: UInt16(clamping: route.port)), !route.host.isEmpty else { throw URLError(.badURL) }
                    var cfg = route.kind == .socks5 ? ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(route.host), port: ep))
                        : ProxyConfiguration(httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(route.host), port: ep), tlsOptions: route.useTLS ? NWProtocolTLS.Options() : nil)
                    if !route.username.isEmpty { cfg.applyCredential(username: route.username, password: pw) }
                    box = ProxyConfigurationBox(value: cfg)
                }
                let r = try await RouteTester.test(route, proxy: box)
                testResult = "✓ Comes out at \(r.ip) · \(r.country) (\(r.colo)) · \(r.ms) ms"
            } catch {
                testResult = "✕ \(error.localizedDescription)"
            }
        }
    }
}

/// The per-tab "Network Route" submenu.
struct RouteMenu: View {
    let model: BrowserModel
    let tab: Tab

    var body: some View {
        if !tab.isPrivate {
            Menu("Network Route", systemImage: "network") {
                ForEach(RouteStore.shared.all) { r in
                    Button { tab.setRoute(r) } label: {
                        Label(r.name, systemImage: tab.route.id == r.id ? "checkmark" : r.symbol)
                    }
                }
                Divider()
                Button("Manage Routes…", systemImage: "slider.horizontal.3") { model.sheet = .routes }
            }
        }
    }
}
