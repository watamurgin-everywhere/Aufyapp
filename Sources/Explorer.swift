import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Models

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct PlaceEntry: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let removable: Bool
    let searchable: Bool
    let icon: String
}

func makeFileItem(_ u: URL) -> FileItem {
    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
    var sz: Int64? = nil
    if let s = v?.fileSize { sz = Int64(s) }
    return FileItem(url: u, isDirectory: v?.isDirectory ?? false, size: sz, modified: v?.contentModificationDate)
}

final class SearchJob {
    var cancelled = false
}

// MARK: - Saved folder access (security-scoped bookmarks)

enum FolderStore {
    private static let key = "aufy.grantedFolders"

    static func loadAll() -> [URL] {
        let stored = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        var urls: [URL] = []
        var keep: [Data] = []
        for data in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                keep.append(data)
                continue
            }
            _ = url.startAccessingSecurityScopedResource()
            urls.append(url)
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                keep.append(fresh)
            } else {
                keep.append(data)
            }
        }
        UserDefaults.standard.set(keep, forKey: key)
        return urls
    }

    static func add(_ url: URL) -> Bool {
        _ = url.startAccessingSecurityScopedResource()
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return false
        }
        var stored = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        stored.append(data)
        UserDefaults.standard.set(stored, forKey: key)
        return true
    }

    static func remove(_ url: URL) {
        let target = url.standardizedFileURL.path
        let stored = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        let kept = stored.filter { data in
            var stale = false
            guard let u = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                return true
            }
            return u.standardizedFileURL.path != target
        }
        UserDefaults.standard.set(kept, forKey: key)
        url.stopAccessingSecurityScopedResource()
    }
}

// MARK: - Explorer model

final class ExplorerModel: ObservableObject {
    @Published var location: URL?
    @Published var items: [FileItem] = []
    @Published var loadError: String?
    @Published var places: [PlaceEntry] = []

    @Published var query = ""
    @Published var results: [FileItem] = []
    @Published var searchActive = false
    @Published var isSearching = false

    @Published var selecting = false
    @Published var selection: Set<String> = []

    @Published var pendingMove: [URL] = []
    @Published var deleteTargets: [URL] = []
    @Published var showDeleteConfirm = false

    @Published var errorMessage: String?
    @Published var infoMessage: String?

    private var searchJob: SearchJob?

    init() {
        refreshPlaces()
    }

    // MARK: Places

