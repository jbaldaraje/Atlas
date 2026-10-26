import SwiftUI
import Charts
import VaultCore

struct FeatureWorkspace: View {
    let section: String
    let select: (UUID) -> Void
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    var body: some View {
        Group {
            switch section {
                        case "Subjects": SubjectWorkspace()
            case "Timeline": timeline
            case "Storage & Cleanup": StorageWorkspace()
            case "Secure Vault": SecureWorkspace()
            case "Recently Deleted": RecoveryWorkspace()
            default: EmptyView()
            }
        }.padding(.horizontal, 24).padding(.bottom, 20)
    }
    private var timeline: some View {
        List {
            Section("Recorded by Vault") {
                ForEach(store.library.files.sorted { $0.indexedAt > $1.indexedAt }) { file in
                    Button { select(file.id) } label: {
                        VStack(alignment: .leading) { Text("Added · \(file.filename)"); Text(file.indexedAt.formatted()).font(.caption).foregroundStyle(.secondary) }
                    }.buttonStyle(.plain)
                }
            }
            Section("Study sessions · explicitly recorded") {
                ForEach(workspace.data.sessions.sorted { $0.date > $1.date }) { session in
                    VStack(alignment: .leading) {
                        Text("\(workspace.data.subjects.first { $0.id == session.subjectID }?.name ?? "Removed subject") · \(session.minutes) minutes")
                        Text(session.note); Text(session.date.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Filesystem timestamps · last indexed") {
                ForEach(store.library.files.filter { $0.modifiedAt != nil }.sorted { $0.modifiedAt! > $1.modifiedAt! }) { file in
                    VStack(alignment: .leading) { Text(file.filename); Text(file.modifiedAt!.formatted()).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct SubjectWorkspace: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var name = ""
    @State private var selected: UUID?
    @State private var note = ""
    @State private var minutes = 25
    var body: some View {
        VStack {
            HStack { TextField("New subject", text: $name); Button("Create") { let value = name.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { workspace.change { $0.subjects.append(Subject(name: value)) }; name = "" } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            Picker("Subject", selection: $selected) { Text("Select a subject").tag(nil as UUID?); ForEach(workspace.data.subjects) { Text($0.name).tag(Optional($0.id)) } }
            if let index = workspace.data.subjects.firstIndex(where: { $0.id == selected }) {
                let subject = workspace.data.subjects[index]
                Form {
                    TextField("Description", text: Binding(get: { subject.description }, set: { value in workspace.change { $0.subjects[index].description = value } }))
                    Toggle("Exam / deadline", isOn: Binding(get: { subject.deadline != nil }, set: { enabled in workspace.change { $0.subjects[index].deadline = enabled ? .now : nil } }))
                    if let deadline = subject.deadline { DatePicker("Date", selection: Binding(get: { deadline }, set: { value in workspace.change { $0.subjects[index].deadline = value } })) }
                    Section("Linked files") {
                        ForEach(store.library.files) { file in
                            Toggle(file.filename, isOn: Binding(get: { subject.fileIDs.contains(file.id) }, set: { linked in workspace.change { if linked { $0.subjects[index].fileIDs.insert(file.id) } else { $0.subjects[index].fileIDs.remove(file.id) } } }))
                        }
                    }
                    Section("Record a study session") {
                        Stepper("\(minutes) minutes", value: $minutes, in: 1...480)
                        TextField("What did you study?", text: $note)
                        Button("Record Session") { workspace.change { $0.sessions.append(StudySession(subjectID: subject.id, minutes: minutes, note: note)) }; note = "" }
                    }
                }.formStyle(.grouped)
            } else { ContentUnavailableView("Organize by subject", systemImage: "books.vertical", description: Text("Create a subject, link files, set a deadline, and explicitly record study sessions.")) }
        }
    }
}

struct StorageWorkspace: View {
    @EnvironmentObject private var trash: NativeTrashService
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var pending: FileItem?
    @State private var minimumMB = 0.0
    @State private var oldOnly = false
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Analyze & Verify Duplicates") { workspace.analyze(store.library.files) }.disabled(workspace.working)
                if workspace.working { ProgressView().controlSize(.small); Button("Cancel") { workspace.cancel() } }
            }
            Text("Only indexed regular files are analyzed. Hard links and duplicate references count once. Original Trash actions require an additional explicit grant. Results describe the last scan, not the whole Mac.").font(.caption).foregroundStyle(.secondary)
            if let report = workspace.report {
                Text("Logical: \(bytes(report.logicalBytes)) · Allocated: \(bytes(report.allocatedBytes)) · Unavailable: \(report.failedIDs.count)").font(.headline)
                let categories = Dictionary(grouping: report.files, by: { $0.file.type.uppercased() }).map { (type: $0.key, size: $0.value.reduce(Int64(0)) { $0 + $1.file.size }) }.sorted { $0.size > $1.size }
                Chart(categories, id: \.type) { item in BarMark(x: .value("Logical bytes", item.size), y: .value("Type", item.type)).foregroundStyle(Color.indigo) }.frame(height: min(220, CGFloat(categories.count * 28 + 20)))
                HStack { Slider(value: $minimumMB, in: 0...1000); Text("Minimum \(Int(minimumMB)) MB"); Toggle("Not modified in 12 months", isOn: $oldOnly) }
                List {
                    Section("Largest files · review suggestions only") {
                        ForEach(report.files.filter { $0.file.size >= Int64(minimumMB * 1_000_000) && (!oldOnly || ($0.file.modifiedAt ?? .now) < Date().addingTimeInterval(-365 * 86400)) }.sorted { $0.file.size > $1.file.size }) { entry in fileRow(entry.file) }
                    }
                    ForEach(Array(report.duplicates.enumerated()), id: \.offset) { index, group in
                        Section("SHA-256 match \(index + 1) · \(group.count) distinct files") { ForEach(group) { fileRow($0.file) } }
                    }
                }
                Text("Allocated bytes are reported filesystem values, not guaranteed recoverable space (APFS clones/compression may share blocks). Hash matches are review candidates; nothing is selected or removed automatically.").font(.caption).foregroundStyle(.secondary)
            }
        }.confirmationDialog("Review file removal", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if pending?.ownership == .managedCopy {
                Button("Move managed copy to recovery area", role: .destructive) { if let pending { workspace.retain(pending, library: store) }; pending = nil }
            } else {
                Button("Move Original to macOS Trash…", role: .destructive) { if let pending { trash.trash(pending, library: store); workspace.report = nil }; pending = nil }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text("\(pending?.filename ?? "")\n\(pending?.originalLocation ?? "")\nAll collection references use this file. Its index entry is removed after a recorded filesystem operation. Managed copies go to Vault recovery; originals go to macOS Trash after another grant. These recoverable operations do not reclaim space immediately.") }
    }
    private func bytes(_ size: Int64) -> String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    private func fileRow(_ file: FileItem) -> some View {
        HStack {
            VStack(alignment: .leading) { Text(file.filename); Text(file.originalLocation).font(.caption).foregroundStyle(.secondary); Text(file.modifiedAt?.formatted() ?? "Unknown modification date").font(.caption) }
            Spacer(); Text(bytes(file.size)); Button("Reveal") { store.reveal(file) }
            Button(file.ownership == .managedCopy ? "Remove Copy…" : "Trash Original…") { pending = file }.disabled(workspace.working)
        }
    }
}

struct RecoveryWorkspace: View {
    @EnvironmentObject private var trash: NativeTrashService
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var pending: RecoveryEntry?
    var body: some View {
        VStack(alignment: .leading) {
            Text("Recently Deleted · recovery locations").font(.headline)
            Text("These files still occupy disk space. Managed copies use Vault recovery; originals use macOS Trash. Finder can remove Trash items independently. Restoring never overwrites an existing file.").font(.caption).foregroundStyle(.secondary)
            List {
                Section("macOS Trash · restore availability checked on request") {
                    ForEach(trash.entries) { entry in
                        VStack(alignment: .leading) {
                            Text(entry.file.filename); Text(entry.file.originalLocation).font(.caption)
                            Text(entry.deletedAt.formatted()).font(.caption)
                            Button("Restore to Location…") { trash.restore(entry, library: store) }
                        }
                    }
                }
                Section("Vault-managed recovery") {
                ForEach(workspace.recoveryEntries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.file.filename).font(.headline)
                    Text(entry.file.originalLocation).font(.caption)
                    Text("Retained \(entry.date.formatted()) · \(ByteCountFormatter.string(fromByteCount: entry.file.size, countStyle: .file))").font(.caption)
                    HStack { Button("Restore") { workspace.restore(entry, library: store) }; Button("Delete Permanently…", role: .destructive) { pending = entry } }.disabled(workspace.working)
                }
            }
                }
            }
        }.task { workspace.refreshRecovery(); trash.refresh() }
            .confirmationDialog("Permanently delete retained copy?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                Button("Delete Permanently", role: .destructive) { if let pending { workspace.permanentlyDelete(pending) }; pending = nil }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { Text("\(pending?.file.filename ?? "")\nOriginal managed location: \(pending?.file.originalLocation ?? "")\nThis retained copy cannot be recovered by Vault after deletion. The source outside Vault is unaffected.") }
    }
}
