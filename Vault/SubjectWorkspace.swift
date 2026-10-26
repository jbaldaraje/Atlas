import SwiftUI
import VaultCore

struct SubjectWorkspace: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    var initialSubjectID: UUID?
    let query: String
    let select: (UUID) -> Void
    @State private var selected: UUID?
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("New subject", text: $name)
                Button("Create") {
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    let subject = VaultCore.Subject(name: value)
                    if workspace.change({ $0.subjects.append(subject) }) { name = ""; selected = subject.id }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let selected {
                SubjectDetail(subjectID: selected, query: query, select: select, back: { self.selected = nil }).id(selected)
            } else {
                FolderBrowser(section: .subjects, query: query, listMode: true, select: select, openSubject: { selected = $0 })
            }
        }.onAppear { selected = initialSubjectID }
    }
}
private struct SubjectDetail: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let subjectID: UUID
    let query: String
    let select: (UUID) -> Void
    let back: () -> Void
    @State private var description = ""
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @State private var note = ""
    @State private var minutes = 25
    @State private var linking = false
    @State private var linkSearch = ""
    private var subject: VaultCore.Subject? { workspace.data.subjects.first { $0.id == subjectID } }
    private var location: CatalogLocation { var location = CatalogLocation(); location.subjectID = subjectID; return location }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("All Subjects", action: back)
                Text(subject?.name ?? "Unavailable subject").font(.headline)
                Spacer()
                Button("Link Files…") { linking = true }.disabled(subject == nil)
            }
            DisclosureGroup("Subject details & deadline") { metadata }
            DisclosureGroup("Record a study session") { study }
            Text("Linked files · open a parent folder to see its contents").font(.caption).foregroundStyle(.secondary)
            FolderBrowser(section: .files, query: query, listMode: true, initialLocation: location, select: select)
        }
        .task(id: subjectID) { description = subject?.description ?? ""; hasDeadline = subject?.deadline != nil; deadline = subject?.deadline ?? .now }
        .sheet(isPresented: $linking) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Link files to " + (subject?.name ?? "subject")).font(.headline); Spacer(); Button("Done") { linking = false } }
                Text("Browse parent folders and check individual files. Originals remain in place.").font(.caption).foregroundStyle(.secondary)
                TextField("Search filenames, tags, or folders…", text: $linkSearch)
                FolderBrowser(section: .files, query: linkSearch, listMode: true, linkingSubjectID: subjectID, select: select)
            }.padding(24).frame(width: 760, height: 580)
        }
    }
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Description", text: $description)
            Toggle("Exam / deadline", isOn: $hasDeadline)
            if hasDeadline { DatePicker("Date", selection: $deadline) }
            Button("Save Subject") {
                workspace.change { data in
                    guard let index = data.subjects.firstIndex(where: { $0.id == subjectID }) else { return }
                    data.subjects[index].description = description; data.subjects[index].deadline = hasDeadline ? deadline : nil
                }
            }
        }.padding(.vertical, 10)
    }
    private var study: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper("\(minutes) minutes", value: $minutes, in: 1...480)
            TextField("What did you study?", text: $note)
            Button("Record Session") {
                if workspace.change({ $0.sessions.append(StudySession(subjectID: subjectID, minutes: minutes, note: note)) }) { note = "" }
            }.disabled(subject == nil)
        }.padding(.vertical, 10)
    }
}
