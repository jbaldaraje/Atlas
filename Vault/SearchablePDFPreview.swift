import SwiftUI
import PDFKit

// One-way ownership handoff: created on a worker, then accessed only by PDFView on the main actor.
private struct LoadedPDF: @unchecked Sendable { let document: PDFDocument? }

/// PDF search uses PDFKit's asynchronous find API and scrolls to the first actual match.
@MainActor
struct SearchablePDFPreview: NSViewRepresentable {
    let url: URL
    let term: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        context.coordinator.view = view
        let label = NSTextField(labelWithString: "Loading PDF…"); label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label); NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        context.coordinator.placeholder = label; context.coordinator.load(url, term: term)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.url != url { context.coordinator.load(url, term: term) }
        else { context.coordinator.search(term) }
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) { coordinator.stop(); view.document = nil }
    @MainActor final class Coordinator: NSObject, PDFDocumentDelegate {
        weak var view: PDFView?
        weak var placeholder: NSTextField?
        var url: URL?
        private var task: Task<Void, Never>?
        private var term = ""
        private var requested = ""
        private var matched = false
        func load(_ url: URL, term: String) {
            stop(); self.url = url; requested = term; placeholder?.stringValue = "Loading PDF…"; placeholder?.isHidden = false
            task = Task {
                let worker = Task.detached(priority: .userInitiated) { () -> LoadedPDF in
                    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 50 * 1024 * 1024 else { return LoadedPDF(document: nil) }
                    return LoadedPDF(document: PDFDocument(url: url))
                }
                let loaded = await worker.value
                let document = loaded.document
                guard !Task.isCancelled, self.url == url else { return }
                document?.delegate = self; view?.document = document
                placeholder?.isHidden = document != nil && document?.isLocked == false
                placeholder?.stringValue = document?.isLocked == true ? "PDF is locked. Open it in the default app." : "PDF preview unavailable. Open it in the default app."
                self.term = ""; search(requested)
            }
        }
        func search(_ value: String) {
            requested = value
            guard view?.document != nil, term != value else { return }
            view?.document?.cancelFindString(); term = value; matched = false; view?.setCurrentSelection(nil, animate: false)
            if !value.isEmpty { view?.document?.beginFindString(value, withOptions: .caseInsensitive) }
        }
        nonisolated func didMatchString(_ instance: PDFSelection) {
            Task { @MainActor [weak self] in
                guard let self, !self.matched, !self.term.isEmpty, instance.pages.first?.document === self.view?.document,
                      instance.string?.range(of: self.term, options: .caseInsensitive) != nil else { return }
                self.matched = true; self.view?.document?.cancelFindString()
                self.view?.setCurrentSelection(instance, animate: false); self.view?.go(to: instance)
            }
        }
        func stop() { task?.cancel(); task = nil; view?.document?.cancelFindString(); view?.document?.delegate = nil; view?.document = nil }
    }
}
