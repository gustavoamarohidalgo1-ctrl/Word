import Cocoa

enum FormatError: Error, LocalizedError {
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .conversionFailed(let msg): return msg
        }
    }
}

struct FormatConverters {
    static func convertLegacyToDocxData(url: URL) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("officeword-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        proc.arguments = ["-convert", "docx", "-output", tempURL.path, url.path]
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0, let data = try? Data(contentsOf: tempURL) else {
            throw FormatError.conversionFailed("No se pudo convertir el archivo .\(url.pathExtension) usando textutil.")
        }
        return data
    }

    static func readPlainText(_ text: String) -> NSAttributedString {
        let def = DocxEngine.blockAttributes(for: "normal")
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacing = 6
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n")
        let str = clean.hasSuffix("\n") ? clean : clean + "\n"
        return NSAttributedString(string: str, attributes: [
            .font: def.font,
            .foregroundColor: def.color,
            .paragraphStyle: ps,
        ])
    }

    static func writePlainText(_ attr: NSAttributedString) -> Data {
        let raw = attr.string
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{000C}", with: "\n")
        return Data(raw.utf8)
    }

    static func readMarkdown(_ markdown: String) -> NSAttributedString {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let out = NSMutableAttributedString()
        var orderedCounter = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                orderedCounter = 0
                let def = DocxEngine.blockAttributes(for: "normal")
                let ps = NSMutableParagraphStyle()
                ps.paragraphSpacing = 6
                out.append(NSAttributedString(string: "\n", attributes: [
                    .font: def.font, .foregroundColor: def.color, .paragraphStyle: ps
                ]))
                continue
            }

            if trimmed == "---" || trimmed == "***" {
                orderedCounter = 0
                let ps = NSMutableParagraphStyle()
                ps.alignment = .center
                ps.paragraphSpacingBefore = 6
                ps.paragraphSpacing = 6
                out.append(NSAttributedString(string: "────────────────────────────────────────\n", attributes: [
                    .font: DocxEngine.resolveFont(family: "Calibri", sizePt: 10, bold: false, italic: false),
                    .foregroundColor: NSColor(srgbRed: 0.78, green: 0.82, blue: 0.88, alpha: 1),
                    .paragraphStyle: ps,
                    .owBlockKind: "hr",
                ]))
                continue
            }

