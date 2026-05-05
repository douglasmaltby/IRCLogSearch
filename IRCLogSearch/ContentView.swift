//
//  ContentView.swift
//  IRCLogSearch
//
//  Created by Douglas Maltby on 5/4/26.
//  Started with Xcode and Apple Intelligence hooked to Gemini 3 Pro (latest) on MBP M4 laptop, then moved to Antigravity with Gemini 3.1 Pro (high) on M1 Ultra Studio
//  Antigravity: Need to add a professional devloper persona with references to Swift code, best practices, etc. Which file does Antigravity use for this??? Is it per project or global?

//  Biggest issue is peformance. I don't want to ingest the data into SQlite , but keep it in memory. How to do this efficiently?
//  UI for selecting channels, sorting, filtering is not ideal yet.
//  Sort on columns, ability to select and copy records to clipboard
//  Facets - rather than just one search box - use facets on the top or left side, i.e. Channels (with checkboxes), date range, users (with checkboxes), message content

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Data Models

struct LogEntry: Identifiable, Sendable {
    let id: Int
    let channel: String
    let timestamp: String
    let author: String
    let message: String
    let lowerAuthor: String
    let lowerMessage: String
}

extension LogEntry {
    /// Fast custom log line parser - placed here to be completely thread-safe and non-isolated
    nonisolated static func parseLine(_ line: String, channel: String, id: Int) -> LogEntry? {
        // Expected basic format: "[14:32:01] <Author> Message"
        // System format: "[14:32:01] -!- Author joined"
        guard line.hasPrefix("["), let closeBracketIndex = line.firstIndex(of: "]") else {
            return nil
        }

        let timestamp = String(line[line.index(after: line.startIndex)..<closeBracketIndex])
        let remainder = line[line.index(after: closeBracketIndex)...].trimmingCharacters(
            in: .whitespaces)

        var author = ""
        var message = remainder

        if remainder.hasPrefix("<"), let closeAngleIndex = remainder.firstIndex(of: ">") {
            // Standard user message
            author = String(
                remainder[remainder.index(after: remainder.startIndex)..<closeAngleIndex])
            let messageStartIndex = remainder.index(after: closeAngleIndex)
            if messageStartIndex < remainder.endIndex {
                message = remainder[messageStartIndex...].trimmingCharacters(in: .whitespaces)
            } else {
                message = ""
            }
        } else {
            // System or action message
            author = "System"
        }

        return LogEntry(
            id: id, channel: channel, timestamp: timestamp, author: author, message: message,
            lowerAuthor: author.lowercased(), lowerMessage: message.lowercased())
    }

    /// Bypasses the heavy KeyPathComparator reflection layer and Unicode normalization.
    /// Uses raw UTF-8 byte comparison for O(N log N) sorting in milliseconds instead of minutes.
    nonisolated static func fastSort(
        _ array: inout [LogEntry], using sortOrder: [KeyPathComparator<LogEntry>]
    ) {
        guard let firstSort = sortOrder.first else { return }
        let isForward = firstSort.order == .forward

        switch firstSort.keyPath {
        case \LogEntry.timestamp:
            array.sort {
                isForward
                    ? $0.timestamp.utf8.lexicographicallyPrecedes($1.timestamp.utf8)
                    : $1.timestamp.utf8.lexicographicallyPrecedes($0.timestamp.utf8)
            }
        case \LogEntry.channel:
            array.sort {
                isForward
                    ? $0.channel.utf8.lexicographicallyPrecedes($1.channel.utf8)
                    : $1.channel.utf8.lexicographicallyPrecedes($0.channel.utf8)
            }
        case \LogEntry.author:
            array.sort {
                isForward
                    ? $0.author.utf8.lexicographicallyPrecedes($1.author.utf8)
                    : $1.author.utf8.lexicographicallyPrecedes($0.author.utf8)
            }
        case \LogEntry.message:
            array.sort {
                isForward
                    ? $0.message.utf8.lexicographicallyPrecedes($1.message.utf8)
                    : $1.message.utf8.lexicographicallyPrecedes($0.message.utf8)
            }
        default:
            break
        }
    }
}

