import SwiftUI
import VaultCore

struct FileInspector: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    let file: FileItem
    let remove: () -> Void
    let select: (UUID) -> Void
    @State private var description = ""
    @State private var tags = ""
    @State private var preview = false
    @State private var showMetadata = false
    @State private var showContent = false
    private var related: [Relationship] { workspace.data.relationships.filter { $0.source == file.id || $0.target == file.id } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("FILE DETAILS").font(.system(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
                    Spacer()
                    Button { var updated = file; updated.favorite.toggle(); store.update(updated) } label: { Image(systemName: file.favorite ? "star.fill" : "star") }.buttonStyle(.plain).help("Toggle favorite").accessibilityLabel(file.favorite ? "Remove favorite" : "Favorite")
                }
                Button { preview = true } label: {
                    FileThumbnail(file: file).frame(height: 170).frame(maxWidth: .infinity).quietPanel()
                }.buttonStyle(.plain).help("Preview file")
                VStack(alignment: .leading, spacing: 6) {
                    Text(file.filename).font(.system(size: 18, weight: .medium)).textSelection(.enabled)
                    Text("\(file.type.uppercased()) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                    Text(file.ownership == .original ? "Indexed original" : "Vault-managed copy").font(.caption2).foregroundStyle(VaultStyle.teal)
                }
                HStack { Button("Open") { store.open(file) }; Button("Preview") { preview = true }; Button { store.reveal(file) } label: { Image(systemName: "arrow.up.forward.square") }.help("Reveal in Finder").accessibilityLabel("Reveal in Finder") }
                if let source = file.noteSource {
                    DisclosureGroup("Apple Notes source") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(source.accountName + " · " + source.folderName)
                            if let date = source.sourceModifiedAt { Text("Modified in Notes: " + date.formatted()).font(.caption) }
                            Text("Local snapshot: " + source.importedAt.formatted()).font(.caption)
                            Text("Plain-text copy. Refresh in the Notes workspace; originals in Apple Notes are unchanged.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 10)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Description & tags").font(.headline)
                    TextEditor(text: $description).frame(height: 80).scrollContentBackground(.hidden).padding(8).quietPanel().accessibilityLabel("File description")
                    TextField("Tags, separated by commas", text: $tags)
                    Button("Save Metadata") {
                        var updated = file; updated.description = description
                        updated.tags = Array(Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
                        store.update(updated)
                    }.disabled(description == file.description && tags == file.tags.joined(separator: ", "))
                }
                DisclosureGroup("Subjects & collections") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(workspace.data.subjects) { subject in
                            Toggle(subject.name, isOn: Binding(get: { subject.fileIDs.contains(file.id) }, set: { included in
                                workspace.change { data in
                                    guard let index = data.subjects.firstIndex(where: { $0.id == subject.id }) else { return }
                                    if included { data.subjects[index].fileIDs.insert(file.id) } else { data.subjects[index].fileIDs.remove(file.id) }
                                }
                            }))
                            Button("Inspect \(subject.name)") { select(subject.id) }.font(.caption)
                        }
                        if store.library.collections.isEmpty { Text("Create a collection from the library toolbar.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(store.library.collections) { collection in
                            Toggle(collection.name, isOn: Binding(get: { file.collectionIDs.contains(collection.id) }, set: { included in
                                var updated = file
                                if included { updated.collectionIDs.insert(collection.id) } else { updated.collectionIDs.remove(collection.id) }
                                store.update(updated)
                            }))
                        }
                    }.padding(.top, 12)
                }
                DisclosureGroup("Related documents · \(related.count)") {
                    VStack(alignment: .leading, spacing: 12) {
                        if related.isEmpty { Text("Create a connection from a file’s Knowledge Map context menu.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(related) { edge in
                            let id = edge.source == file.id ? edge.target : edge.source
                            if let target = store.library.files.first(where: { $0.id == id }) {
                                HStack { Button(target.filename) { select(target.id) }.lineLimit(2); Spacer(); Button { select(edge.id) } label: { Image(systemName: "link") }.help("Inspect relationship").accessibilityLabel("Inspect relationship to \(target.filename)") }
                            }
                        }
                    }.padding(.top, 12)
                }
                if let facts = workspace.data.organizationFacts?[file.id] {
                    organizationEvidence(facts)
                }
                DisclosureGroup("File information", isExpanded: $showMetadata) {
                    VStack(alignment: .leading, spacing: 14) {
                        detail("Created on disk", file.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable")
                        detail("Modified on disk", file.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable")
                        detail("Added to Vault", file.indexedAt.formatted(date: .abbreviated, time: .shortened))
                        detail("Location at indexing", file.originalLocation)
                        Text("Details reflect the last index refresh. Monitored locations refresh while Vault runs.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                }
                DisclosureGroup("Local content index", isExpanded: $showContent) { contentTools.padding(.top, 12) }
                Divider()
                Button("Remove from Index…", role: .destructive, action: remove)
                Text("This never deletes the underlying file.").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }.sheet(isPresented: $preview) { FilePreview(file: file) }
            .onAppear { description = file.description; tags = file.tags.joined(separator: ", ") }
    }
    private func organizationEvidence(_ facts: OrganizationFacts) -> some View {
        DisclosureGroup("Organization evidence") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Folder context: " + facts.folderContext).font(.caption).textSelection(.enabled)
                if let date = facts.captureDate { Text("EXIF capture time (as recorded): " + date).font(.caption) }
                if let month = facts.captureMonth { Text("EXIF capture month: " + month).font(.caption) }
                if let area = facts.gpsArea { Text("EXIF GPS area: " + area).font(.caption) }
                Text("Document content: " + facts.textStatus).font(.caption).foregroundStyle(.secondary)
                ForEach(facts.topics.keys.sorted(), id: \.self) { topic in
                    Text(topic + ": " + (facts.topics[topic] ?? "")).font(.caption)
                }
                ForEach(facts.reviewReasons, id: \.self) { Text($0).font(.caption).foregroundStyle(VaultStyle.amber) }
                if !facts.reviewReasons.isEmpty { Button("Mark Reviewed") { markReviewed(facts) } }
                Text("Group memberships and subjects remain editable above. No original file was moved or renamed.").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 12)
        }
    }
    private func markReviewed(_ facts: OrganizationFacts) {
        var updated = file
        let reviewIDs = Set(store.library.collections.filter { $0.organizationKey == "needs-review" }.map(\.id))
        updated.collectionIDs.subtract(reviewIDs)
        guard store.update(updated) else { return }
        workspace.change { data in
            var reviewed = facts; reviewed.reviewReasons = []; reviewed.generatedGroupIDs?.subtract(reviewIDs)
            data.organizationFacts?[file.id] = reviewed
        }
    }
    private var contentTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional extraction stores searchable plaintext in workspace.json. Do not extract sensitive content. Supports text PDFs, UTF-8 text, and image OCR up to 50 MB.").font(.caption).foregroundStyle(.secondary)
            Button("Extract Text / OCR Locally") { workspace.extract(file) }.disabled(workspace.working)
            if workspace.working { Button("Cancel Processing") { workspace.cancel() } }
            if let text = workspace.data.extractedText[file.id] {
                Text("Indexed \(text.count) characters").font(.caption)
                DisclosureGroup("Extracted text") { Text(String(text.prefix(4000))).font(.caption).textSelection(.enabled) }
                Button("Use Local Excerpt as Description") { description = String(text.prefix(400)) }
                Button("Suggest Tags Locally") {
                    let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 5 }
                    let counts = Dictionary(grouping: words, by: { $0 }).mapValues { $0.count }
                    tags = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(5).map(\.key).joined(separator: ", ")
                }
                Text("Review suggestions, then Save Metadata to apply.").font(.caption)
                Button("Remove Extracted Text") { workspace.change { $0.extractedText.removeValue(forKey: file.id) } }
            }
        }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 11)).textSelection(.enabled) }
    }
}

