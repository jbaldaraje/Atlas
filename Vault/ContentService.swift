import Foundation
import PDFKit
import Vision
import ImageIO
import VaultCore

actor ContentService {
    /// Explicit opt-in only. Limits extraction to avoid unbounded index growth.
    func extract(_ file: FileItem, ocr: Bool) throws -> String {
        try Task.checkCancellation()
        return try FileAccessService.withAccess(file) { url in
            guard let actualSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, actualSize <= 50 * 1024 * 1024 else { throw ContentError.tooLarge }
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
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                var data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                // Trim at most one partial UTF-8 scalar at the bounded read boundary.
                for _ in 0..<4 {
                    if let text = String(data: data, encoding: .utf8) { return String(text.prefix(200_000)) }
                    if !data.isEmpty { data.removeLast() }
                }
                throw ContentError.unsupported
            }
            if ocr, let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceShouldCacheImmediately: false] as CFDictionary) {
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