enum SortColumn: String, CaseIterable {
    case timestamp = "Date"
    case channel = "Channel"
    case author = "Author"
    case message = "Message"

    var keyPath: KeyPath<LogEntry, String> {
        switch self {
        case .timestamp: return \.timestamp
        case .channel: return \.channel
        case .author: return \.author
        case .message: return \.message
        }
    }
}

// MARK: - State Management

@Observable @MainActor
class LogSearchModel {
    var allEntries: [LogEntry] = []
    var filteredEntries: [LogEntry] = []  // Cache for search results before sorting
    var displayedEntries: [LogEntry] = []

    var channels: [String] = []
    var selectedChannels: Set<String> = []
    var searchText: String = ""

    // Sort ordering state for the Table
    var sortOrder: [KeyPathComparator<LogEntry>] = [KeyPathComparator(\.timestamp)]

    var activeSortColumn: SortColumn {
        get {
            guard let kp = sortOrder.first?.keyPath as? KeyPath<LogEntry, String> else {
                return .timestamp
            }
            return SortColumn.allCases.first { $0.keyPath == kp } ?? .timestamp
        }
        set {
            sortOrder = [KeyPathComparator(newValue.keyPath, order: activeSortDirection)]
        }
    }

    var activeSortDirection: SortOrder {
        get { sortOrder.first?.order ?? .forward }
        set {
            let kp = sortOrder.first?.keyPath as? KeyPath<LogEntry, String> ?? \.timestamp
            sortOrder = [KeyPathComparator(kp, order: newValue)]
        }
    }

    var isIngesting: Bool = false
    var isSearching: Bool = false
    var totalFilesScanned: Int = 0

    // Keep track of tasks to cancel them on rapid typing
    private var filterTask: Task<Void, Never>?
    private var sortTask: Task<Void, Never>?

    /// Opens a native macOS panel to select the log directory
    func selectLogFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Textual Logs Folder"
        panel.message = "Please select the TWIT Channels directory."

