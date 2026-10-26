import Foundation
import PDFKit
import Vision
import AppKit
import VaultCore

actor ContentService {
    /// Explicit opt-in only. Limits extraction to avoid unbounded index growth.
    func extract(_ file: FileItem, ocr: Bool) throws -> String {
        try Task.checkCancellation()
        return try FileAccessService.withAccess(file) { url in
            guard file.size <= 50 * 1024 * 1024 else { throw ContentError.tooLarge }
            if file.type.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
                var text = ""
                for i in 0..<min(pdf.pageCount, 300) {
                    try Task.checkCancellation()
                    text += (pdf.page(at: i)?.string ?? "") + "\n"
                    if text.count > 200_000 { break }
                }
                return String(text.prefix(200_000))
            }
            if ["txt", "md", "csv", "json"].contains(file.type.lowercased()) {
                return String(try String(contentsOf: url, encoding: .utf8).prefix(200_000))
            }
            if ocr, let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: cg).perform([request])
                return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(200_000))
            }
            throw ContentError.unsupported
        }
    }
    enum ContentError: LocalizedError {
        case unsupported, tooLarge
        var errorDescription: String? { self == .unsupported ? "Text extraction supports text PDFs, UTF-8 text/Markdown/CSV/JSON, and image OCR. This file is unsupported." : "Content extraction is limited to files up to 50 MB." }
    }
}