    func refreshPlaces() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var list: [PlaceEntry] = [
            PlaceEntry(name: "App Documents", url: home.appendingPathComponent("Documents"), removable: false, searchable: false, icon: "folder.fill"),
            PlaceEntry(name: "App Container (all)", url: home, removable: false, searchable: true, icon: "internaldrive"),
            PlaceEntry(name: "System (/) - mostly read-only", url: URL(fileURLWithPath: "/"), removable: false, searchable: false, icon: "lock.shield")
        ]
        for u in FolderStore.loadAll() {
            list.append(PlaceEntry(name: u.lastPathComponent, url: u, removable: true, searchable: true, icon: "folder.badge.plus"))
        }
        places = list
    }

    func addGrantedFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        if places.contains(where: { $0.url.standardizedFileURL.path == path }) { return }
        if FolderStore.add(url) {
            refreshPlaces()
        } else {
            errorMessage = "Couldn't save access to that folder."
        }
    }

    func removeGranted(_ url: URL) {
        FolderStore.remove(url)
        refreshPlaces()
    }

    private func isRoot(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return places.contains { $0.url.standardizedFileURL.path == p }
    }

    // MARK: Navigation

    func open(_ url: URL) {
        clearSearch()
        clearSelection()
        location = url
        reload()
    }

    func goUp() {
        guard let loc = location else { return }
        clearSelection()
        if isRoot(loc) {
            location = nil
            items = []
            loadError = nil
            return
        }
        let parent = loc.deletingLastPathComponent()
        if parent.standardizedFileURL.path == loc.standardizedFileURL.path {
            location = nil
            items = []
        } else {
            location = parent
            reload()
        }
    }

    func reload() {
        guard let loc = location else {
            items = []
            loadError = nil
            return
        }
        do {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let urls = try FileManager.default.contentsOfDirectory(at: loc, includingPropertiesForKeys: keys, options: [])
            items = urls.map(makeFileItem).sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            loadError = nil
        } catch {
            items = []
            loadError = "Can't open this folder. iOS may be blocking it.\n\(error.localizedDescription)"
        }
    }

    func reveal(_ item: FileItem) {
        if item.isDirectory {
            open(item.url)
        } else {
            open(item.url.deletingLastPathComponent())
        }
    }

    // MARK: Search

    func runSearch() {
        searchJob?.cancelled = true
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            clearSearch()
            return
        }
        let bases: [URL]
        if let loc = location {
            bases = [loc]
        } else {
            bases = places.filter { $0.searchable }.map { $0.url }
        }
        let job = SearchJob()
        searchJob = job
        searchActive = true
        isSearching = true
        results = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [FileItem] = []
            var seen = Set<String>()
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            outer: for base in bases {
                guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { continue }
                while let obj = en.nextObject() {
                    if job.cancelled { return }
                    guard let u = obj as? URL else { continue }
                    if u.lastPathComponent.localizedCaseInsensitiveContains(q), seen.insert(u.path).inserted {
                        found.append(makeFileItem(u))
                        if found.count >= 500 { break outer }
                    }
                }
            }
            let finalResults = found
            DispatchQueue.main.async {
                guard let self = self, !job.cancelled else { return }
                self.results = finalResults
                self.isSearching = false
            }
        }
    }

    func clearSearch() {
        searchJob?.cancelled = true
        searchJob = nil
        query = ""
        results = []
        searchActive = false
        isSearching = false
    }

    // MARK: Selection

    func toggleSelectMode() {
        selecting.toggle()
        if !selecting { selection = [] }
    }

    func clearSelection() {
        selecting = false
        selection = []
    }

    func toggle(_ item: FileItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    func selectedURLs() -> [URL] {
        let all = items + results
        var seen = Set<String>()
        var out: [URL] = []
        for it in all where selection.contains(it.id) {
            if seen.insert(it.id).inserted { out.append(it.url) }
        }
        return out
    }

    // MARK: Create

    private func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." || name.contains("/") {
            errorMessage = "That name isn't allowed. Use a name without slashes."
            return nil
        }
        return name
    }

    func createFolder(_ raw: String) {
        guard let dir = location, let name = validName(raw) else { return }
        let target = dir.appendingPathComponent(name, isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                errorMessage = "\"\(name)\" already exists here."
                return
            }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            reload()
        } catch {
            errorMessage = "Couldn't create the folder: \(error.localizedDescription)"
        }
    }

    func createFile(_ raw: String, text: String) {
        guard let dir = location, let name = validName(raw) else { return }
        let target = dir.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                errorMessage = "\"\(name)\" already exists here."
                return
            }
            try Data(text.utf8).write(to: target, options: .atomic)
            reload()
        } catch {
            errorMessage = "Couldn't create the file: \(error.localizedDescription)"
        }
    }

    // MARK: Delete

    func requestDelete(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        deleteTargets = urls
        showDeleteConfirm = true
    }

    func confirmDelete() {
        let urls = deleteTargets
        deleteTargets = []
        var failures: [String] = []
        for u in urls {
            do {
                try FileManager.default.removeItem(at: u)
            } catch {
                failures.append("\(u.lastPathComponent): \(error.localizedDescription)")
            }
        }
        clearSelection()
        reload()
        results.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        if !failures.isEmpty {
            errorMessage = "Some items couldn't be deleted:\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: Move

    func startMove(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingMove = urls
        clearSelection()
        if searchActive { clearSearch() }
    }

    func cancelMove() {
        pendingMove = []
    }

    func finishMove() {
        guard let dest = location else { return }
        let destPath = dest.standardizedFileURL.path
        var failures: [String] = []
        for src in pendingMove {
            let srcPath = src.standardizedFileURL.path
            let target = dest.appendingPathComponent(src.lastPathComponent)
            if destPath == srcPath || destPath.hasPrefix(srcPath + "/") {
                failures.append("\(src.lastPathComponent): can't move a folder into itself")
                continue
            }
            if target.standardizedFileURL.path == srcPath { continue }
            if FileManager.default.fileExists(atPath: target.path) {
                failures.append("\(src.lastPathComponent): something with that name is already here")
                continue
            }
            do {
                try FileManager.default.moveItem(at: src, to: target)
            } catch {
                failures.append("\(src.lastPathComponent): \(error.localizedDescription)")
            }
        }
        pendingMove = []
        reload()
        if !failures.isEmpty {
            errorMessage = "Some items couldn't be moved:\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: Info

    func showInfo(_ item: FileItem) {
        let size = item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown size"
        infoMessage = "\(item.name)\n\(size)\n\(item.url.path)"
    }
}

// MARK: - Folder picker (lets iOS grant access to a folder)

struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                _ = url.startAccessingSecurityScopedResource()
                onPick(url)
            }
        }
    }
}

// MARK: - New file / folder sheet