        // Attempt to default to the specific Temp folder you mentioned
        let defaultPath = "/Temp/TWIT Channels"
        if FileManager.default.fileExists(atPath: defaultPath) {
            panel.directoryURL = URL(fileURLWithPath: defaultPath)
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url {
                    Task { await self.ingestLogs(from: url) }
                }
            }
        } else {
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    Task { await self.ingestLogs(from: url) }
                }
            }
        }
    }

    /// Asynchronously parses log files in the background
    private func ingestLogs(from url: URL) async {
        isIngesting = true

        // Run the heavy lifting off the main thread
        let result = await Task.detached(priority: .userInitiated) {
            () -> ([String], [LogEntry], Int) in
            let fileManager = FileManager.default
            guard
                let enumerator = fileManager.enumerator(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey])
            else {
                return ([], [], 0)
            }

            var parsedEntries: [LogEntry] = []
            var foundChannels: Set<String> = []
            var filesScanned = 0

            while let fileURL = enumerator.nextObject() as? URL {
                guard fileURL.pathExtension == "txt" else { continue }
                filesScanned += 1

                let channelName = fileURL.deletingLastPathComponent().lastPathComponent
                foundChannels.insert(channelName)

                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    let lines = content.components(separatedBy: .newlines)
                    for line in lines where !line.isEmpty {
                        if let entry = LogEntry.parseLine(
                            line, channel: channelName, id: parsedEntries.count)
                        {
                            parsedEntries.append(entry)
                        }
                    }
                }
            }

            let sortedChannels = foundChannels.sorted()

            // Pre-sort all entries by timestamp for fastest initial load
            LogEntry.fastSort(&parsedEntries, using: [KeyPathComparator(\.timestamp)])

            return (sortedChannels, parsedEntries, filesScanned)
        }.value

        // Apply parsed data to the UI on the Main Actor
        self.channels = result.0
        self.selectedChannels = Set(result.0)  // Select all by default
        self.allEntries = result.1
        self.totalFilesScanned = result.2
        self.isIngesting = false

        updateFilter()
    }

    /// Filters search and channel results concurrently across CPU cores
    func updateFilter() {
        // Cancel previous tasks so rapid typing doesn't hang the app
        filterTask?.cancel()
        sortTask?.cancel()
        isSearching = true

        // Capture value types to avoid retaining the non-Sendable @MainActor class in Task.detached
        let search = searchText.lowercased()
        let selected = selectedChannels
        let entries = allEntries
        let totalChannelsCount = channels.count
        let currentSort = sortOrder

        filterTask = Task {
            let (filtered, sorted) = await Task.detached(priority: .userInitiated) {
                if selected.isEmpty { return ([LogEntry](), [LogEntry]()) }

                let checkChannels = selected.count < totalChannelsCount
                let checkSearch = !search.isEmpty

                // If there are no active filters, instantly return the pre-sorted massive array
                if !checkChannels && !checkSearch {
                    var sortedFiltered = entries
                    let isDefaultSort =
                        currentSort.count == 1 && currentSort.first?.keyPath == \LogEntry.timestamp
                        && currentSort.first?.order == .forward
                    if !isDefaultSort {
                        LogEntry.fastSort(&sortedFiltered, using: currentSort)
                    }
                    return (entries, sortedFiltered)
                }

                // Spawn parallel worker tasks to process 100k items per thread
                let finalFiltered = await withTaskGroup(of: [LogEntry].self) { group in
                    let chunkSize = 100_000
                    var startIndex = 0

                    while startIndex < entries.count {
                        let endIndex = min(startIndex + chunkSize, entries.count)

                        // MUST copy these variables to immutable references.
                        // Otherwise the @Sendable closure captures the mutable reference and all
                        // tasks evaluate out-of-bounds at the very end of the array.
                        let taskStart = startIndex
                        let taskEnd = endIndex

                        group.addTask {
                            var localFiltered: [LogEntry] = []
                            localFiltered.reserveCapacity(chunkSize / 10)

                            // Iterate specific ranges so we don't pay the Array Slice overhead
                            for i in taskStart..<taskEnd {
                                if Task.isCancelled { return [] }
                                let entry = entries[i]

                                if checkChannels {
                                    guard selected.contains(entry.channel) else { continue }
                                }

                                if checkSearch {
                                    let match =
                                        entry.lowerMessage.contains(search)
                                        || entry.lowerAuthor.contains(search)
                                    guard match else { continue }
                                }

                                localFiltered.append(entry)
                            }
                            return localFiltered
                        }
                        startIndex = endIndex
                    }

                    var collated: [LogEntry] = []
                    for await chunkResult in group {
                        collated.append(contentsOf: chunkResult)
                    }
                    return collated
                }

                var sortedFiltered = finalFiltered
                let isDefaultSort =
                    currentSort.count == 1 && currentSort.first?.keyPath == \LogEntry.timestamp
                    && currentSort.first?.order == .forward
                if !isDefaultSort {
                    LogEntry.fastSort(&sortedFiltered, using: currentSort)
                }
                return (finalFiltered, sortedFiltered)
            }.value

            // Assuming we haven't been cancelled by a new keystroke, save findings
            if !Task.isCancelled {
                self.filteredEntries = filtered
                self.displayedEntries = sorted
                self.isSearching = false
            }
        }
    }

    /// Bypasses the heavy filter evaluation and only sorts the already-filtered array subset
    func applySort() {
        sortTask?.cancel()
        isSearching = true

        let entries = filteredEntries
        let currentSort = sortOrder

        sortTask = Task {
            let sorted = await Task.detached(priority: .userInitiated) {
                var result = entries
                let isDefaultSort =
                    currentSort.count == 1 && currentSort.first?.keyPath == \LogEntry.timestamp
                    && currentSort.first?.order == .forward
                if !isDefaultSort {
                    LogEntry.fastSort(&result, using: currentSort)
                }
                return result
            }.value

            if !Task.isCancelled {
                self.displayedEntries = sorted
                self.isSearching = false
            }
        }
    }

    /// Selects or deselects all channels
    func toggleAllChannels(_ selectAll: Bool) {
        if selectAll {
            selectedChannels = Set(channels)
        } else {
            selectedChannels.removeAll()
        }
        updateFilter()
    }
}

// MARK: - Views

struct ContentView: View {
    @State private var model = LogSearchModel()
    @State private var selectedEntries = Set<LogEntry.ID>()

