import SwiftUI

struct SpaceEditor: View {
    let model: BrowserModel
    let request: SpaceEditorRequest
    @State private var info: SpaceInfo
    @Environment(\.dismiss) private var dismiss

    init(model: BrowserModel, request: SpaceEditorRequest) {
        self.model = model
        self.request = request
        _info = State(initialValue: request.info)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: info.symbol).font(.title2).foregroundStyle(info.color.color)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(info.color.color.opacity(0.18)))
                TextField("Space name", text: $info.name).textFieldStyle(.roundedBorder).font(.title3)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon").font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                    ForEach(SpaceInfo.symbols, id: \.self) { symbol in
                        Button { info.symbol = symbol } label: {
                            Image(systemName: symbol).frame(maxWidth: .infinity).frame(height: 34)
                                .background(RoundedRectangle(cornerRadius: 8).fill(info.symbol == symbol ? info.color.color.opacity(0.25) : Color.primary.opacity(0.05)))
                        }.buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(SpaceColor.allCases, id: \.self) { c in
                        Button { info.color = c } label: {
                            Circle().fill(c.color).frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(.white, lineWidth: info.color == c ? 2.5 : 0))
                                .shadow(color: info.color == c ? c.color.opacity(0.6) : .clear, radius: 5)
                        }.buttonStyle(.plain).help(c.title)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Sign-ins").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $info.isolated) {
                    Text("Stay signed in").tag(false)
                    Text("Start afresh").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().disabled(!request.isNew)
                Text(info.isolated ? "This space keeps its own cookies and logins, separate from your other spaces."
                                   : "This space shares your existing sign-ins.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.isNew ? "Create Space" : "Save") {
                    if request.isNew { model.addSpace(info) } else { model.update(info) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(info.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 440)
    }
}

struct BookmarksSheet: View {
    let model: BrowserModel
    private let store = BookmarkStore.shared
    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Bookmarks", filter: $filter) { dismiss() }
            let items = filter.isEmpty ? store.items : store.search(filter, limit: 200)
            if items.isEmpty {
                ContentUnavailableView(filter.isEmpty ? "No bookmarks yet" : "No matches", systemImage: "star",
                                       description: Text(filter.isEmpty ? "Press ⌘D on a page to bookmark it." : ""))
            } else {
                List(items) { b in
                    HStack(spacing: 10) {
                        Button { store.setFavorite(b.id, !b.isFavorite) } label: {
                            Image(systemName: b.isFavorite ? "heart.fill" : "heart").foregroundStyle(b.isFavorite ? .pink : .secondary)
                        }.buttonStyle(.plain).help("Show on the new-tab page")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.title).lineLimit(1)
                            Text(b.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !b.folder.isEmpty { Text(b.folder).font(.caption).foregroundStyle(.tertiary) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if let u = URL(string: b.url) { model.open(u); dismiss() } }
                    .contextMenu {
                        Button("Open in New Tab") { if let u = URL(string: b.url) { model.open(u, inNewTab: true); dismiss() } }
                        Button("Delete", role: .destructive) { store.remove(b.id) }
                    }
                }
            }
        }
        .frame(width: 560, height: 520)
    }
}

struct HistorySheet: View {
    let model: BrowserModel
    @State private var entries: [HistoryEntry] = []
    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "History", filter: $filter) { dismiss() }
            if entries.isEmpty {
                ContentUnavailableView(filter.isEmpty ? "No history yet" : "No matches", systemImage: "clock")
            } else {
                List(entries) { e in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title.isEmpty ? e.url : e.title).lineLimit(1)
                            Text(e.host).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(e.lastVisit, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if let u = URL(string: e.url) { model.open(u); dismiss() } }
                    .contextMenu {
                        Button("Open in New Tab") { if let u = URL(string: e.url) { model.open(u, inNewTab: true); dismiss() } }
                        Button("Remove from History", role: .destructive) { HistoryStore.shared.delete(url: e.url); entries.removeAll { $0.id == e.id } }
                    }
                }
            }
        }
        .frame(width: 600, height: 540)
        .task(id: filter) {
            entries = filter.isEmpty ? await HistoryStore.shared.recent(limit: 300) : await HistoryStore.shared.search(filter, limit: 200)
        }
    }
}

struct SheetHeader: View {
    let title: String
    @Binding var filter: String
    let done: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            TextField("Search", text: $filter).textFieldStyle(.roundedBorder)
            Button("Done", action: done).keyboardShortcut(.defaultAction)
        }
        .padding(16)
        Divider()
    }
}
