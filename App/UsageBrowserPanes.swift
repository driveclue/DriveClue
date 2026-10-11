import DriveClueCore
import SwiftUI

/// Folders navigate the current scan; files retain the existing Inspector selection.
struct UsageBrowserPanes: View {
    var items: [UsageNode]
    var total: UInt64
    var selectedPath: String
    var isSearching: Bool
    var openFolder: (UsageNode) -> Void
    var selectFile: (UsageNode) -> Void

    var body: some View {
        HSplitView {
            pane(title: "Folders", items: items.filter(\.isDirectory), isDirectory: true)
                .frame(minWidth: 145, idealWidth: 210, maxWidth: 320)
            pane(title: "Files", items: items.filter { !$0.isDirectory }, isDirectory: false)
                .frame(minWidth: 175, maxWidth: .infinity)
        }
        .frame(height: 286)
    }

    private func pane(title: String, items: [UsageNode], isDirectory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(title, systemImage: isDirectory ? "folder" : "doc")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(items.count.formatted())
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(DiagnosticTheme.muted)
            }
            .padding(.horizontal, 9)
            if items.isEmpty {
                Text(isSearching ? "No matching \(title.lowercased())." : "No \(title.lowercased()) in this folder.")
                    .font(.system(size: 12))
                    .foregroundStyle(DiagnosticTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 4)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func row(_ item: UsageNode) -> some View {
        let tint = item.isDirectory ? DiagnosticTheme.cyan : DiagnosticTheme.purple
        return Button {
            if item.isDirectory { openFolder(item) }
            else { selectFile(item) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(tint)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 7) {
                        Text(ByteFormat.bytes(item.size))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(DiagnosticTheme.muted)
                            .fixedSize()
                        if item.isDirectory {
                            DiagnosticBar(value: total == 0 ? 0 : Double(item.size) / Double(total) * 100,
                                          color: tint)
                                .frame(maxWidth: 100)
                                .accessibilityHidden(true)
                        }
                    }
                }
                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DiagnosticTheme.muted)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(DiagnosticTheme.text)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(selectedPath == item.path ? DiagnosticTheme.selection.opacity(0.45) : DiagnosticTheme.rowAlternate)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(item.name) · \(ByteFormat.bytes(item.size))")
        .accessibilityLabel("\(item.name), \(item.isDirectory ? "Folder" : "File"), \(ByteFormat.bytes(item.size))")
        .accessibilityHint(item.isDirectory ? "Open folder" : "Select file in Inspector")
        .accessibilityAddTraits(selectedPath == item.path ? .isSelected : [])
    }
}

enum UsageItemSort: String, CaseIterable, Identifiable {
    case size = "Largest first"
    case name = "Name"
    case kind = "Kind"
    var id: Self { self }
}

struct UsageBrowserPanel<Navigation: View>: View {
    var items: [UsageNode]
    var total: UInt64
    var selectedPath: String
    @Binding var query: String
    @Binding var sortOrder: UsageItemSort
    var canGoBack: Bool
    var isTruncated: Bool
    var navigation: Navigation
    var goBack: () -> Void
    var openFolder: (UsageNode) -> Void
    var selectFile: (UsageNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "File Explorer", symbol: "list.bullet.rectangle", tint: DiagnosticTheme.teal)
                Spacer()
                Text("\(items.count) shown")
                    .font(.system(size: 11))
                    .foregroundStyle(DiagnosticTheme.muted)
            }
            HStack(spacing: 9) {
                Button {
                    goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(!canGoBack)
                .help("Go to parent folder")
                navigation
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField("Search this folder", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $sortOrder) {
                    ForEach(UsageItemSort.allCases) { order in Text(order.rawValue).tag(order) }
                }
                .labelsHidden()
                .frame(width: 125)
            }
            UsageBrowserPanes(items: items, total: total, selectedPath: selectedPath,
                              isSearching: !query.isEmpty, openFolder: openFolder) { item in
                selectFile(item)
            }
            if isTruncated {
                Text("Additional items in this folder are included in its total but are not listed individually.")
                    .font(.system(size: 11))
                    .foregroundStyle(DiagnosticTheme.muted)
            }
        }
        .panel()
    }
}

struct UsageInspectorPanel: View {
    var item: UsageNode
    var current: UsageNode
    var rootPath: String
    var sizesStale: Bool
    var canTrash: Bool
    var openFolder: (UsageNode) -> Void
    var reveal: (UsageNode) -> Void
    var trash: (UsageNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Inspector", symbol: "info.circle", tint: DiagnosticTheme.purple)
            HStack(alignment: .top, spacing: 20) {
                itemDetails
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    inspectorLine("Kind", item.isDirectory ? "Folder" : "File")
                    if item.isDirectory {
                        inspectorLine("Files below", item.fileCount.formatted())
                    }
                    if current.size > 0, item.path != current.path {
                        inspectorLine("Of this folder", String(format: "%.1f%%", Double(item.size) / Double(current.size) * 100))
                    }
                }
                .frame(width: 150)
                actions
                    .frame(width: 150, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var itemDetails: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 30))
                .foregroundStyle(item.isDirectory ? DiagnosticTheme.cyan : DiagnosticTheme.purple)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(ByteFormat.bytes(item.size))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                Text(item.path)
                    .font(.system(size: 10))
                    .foregroundStyle(DiagnosticTheme.muted)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.isDirectory, item.path != current.path {
                Button("Open Folder") { openFolder(item) }
                    .buttonStyle(.bordered)
            }
            Button("Show in Finder") { reveal(item) }
                .buttonStyle(.bordered)
            if item.path != rootPath, canTrash {
                Button("Move to Trash", role: .destructive) { trash(item) }
                    .buttonStyle(.bordered)
                    .disabled(sizesStale)
            } else if item.path != rootPath {
                Label("Protected system folder", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DiagnosticTheme.muted)
            }
        }
    }

    private func inspectorLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(DiagnosticTheme.muted)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 11))
    }
}
