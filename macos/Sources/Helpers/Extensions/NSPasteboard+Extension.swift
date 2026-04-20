import AppKit
import GhosttyKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Initialize a pasteboard type from a MIME type string
    init?(mimeType: String) {
        // Explicit mappings for common MIME types
        switch mimeType {
        case "text/plain":
            self = .string
            return
        default:
            break
        }

        // Try to get UTType from MIME type
        guard let utType = UTType(mimeType: mimeType) else {
            // Fallback: use the MIME type directly as identifier
            self.init(mimeType)
            return
        }

        // Use the UTType's identifier
        self.init(utType.identifier)
    }
}

extension NSPasteboard {
    /// The pasteboard to used for Ghostty selection.
    static var ghosttySelection: NSPasteboard = {
        NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
    }()

    /// Gets the contents of the pasteboard as a string following a specific set of semantics.
    /// Does these things in order:
    /// - Tries to get the absolute filesystem path of the file in the pasteboard if there is one and ensures the file path is properly escaped.
    /// - Tries to get any string from the pasteboard.
    /// - If the plain-text variant looks encoding-lossy, falls back to
    ///   extracting plain text from the RTF or HTML variant.
    /// If all of the above fail, returns None.
    func getOpinionatedStringContents() -> String? {
        if let urls = readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.count > 0 {
            return urls
                .map { $0.isFileURL ? Ghostty.Shell.escape($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }

        let plainText = self.string(forType: .string)

        // Some apps (certain IMs, Electron ports, legacy native apps) write a
        // mangled plain-text variant alongside a correctly-encoded rich-text
        // variant — e.g. non-ASCII chars arrive as U+FFFD or literal '?' runs
        // because the app's plain-text writer fell back to an ASCII encoding.
        // Prefer the rich-text variant only when it demonstrably carries more
        // non-ASCII content than the plain variant, so that legitimate user
        // text containing '?' runs is not replaced by a stripped RTF/HTML
        // rendering.
        if let s = plainText, Self.looksEncodingLossy(s),
           let recovered = self.richTextFallback(),
           Self.nonASCIIScalarCount(recovered) > Self.nonASCIIScalarCount(s) {
            return recovered
        }

        if let s = plainText { return s }
        return self.richTextFallback()
    }

    private static func looksEncodingLossy(_ s: String) -> Bool {
        if s.contains("\u{FFFD}") { return true }
        var run = 0
        for scalar in s.unicodeScalars {
            if scalar == "?" {
                run += 1
                if run >= 3 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    private static func nonASCIIScalarCount(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $1.value > 127 ? $0 + 1 : $0 }
    }

    private func richTextFallback() -> String? {
        // Try RTF first: Apple's RTF parser is local and never fetches
        // external resources. Fall back to HTML only when RTF is absent,
        // since HTML parsing via NSAttributedString goes through WebKit
        // and is heavier even when the attributed string is only used to
        // extract `.string`.
        if let data = self.data(forType: .rtf),
           let attr = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ),
           !attr.string.isEmpty {
            return attr.string
        }

        if let data = self.data(forType: .html),
           let attr = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue,
               ],
               documentAttributes: nil
           ),
           !attr.string.isEmpty {
            return attr.string
        }

        return nil
    }

    /// The pasteboard for the Ghostty enum type.
    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return Self.general

        case GHOSTTY_CLIPBOARD_SELECTION:
            return Self.ghosttySelection

        default:
            return nil
        }
    }
}