struct NewItemSheet: View {
    let isFile: Bool
    let onCreate: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(isFile ? "File name, e.g. notes.txt" : "Folder name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if isFile {
                    Section("Contents (optional)") {
                        TextEditor(text: $text)
                            .frame(minHeight: 140)
                    }
                }
            }
            .navigationTitle(isFile ? "New File" : "New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name, text)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

enum ActiveSheet: Identifiable {
    case newFile, newFolder, picker

    var id: Int {
        switch self {
        case .newFile: return 0
        case .newFolder: return 1
        case .picker: return 2
        }
    }
}

// MARK: - Explorer screen

struct ExplorerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ExplorerModel()
    @State private var sheet: ActiveSheet?

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .alert("Aufy", isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(model.errorMessage ?? "")
                }
            Divider()
            searchBar
                .alert("File", isPresented: Binding(
                    get: { model.infoMessage != nil },
                    set: { if !$0 { model.infoMessage = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(model.infoMessage ?? "")
                }
            Divider()
            if model.location != nil && !model.searchActive {
                pathBar
                Divider()
            }
            content
            bottomBar
        }
        .background(Color(.systemBackground))
        .alert("Delete \(model.deleteTargets.count) item(s)?", isPresented: $model.showDeleteConfirm) {
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.deleteTargets = [] }
        } message: {
            Text("This can't be undone.")
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .newFile:
                NewItemSheet(isFile: true) { name, text in
                    model.createFile(name, text: text)
                }
            case .newFolder:
                NewItemSheet(isFile: false) { name, _ in
                    model.createFolder(name)
                }
            case .picker:
                FolderPicker { url in
                    model.addGrantedFolder(url)
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack {
            // Back button: always top-left, always exits the explorer.
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
            }

            Spacer()

            Text(model.location?.lastPathComponent ?? "Locations")
                .font(.headline)
                .lineLimit(1)

            Spacer()

            Menu {
                Button {
                    sheet = .newFile
                } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                }
                .disabled(model.location == nil)

                Button {
                    sheet = .newFolder
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(model.location == nil)

                Button {
                    model.toggleSelectMode()
                } label: {
                    Label(model.selecting ? "Done Selecting" : "Select", systemImage: "checkmark.circle")
                }
                .disabled(model.location == nil && !model.searchActive)

                Button {
                    sheet = .picker
                } label: {
                    Label("Add Folder Access", systemImage: "externaldrive.badge.plus")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField(model.location == nil ? "Search all locations" : "Search in this folder", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { model.runSearch() }
            if model.isSearching {
                ProgressView()
            }
            if !model.query.isEmpty || model.searchActive {
                Button {
                    model.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var pathBar: some View {
        HStack(spacing: 10) {
            Button {
                model.goUp()
            } label: {
                Label("Up", systemImage: "arrow.up")
            }
            Text(model.location?.path ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if !model.pendingMove.isEmpty {
            HStack(spacing: 16) {
                Text("Moving \(model.pendingMove.count) item(s)")
                    .font(.subheadline)
                Spacer()
                Button("Cancel") { model.cancelMove() }
                Button("Move here") { model.finishMove() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.location == nil || model.searchActive)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
        } else if model.selecting {
            HStack(spacing: 16) {
                Text("\(model.selection.count) selected")
                    .font(.subheadline)
                Spacer()
                Button("Move") { model.startMove(model.selectedURLs()) }
                    .disabled(model.selection.isEmpty)
                Button("Delete", role: .destructive) { model.requestDelete(model.selectedURLs()) }
                    .disabled(model.selection.isEmpty)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.searchActive {
            resultList
        } else if model.location == nil {
            placeList
        } else {
            directoryList
        }
    }

    private var placeList: some View {
        List {
            Section("This device") {
                ForEach(model.places.filter { !$0.removable }) { place in
                    placeRow(place)
                }
            }
            Section("Folders you've granted") {
                ForEach(model.places.filter { $0.removable }) { place in
                    placeRow(place)
                }
                Button {
                    sheet = .picker
                } label: {
                    Label("Add folder access", systemImage: "plus.circle")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func placeRow(_ place: PlaceEntry) -> some View {
        Button {
            model.open(place.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: place.icon)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                    Text(place.url.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .foregroundColor(.primary)
        .contextMenu {
            if place.removable {
                Button(role: .destructive) {
                    model.removeGranted(place.url)
                } label: {
                    Label("Remove access (files stay)", systemImage: "minus.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var directoryList: some View {
        if let err = model.loadError {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text(err)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if model.items.isEmpty {
            VStack {
                Spacer()
                Text("This folder is empty")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(model.items) { item in
                row(item, showPath: false)
            }
            .listStyle(.plain)
            .refreshable { model.reload() }
        }
    }

    @ViewBuilder
    private var resultList: some View {
        if model.isSearching && model.results.isEmpty {
            VStack {
                Spacer()
                ProgressView("Searching...")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if model.results.isEmpty {
            VStack {
                Spacer()
                Text("No matches")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(model.results) { item in
                row(item, showPath: true)
            }
            .listStyle(.plain)
        }
    }

    private func row(_ item: FileItem, showPath: Bool) -> some View {
        Button {
            if model.selecting {
                model.toggle(item)
            } else if showPath {
                model.reveal(item)
            } else if item.isDirectory {
                model.open(item.url)
            } else {
                model.showInfo(item)
            }
        } label: {
            HStack(spacing: 12) {
                if model.selecting {
                    Image(systemName: model.selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(model.selection.contains(item.id) ? .blue : .secondary)
                }
                Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                    .foregroundColor(item.isDirectory ? .blue : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(1)
                    Text(showPath ? item.url.deletingLastPathComponent().path : detail(item))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .foregroundColor(.primary)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.requestDelete([item.url])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                model.startMove([item.url])
            } label: {
                Label("Move...", systemImage: "arrow.right.circle")
            }
            Button(role: .destructive) {
                model.requestDelete([item.url])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func detail(_ item: FileItem) -> String {
        var parts: [String] = []
        if item.isDirectory {
            parts.append("Folder")
        } else if let s = item.size {
            parts.append(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
        }
        if let d = item.modified {
            parts.append(d.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}
