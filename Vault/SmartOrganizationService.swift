import Foundation
import ImageIO
import VaultCore

actor SmartOrganizationService {
    private let content = ContentService()
    func facts(for file: FileItem, source: ScanLocation, existingSubjects: [String]) async throws -> (OrganizationFacts, String?) {
        try Task.checkCancellation()
        var facts = OrganizationFacts(file: file, folderContext: URL(fileURLWithPath: file.originalLocation).deletingLastPathComponent().path)
        facts.inputTags = file.tags
        facts.textRequested = source.extractContent; facts.locationsRequested = source.includePhotoLocations == true
        var text: String?
        if facts.category == .images {
            do {
                let metadata = try FileAccessService.withAccess(file) { url -> (String?, String?, String?) in
                    guard let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] else { return (nil, nil, nil) }
                    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
                    let date = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String
                    let month = Self.captureMonth(date)
                    var area: String?
                    if source.includePhotoLocations == true,
                       let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
                       let latitude = gps[kCGImagePropertyGPSLatitude as String] as? NSNumber,
                       let longitude = gps[kCGImagePropertyGPSLongitude as String] as? NSNumber,
                       let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
                       let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String {
                        area = OrganizationRules.gpsArea(latitude: latitude.doubleValue, longitude: longitude.doubleValue, latitudeRef: latitudeRef, longitudeRef: longitudeRef)
                    }
                    return (month, area, month == nil ? nil : date)
                }
                facts.captureMonth = metadata.0; facts.gpsArea = metadata.1; facts.captureDate = metadata.2
                if metadata.0 == nil { facts.reviewReasons.append("No valid EXIF capture date; filesystem dates were not substituted.") }
            } catch { facts.reviewReasons.append("Image metadata was unavailable.") }
        } else if source.extractContent {
            do {
                text = try await content.extract(file, ocr: false)
                facts.textStatus = text?.isEmpty == false ? "Supported text extracted locally" : "No text found; OCR was not performed"
            } catch is CancellationError { throw CancellationError() }
            catch { facts.textStatus = "Unsupported or unavailable text; filename, folder, and tags only" }
        }
        facts.topics = OrganizationRules.topics(filename: file.filename, context: facts.folderContext, tags: file.tags, text: text, existing: existingSubjects)
        if [.documents, .pdf, .presentations, .data].contains(facts.category), facts.topics.isEmpty {
            facts.reviewReasons.append("No reliable topic evidence. Organized by type and folder for review.")
        }
        try Task.checkCancellation()
        return (facts, text)
    }
    private static func captureMonth(_ value: String?) -> String? {
        guard let value, value.count >= 19 else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"; formatter.isLenient = false
        guard formatter.date(from: String(value.prefix(19))) != nil else { return nil }
        return String(value.prefix(7)).replacingOccurrences(of: ":", with: "-")
    }
}
