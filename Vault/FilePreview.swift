import SwiftUI
import Quartz
import VaultCore

struct FilePreview: View {
    let file: FileItem
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var scoped = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(file.filename).font(.headline).lineLimit(1); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
            Divider()
            if let url { NativePreview(url: url) }
            else if let error { ContentUnavailableView("Preview unavailable", systemImage: "doc.questionmark", description: Text(error)) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(minWidth: 600, idealWidth: 800, minHeight: 440, idealHeight: 650)
        .onAppear {
            do {
                var stale = false
                let resolved = try URL(resolvingBookmarkData: file.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { throw FileAccessService.AccessError.staleBookmark }
                scoped = resolved.startAccessingSecurityScopedResource()
                url = resolved
                guard FileManager.default.fileExists(atPath: resolved.path) else { throw FileAccessService.AccessError.missingFile }
            } catch { self.error = error.localizedDescription; if scoped { url?.stopAccessingSecurityScopedResource() }; scoped = false; url = nil }
        }
        .onDisappear { if scoped { url?.stopAccessingSecurityScopedResource() }; scoped = false; url = nil }
    }
}

private struct NativePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView {
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
            return NSTextField(labelWithString: "Native preview is unavailable. Open the file in its default app.")
        }
        preview.previewItem = url as NSURL
        return preview
    }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? QLPreviewView)?.previewItem = url as NSURL }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) { (nsView as? QLPreviewView)?.previewItem = nil }
}