    var body: some View {
        NavigationSplitView {
            // MARK: Faceted Search Sidebar
            VStack {
                List {
                    if model.isIngesting {
                        HStack {
                            Spacer()
                            ProgressView("Reading Logs...")
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding()
                    } else if model.channels.isEmpty {
                        ContentUnavailableView(
                            "No Logs",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text(
                                "Select the folder containing your Textual log files.")
                        )
                    } else {
                        Section("Channels") {
                            ForEach(model.channels, id: \.self) { channel in
                                Toggle(
                                    isOn: Binding(
                                        get: { model.selectedChannels.contains(channel) },
                                        set: { isOn in
                                            if isOn {
                                                model.selectedChannels.insert(channel)
                                            } else {
                                                model.selectedChannels.remove(channel)
                                            }
                                            model.updateFilter()
                                        }
                                    )
                                ) {
                                    Text(channel)
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                }

                if !model.channels.isEmpty {
                    HStack {
                        Button("All") { model.toggleAllChannels(true) }
                        Button("None") { model.toggleAllChannels(false) }
                    }
                    .buttonStyle(.borderless)
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle("Filters")
        } detail: {
            // MARK: Main Data Pane
            VStack(spacing: 0) {
                // Top Status / Search Header
                HStack {
                    if model.isSearching {
                        ProgressView().controlSize(.small)
                    }
                    Text(
                        "Showing \(model.displayedEntries.count) of \(model.allEntries.count) events"
                    )
                    .foregroundStyle(.secondary)
                    .font(.caption)

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // Wide Results Pane with configured sort ordering
                resultsTable
            }
            .searchable(
                text: Binding(
                    get: { model.searchText },
                    set: {
                        model.searchText = $0
                        model.updateFilter()
                    }
                ), prompt: "Search messages or authors..."
            )
            .navigationTitle("IRC Log Search")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    sortMenu

                    Button {
                        model.selectLogFolder()
                    } label: {
                        Label("Load Logs", systemImage: "folder.badge.plus")
                    }
                    .help("Select directory containing IRC Logs")
                }
            }
        }
    }

    @ViewBuilder
    private var resultsTable: some View {
        Table(model.displayedEntries, selection: $selectedEntries, sortOrder: $model.sortOrder) {
            TableColumn("Date", value: \.timestamp)
                .width(min: 60, max: 120)
            TableColumn("Channel", value: \.channel)
                .width(min: 80, max: 140)
            TableColumn("Author", value: \.author)
                .width(min: 80, max: 150)
            TableColumn("Message", value: \.message)
        }
        .contextMenu(forSelectionType: LogEntry.ID.self) { items in
            Button("Copy") {
                copyToClipboard(items: items)
            }
        }
        .onCommand(Selector("copy:")) {
            copyToClipboard(items: selectedEntries)
        }
        .onChange(of: model.sortOrder) { _, _ in
            // ONLY trigger a re-sort instead of repeating the huge search evaluation
            model.applySort()
        }
    }

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            Picker(
                "Sort By",
                selection: Binding(
                    get: { model.activeSortColumn },
                    set: { model.activeSortColumn = $0 }
                )
            ) {
                ForEach(SortColumn.allCases, id: \.self) { column in
                    Text(column.rawValue).tag(column)
                }
            }

            Picker(
                "Order",
                selection: Binding(
                    get: { model.activeSortDirection },
                    set: { model.activeSortDirection = $0 }
                )
            ) {
                Text("Ascending").tag(SortOrder.forward)
                Text("Descending").tag(SortOrder.reverse)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort logs")
    }

    private func copyToClipboard(items: Set<LogEntry.ID>) {
        guard !items.isEmpty else { return }

        let entriesToCopy = model.displayedEntries.filter { items.contains($0.id) }
        let text = entriesToCopy.map { entry in
            if entry.author == "System" {
                return "[\(entry.timestamp)] \(entry.channel) -!- \(entry.message)"
            } else {
                return "[\(entry.timestamp)] \(entry.channel) <\(entry.author)> \(entry.message)"
            }
        }.joined(separator: "\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

#Preview {
    ContentView()
}