            if trimmed.hasPrefix("### ") {
                orderedCounter = 0
                appendStyledParagraph(String(trimmed.dropFirst(4)), kind: "h3", into: out)
            } else if trimmed.hasPrefix("## ") {
                orderedCounter = 0
                appendStyledParagraph(String(trimmed.dropFirst(3)), kind: "h2", into: out)
            } else if trimmed.hasPrefix("# ") {
                orderedCounter = 0
                appendStyledParagraph(String(trimmed.dropFirst(2)), kind: "h1", into: out)
            } else if trimmed.hasPrefix("> ") {
                orderedCounter = 0
                appendStyledParagraph(String(trimmed.dropFirst(2)), kind: "quote", into: out)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                orderedCounter = 0
                appendListParagraph(String(trimmed.dropFirst(2)), ordered: false, index: 1, into: out)
            } else if let range = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                orderedCounter += 1
                let body = String(trimmed[range.upperBound...])
                appendListParagraph(body, ordered: true, index: orderedCounter, into: out)
            } else {
                orderedCounter = 0
                appendStyledParagraph(line, kind: "normal", into: out)
            }
        }
        return out
    }

    static func writeMarkdown(_ attr: NSAttributedString) -> Data {
        let nsStr = attr.string as NSString
        var lines: [String] = []
        var pos = 0

        while pos < nsStr.length {
            let lineRange = nsStr.lineRange(for: NSRange(location: pos, length: 0))
            pos = NSMaxRange(lineRange)
            var contentRange = lineRange
            if contentRange.length > 0 && nsStr.substring(with: NSRange(location: NSMaxRange(contentRange) - 1, length: 1)) == "\n" {
                contentRange.length -= 1
            }

            if contentRange.length == 0 {
                lines.append("")
                continue
            }

            let attrs = attr.attributes(at: contentRange.location, effectiveRange: nil)
            let kind = attrs[.owBlockKind] as? String
            if kind == "hr" {
                lines.append("---")
                continue
            }
            if kind == "pageBreak" {
                lines.append("")
                continue
            }

            var prefix = ""
            switch kind {
            case "title", "h1": prefix = "# "
            case "h2": prefix = "## "
            case "h3": prefix = "### "
            case "quote": prefix = "> "
            default: break
            }

            var workRange = contentRange
            if let ps = attrs[.paragraphStyle] as? NSParagraphStyle, let list = ps.textLists.first {
                let isOrdered = list.markerFormat != .disc && list.markerFormat != .circle && list.markerFormat != .square
                let slice = nsStr.substring(with: workRange)
                if let regex = try? NSRegularExpression(pattern: "^\\t([^\\t\\n]{1,14})\\t"),
                   let match = regex.firstMatch(in: slice, range: NSRange(location: 0, length: (slice as NSString).length)) {
                    let marker = (slice as NSString).substring(with: match.range(at: 1))
                    prefix = isOrdered ? "\(marker) " : "- "
                    workRange = NSRange(location: workRange.location + match.range.length, length: workRange.length - match.range.length)
                } else {
                    prefix = isOrdered ? "1. " : "- "
                }
            }

            var lineBody = ""
            attr.enumerateAttributes(in: workRange, options: []) { subAttrs, subRange, _ in
                if subAttrs[.attachment] != nil { return }
                var chunk = nsStr.substring(with: subRange)
                if chunk.isEmpty { return }
                if let font = subAttrs[.font] as? NSFont {
                    let traits = NSFontManager.shared.traits(of: font)
                    if traits.contains(.boldFontMask) && prefix.isEmpty { chunk = "**\(chunk)**" }
                    if traits.contains(.italicFontMask) && kind != "quote" { chunk = "*\(chunk)*" }
                }
                if let strike = subAttrs[.strikethroughStyle] as? Int, strike != 0 {
                    chunk = "~~\(chunk)~~"
                }
                if let url = subAttrs[.link] as? URL {
                    chunk = "[\(chunk)](\(url.absoluteString))"
                }
                lineBody += chunk
            }
            lines.append(prefix + lineBody)
        }

        let md = lines.joined(separator: "\n")
        return Data(md.utf8)
    }

    static func writeRtf(_ attr: NSAttributedString) throws -> Data {
        try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func writeHtml(_ attr: NSAttributedString) throws -> Data {
        try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ])
    }

    static func readHtml(data: Data) throws -> NSAttributedString {
        try NSAttributedString(data: data, options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ], documentAttributes: nil)
    }

    private static func appendStyledParagraph(_ raw: String, kind: String, into out: NSMutableAttributedString) {
        let cfg = DocxEngine.blockAttributes(for: kind)
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacingBefore = cfg.spaceBefore
        ps.paragraphSpacing = cfg.spaceAfter
        ps.headIndent = cfg.leftIndent
        ps.firstLineHeadIndent = cfg.leftIndent

        let inline = parseInlineMarkdown(raw, baseFont: cfg.font, baseColor: cfg.color)
        inline.append(NSAttributedString(string: "\n", attributes: [.font: cfg.font, .foregroundColor: cfg.color]))
        let range = NSRange(location: 0, length: inline.length)
        inline.addAttribute(.paragraphStyle, value: ps, range: range)
        if kind != "normal" {
            inline.addAttribute(.owBlockKind, value: kind, range: range)
        }
        out.append(inline)
    }

    private static func appendListParagraph(_ raw: String, ordered: Bool, index: Int, into out: NSMutableAttributedString) {
        let cfg = DocxEngine.blockAttributes(for: "normal")
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacing = 4
        ps.textLists = [NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)]
        ps.headIndent = 28
        ps.firstLineHeadIndent = 0
        ps.tabStops = [
            NSTextTab(textAlignment: .right, location: 22),
            NSTextTab(textAlignment: .left, location: 28),
        ]
        let marker = ordered ? "\(index)." : "•"
        let inline = parseInlineMarkdown(raw, baseFont: cfg.font, baseColor: cfg.color)
        inline.insert(NSAttributedString(string: "\t\(marker)\t", attributes: [.font: cfg.font, .foregroundColor: cfg.color]), at: 0)
        inline.append(NSAttributedString(string: "\n", attributes: [.font: cfg.font, .foregroundColor: cfg.color]))
        inline.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: inline.length))
        out.append(inline)
    }

    private static func parseInlineMarkdown(_ text: String, baseFont: NSFont, baseColor: NSColor) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.font: baseFont, .foregroundColor: baseColor])
        let fm = NSFontManager.shared
        // Bold **...**
        if let boldRe = try? NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#) {
            let matches = boldRe.matches(in: out.string, range: NSRange(location: 0, length: out.length)).reversed()
            for m in matches {
                let inner = (out.string as NSString).substring(with: m.range(at: 1))
                let boldFont = fm.convert(baseFont, toHaveTrait: .boldFontMask)
                out.replaceCharacters(in: m.range, with: NSAttributedString(string: inner, attributes: [.font: boldFont, .foregroundColor: baseColor]))
            }
        }
        // Italic *...*
        if let italicRe = try? NSRegularExpression(pattern: #"\*([^*]+)\*"#) {
            let matches = italicRe.matches(in: out.string, range: NSRange(location: 0, length: out.length)).reversed()
            for m in matches {
                let inner = (out.string as NSString).substring(with: m.range(at: 1))
                let italicFont = fm.convert(baseFont, toHaveTrait: .italicFontMask)
                out.replaceCharacters(in: m.range, with: NSAttributedString(string: inner, attributes: [.font: italicFont, .foregroundColor: baseColor]))
            }
        }
        return out
    }
}
