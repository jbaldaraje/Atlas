import AppKit
import Carbon
import Foundation
import VaultCore

struct NotesAccount: Identifiable { let id: String; let name: String }
struct NotesFolder: Identifiable { let id: String; let name: String }
struct NotesHeader: Identifiable { let id: String; let title: String; let locked: Bool }

/// User-initiated read-only Automation of the installed Notes app. NSAppleScript stays on the main thread.
@MainActor
final class AppleNotesBridge {
    private var script: NSAppleScript?
    func accounts() throws -> [NotesAccount] {
        try rows(call("listaccounts")).map { NotesAccount(id: try string($0, 1), name: try string($0, 2)) }
    }
    func folders(account: String) throws -> [NotesFolder] {
        try rows(call("listfolders", arguments: [account])).map { NotesFolder(id: try string($0, 1), name: try string($0, 2)) }
    }
    func headers(account: String, folder: String) throws -> [NotesHeader] {
        try rows(call("listnotes", arguments: [account, folder])).map {
            NotesHeader(id: try string($0, 1), title: try string($0, 2), locked: $0.atIndex(3)?.booleanValue ?? true)
        }
    }
    func read(account: NotesAccount, folder: NotesFolder, id: String) throws -> ImportedNoteSnapshot {
        let row = try call("readnote", arguments: [account.id, folder.id, id])
        let source = ImportedNoteSource(accountID: account.id, accountName: account.name, folderID: folder.id, folderName: folder.name,
                                       noteID: id, title: try string(row, 1), sourceCreatedAt: row.atIndex(3)?.dateValue, sourceModifiedAt: row.atIndex(4)?.dateValue)
        return ImportedNoteSnapshot(source: source, text: try string(row, 2))
    }
    private func call(_ handler: String, arguments: [String] = []) throws -> NSAppleEventDescriptor {
        if script == nil { script = NSAppleScript(source: Self.source) }
        guard let script else { throw NotesError.unavailable }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        for (index, value) in arguments.enumerated() { parameters.insert(NSAppleEventDescriptor(string: value), at: index + 1) }
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error { throw NotesError.automation((error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? 0) }
        return result
    }
    private func rows(_ result: NSAppleEventDescriptor) throws -> [NSAppleEventDescriptor] {
        guard result.numberOfItems > 0 else { return [] }
        return try (1...result.numberOfItems).map { index in
            guard let row = result.atIndex(index) else { throw NotesError.invalidReply }; return row
        }
    }
    private func string(_ row: NSAppleEventDescriptor, _ index: Int) throws -> String {
        guard let value = row.atIndex(index)?.stringValue else { throw NotesError.invalidReply }; return value
    }
    enum NotesError: LocalizedError {
        case unavailable, invalidReply, automation(Int)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Apple Notes scripting is unavailable. Import exported PDF or text notes instead."
            case .invalidReply: return "Apple Notes returned an unexpected reply. Existing local snapshots were preserved."
            case .automation(let code):
                if code == -1743 { return "Notes access was denied. In System Settings → Privacy & Security → Automation, allow Vault to control Notes, then retry. Vault uses that permission only to read your selected notes." }
                if code == -1712 { return "Apple Notes did not respond in time. Open Notes, wait for iCloud syncing to finish, and retry." }
                if code == -128 { return "The request was cancelled. No Apple Notes content was changed." }
                if code == -2700 { return "This note is locked or its protected status could not be checked. Vault does not unlock protected notes. Export a copy yourself from Notes if you wish to import it." }
                return "Could not read Apple Notes (error \(code)). Reconnect and select the current folder if the note moved, or import an exported copy."
            }
        }
    }
    // IDs are encoded as Apple-event arguments; no user/Notes data is interpolated into script source.
    private static let source = """
    on listaccounts()
        with timeout of 15 seconds
            tell application id "com.apple.Notes"
                set output to {}
                repeat with a in accounts
                    set end of output to {id of a, name of a}
                end repeat
                return output
            end tell
        end timeout
    end listaccounts
    on collectfolders(parentContainer, prefixText)
        tell application id "com.apple.Notes"
            set output to {}
            repeat with f in folders of parentContainer
                set folderName to prefixText & (name of f)
                set end of output to {id of f, folderName}
                set output to output & (my collectfolders(contents of f, folderName & " / "))
            end repeat
            return output
        end tell
    end collectfolders
    on findfolder(parentContainer, wantedID)
        tell application id "com.apple.Notes"
            repeat with f in folders of parentContainer
                if (id of f) is wantedID then return contents of f
                set nestedFolder to my findfolder(contents of f, wantedID)
                if nestedFolder is not missing value then return nestedFolder
            end repeat
        end tell
        return missing value
    end findfolder
    on listfolders(accountID)
        with timeout of 15 seconds
            tell application id "com.apple.Notes"
                set a to account id accountID
                return my collectfolders(a, "")
            end tell
        end timeout
    end listfolders
    on listnotes(accountID, folderID)
        with timeout of 15 seconds
            tell application id "com.apple.Notes"
                set f to my findfolder(account id accountID, folderID)
                if f is missing value then error number -1728
                set output to {}
                repeat with n in notes of f
                    set protectedNote to true
                    try
                        set protectedNote to password protected of n
                    end try
                    set end of output to {id of n, name of n, protectedNote}
                end repeat
                return output
            end tell
        end timeout
    end listnotes
    on readnote(accountID, folderID, noteID)
        with timeout of 15 seconds
            tell application id "com.apple.Notes"
                set f to my findfolder(account id accountID, folderID)
                if f is missing value then error number -1728
                set n to note id noteID of f
                set protectedNote to true
                try
                    set protectedNote to password protected of n
                end try
                if protectedNote then error number -2700
                return {name of n, plaintext of n, creation date of n, modification date of n}
            end tell
        end timeout
    end readnote
    """
}
