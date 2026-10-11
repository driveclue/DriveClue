import AppKit
import DriveClueCore
import SwiftUI

/// On-demand storage analysis for one mounted volume.
struct UsageView: View {
    @Bindable var model: AppModel
    var drive: DriveSnapshot

    @State private var volumeBSD = ""
    @State private var currentPath = ""
    @State private var selectedPath = ""
    @State private var query = ""
    @State private var sortOrder: UsageItemSort = .size
    @State private var pendingTrash: UsageNode?
    @State private var showUnreadable = false

    private struct MapItem: Identifiable {
        let id: String
        let name: String
        let size: UInt64
        let node: UsageNode?
    }

    private struct MapTile: Identifiable {
        let item: MapItem
        let rect: CGRect
        var id: String { item.id }
    }

    private var volumes: [VolumeInfo] {
        let candidates = drive.volumes.filter { $0.isUserFacing && $0.mountPath != nil }
        // System and Data share an APFS container. The Data mount contains user files.
        if candidates.contains(where: { $0.role == "Data" }) {
            return candidates.filter { $0.role != "System" }
        }
        return candidates
    }

    private var selectedVolume: VolumeInfo? {
        volumes.first { $0.bsdName == volumeBSD } ?? volumes.first
    }

    private var scanState: UsageScanState? {
        guard let volume = selectedVolume, let state = model.usage,
              state.driveID == drive.id, state.volumeBSD == volume.bsdName else { return nil }
        return state
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let state = scanState, state.isScanning {
                scanningView(state)
            } else if let result = scanState?.result {
                if let error = result.rootReadError {
                    scanFailureView(error)
                } else {
                    resultsView(result)
                }
            } else {
                idleView(cancelled: (scanState?.scannedFiles ?? 0) > 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiagnosticTheme.background)
        .task(id: drive.id) {
            if volumeBSD.isEmpty || !volumes.contains(where: { $0.bsdName == volumeBSD }) {
                volumeBSD = volumes.first?.bsdName ?? ""
            }
        }
        .onChange(of: drive.id) {
            currentPath = ""
            selectedPath = ""
            query = ""
        }
        .onChange(of: volumeBSD) {
            currentPath = ""
            selectedPath = ""
            query = ""
        }
        .onChange(of: query) { clearSelectionIfHidden() }
        .onChange(of: sortOrder) { clearSelectionIfHidden() }
        .confirmationDialog(
            pendingTrash.map { "Move “\($0.name)” to the Trash?" } ?? "",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let item = pendingTrash {
                    Task {
                        if let error = await model.trashUsageFile(item) { model.alertText = error }
                        else { selectedPath = "" }
                    }
                }
                pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: {
            Text("The item can be restored from the Trash. Scan again to update the sizes.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SectionHeader(title: "Storage Analyzer", symbol: "internaldrive.fill", tint: DiagnosticTheme.teal)
            Spacer()
            if volumes.count > 1 {
                Picker("Volume", selection: $volumeBSD) {
                    ForEach(volumes) { volume in
                        Text(volume.name).tag(volume.bsdName)
                    }
                }
                .frame(width: 190)
            } else if let volume = selectedVolume {
                Label(volume.name, systemImage: "externaldrive")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DiagnosticTheme.muted)
                    .lineLimit(1)
            }
            if scanState?.result != nil {
                Button("Scan Again") { startScan() }
                    .disabled(scanState?.isScanning == true)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
        .overlay(alignment: .bottom) { DiagnosticTheme.line.frame(height: 1) }
    }

    private func idleView(cancelled: Bool) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "square.3.layers.3d.down.right")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(DiagnosticTheme.cyan)
                .frame(width: 104, height: 104)
                .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 25))
            VStack(spacing: 7) {
                Text(cancelled ? "Analysis stopped" : "See what’s using your space")
                    .font(.system(size: 23, weight: .semibold))
                Text(idleDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(DiagnosticTheme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }
            Button(action: startScan) {
                Label(cancelled ? "Analyze Disk Again" : "Analyze Disk", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 238, height: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(DiagnosticTheme.selection)
            .disabled(selectedVolume == nil)
            if let volume = selectedVolume {
                Text("\(volume.name) · \(ByteFormat.bytes(volume.availableBytes)) available")
                    .font(.system(size: 11))
                    .foregroundStyle(DiagnosticTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var idleDescription: String {
        selectedVolume == nil ? "Connect or mount a volume to analyze its files." : "Explore folders and files by size. Analysis starts only when you choose to run it."
    }

    private func scanningView(_ state: UsageScanState) -> some View {
        VStack(spacing: 17) {
            ProgressView()
                .controlSize(.large)
            Text(state.scanPhase == .finalizing ? "Finishing analysis of \(state.volumeName)" : "Analyzing \(state.volumeName)")
                .font(.system(size: 20, weight: .semibold))
            Text("\(state.scannedFiles.formatted()) files · \(state.scannedFolders.formatted()) folders examined")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(DiagnosticTheme.muted)
            TimelineView(.periodic(from: state.startedAt, by: 1)) { timeline in
                Text("Elapsed: \(max(0, Int(timeline.date.timeIntervalSince(state.startedAt)))) seconds")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(DiagnosticTheme.muted)
            }
            if !state.currentPath.isEmpty {
                Text(state.currentPath)
                    .font(.system(size: 11))
                    .foregroundStyle(DiagnosticTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            Text(state.scanPhase == .finalizing
                 ? "The file walk is complete. Finishing totals and the disk map…"
                 : "Large volumes may take a while. You can stop at any time.")
                .font(.system(size: 12))
                .foregroundStyle(DiagnosticTheme.muted)
            Button("Stop Analysis") { model.cancelUsageScan() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanFailureView(_ error: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 38))
                .foregroundStyle(DiagnosticTheme.amber)
            Text("Couldn’t analyze this volume")
                .font(.system(size: 20, weight: .semibold))
            Text(error)
                .font(.system(size: 13))
                .foregroundStyle(DiagnosticTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            Button("Try Again", action: startScan)
                .buttonStyle(.borderedProminent)
                .disabled(selectedVolume == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func resultsView(_ result: UsageScanResult) -> some View {
        let current = node(at: currentPath, in: result)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summary(result)
                if scanState?.sizesStale == true {
                    Label("Items were moved to the Trash. Scan again to refresh sizes.", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(DiagnosticTheme.amber)
                        .panel(padding: 10)
                }
                if scanState?.scanWasCancelled == true, scanState?.result != nil {
                    Label("Rescan cancelled. Showing the last completed analysis.", systemImage: "arrow.uturn.backward.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(DiagnosticTheme.amber)
                        .panel(padding: 10)
                }
                if result.unreadableEntries > 0 {
                    Text("Some items could not be read. Sizes and totals may be incomplete.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DiagnosticTheme.amber)
                        .panel(padding: 10)
                }
                if !result.unreadablePaths.isEmpty {
                    DisclosureGroup("Unreadable items (\(result.unreadableEntries.formatted()))", isExpanded: $showUnreadable) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(result.unreadablePaths.prefix(8), id: \.self) { path in
                                Text(path)
                                    .font(.system(size: 10).monospaced())
                                    .foregroundStyle(DiagnosticTheme.muted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if result.unreadablePaths.count > 8 {
                                Text("Showing the first 8 paths. The scan found \(result.unreadableEntries.formatted()) unreadable entries.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DiagnosticTheme.muted)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DiagnosticTheme.amber)
                    .panel(padding: 10)
                }
                mapPanel(current, result: result)
                browserPanel(current, result: result)
                inspectorPanel(current, result: result)
            }
            .padding(16)
        }
    }

    private func summary(_ result: UsageScanResult) -> some View {
        HStack(spacing: 0) {
            metric("SCANNED SPACE", value: ByteFormat.bytes(result.root.size), symbol: "internaldrive")
            metric("FILES", value: result.scannedFiles.formatted(), symbol: "doc.on.doc")
            metric("TOP-LEVEL FOLDERS", value: result.root.directories.count.formatted(), symbol: "folder")
            if result.unreadableEntries > 0 {
                metric("UNREADABLE", value: result.unreadableEntries.formatted(), symbol: "lock")
            }
        }
        .panel(padding: 12)
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(DiagnosticTheme.muted)
            Text(value)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mapPanel(_ current: UsageNode, result: UsageScanResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Disk Map", symbol: "square.grid.3x3.fill", tint: DiagnosticTheme.cyan)
                Spacer()
                Text("Area represents allocated size")
                    .font(.system(size: 11))
                    .foregroundStyle(DiagnosticTheme.muted)
            }
            breadcrumbs(result, current: current)
            if current.size == 0 {
                Text("No readable files in this folder.")
                    .foregroundStyle(DiagnosticTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                GeometryReader { geometry in
                    let tiles = mapTiles(for: current, in: CGRect(origin: .zero, size: geometry.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(tiles) { tile in
                            let width = max(0, tile.rect.width - 3)
                            let height = max(0, tile.rect.height - 3)
                            Button {
                                if let node = tile.item.node { selectedPath = node.path }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    if width > 85 && height > 35 {
                                        Text(tile.item.name)
                                            .font(.system(size: 11, weight: .semibold))
                                            .lineLimit(1)
                                        if height > 55 {
                                            Text(ByteFormat.bytes(tile.item.size))
                                                .font(.system(size: 10).monospacedDigit())
                                                .opacity(0.88)
                                        }
                                    }
                                }
                                .padding(7)
                                .frame(width: width, height: height, alignment: .topLeading)
                                .background(mapColor(tile.item, in: current), in: RoundedRectangle(cornerRadius: 5))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(selectedPath == tile.item.id ? Color.white : Color.clear, lineWidth: 2)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(tile.item.node == nil)
                            .help("\(tile.item.name) · \(ByteFormat.bytes(tile.item.size))")
                            .accessibilityLabel("\(tile.item.name), \(ByteFormat.bytes(tile.item.size))")
                            .accessibilityHint(tile.item.node == nil ? "Additional items included in the folder total." : "Select item")
                            .position(x: tile.rect.midX, y: tile.rect.midY)
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                if let node = tile.item.node, node.isDirectory { openFolder(node) }
                            })
                        }
                    }
                }
                .frame(height: 220)
            }
            if current.truncated || result.unreadableEntries > 0 {
                Text("Some folders are summarized or inaccessible. The map shows only space this scan could read.")
                    .font(.system(size: 11))
                    .foregroundStyle(DiagnosticTheme.muted)
            }
            Text("Readable file allocations can differ from macOS’s used-space total.")
                .font(.system(size: 11))
                .foregroundStyle(DiagnosticTheme.muted)
        }
        .panel()
    }

    private func browserPanel(_ current: UsageNode, result: UsageScanResult) -> some View {
        UsageBrowserPanel(items: visibleItems(in: current), total: current.size, selectedPath: selectedPath,
                          query: $query, sortOrder: $sortOrder, canGoBack: current.path != result.root.path,
                          isTruncated: current.truncated, navigation: breadcrumbs(result, current: current),
                          goBack: { navigate(to: parentFolder(of: current, in: result)) },
                          openFolder: openFolder, selectFile: { selectedPath = $0.path })
    }

    private func inspectorPanel(_ current: UsageNode, result: UsageScanResult) -> some View {
        let item = (current.directories + current.files).first { $0.path == selectedPath } ?? current
        return UsageInspectorPanel(item: item, current: current, rootPath: result.root.path,
                                   sizesStale: scanState?.sizesStale == true, canTrash: canMoveToTrash(item),
                                   openFolder: openFolder, reveal: { model.revealInFinder($0.path) },
                                   trash: { pendingTrash = $0 })
    }

    private func breadcrumbs(_ result: UsageScanResult, current: UsageNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(crumbs(in: result, to: current), id: \.path) { crumb in
                    if crumb.path != result.root.path {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(DiagnosticTheme.muted)
                    }
                    Button(crumb.name) {
                        navigate(to: crumb.path)
                    }
                    .font(.system(size: 11, weight: crumb.path == current.path ? .semibold : .regular))
                    .buttonStyle(.borderless)
                    .disabled(crumb.path == current.path)
                }
            }
        }
    }

    private func visibleItems(in node: UsageNode) -> [UsageNode] {
        var items = (node.directories + node.files).filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
        }
        switch sortOrder {
        case .size: items.sort { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
        case .name: items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .kind: items.sort { $0.isDirectory == $1.isDirectory ? $0.name < $1.name : $0.isDirectory }
        }
        return items
    }

    private func mapTiles(for node: UsageNode, in bounds: CGRect) -> [MapTile] {
        let children = (node.directories + node.files).filter { $0.size > 0 }.sorted { $0.size > $1.size }
        var items = children.prefix(15).map { MapItem(id: $0.path, name: $0.name, size: $0.size, node: $0) }
        let shown = items.reduce(UInt64(0)) { $0 + $1.size }
        if node.size > shown {
            items.append(MapItem(id: "other:\(node.path)", name: "Other items", size: node.size - shown, node: nil))
        }
        let rects = UsageTreemap.layout(weights: items.map(\.size), in: bounds)
        return zip(items, rects).map { MapTile(item: $0.0, rect: $0.1) }
    }

    private func mapColor(_ item: MapItem, in node: UsageNode) -> Color {
        guard let child = item.node else { return DiagnosticTheme.muted.opacity(0.45) }
        let palette = [DiagnosticTheme.cyan, DiagnosticTheme.teal, DiagnosticTheme.indigo,
                       DiagnosticTheme.purple, DiagnosticTheme.selection, DiagnosticTheme.rose]
        let index = (node.directories + node.files).firstIndex(where: { $0.path == child.path }) ?? 0
        return palette[index % palette.count].opacity(0.78)
    }

    private func startScan() {
        guard let volume = selectedVolume else { return }
        currentPath = ""
        selectedPath = ""
        query = ""
        model.startUsageScan(drive: drive, volume: volume)
    }

    private func openFolder(_ node: UsageNode) { navigate(to: node.path) }

    private func navigate(to path: String) {
        currentPath = path
        selectedPath = ""
        query = ""
    }

    private func clearSelectionIfHidden() {
        guard !selectedPath.isEmpty, let result = scanState?.result else { return }
        if !visibleItems(in: node(at: currentPath, in: result)).contains(where: { $0.path == selectedPath }) {
            selectedPath = ""
        }
    }

    private func canMoveToTrash(_ item: UsageNode) -> Bool {
        guard !item.isDirectory else {
            return !["System", "Users", "Applications", "Library", "private", "usr", "opt", "Volumes", "cores", "mnt"].contains(item.name)
        }
        return true
    }

    private func parentFolder(of current: UsageNode, in result: UsageScanResult) -> String {
        let path = current.path
        guard path != result.root.path else { return path }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.hasPrefix(result.root.path) ? parent : result.root.path
    }

    private func node(at path: String, in result: UsageScanResult) -> UsageNode {
        var node = result.root
        guard path.hasPrefix(result.root.path), path != result.root.path else { return node }
        for component in path.dropFirst(result.root.path.count).split(separator: "/") {
            let childPath = node.path.hasSuffix("/") ? node.path + component : node.path + "/" + component
            guard let next = node.directories.first(where: { $0.path == childPath }) else { return node }
            node = next
        }
        return node
    }

    private func crumbs(in result: UsageScanResult, to current: UsageNode) -> [(path: String, name: String)] {
        var crumbs = [(path: result.root.path, name: result.root.name)]
        var node = result.root
        guard current.path != node.path else { return crumbs }
        for component in current.path.dropFirst(result.root.path.count).split(separator: "/") {
            let childPath = node.path.hasSuffix("/") ? node.path + component : node.path + "/" + component
            guard let next = node.directories.first(where: { $0.path == childPath }) else { break }
            crumbs.append((next.path, next.name))
            node = next
        }
        return crumbs
    }
}