struct ImportReview: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var copy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Bring your files into focus", systemImage: "tray.and.arrow.down").font(.title2.bold())
            Text("Vault accesses only the files you selected. It does not scan your Mac.").foregroundStyle(.secondary)
            Picker("How should Vault add these files?", selection: $copy) {
                Text("Index in place — originals stay where they are").tag(false)
                Text("Copy into Vault — preserve originals").tag(true)
            }.pickerStyle(.radioGroup)
            Text("\(store.candidates.count) files · \(ByteCountFormatter.string(fromByteCount: store.candidates.reduce(0) { $0 + $1.size }, countStyle: .file))").font(.headline)
            List(store.candidates) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.url.lastPathComponent)
                    Text(candidate.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(height: 200)
            Text(copy ? "Copies are verified before indexing. Filename conflicts use separate unique directories. Original files remain untouched." : "Existing references to the same selected path are skipped. Verify content duplicates in Storage & Cleanup.").font(.caption)
            Text("All regular file types can be indexed. Native previews depend on macOS support; text extraction is an optional inspector action. Review sensitive files before continuing. Progress and cancellation are available during import; cancellation retains completed items. Keep Vault open until processing ends.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Import") { store.performImport(copy: copy) }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 600)
    }
}

struct PreferencesView: View {
    @AppStorage("appearance") private var appearance = "dark"
    @AppStorage("cinematicMotion") private var cinematicMotion = true
    @AppStorage("showVaultMascot") private var showMascot = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vault · Development").font(.title2.bold())
            Picker("Appearance", selection: $appearance) {
                Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system")
            }
            Toggle("Cinematic animations", isOn: $cinematicMotion)
            Toggle("Show 3D sidebar mascot", isOn: $showMascot)
            Text("Motion pauses in inactive windows and respects Reduce Motion. Glass surfaces respect Reduce Transparency.").font(.caption).foregroundStyle(.secondary)
            Text("Local library & privacy").font(.headline)
            Text("Metadata and managed copies are stored inside Vault’s sandbox Application Support directory. Back up this directory along with the originals. Bookmarks are access references, not file backups.")
            Text("No cloud services, remote AI, or telemetry are included. Approved folders can be monitored while Vault runs. Opt-in content extraction is local. Secure records use a separate encrypted store and device-bound Keychain key.")
            Text("Choose dark, light, or system appearance. Back up regular library metadata and files separately. Secure Vault has no portable key recovery; encrypted-file backups alone cannot restore records on another Mac.").foregroundStyle(.secondary)
        }.font(.callout)
    }
}
