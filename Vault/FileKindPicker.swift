import SwiftUI
import VaultCore

/// One persistent choice shared by file workspaces and their navigation sheets.
struct FileKindPicker: View {
    @AppStorage("fileKindFilter") private var selection = FileKindFilter.all
    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker.pickerStyle(.segmented).frame(width: 365)
            picker.pickerStyle(.menu).frame(maxWidth: 200)
        }
        .help(selection.detail + " Applies to file results on every workspace; scan settings stay separate.")
        .accessibilityIdentifier("fileKindFilter")
    }
    private var picker: some View {
        Picker("File types", selection: $selection) {
            ForEach(FileKindFilter.allCases) { kind in Text(kind.title).tag(kind) }
        }.accessibilityLabel("Filter file types")
    }
}
