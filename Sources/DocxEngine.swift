import Cocoa
import CoreText

extension NSAttributedString.Key {
    static let owBlockKind = NSAttributedString.Key("OWBlockKind")
    static let owFontName = NSAttributedString.Key("OWFontName")
    static let owBookmarks = NSAttributedString.Key("OWBookmarks")
}

enum PaperSize: String, CaseIterable {
    case a4 = "A4"
    case letter = "Letter"
    case legal = "Legal"

    var sizePoints: NSSize {
        switch self {
        case .a4: return NSSize(width: 595.28, height: 841.89)
        case .letter: return NSSize(width: 612.0, height: 792.0)
        case .legal: return NSSize(width: 612.0, height: 1008.0)
        }
    }

    var sizeTwips: (w: Int, h: Int) {
        switch self {
        case .a4: return (11906, 16838)
        case .letter: return (12240, 15840)
        case .legal: return (12240, 20160)
        }
    }
}

enum PageOrientation: String {
    case portrait
    case landscape
}

struct DocPageSetup: Equatable {
    var size: PaperSize = .a4
    var orientation: PageOrientation = .portrait
    var marginTopMm: Double = 25.0
    var marginRightMm: Double = 25.0
    var marginBottomMm: Double = 25.0
    var marginLeftMm: Double = 25.0
    var customSizePt: NSSize? = nil

    var effectivePageSizePt: NSSize {
        let base = customSizePt ?? size.sizePoints
        return orientation == .landscape
            ? NSSize(width: base.height, height: base.width)
            : base
    }

    var marginsPt: NSEdgeInsets {
        let k = 72.0 / 25.4
        return NSEdgeInsets(
            top: CGFloat(marginTopMm * k),
            left: CGFloat(marginLeftMm * k),
            bottom: CGFloat(marginBottomMm * k),
            right: CGFloat(marginRightMm * k)
        )
    }

    var printableWidthPt: CGFloat {
        let m = marginsPt
        return Swift.max(180, effectivePageSizePt.width - m.left - m.right)
    }
}

struct ParsedDocxDocument {
    let attributedString: NSAttributedString
    let pageSetup: DocPageSetup
    let headerText: String
    let footerText: String
    let title: String
}

enum DocxError: Error, LocalizedError {
    case missingDocumentXml
    case invalidXml(String)

    var errorDescription: String? {
        switch self {
        case .missingDocumentXml: return "El archivo .docx no contiene word/document.xml."
        case .invalidXml(let msg): return "XML inválido en .docx: \(msg)"
        }
    }
}

// MARK: - XMLElement Helpers
private extension XMLElement {
    var elementChildren: [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }
    }

    func child(localName: String) -> XMLElement? {
        elementChildren.first { $0.localName == localName || $0.name == localName }
    }

    func children(localName: String) -> [XMLElement] {
        elementChildren.filter { $0.localName == localName || $0.name == localName }
    }

    func descendants(localName: String) -> [XMLElement] {
        var result: [XMLElement] = []
        for c in elementChildren {
            if c.localName == localName || c.name == localName {
                result.append(c)
            }
            result.append(contentsOf: c.descendants(localName: localName))
        }
        return result
    }

    func attr(_ localName: String) -> String? {
        if let exact = attribute(forName: localName)?.stringValue {
            return exact
        }
        for attr in attributes ?? [] {
            if attr.localName == localName || attr.name == localName || (attr.name?.hasSuffix(":\(localName)") == true) {
                return attr.stringValue
            }
        }
        return nil
    }
}

// MARK: - Color & Font Helpers
private extension NSColor {
    var hexRRGGBB: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        if rgb.alphaComponent < 0.05 { return nil }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }

    static func fromHex(_ hex: String?) -> NSColor? {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.lowercased() == "auto" || s.lowercased() == "none" { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let val = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

private let wordHighlightHex: [String: String] = [
    "yellow": "FEF08A",
    "green": "BBF7D0",
    "cyan": "A5F3FC",
    "magenta": "F5D0FE",
    "blue": "BFDBFE",
    "red": "FECACA",
    "darkBlue": "1E3A8A",
    "darkCyan": "164E63",
    "darkGreen": "14532D",
    "darkMagenta": "701A75",
    "darkRed": "7F1D1D",
    "darkYellow": "FEF08A",
    "darkGray": "D1D5DB",
    "lightGray": "E5E7EB",
    "black": "111827",
    "white": "FFFFFF",
]

private func nearestWordHighlightName(forHex hex: String) -> String? {
    switch hex.uppercased() {
    case "FFFF00", "FEF08A", "FEF9C3", "FFF59D": return "yellow"
    case "00FF00", "BBF7D0", "ECFDF5", "A7F3D0": return "green"
    case "00FFFF", "A5F3FC", "BAE6FD": return "cyan"
    case "FF00FF", "F5D0FE", "FBCFE8": return "magenta"
    case "0000FF", "BFDBFE", "EFF6FF": return "blue"
    case "FF0000", "FECACA", "FEE2E2": return "red"
    case "D1D5DB", "E5E7EB", "F1F5F9", "C0C0C0": return "lightGray"
    default: return nil
    }
}

private func xmlEscape(_ str: String) -> String {
    var out = ""
    out.reserveCapacity(str.count + 8)
    for scalar in str.unicodeScalars {
        let v = scalar.value
        // Strip XML 1.0 illegal control characters (preserve \t, \n, \r)
        if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D { continue }
        switch scalar {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out
}

// MARK: - OpenXML Properties
private struct RunProps {
    var fontFamily: String?
    var fontSizePt: CGFloat?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var superscriptVal: Int? // +1 super, -1 sub
    var color: NSColor?
    var highlight: NSColor?
    var rStyle: String?

    func merged(with override: RunProps) -> RunProps {
        RunProps(
            fontFamily: override.fontFamily ?? fontFamily,
            fontSizePt: override.fontSizePt ?? fontSizePt,
            bold: override.bold ?? bold,
            italic: override.italic ?? italic,
            underline: override.underline ?? underline,
            strike: override.strike ?? strike,
            superscriptVal: override.superscriptVal ?? superscriptVal,
            color: override.color ?? color,
            highlight: override.highlight ?? highlight,
            rStyle: override.rStyle ?? rStyle
        )
    }
}

private struct CellMarginsPt {
    var top: CGFloat?
    var right: CGFloat?
    var bottom: CGFloat?
    var left: CGFloat?

    func merged(with override: CellMarginsPt) -> CellMarginsPt {
        CellMarginsPt(
            top: override.top ?? top,
            right: override.right ?? right,
            bottom: override.bottom ?? bottom,
            left: override.left ?? left
        )
    }
}

private struct ParaProps {
    var pStyle: String?
    var align: NSTextAlignment?
    var lineHeightMultiple: CGFloat?
    var minLineHeightPt: CGFloat?
    var maxLineHeightPt: CGFloat?
    var spaceBeforePt: CGFloat?
    var spaceAfterPt: CGFloat?
    var leftIndentPt: CGFloat?
    var firstLineIndentPt: CGFloat?
    var numId: String?
    var ilvl: Int?
    var outlineLvl: Int?
    var hasBottomBorder: Bool = false
    var hasLeftBorder: Bool = false
    var pageBreakBefore: Bool?
    var rPr: RunProps?

    func merged(with override: ParaProps) -> ParaProps {
        let hasOverrideLineMult = override.lineHeightMultiple != nil
        let hasOverrideFixedLH = override.minLineHeightPt != nil || override.maxLineHeightPt != nil
        return ParaProps(
            pStyle: override.pStyle ?? pStyle,
            align: override.align ?? align,
            lineHeightMultiple: hasOverrideLineMult ? override.lineHeightMultiple : (hasOverrideFixedLH ? nil : lineHeightMultiple),
            minLineHeightPt: hasOverrideFixedLH ? override.minLineHeightPt : (hasOverrideLineMult ? nil : minLineHeightPt),
            maxLineHeightPt: hasOverrideFixedLH ? override.maxLineHeightPt : (hasOverrideLineMult ? nil : maxLineHeightPt),
            spaceBeforePt: override.spaceBeforePt ?? spaceBeforePt,
            spaceAfterPt: override.spaceAfterPt ?? spaceAfterPt,
            leftIndentPt: override.leftIndentPt ?? leftIndentPt,
            firstLineIndentPt: override.firstLineIndentPt ?? firstLineIndentPt,
            numId: override.numId ?? numId,
            ilvl: override.ilvl ?? ilvl,
            outlineLvl: override.outlineLvl ?? outlineLvl,
            hasBottomBorder: override.hasBottomBorder || hasBottomBorder,
            hasLeftBorder: override.hasLeftBorder || hasLeftBorder,
            pageBreakBefore: override.pageBreakBefore ?? pageBreakBefore,
            rPr: (rPr ?? RunProps()).merged(with: override.rPr ?? RunProps())
        )
    }
}

// MARK: - DocxEngine
struct DocxEngine {
    private static var didRegisterBundledFonts = false

    static let wordFontNames: [String] = [
        "Aptos", "Aptos Display", "Arial", "Arial Black", "Arial Narrow",
        "Book Antiqua", "Bookman Old Style", "Calibri", "Calibri Light", "Cambria",
        "Candara", "Century Gothic", "Comic Sans MS", "Consolas", "Constantia",
        "Corbel", "Courier New", "Franklin Gothic", "Garamond", "Georgia",
        "Impact", "Lucida Sans Unicode", "Palatino", "Rockwell", "Segoe UI",
        "Tahoma", "Times New Roman", "Trebuchet MS", "Verdana",
    ]

    private static let wordFontSubstitutes: [String: [String]] = [
        "calibri": ["Carlito", "Inter", "Helvetica Neue"],
        "calibri light": ["Carlito", "Inter", "Helvetica Neue"],
        "cambria": ["Caladea", "STIX Two Text", "Georgia"],
        "cambria math": ["STIX Two Math", "Caladea", "Georgia"],
        "aptos": ["Inter", "Carlito", "Helvetica Neue"],
        "aptos display": ["Inter", "Montserrat", "Helvetica Neue"],
        "aptos narrow": ["Libre Franklin", "Arial Narrow", "Helvetica Neue"],
        "aptos mono": ["Source Code Pro", "Menlo", "Courier New"],
        "aptos serif": ["Caladea", "Georgia"],
        "bierstadt": ["Inter", "Carlito", "Helvetica Neue"],
        "segoe ui": ["Open Sans", "Carlito", "Helvetica Neue"],
        "segoe ui light": ["Open Sans", "Lato", "Helvetica Neue"],
        "segoe ui semibold": ["Open Sans", "Carlito", "Helvetica Neue"],
        "segoe ui symbol": ["Apple Symbols", "Open Sans"],
        "microsoft sans serif": ["Microsoft Sans Serif", "Open Sans", "Helvetica Neue"],
        "consolas": ["Source Code Pro", "Cousine", "Menlo", "Courier New"],
        "lucida console": ["Source Code Pro", "Menlo", "Courier New"],
        "dejavu sans mono": ["Cousine", "Source Code Pro", "Menlo"],
        "garamond": ["EB Garamond", "Hoefler Text", "Georgia"],
        "adobe garamond": ["EB Garamond", "Hoefler Text"],
        "adobe garamond pro": ["EB Garamond", "Hoefler Text"],
        "palatino linotype": ["Palatino", "Caladea", "Georgia"],
        "book antiqua": ["Palatino", "Caladea", "Georgia"],
        "bookman old style": ["Charter", "PT Serif", "Georgia"],
        "century": ["Charter", "Caladea", "Georgia"],
        "century schoolbook": ["Libre Baskerville", "Charter", "Georgia"],
        "century gothic": ["Poppins", "Futura", "Avenir Next"],
        "franklin gothic": ["Libre Franklin", "DIN Alternate", "Helvetica Neue"],
        "franklin gothic medium": ["Libre Franklin", "DIN Alternate", "Helvetica Neue"],
        "franklin gothic book": ["Libre Franklin", "Helvetica Neue"],
        "franklin gothic demi": ["Libre Franklin", "DIN Alternate"],
        "candara": ["Fira Sans", "Optima", "Gill Sans"],
        "candara light": ["Fira Sans", "Optima"],
        "corbel": ["Lato", "Open Sans", "Helvetica Neue"],
        "corbel light": ["Lato", "Open Sans"],
        "constantia": ["Merriweather", "Caladea", "Georgia"],
        "times new roman": ["Times New Roman", "Tinos", "Georgia"],
        "times": ["Times New Roman", "Tinos", "Times"],
        "nimbus roman": ["Tinos", "Times New Roman"],
        "arial": ["Arial", "Arimo", "Helvetica Neue"],
        "arial mt": ["Arial", "Arimo"],
        "helvetica": ["Helvetica", "Helvetica Neue", "Arial"],
        "liberation sans": ["Arimo", "Arial"],
        "liberation serif": ["Tinos", "Times New Roman"],
        "liberation mono": ["Cousine", "Courier New"],
        "courier": ["Courier New", "Cousine", "Courier"],
        "courier new": ["Courier New", "Cousine", "Menlo"],
        "georgia": ["Georgia", "Gelasio"],
        "tahoma": ["Tahoma", "Geneva", "Verdana"],
        "verdana": ["Verdana", "Open Sans"],
        "trebuchet ms": ["Trebuchet MS", "Fira Sans"],
        "comic sans ms": ["Comic Sans MS", "Chalkboard SE"],
        "comic sans": ["Comic Sans MS", "Chalkboard SE"],
        "impact": ["Impact", "DIN Condensed", "Oswald"],
        "lucida sans unicode": ["Lucida Grande", "Open Sans"],
        "lucida sans": ["Lucida Grande", "Open Sans"],
        "rockwell": ["Rockwell", "Merriweather"],
        "rockwell extra bold": ["Rockwell", "Merriweather"],
        "baskerville old face": ["Baskerville", "Libre Baskerville"],
        "bodoni mt": ["Bodoni 72", "Playfair Display"],
        "didot": ["Didot", "Playfair Display"],
        "gill sans mt": ["Gill Sans", "Lato"],
        "brush script mt": ["Brush Script MT", "Snell Roundhand"],
        "monotype corsiva": ["Apple Chancery", "Zapfino"],
        "copperplate gothic bold": ["Copperplate"],
        "copperplate gothic light": ["Copperplate"],
        "agency fb": ["Oswald", "DIN Condensed"],
        "bahnschrift": ["Oswald", "DIN Alternate", "Inter"],
        "tw cen mt": ["Futura", "Poppins"],
        "calisto mt": ["Baskerville", "Palatino"],
        "perpetua": ["Hoefler Text", "Palatino"],
        "footlight mt light": ["Hoefler Text", "Georgia"],
        "ms gothic": ["Hiragino Sans", "Hiragino Kaku Gothic ProN"],
        "ms mincho": ["Hiragino Mincho ProN"],
        "meiryo": ["Hiragino Sans"],
        "yu gothic": ["Hiragino Sans"],
        "simsun": ["Songti SC", "PingFang SC"],
        "simhei": ["Heiti SC", "PingFang SC"],
        "microsoft yahei": ["PingFang SC", "Hiragino Sans GB"],
        "malgun gothic": ["Apple SD Gothic Neo"],
        "gulim": ["Apple SD Gothic Neo"],
    ]

    static func registerBundledFonts() {
        guard !didRegisterBundledFonts else { return }
        didRegisterBundledFonts = true

        var candidateDirs: [URL] = []
        if let resFonts = Bundle.main.resourceURL?.appendingPathComponent("Fonts") {
            candidateDirs.append(resFonts)
        }
        let cwdFonts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Fonts")
        candidateDirs.append(cwdFonts)

        for dir in candidateDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            let fontURLs = files.filter {
                let ext = $0.pathExtension.lowercased()
                return ext == "ttf" || ext == "otf" || ext == "ttc"
            }
            if !fontURLs.isEmpty {
                registerFontURLs(fontURLs)
                break
            }
        }
    }

    private static func registerFontURLs(_ urls: [URL]) {
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func allDisplayFontFamilies() -> [String] {
        registerBundledFonts()
        let available = NSFontManager.shared.availableFontFamilies
        var seen = Set<String>()
        var extras: [String] = []
        for f in available where !f.hasPrefix(".") {
            let key = f.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                extras.append(f)
            }
        }
        return extras.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func resolveFontAndSource(family: String?, sizePt: CGFloat, bold: Bool, italic: Bool) -> (font: NSFont, logicalName: String?) {
        registerBundledFonts()
        let size = Swift.max(7, Swift.min(144, sizePt))
        let requested = family?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = NSFontManager.shared

        var availableByLower: [String: String] = [:]
        for f in fm.availableFontFamilies {
            availableByLower[f.lowercased()] = f
        }

        func instantiate(family canonicalFamily: String) -> NSFont? {
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }

            var font = fm.font(withFamily: canonicalFamily, traits: traits, weight: bold ? 9 : 5, size: size)
            if font == nil {
                font = NSFont(name: canonicalFamily, size: size)
            }
            guard var f = font else { return nil }
            if bold && !fm.traits(of: f).contains(.boldFontMask) {
                f = fm.convert(f, toHaveTrait: .boldFontMask)
            }
            if italic && !fm.traits(of: f).contains(.italicFontMask) {
                f = fm.convert(f, toHaveTrait: .italicFontMask)
            }
            return f
        }

        if let requested, !requested.isEmpty {
            let lower = requested.lowercased()
            if let exact = availableByLower[lower], let f = instantiate(family: exact) {
                return (f, nil)
            }
            // Also try direct PostScript / face name before substitute list
            if let direct = NSFont(name: requested, size: size) {
                var f = direct
                if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
                if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
                let sameFamily = (f.familyName?.caseInsensitiveCompare(requested) == .orderedSame)
                return (f, sameFamily ? nil : requested)
            }
            if let candidates = wordFontSubstitutes[lower] {
                for cand in candidates {
                    if let canonical = availableByLower[cand.lowercased()], let f = instantiate(family: canonical) {
                        return (f, requested)
                    }
                }
            }
            // Fallback strip suffixes like " Bold" / " Light" / " MT"
            for cand in ["Carlito", "Inter", "Helvetica Neue"] {
                if let canonical = availableByLower[cand.lowercased()], let f = instantiate(family: canonical) {
                    return (f, requested)
                }
            }
        }

        for cand in ["Carlito", "Helvetica Neue"] {
            if let canonical = availableByLower[cand.lowercased()], let f = instantiate(family: canonical) {
                return (f, requested ?? "Calibri")
            }
        }
        var sys = NSFont.systemFont(ofSize: size)
        if bold { sys = fm.convert(sys, toHaveTrait: .boldFontMask) }
        if italic { sys = fm.convert(sys, toHaveTrait: .italicFontMask) }
        return (sys, requested)
    }

    static func resolveFont(family: String?, sizePt: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        resolveFontAndSource(family: family, sizePt: sizePt, bold: bold, italic: italic).font
    }

    static func blockAttributes(for kind: String) -> (font: NSFont, color: NSColor, spaceBefore: CGFloat, spaceAfter: CGFloat, leftIndent: CGFloat) {
        let s = fullBlockStyle(for: kind)
        return (s.font, s.color, s.spaceBefore, s.spaceAfter, s.leftIndent)
    }

    static func fullBlockStyle(for kind: String) -> (
        font: NSFont,
        logicalFontName: String,
        color: NSColor,
        backgroundColor: NSColor?,
        spaceBefore: CGFloat,
        spaceAfter: CGFloat,
        lineSpacing: CGFloat,
        leftIndent: CGFloat,
        align: NSTextAlignment
    ) {
        switch kind {
        case "noSpacing":
            return (resolveFont(family: "Calibri", sizePt: 11.5, bold: false, italic: false), "Calibri", NSColor(srgbRed: 0.07, green: 0.09, blue: 0.15, alpha: 1), nil, 0, 0, 1.0, 0, .left)
        case "title":
            return (resolveFont(family: "Calibri", sizePt: 26, bold: true, italic: false), "Calibri", NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 1), nil, 4, 8, 1.15, 0, .left)
        case "subtitle":
            return (resolveFont(family: "Calibri", sizePt: 14, bold: false, italic: true), "Calibri", NSColor(srgbRed: 0.28, green: 0.33, blue: 0.41, alpha: 1), nil, 0, 12, 1.15, 0, .left)
        case "h1":
            return (resolveFont(family: "Calibri", sizePt: 20, bold: true, italic: false), "Calibri", NSColor(srgbRed: 0.12, green: 0.23, blue: 0.54, alpha: 1), nil, 14, 6, 1.15, 0, .left)
        case "h2":
            return (resolveFont(family: "Calibri", sizePt: 15, bold: true, italic: false), "Calibri", NSColor(srgbRed: 0.12, green: 0.25, blue: 0.69, alpha: 1), nil, 12, 5, 1.15, 0, .left)
        case "h3":
            return (resolveFont(family: "Calibri", sizePt: 12.5, bold: true, italic: false), "Calibri", NSColor(srgbRed: 0.12, green: 0.16, blue: 0.22, alpha: 1), nil, 10, 4, 1.15, 0, .left)
        case "h4":
            return (resolveFont(family: "Calibri", sizePt: 11.5, bold: true, italic: true), "Calibri", NSColor(srgbRed: 0.20, green: 0.25, blue: 0.33, alpha: 1), nil, 8, 4, 1.15, 0, .left)
        case "quote":
            return (resolveFont(family: "Calibri", sizePt: 11.5, bold: false, italic: true), "Calibri", NSColor(srgbRed: 0.20, green: 0.25, blue: 0.33, alpha: 1), nil, 6, 6, 1.15, 18, .left)
        case "intenseQuote":
            return (resolveFont(family: "Calibri", sizePt: 12, bold: true, italic: true), "Calibri", NSColor(srgbRed: 0.11, green: 0.31, blue: 0.85, alpha: 1), nil, 10, 10, 1.25, 24, .center)
        case "caption":
            return (resolveFont(family: "Calibri", sizePt: 9.5, bold: false, italic: true), "Calibri", NSColor(srgbRed: 0.39, green: 0.45, blue: 0.55, alpha: 1), nil, 2, 6, 1.1, 0, .left)
        case "code":
            return (resolveFont(family: "Consolas", sizePt: 10, bold: false, italic: false), "Consolas", NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 1), NSColor(srgbRed: 0.945, green: 0.96, blue: 0.976, alpha: 1), 6, 6, 1.15, 12, .left)
        default:
            return (resolveFont(family: "Calibri", sizePt: 11.5, bold: false, italic: false), "Calibri", NSColor(srgbRed: 0.07, green: 0.09, blue: 0.15, alpha: 1), nil, 0, 6, 1.15, 0, .left)
        }
    }

    // MARK: - Read .docx
    static func readDocx(data: Data) throws -> ParsedDocxDocument {
        registerBundledFonts()
        let entries = try PureZip.read(data: data)
        guard let docXmlData = findEntry(entries, path: "word/document.xml") else {
            throw DocxError.missingDocumentXml
        }

        let docXml = try XMLDocument(data: docXmlData, options: [.nodePreserveWhitespace])
        guard let root = docXml.rootElement(), let bodyEl = root.child(localName: "body") else {
            throw DocxError.invalidXml("Falta elemento w:body.")
        }

        let rels = parseRelationships(findEntry(entries, path: "word/_rels/document.xml.rels"))
        registerEmbeddedDocxFonts(entries: entries)
        let themeFonts = parseThemeFonts(entries: entries, rels: rels)
        let styles = parseStyles(findEntry(entries, path: "word/styles.xml"), themeFonts: themeFonts)
        let numbering = parseNumbering(findEntry(entries, path: "word/numbering.xml"))

        let sectPr = bodyEl.child(localName: "sectPr") ?? bodyEl.descendants(localName: "sectPr").last
        let pageSetup = parsePageSetup(sectPr)
        let maxImgWidth = pageSetup.printableWidthPt

        var headerText = ""
        var footerText = ""
        if let sectPr {
            if let hdrRef = sectPr.child(localName: "headerReference"),
               let rId = hdrRef.attr("id"),
               let target = rels[rId]?.target,
               let hdrData = findEntry(entries, path: resolveWordPath(target)),
               let hdrDoc = try? XMLDocument(data: hdrData, options: [.nodePreserveWhitespace]) {
                headerText = hdrDoc.rootElement()?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            if let ftrRef = sectPr.child(localName: "footerReference"),
               let rId = ftrRef.attr("id"),
               let target = rels[rId]?.target,
               let ftrData = findEntry(entries, path: resolveWordPath(target)),
               let ftrDoc = try? XMLDocument(data: ftrData, options: [.nodePreserveWhitespace]) {
                footerText = ftrDoc.rootElement()?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
        }

        var docTitle = ""
        if let coreData = findEntry(entries, path: "docProps/core.xml"),
           let coreDoc = try? XMLDocument(data: coreData, options: []),
           let titleEl = coreDoc.rootElement()?.descendants(localName: "title").first {
            docTitle = titleEl.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        var listCounters: [String: Int] = [:]
        let result = NSMutableAttributedString()

        func loadImage(rId: String?) -> NSImage? {
            guard let rId, let rel = rels[rId] else { return nil }
            let path = resolveWordPath(rel.target)
            guard let imgData = findEntry(entries, path: path) else { return nil }
            return NSImage(data: imgData)
        }

        func pageBreakAttributedString() -> NSAttributedString {
            let ps = NSMutableParagraphStyle()
            ps.paragraphSpacing = 0
            ps.paragraphSpacingBefore = 0
            ps.minimumLineHeight = 1
            ps.maximumLineHeight = 1
            return NSAttributedString(string: "\u{000C}", attributes: [
                .font: NSFont.systemFont(ofSize: 1),
                .foregroundColor: NSColor.clear,
                .paragraphStyle: ps,
                .owBlockKind: "pageBreak",
            ])
        }

        func endsWithPageBreak(_ str: String) -> Bool {
            str.hasSuffix("\u{000C}") || str.hasSuffix("\u{000C}\n")
        }

        func buildAttributes(from rPr: RunProps) -> [NSAttributedString.Key: Any] {
            let resolved = resolveFontAndSource(
                family: rPr.fontFamily ?? themeFonts.minor,
                sizePt: rPr.fontSizePt ?? 11.0,
                bold: rPr.bold ?? false,
                italic: rPr.italic ?? false
            )
            var attrs: [NSAttributedString.Key: Any] = [
                .font: resolved.font,
                .foregroundColor: rPr.color ?? NSColor(srgbRed: 0.07, green: 0.09, blue: 0.15, alpha: 1.0),
            ]
            if let logical = resolved.logicalName {
                attrs[.owFontName] = logical
            }
            if rPr.underline == true {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if rPr.strike == true {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let sup = rPr.superscriptVal, sup != 0 {
                attrs[.superscript] = NSNumber(value: sup)
            }
            if let hl = rPr.highlight {
                attrs[.backgroundColor] = hl
            }
            return attrs
        }

        struct ActiveField {
            var instr: String = ""
            var inResult: Bool = false
            var linkURL: URL? = nil
        }

        func appendBookmarkMarkers(_ names: [String], onto target: NSMutableAttributedString, at charIndex: Int) {
            guard !names.isEmpty, charIndex >= 0, charIndex < target.length else { return }
            let existing = (target.attribute(.owBookmarks, at: charIndex, effectiveRange: nil) as? [String]) ?? []
            var merged = existing
            for n in names where !merged.contains(n) {
                merged.append(n)
            }
            target.addAttribute(.owBookmarks, value: merged, range: NSRange(location: charIndex, length: 1))
        }

        func makeParagraphStyle(from effPPr: ParaProps, tableBlock: NSTextTableBlock? = nil) -> NSMutableParagraphStyle {
            let ps = NSMutableParagraphStyle()
            if let align = effPPr.align { ps.alignment = align }
            if let lh = effPPr.lineHeightMultiple { ps.lineHeightMultiple = lh }
            if let minLH = effPPr.minLineHeightPt, minLH > 0 { ps.minimumLineHeight = minLH }
            if let maxLH = effPPr.maxLineHeightPt, maxLH > 0 { ps.maximumLineHeight = maxLH }
            ps.paragraphSpacingBefore = effPPr.spaceBeforePt ?? 0
            ps.paragraphSpacing = effPPr.spaceAfterPt ?? 0
            if let left = effPPr.leftIndentPt, effPPr.numId == nil { ps.headIndent = left; ps.firstLineHeadIndent = left }
            if let first = effPPr.firstLineIndentPt, effPPr.numId == nil { ps.firstLineHeadIndent = (effPPr.leftIndentPt ?? 0) + first }
            if let tableBlock { ps.textBlocks = [tableBlock] }
            return ps
        }

        func appendParagraph(
            _ pNode: XMLElement,
            tableBlock: NSTextTableBlock? = nil,
            tableBasePPr: ParaProps? = nil,
            tableBaseRPr: RunProps? = nil,
            initialBookmarks: [String] = [],
            into target: NSMutableAttributedString
        ) {
            let inlinePPr = extractPPr(pNode.child(localName: "pPr"), themeFonts: themeFonts)
            let explicitPStyle = inlinePPr.pStyle
            let effectivePStyleId = explicitPStyle ?? styles.defaultParagraphStyleId
            let styleObj = effectivePStyleId.flatMap { styles.styles[$0] }
            let applyTableStyleAfterParaStyle = (tableBasePPr != nil || tableBaseRPr != nil)
                && (explicitPStyle == nil || explicitPStyle == styles.defaultParagraphStyleId)

            var layeredPPr = styles.defaultPPr
            var layeredRPr = RunProps()
            if applyTableStyleAfterParaStyle {
                if let s = styleObj {
                    layeredPPr = layeredPPr.merged(with: s.pPr)
                    layeredRPr = layeredRPr.merged(with: s.rPr)
                }
                if let tp = tableBasePPr { layeredPPr = layeredPPr.merged(with: tp) }
                if let tr = tableBaseRPr { layeredRPr = layeredRPr.merged(with: tr) }
            } else {
                if let tp = tableBasePPr { layeredPPr = layeredPPr.merged(with: tp) }
                if let tr = tableBaseRPr { layeredRPr = layeredRPr.merged(with: tr) }
                if let s = styleObj {
                    layeredPPr = layeredPPr.merged(with: s.pPr)
                    layeredRPr = layeredRPr.merged(with: s.rPr)
                }
            }
            let effPPr = layeredPPr.merged(with: inlinePPr)
            let baseRPr = layeredRPr.merged(with: inlinePPr.rPr ?? RunProps())

            let pStyleLower = (effectivePStyleId ?? "").lowercased()
            let pStyleNameLower = (styleObj?.name ?? "").lowercased()
            let isTocParagraph = pStyleLower.hasPrefix("toc")
                || pStyleNameLower.hasPrefix("toc")
                || pStyleLower.contains("tabla de contenido")
                || pStyleNameLower.contains("table of contents")
                || pStyleLower.hasPrefix("tdc")

            var pendingBookmarks = initialBookmarks
            var fieldStack: [ActiveField] = []

            let paraStr = NSMutableAttributedString()
            func appendChunk(_ chunk: NSAttributedString) {
                guard chunk.length > 0 else { return }
                let startOffset = paraStr.length
                paraStr.append(chunk)
                if !pendingBookmarks.isEmpty {
                    appendBookmarkMarkers(pendingBookmarks, onto: paraStr, at: startOffset)
                    pendingBookmarks.removeAll()
                }
            }

            func currentEffectiveLink(_ explicitLink: URL?) -> URL? {
                explicitLink ?? fieldStack.reversed().compactMap(\.linkURL).first
            }

            func appendRun(_ rNode: XMLElement, baseRPr: RunProps, linkURL: URL?) {
                let inlineRPr = extractRPr(rNode.child(localName: "rPr"), themeFonts: themeFonts)

                func runAttrs() -> [NSAttributedString.Key: Any] {
                    let activeLink = currentEffectiveLink(linkURL)
                    let isInternalLink = activeLink?.absoluteString.hasPrefix("#") == true
                    let isTocAnchor = activeLink?.fragment?.hasPrefix("_Toc") == true
                    let rStyleIdLower = (inlineRPr.rStyle ?? "").lowercased()
                    let isHyperlinkRStyle = (rStyleIdLower == "hyperlink" || rStyleIdLower == "hipervinculo" || rStyleIdLower == "hipervínculo" || rStyleIdLower == "vinculo")
                    let suppressTocHyperlinkStyle = isInternalLink && (isTocParagraph || isTocAnchor) && isHyperlinkRStyle

                    let rStyleRPr = suppressTocHyperlinkStyle ? RunProps() : (inlineRPr.rStyle.flatMap { styles.styles[$0]?.rPr } ?? RunProps())
                    let effRPr = styles.defaultRPr.merged(with: baseRPr).merged(with: rStyleRPr).merged(with: inlineRPr)

                    var attrs = buildAttributes(from: effRPr)
                    if let activeLink {
                        attrs[.link] = activeLink
                        if !isInternalLink {
                            attrs[.foregroundColor] = effRPr.color ?? NSColor(srgbRed: 0.15, green: 0.39, blue: 0.92, alpha: 1.0)
                            if effRPr.underline == nil {
                                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                            }
                        }
                    }
                    return attrs
                }

                for child in rNode.elementChildren {
                    let lname = child.localName ?? ""
                    if lname == "fldChar" {
                        switch (child.attr("fldCharType") ?? "").lowercased() {
                        case "begin":
                            fieldStack.append(ActiveField())
                        case "separate":
                            if !fieldStack.isEmpty {
                                let idx = fieldStack.count - 1
                                fieldStack[idx].inResult = true
                                fieldStack[idx].linkURL = parseFieldHyperlinkURL(from: fieldStack[idx].instr)
                            }
                        case "end":
                            if !fieldStack.isEmpty { _ = fieldStack.removeLast() }
                        default:
                            break
                        }
                        continue
                    }
                    if lname == "instrText" {
                        if !fieldStack.isEmpty && fieldStack[fieldStack.count - 1].inResult == false {
                            fieldStack[fieldStack.count - 1].instr += child.stringValue ?? ""
                        }
                        continue
                    }
                    // Skip display nodes inside instruction phase of complex fields (between begin and separate)
                    if let top = fieldStack.last, !top.inResult {
                        continue
                    }

                    let attrs = runAttrs()
                    switch lname {
                    case "t":
                        let txt = child.stringValue ?? ""
                        if !txt.isEmpty {
                            appendChunk(NSAttributedString(string: txt, attributes: attrs))
                        }
                    case "tab":
                        appendChunk(NSAttributedString(string: "\t", attributes: attrs))
                    case "br":
                        let brType = (child.attr("type") ?? "").lowercased()
                        if brType == "page" {
                            appendChunk(pageBreakAttributedString())
                        } else {
                            appendChunk(NSAttributedString(string: "\u{2028}", attributes: attrs)) // soft line break
                        }
                    case "cr":
                        appendChunk(NSAttributedString(string: "\u{2028}", attributes: attrs))
                    case "sym":
                        if let hexChar = child.attr("char"), let code = UInt32(hexChar, radix: 16), let scalar = UnicodeScalar(code) {
                            appendChunk(NSAttributedString(string: String(scalar), attributes: attrs))
                        }
                    case "drawing":
                        if let blip = child.descendants(localName: "blip").first,
                           let rId = blip.attr("embed") ?? blip.attr("link"),
                           let img = loadImage(rId: rId) {
                            let extent = child.descendants(localName: "extent").first
                            let cx = Double(extent?.attr("cx") ?? "") ?? 0
                            let cy = Double(extent?.attr("cy") ?? "") ?? 0
                            var wPt = cx > 0 ? CGFloat(cx / 12700.0) : img.size.width
                            var hPt = cy > 0 ? CGFloat(cy / 12700.0) : img.size.height
                            if wPt <= 0 { wPt = 320 }
                            if hPt <= 0 { hPt = 200 }
                            if wPt > maxImgWidth {
                                let ratio = maxImgWidth / wPt
                                wPt = maxImgWidth
                                hPt *= ratio
                            }
                            let attachment = NSTextAttachment()
                            attachment.image = img
                            attachment.bounds = CGRect(x: 0, y: 0, width: wPt, height: hPt)
                            appendChunk(NSAttributedString(attachment: attachment))
                        }
                    case "pict":
                        if let imgDataEl = child.descendants(localName: "imagedata").first,
                           let rId = imgDataEl.attr("id"),
                           let img = loadImage(rId: rId) {
                            var wPt = img.size.width > 0 ? img.size.width : 300
                            var hPt = img.size.height > 0 ? img.size.height : 200
                            if wPt > maxImgWidth {
                                let ratio = maxImgWidth / wPt
                                wPt = maxImgWidth
                                hPt *= ratio
                            }
                            let attachment = NSTextAttachment()
                            attachment.image = img
                            attachment.bounds = CGRect(x: 0, y: 0, width: wPt, height: hPt)
                            appendChunk(NSAttributedString(attachment: attachment))
                        }
                    default:
                        break
                    }
                }
            }

            func appendInlineChildren(of node: XMLElement, baseRPr: RunProps, linkURL: URL?) {
                for child in node.elementChildren {
                    switch child.localName ?? "" {
                    case "r":
                        appendRun(child, baseRPr: baseRPr, linkURL: linkURL)
                    case "hyperlink":
                        var nextURL = linkURL
                        let rIdTarget = child.attr("id").flatMap { rels[$0]?.target }
                        let anchorAttr = child.attr("anchor")
                        if let targetStr = rIdTarget {
                            if let anchor = anchorAttr, !anchor.isEmpty, !targetStr.contains("#") {
                                let enc = anchor.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? anchor
                                nextURL = makeExternalOrRelativeURL("\(targetStr)#\(enc)")
                            } else {
                                nextURL = makeExternalOrRelativeURL(targetStr)
                            }
                        } else if let anchor = anchorAttr {
                            nextURL = makeAnchorURL(anchor)
                        }
                        appendInlineChildren(of: child, baseRPr: baseRPr, linkURL: nextURL)
                    case "fldSimple":
                        let fldURL = child.attr("instr").flatMap { parseFieldHyperlinkURL(from: $0) } ?? linkURL
                        appendInlineChildren(of: child, baseRPr: baseRPr, linkURL: fldURL)
                    case "bookmarkStart":
                        if let name = child.attr("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !name.isEmpty, name != "_GoBack" {
                            pendingBookmarks.append(name)
                        }
                    case "ins", "smartTag":
                        appendInlineChildren(of: child, baseRPr: baseRPr, linkURL: linkURL)
                    case "sdt":
                        if let sdtContent = child.child(localName: "sdtContent") {
                            appendInlineChildren(of: sdtContent, baseRPr: baseRPr, linkURL: linkURL)
                        }
                    default:
                        break
                    }
                }
            }

            if tableBlock == nil && effPPr.pageBreakBefore == true && target.length > 0 && !endsWithPageBreak(target.string) {
                target.append(pageBreakAttributedString())
            }

            appendInlineChildren(of: pNode, baseRPr: baseRPr, linkURL: nil)

            if tableBlock == nil && paraStr.string == "\u{000C}" {
                if !endsWithPageBreak(target.string) {
                    target.append(pageBreakAttributedString())
                }
                return
            }

            let kind = classifyBlockKind(styleId: effectivePStyleId, styleName: styleObj?.name, pPr: effPPr)
            if paraStr.length == 0 && effPPr.hasBottomBorder {
                let ps = NSMutableParagraphStyle()
                ps.alignment = .center
                ps.paragraphSpacingBefore = 6
                ps.paragraphSpacing = 6
                if let tableBlock { ps.textBlocks = [tableBlock] }
                let hrAttrs: [NSAttributedString.Key: Any] = [
                    .font: resolveFont(family: "Calibri", sizePt: 10, bold: false, italic: false),
                    .foregroundColor: NSColor(srgbRed: 0.78, green: 0.82, blue: 0.88, alpha: 1),
                    .paragraphStyle: ps,
                    .owBlockKind: "hr",
                ]
                target.append(NSAttributedString(string: "────────────────────────────────────────\n", attributes: hrAttrs))
                return
            }

            let ps = makeParagraphStyle(from: effPPr, tableBlock: tableBlock)

            if let numId = effPPr.numId {
                let ilvl = effPPr.ilvl ?? 0
                let numFmt = numbering[numId]?[ilvl]?.numFmt ?? "bullet"
                let isOrdered = numFmt != "bullet" && numFmt != "none"
                let textList = NSTextList(markerFormat: isOrdered ? .decimal : .disc, options: 0)
                ps.textLists = [textList]
                let indent = CGFloat(28 + ilvl * 20)
                ps.headIndent = indent
                ps.firstLineHeadIndent = CGFloat(ilvl * 20)
                ps.tabStops = [
                    NSTextTab(textAlignment: .right, location: indent - 6),
                    NSTextTab(textAlignment: .left, location: indent),
                ]

                let counterKey = "\(numId):\(ilvl)"
                let nextNum = (listCounters[counterKey] ?? 0) + 1
                listCounters[counterKey] = nextNum
                let marker = isOrdered ? "\(nextNum)." : "•"
                let markerAttrs = buildAttributes(from: styles.defaultRPr.merged(with: baseRPr))
                paraStr.insert(NSAttributedString(string: "\t\(marker)\t", attributes: markerAttrs), at: 0)
            }

            // Ensure newline ends every paragraph
            let newlineAttrs: [NSAttributedString.Key: Any]
            if paraStr.length > 0 {
                newlineAttrs = paraStr.attributes(at: paraStr.length - 1, effectiveRange: nil)
            } else {
                newlineAttrs = buildAttributes(from: styles.defaultRPr.merged(with: baseRPr))
            }
            paraStr.append(NSAttributedString(string: "\n", attributes: newlineAttrs))

            let fullRange = NSRange(location: 0, length: paraStr.length)
            paraStr.addAttribute(.paragraphStyle, value: ps, range: fullRange)
            if let kind {
                paraStr.addAttribute(.owBlockKind, value: kind, range: fullRange)
            }
            if !pendingBookmarks.isEmpty {
                appendBookmarkMarkers(pendingBookmarks, onto: paraStr, at: paraStr.length - 1)
                pendingBookmarks.removeAll()
            }

            target.append(paraStr)
        }

        func appendTable(_ tblNode: XMLElement, into target: NSMutableAttributedString) {
            let rows = tblNode.children(localName: "tr")
            guard !rows.isEmpty else { return }

            let tblPr = tblNode.child(localName: "tblPr")
            let tblStyleId = tblPr?.child(localName: "tblStyle")?.attr("val") ?? styles.defaultTableStyleId
            let tblStyle = tblStyleId.flatMap { styles.tableStyles[$0] }

            var colCount = 1
            var gridColTwips: [Double] = []
            if let tblGrid = tblNode.child(localName: "tblGrid") {
                gridColTwips = tblGrid.children(localName: "gridCol").compactMap { col in
                    Double(col.attr("w") ?? "")
                }
                if gridColTwips.count > colCount { colCount = gridColTwips.count }
            }
            for tr in rows {
                var rowCols = 0
                for tc in tr.children(localName: "tc") {
                    let span = Int(tc.child(localName: "tcPr")?.child(localName: "gridSpan")?.attr("val") ?? "") ?? 1
                    rowCols += max(1, span)
                }
                if rowCols > colCount { colCount = rowCols }
            }

            if gridColTwips.count < colCount {
                gridColTwips.append(contentsOf: repeatElement(0.0, count: colCount - gridColTwips.count))
            }
            if gridColTwips.contains(where: { $0 <= 0 }) {
                for tr in rows {
                    var colCursor = 0
                    for tc in tr.children(localName: "tc") {
                        let tcPr = tc.child(localName: "tcPr")
                        let span = max(1, Int(tcPr?.child(localName: "gridSpan")?.attr("val") ?? "") ?? 1)
                        if span == 1, colCursor < colCount, gridColTwips[colCursor] <= 0,
                           let tcW = tcPr?.child(localName: "tcW") {
                            let wType = (tcW.attr("type") ?? "dxa").lowercased()
                            if (wType == "dxa" || wType.isEmpty), let w = Double(tcW.attr("w") ?? ""), w > 0 {
                                gridColTwips[colCursor] = w
                            }
                        }
                        colCursor += span
                    }
                }
            }

            let totalGridTwips = gridColTwips.prefix(colCount).reduce(0, +)
            let hasValidGrid = colCount > 0 && gridColTwips.prefix(colCount).allSatisfy { $0 > 0 } && totalGridTwips > 0

            let table = NSTextTable()
            table.numberOfColumns = colCount
            table.collapsesBorders = true

            var tableWidthPct: CGFloat = 100
            let pagePrintableTwips = max(1.0, Double(maxImgWidth) * 20.0)
            if let tblW = tblPr?.child(localName: "tblW"), let wVal = Double(tblW.attr("w") ?? "") {
                let wType = (tblW.attr("type") ?? "dxa").lowercased()
                if wType == "pct", wVal > 0 {
                    tableWidthPct = min(100, max(5, CGFloat(wVal / 50.0)))
                } else if (wType == "dxa" || wType.isEmpty), wVal > 0 {
                    tableWidthPct = min(100, max(5, CGFloat((wVal / pagePrintableTwips) * 100.0)))
                } else if hasValidGrid && totalGridTwips < pagePrintableTwips * 0.99 {
                    tableWidthPct = min(100, max(5, CGFloat((totalGridTwips / pagePrintableTwips) * 100.0)))
                }
            } else if hasValidGrid && totalGridTwips < pagePrintableTwips * 0.99 {
                tableWidthPct = min(100, max(5, CGFloat((totalGridTwips / pagePrintableTwips) * 100.0)))
            }
            table.setContentWidth(tableWidthPct, type: .percentageValueType)

            let defaultCellMargins = CellMarginsPt(top: 0, right: 5.4, bottom: 0, left: 5.4)
            let tableCellMargins = defaultCellMargins
                .merged(with: tblStyle?.cellMargins ?? CellMarginsPt())
                .merged(with: extractCellMarginsPt(tblPr?.child(localName: "tblCellMar")))
            let directTblBorders = extractTableBorders(tblPr?.child(localName: "tblBorders"))
            let tblBorderPt = directTblBorders.pt ?? tblStyle?.borderPt ?? 0
            let tblBorderColor = directTblBorders.color ?? tblStyle?.borderColor ?? NSColor(srgbRed: 0.80, green: 0.84, blue: 0.89, alpha: 1.0)

            for (rIdx, tr) in rows.enumerated() {
                let trPr = tr.child(localName: "trPr")
                let isHeader = trPr?.child(localName: "tblHeader") != nil
                var colCursor = 0
                for tc in tr.children(localName: "tc") {
                    let tcPr = tc.child(localName: "tcPr")
                    let span = max(1, Int(tcPr?.child(localName: "gridSpan")?.attr("val") ?? "") ?? 1)
                    let block = NSTextTableBlock(
                        table: table,
                        startingRow: rIdx,
                        rowSpan: 1,
                        startingColumn: colCursor,
                        columnSpan: span
                    )
                    var widthPct = 100.0 * Double(span) / Double(colCount)
                    if hasValidGrid && colCursor < colCount {
                        let endCol = min(colCount, colCursor + span)
                        let spanSum = gridColTwips[colCursor..<endCol].reduce(0, +)
                        if spanSum > 0 {
                            widthPct = 100.0 * spanSum / totalGridTwips
                        }
                    } else if let tcW = tcPr?.child(localName: "tcW"), let wVal = Double(tcW.attr("w") ?? ""), wVal > 0 {
                        let wType = (tcW.attr("type") ?? "dxa").lowercased()
                        if wType == "pct" {
                            widthPct = min(100.0, max(1.0, wVal / 50.0))
                        } else if wType == "dxa" || wType.isEmpty {
                            let denom = totalGridTwips > 0 ? totalGridTwips : pagePrintableTwips
                            widthPct = min(100.0, max(1.0, 100.0 * wVal / denom))
                        }
                    }
                    block.setValue(CGFloat(max(1.0, widthPct)), type: .percentageValueType, for: .width)

                    let cellBorders = extractTableBorders(tcPr?.child(localName: "tcBorders"))
                    let cellBorderPt = cellBorders.pt ?? tblBorderPt
                    block.setWidth(cellBorderPt, type: .absoluteValueType, for: .border)
                    if cellBorderPt > 0 {
                        block.setBorderColor(cellBorders.color ?? tblBorderColor)
                    }

                    let cellMargins = tableCellMargins.merged(with: extractCellMarginsPt(tcPr?.child(localName: "tcMar")))
                    block.setWidth(cellMargins.left ?? 5.4, type: .absoluteValueType, for: .padding, edge: .minX)
                    block.setWidth(cellMargins.right ?? 5.4, type: .absoluteValueType, for: .padding, edge: .maxX)
                    block.setWidth(cellMargins.top ?? 0, type: .absoluteValueType, for: .padding, edge: .minY)
                    block.setWidth(cellMargins.bottom ?? 0, type: .absoluteValueType, for: .padding, edge: .maxY)

                    if let fill = tcPr?.child(localName: "shd")?.attr("fill"),
                       let bg = NSColor.fromHex(fill) {
                        block.backgroundColor = bg
                    } else if isHeader {
                        block.backgroundColor = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1.0)
                    }

                    let innerParas = tc.children(localName: "p")
                    if innerParas.isEmpty {
                        let defaultStyle = styles.defaultParagraphStyleId.flatMap { styles.styles[$0] }
                        let emptyPPr = styles.defaultPPr.merged(with: defaultStyle?.pPr ?? ParaProps()).merged(with: tblStyle?.pPr ?? ParaProps())
                        var emptyRPr = styles.defaultRPr.merged(with: defaultStyle?.rPr ?? RunProps()).merged(with: tblStyle?.rPr ?? RunProps())
                        if isHeader && emptyRPr.bold == nil { emptyRPr.bold = true }
                        let ps = makeParagraphStyle(from: emptyPPr, tableBlock: block)
                        var emptyAttrs = buildAttributes(from: emptyRPr)
                        emptyAttrs[.paragraphStyle] = ps
                        target.append(NSAttributedString(string: "\n", attributes: emptyAttrs))
                    } else {
                        for p in innerParas {
                            appendParagraph(
                                p,
                                tableBlock: block,
                                tableBasePPr: tblStyle?.pPr,
                                tableBaseRPr: tblStyle?.rPr,
                                into: target
                            )
                        }
                    }
                    colCursor += span
                }
            }
        }

        var pendingSectionBreak = false
        var pendingBlockBookmarks: [String] = []
        func processBlockElements(_ nodes: [XMLElement]) {
            for node in nodes {
                switch node.localName ?? "" {
                case "bookmarkStart":
                    if let name = node.attr("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !name.isEmpty, name != "_GoBack" {
                        pendingBlockBookmarks.append(name)
                    }
                case "p":
                    if pendingSectionBreak && result.length > 0 && !endsWithPageBreak(result.string) {
                        result.append(pageBreakAttributedString())
                    }
                    pendingSectionBreak = false
                    let blockBms = pendingBlockBookmarks
                    pendingBlockBookmarks.removeAll()
                    appendParagraph(node, initialBookmarks: blockBms, into: result)
                    if let pSectPr = node.child(localName: "pPr")?.child(localName: "sectPr") {
                        let brType = (pSectPr.child(localName: "type")?.attr("val") ?? "nextPage").lowercased()
                        if brType != "continuous" {
                            pendingSectionBreak = true
                        }
                    }
                case "tbl":
                    if pendingSectionBreak && result.length > 0 && !endsWithPageBreak(result.string) {
                        result.append(pageBreakAttributedString())
                    }
                    pendingSectionBreak = false
                    appendTable(node, into: result)
                case "sdt":
                    if let sdtContent = node.child(localName: "sdtContent") {
                        processBlockElements(sdtContent.elementChildren)
                    }
                default:
                    break
                }
            }
        }

        processBlockElements(bodyEl.elementChildren)

        // Ensure non-empty document and trailing paragraph after terminal tables so user can type below
        let endsInTable: Bool = {
            guard result.length > 0 else { return false }
            let ps = result.attribute(.paragraphStyle, at: result.length - 1, effectiveRange: nil) as? NSParagraphStyle
            return !(ps?.textBlocks.isEmpty ?? true)
        }()
        if result.length == 0 || endsInTable {
            let def = blockAttributes(for: "normal")
            let ps = NSMutableParagraphStyle()
            ps.paragraphSpacing = 0
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: def.font,
                .foregroundColor: def.color,
                .paragraphStyle: ps,
            ]))
        }

        return ParsedDocxDocument(
            attributedString: result,
            pageSetup: pageSetup,
            headerText: headerText,
            footerText: footerText,
            title: docTitle
        )
    }

    // MARK: - Write .docx
    static func writeDocx(
        attributedString: NSAttributedString,
        pageSetup: DocPageSetup,
        title: String,
        headerText: String = "",
        footerText: String = ""
    ) throws -> Data {
        let baseTwip = pageSetup.customSizePt.map { (w: Int(round($0.width * 20.0)), h: Int(round($0.height * 20.0))) } ?? pageSetup.size.sizeTwips
        let isLandscape = pageSetup.orientation == .landscape
        let pageW = isLandscape ? baseTwip.h : baseTwip.w
        let pageH = isLandscape ? baseTwip.w : baseTwip.h
        let mmToTwips: (Double) -> Int = { max(0, Int(round($0 * 56.6929))) }
        let marTop = mmToTwips(pageSetup.marginTopMm)
        let marRight = mmToTwips(pageSetup.marginRightMm)
        let marBottom = mmToTwips(pageSetup.marginBottomMm)
        let marLeft = mmToTwips(pageSetup.marginLeftMm)
        let contentWidthTwips = max(2880, pageW - marLeft - marRight)
        let contentWidthEmu = contentWidthTwips * 635

        var nextRelId = 3 // rId1 = styles.xml, rId2 = numbering.xml
        var relsXmlItems = [
            "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>",
            "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>",
        ]
        var mediaEntries: [String: Data] = [:]
        var nextMediaIndex = 1
        var nextDocPrId = 1
        var nextBookmarkId = 1
        var nextOrderedNumId = 2

        func bookmarkTags(for names: [String]) -> (start: String, end: String) {
            var starts = ""
            var ends = ""
            for name in names where !name.isEmpty {
                let id = nextBookmarkId
                nextBookmarkId += 1
                starts += "<w:bookmarkStart w:id=\"\(id)\" w:name=\"\(xmlEscape(name))\"/>"
                ends = "<w:bookmarkEnd w:id=\"\(id)\"/>" + ends
            }
            return (starts, ends)
        }
        var orderedNumIds: [String] = []
        var activeOrderedNumId: String?

        func allocRelId() -> String {
            let id = "rId\(nextRelId)"
            nextRelId += 1
            return id
        }

        func registerLink(_ url: URL) -> String? {
            let abs = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !abs.isEmpty else { return nil }
            let rId = allocRelId()
            relsXmlItems.append(
                "<Relationship Id=\"\(rId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xmlEscape(abs))\" TargetMode=\"External\"/>"
            )
            return rId
        }

        func registerImage(_ attachment: NSTextAttachment) -> String? {
            guard let img = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap({ NSImage(data: $0) }) else {
                return nil
            }
            guard let tiff = img.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }
            let fileName = "image\(nextMediaIndex).png"
            nextMediaIndex += 1
            mediaEntries["word/media/\(fileName)"] = pngData

            let rId = allocRelId()
            relsXmlItems.append(
                "<Relationship Id=\"\(rId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(fileName)\"/>"
            )

            let boxSize = attachment.bounds.size
            let wPt = boxSize.width > 1 ? boxSize.width : (img.size.width > 1 ? img.size.width : 300)
            let hPt = boxSize.height > 1 ? boxSize.height : (img.size.height > 1 ? img.size.height : 200)
            var cx = Int(round(Double(wPt) * 12700.0))
            var cy = Int(round(Double(hPt) * 12700.0))
            if cx > contentWidthEmu {
                let ratio = Double(contentWidthEmu) / Double(cx)
                cx = contentWidthEmu
                cy = max(12700, Int(round(Double(cy) * ratio)))
            }
            let docId = nextDocPrId
            nextDocPrId += 1
            let name = xmlEscape(fileName)

            return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/><wp:docPr id=\"\(docId)\" name=\"\(name)\" descr=\"\(name)\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" noChangeAspect=\"1\"/></wp:cNvGraphicFramePr><a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:nvPicPr><pic:cNvPr id=\"\(docId)\" name=\"\(name)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(rId)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
        }

        func serializeRuns(in range: NSRange, stripListPrefix: Bool) -> String {
            var workingRange = range
            let fullNS = attributedString.string as NSString
            if stripListPrefix && workingRange.length > 0 {
                let slice = fullNS.substring(with: workingRange)
                if let regex = try? NSRegularExpression(pattern: "^\\t[^\\t\\n]{1,14}\\t"),
                   let match = regex.firstMatch(in: slice, range: NSRange(location: 0, length: (slice as NSString).length)) {
                    let dropLen = match.range.length
                    workingRange = NSRange(location: workingRange.location + dropLen, length: workingRange.length - dropLen)
                }
            }

            if workingRange.length <= 0 { return "" }

            var runsXml = ""
            attributedString.enumerateAttributes(in: workingRange, options: []) { attrs, subRange, _ in
                if let attachment = attrs[.attachment] as? NSTextAttachment {
                    if let imgXml = registerImage(attachment) {
                        runsXml += imgXml
                    }
                    return
                }

                let text = fullNS.substring(with: subRange)
                if text.isEmpty { return }

                let font = attrs[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                var rPrParts: [String] = []
                if let family = (attrs[.owFontName] as? String) ?? font?.familyName ?? font?.fontName {
                    let cleanFamily = family == ".AppleSystemUIFont" ? "Calibri" : family
                    let esc = xmlEscape(cleanFamily)
                    rPrParts.append("<w:rFonts w:ascii=\"\(esc)\" w:hAnsi=\"\(esc)\" w:cs=\"\(esc)\"/>")
                }
                if traits.contains(.boldFontMask) { rPrParts.append("<w:b/>") }
                if traits.contains(.italicFontMask) { rPrParts.append("<w:i/>") }
                if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 {
                    rPrParts.append("<w:strike/>")
                }
                if let fg = attrs[.foregroundColor] as? NSColor, let hex = fg.hexRRGGBB {
                    rPrParts.append("<w:color w:val=\"\(hex)\"/>")
                }
                if let size = font?.pointSize {
                    let halfPts = max(12, min(200, Int(round(size * 2.0))))
                    rPrParts.append("<w:sz w:val=\"\(halfPts)\"/><w:szCs w:val=\"\(halfPts)\"/>")
                }
                if let bg = attrs[.backgroundColor] as? NSColor, let hex = bg.hexRRGGBB, hex != "FFFFFF" {
                    if let hlName = nearestWordHighlightName(forHex: hex) {
                        rPrParts.append("<w:highlight w:val=\"\(hlName)\"/>")
                    } else {
                        rPrParts.append("<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(hex)\"/>")
                    }
                }
                if let ul = attrs[.underlineStyle] as? Int, ul != 0 {
                    rPrParts.append("<w:u w:val=\"single\"/>")
                }
                if let sup = attrs[.superscript] as? NSNumber, sup.intValue != 0 {
                    let val = sup.intValue > 0 ? "superscript" : "subscript"
                    rPrParts.append("<w:vertAlign w:val=\"\(val)\"/>")
                }

                let rPrXml = rPrParts.isEmpty ? "" : "<w:rPr>\(rPrParts.joined())</w:rPr>"

                // Split tabs, line breaks, and page breaks cleanly
                var innerRunParts = ""
                var textBuf = ""
                func flushTextBuf() {
                    guard !textBuf.isEmpty else { return }
                    let needsPreserve = textBuf.first?.isWhitespace == true || textBuf.last?.isWhitespace == true || textBuf.contains("  ")
                    let tEl = needsPreserve ? "<w:t xml:space=\"preserve\">\(xmlEscape(textBuf))</w:t>" : "<w:t>\(xmlEscape(textBuf))</w:t>"
                    innerRunParts += "<w:r>\(rPrXml)\(tEl)</w:r>"
                    textBuf = ""
                }

                for scalar in text.unicodeScalars {
                    if scalar.value == 0x09 {
                        flushTextBuf()
                        innerRunParts += "<w:r>\(rPrXml)<w:tab/></w:r>"
                    } else if scalar.value == 0x2028 {
                        flushTextBuf()
                        innerRunParts += "<w:r>\(rPrXml)<w:br/></w:r>"
                    } else if scalar.value == 0x0C {
                        flushTextBuf()
                        innerRunParts += "<w:r><w:br w:type=\"page\"/></w:r>"
                    } else {
                        textBuf.unicodeScalars.append(scalar)
                    }
                }
                flushTextBuf()

                let runXml: String
                if let url = (attrs[.link] as? URL) ?? (attrs[.link] as? String).flatMap({ URL(string: $0) }) {
                    let abs = url.absoluteString
                    if abs.hasPrefix("#") {
                        let rawAnchor = url.fragment ?? String(abs.dropFirst())
                        let decodedAnchor = (rawAnchor.removingPercentEncoding ?? rawAnchor).trimmingCharacters(in: .whitespacesAndNewlines)
                        runXml = decodedAnchor.isEmpty ? innerRunParts : "<w:hyperlink w:anchor=\"\(xmlEscape(decodedAnchor))\">\(innerRunParts)</w:hyperlink>"
                    } else if let rId = registerLink(url) {
                        runXml = "<w:hyperlink r:id=\"\(rId)\">\(innerRunParts)</w:hyperlink>"
                    } else {
                        runXml = innerRunParts
                    }
                } else {
                    runXml = innerRunParts
                }
                if let bms = attrs[.owBookmarks] as? [String], !bms.isEmpty {
                    let tags = bookmarkTags(for: bms)
                    runsXml += tags.start + runXml + tags.end
                } else {
                    runsXml += runXml
                }
            }
            return runsXml
        }

        // Partition document into paragraph ranges
        let fullStr = attributedString.string as NSString
        var paraRanges: [NSRange] = []
        var pos = 0
        while pos < fullStr.length {
            let lineRange = fullStr.lineRange(for: NSRange(location: pos, length: 0))
            paraRanges.append(lineRange)
            pos = NSMaxRange(lineRange)
        }
        if paraRanges.isEmpty {
            paraRanges.append(NSRange(location: 0, length: 0))
        }

        // Helper to serialize one paragraph (outside or inside table cell)
        func serializeParagraph(range: NSRange) -> String {
            var contentRange = range
            if contentRange.length > 0 && fullStr.substring(with: NSRange(location: NSMaxRange(contentRange) - 1, length: 1)) == "\n" {
                contentRange.length -= 1
            }

            if contentRange.length == 1 && fullStr.substring(with: contentRange) == "\u{000C}" {
                activeOrderedNumId = nil
                return "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }

            var hasPageBreakBefore = false
            while contentRange.length > 0 && fullStr.substring(with: NSRange(location: contentRange.location, length: 1)) == "\u{000C}" {
                hasPageBreakBefore = true
                contentRange.location += 1
                contentRange.length -= 1
            }
            if hasPageBreakBefore && contentRange.length == 0 {
                activeOrderedNumId = nil
                return "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }

            let sampleLoc = min(contentRange.location, max(0, fullStr.length - 1))
            let attrs = fullStr.length > 0 ? attributedString.attributes(at: sampleLoc, effectiveRange: nil) : [:]
            let ps = attrs[.paragraphStyle] as? NSParagraphStyle
            let blockKind = attrs[.owBlockKind] as? String

            if blockKind == "hr" {
                activeOrderedNumId = nil
                return "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"CBD5E1\"/></w:pBdr><w:spacing w:before=\"120\" w:after=\"120\"/></w:pPr></w:p>"
            }

            if blockKind == "pageBreak" {
                activeOrderedNumId = nil
                return "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }

            var pPrParts: [String] = []
            if hasPageBreakBefore {
                pPrParts.append("<w:pageBreakBefore/>")
            }
            var pStyleId: String?
            switch blockKind {
            case "noSpacing": pStyleId = "NoSpacing"
            case "title": pStyleId = "Title"
            case "subtitle": pStyleId = "Subtitle"
            case "h1": pStyleId = "Heading1"
            case "h2": pStyleId = "Heading2"
            case "h3": pStyleId = "Heading3"
            case "h4": pStyleId = "Heading4"
            case "quote": pStyleId = "Quote"
            case "intenseQuote": pStyleId = "IntenseQuote"
            case "caption": pStyleId = "Caption"
            case "code": pStyleId = "Code"
            default: break
            }

            var isList = false
            if let textList = ps?.textLists.first {
                isList = true
                let isOrdered = textList.markerFormat != .disc && textList.markerFormat != .circle && textList.markerFormat != .square && textList.markerFormat != .hyphen && textList.markerFormat != .diamond
                let numId: String
                if isOrdered {
                    if let current = activeOrderedNumId {
                        numId = current
                    } else {
                        let newId = String(nextOrderedNumId)
                        nextOrderedNumId += 1
                        orderedNumIds.append(newId)
                        activeOrderedNumId = newId
                        numId = newId
                    }
                } else {
                    activeOrderedNumId = nil
                    numId = "1"
                }
                let ilvl = max(0, min(8, Int(round(max(0, (ps?.headIndent ?? 28) - 28) / 20.0))))
                pStyleId = "ListParagraph"
                pPrParts.append("<w:pStyle w:val=\"ListParagraph\"/>")
                pPrParts.append("<w:numPr><w:ilvl w:val=\"\(ilvl)\"/><w:numId w:val=\"\(numId)\"/></w:numPr>")
            } else {
                activeOrderedNumId = nil
                if let pStyleId {
                    pPrParts.append("<w:pStyle w:val=\"\(pStyleId)\"/>")
                }
            }

            if blockKind == "quote" {
                pPrParts.append("<w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"10\" w:color=\"64748B\"/></w:pBdr>")
            } else if blockKind == "intenseQuote" {
                pPrParts.append("<w:pBdr><w:top w:val=\"single\" w:sz=\"6\" w:space=\"6\" w:color=\"2563EB\"/><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"6\" w:color=\"2563EB\"/></w:pBdr>")
            } else if blockKind == "code" {
                pPrParts.append("<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F1F5F9\"/>")
            }

            if let ps {
                var spAttrs: [String] = []
                if ps.paragraphSpacingBefore > 0 && pStyleId == nil {
                    spAttrs.append("w:before=\"\(Int(round(ps.paragraphSpacingBefore * 20)))\"")
                }
                if ps.paragraphSpacing > 0 && pStyleId == nil {
                    spAttrs.append("w:after=\"\(Int(round(ps.paragraphSpacing * 20)))\"")
                }
                if ps.lineHeightMultiple > 0 {
                    spAttrs.append("w:line=\"\(Int(round(ps.lineHeightMultiple * 240)))\" w:lineRule=\"auto\"")
                }
                if !spAttrs.isEmpty {
                    pPrParts.append("<w:spacing \(spAttrs.joined(separator: " "))/>")
                }

                if !isList && pStyleId == nil && ps.headIndent > 0 {
                    pPrParts.append("<w:ind w:left=\"\(Int(round(ps.headIndent * 20)))\"/>")
                }

                let jc: String?
                switch ps.alignment {
                case .center: jc = "center"
                case .right: jc = "right"
                case .justified: jc = "both"
                default: jc = nil
                }
                if let jc {
                    pPrParts.append("<w:jc w:val=\"\(jc)\"/>")
                }
            }

            let pPrXml = pPrParts.isEmpty ? "" : "<w:pPr>\(pPrParts.joined())</w:pPr>"
            var runsXml = serializeRuns(in: contentRange, stripListPrefix: isList)
            if contentRange.length == 0, let bms = attrs[.owBookmarks] as? [String], !bms.isEmpty {
                let tags = bookmarkTags(for: bms)
                runsXml += tags.start + tags.end
            }
            return "<w:p>\(pPrXml)\(runsXml)</w:p>"
        }

        // Group contiguous table paragraphs sharing the same NSTextTable instance
        var bodyContentXml = ""
        var i = 0
        while i < paraRanges.count {
            let r = paraRanges[i]
            let loc = min(r.location, max(0, fullStr.length - 1))
            let ps = fullStr.length > 0 ? (attributedString.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle) : nil
            if let firstBlock = ps?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                activeOrderedNumId = nil
                let table = firstBlock.table
                let tableId = ObjectIdentifier(table)
                var cellParas: [String: (block: NSTextTableBlock, paras: [NSRange])] = [:]
                var maxRow = 0
                var maxCol = max(1, table.numberOfColumns)

                while i < paraRanges.count {
                    let trRange = paraRanges[i]
                    let trLoc = min(trRange.location, max(0, fullStr.length - 1))
                    let trPs = fullStr.length > 0 ? (attributedString.attribute(.paragraphStyle, at: trLoc, effectiveRange: nil) as? NSParagraphStyle) : nil
                    guard let blk = trPs?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first,
                          ObjectIdentifier(blk.table) == tableId else {
                        break
                    }
                    let key = "\(blk.startingRow):\(blk.startingColumn)"
                    if var existing = cellParas[key] {
                        existing.paras.append(trRange)
                        cellParas[key] = existing
                    } else {
                        cellParas[key] = (blk, [trRange])
                    }
                    maxRow = max(maxRow, blk.startingRow)
                    maxCol = max(maxCol, blk.startingColumn + max(1, blk.columnSpan))
                    i += 1
                }

                let colW = max(360, contentWidthTwips / maxCol)
                let gridXml = (0..<maxCol).map { _ in "<w:gridCol w:w=\"\(colW)\"/>" }.joined()
                var rowsXml = ""
                for rowIdx in 0...maxRow {
                    let rowCells = cellParas.values
                        .filter { $0.block.startingRow == rowIdx }
                        .sorted { $0.block.startingColumn < $1.block.startingColumn }
                    guard !rowCells.isEmpty else { continue }
                    var cellsXml = ""
                    for entry in rowCells {
                        let span = max(1, entry.block.columnSpan)
                        let tcW = colW * span
                        var tcPr = "<w:tcW w:w=\"\(tcW)\" w:type=\"dxa\"/>"
                        if span > 1 { tcPr += "<w:gridSpan w:val=\"\(span)\"/>" }
                        if let bg = entry.block.backgroundColor, let hex = bg.hexRRGGBB, hex != "FFFFFF" {
                            tcPr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(hex)\"/>"
                        }
                        let innerXml = entry.paras.map { serializeParagraph(range: $0) }.joined()
                        cellsXml += "<w:tc><w:tcPr>\(tcPr)</w:tcPr>\(innerXml.isEmpty ? "<w:p/>" : innerXml)</w:tc>"
                    }
                    rowsXml += "<w:tr>\(cellsXml)</w:tr>"
                }

                bodyContentXml += """
                <w:tbl>
                  <w:tblPr>
                    <w:tblW w:w="\(contentWidthTwips)" w:type="dxa"/>
                    <w:tblBorders>
                      <w:top w:val="single" w:sz="6" w:space="0" w:color="CBD5E1"/>
                      <w:left w:val="single" w:sz="6" w:space="0" w:color="CBD5E1"/>
                      <w:bottom w:val="single" w:sz="6" w:space="0" w:color="CBD5E1"/>
                      <w:right w:val="single" w:sz="6" w:space="0" w:color="CBD5E1"/>
                      <w:insideH w:val="single" w:sz="6" w:space="0" w:color="CBD5E1"/>
                      <w:insideV w:val="single" w:sz="6" w:space="0" w:color="CBD5E1"/>
                    </w:tblBorders>
                    <w:tblCellMar>
                      <w:top w:w="80" w:type="dxa"/><w:left w:w="120" w:type="dxa"/>
                      <w:bottom w:w="80" w:type="dxa"/><w:right w:w="120" w:type="dxa"/>
                    </w:tblCellMar>
                  </w:tblPr>
                  <w:tblGrid>\(gridXml)</w:tblGrid>
                  \(rowsXml)
                </w:tbl>
                """
                continue
            }

            // Skip synthetic final empty newline if previous paragraph already ended with \n
            if i == paraRanges.count - 1 && r.length == 0 && i > 0 {
                i += 1
                continue
            }
            bodyContentXml += serializeParagraph(range: r)
            i += 1
        }

        if bodyContentXml.isEmpty {
            bodyContentXml = "<w:p/>"
        }

        var archive: [String: Data] = [:]
        var sectPrParts: [String] = []
        var extraOverrides = ""

        let cleanHdr = headerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanHdr.isEmpty {
            let rId = allocRelId()
            relsXmlItems.append("<Relationship Id=\"\(rId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/>")
            extraOverrides += "\n  <Override PartName=\"/word/header1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml\"/>"
            sectPrParts.append("<w:headerReference w:type=\"default\" r:id=\"\(rId)\"/>")
            archive["word/header1.xml"] = Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:rPr><w:color w:val="64748B"/><w:sz w:val="18"/></w:rPr><w:t>\(xmlEscape(cleanHdr))</w:t></w:r></w:p>
            </w:hdr>
            """.utf8)
        }

        let cleanFtr = footerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanFtr.isEmpty {
            let rId = allocRelId()
            relsXmlItems.append("<Relationship Id=\"\(rId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>")
            extraOverrides += "\n  <Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>"
            sectPrParts.append("<w:footerReference w:type=\"default\" r:id=\"\(rId)\"/>")
            archive["word/footer1.xml"] = Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:color w:val="64748B"/><w:sz w:val="18"/></w:rPr><w:t>\(xmlEscape(cleanFtr))</w:t></w:r></w:p>
            </w:ftr>
            """.utf8)
        }

        let orientAttr = isLandscape ? " w:orient=\"landscape\"" : ""
        sectPrParts.append("<w:pgSz w:w=\"\(pageW)\" w:h=\"\(pageH)\"\(orientAttr)/>")
        sectPrParts.append("<w:pgMar w:top=\"\(marTop)\" w:right=\"\(marRight)\" w:bottom=\"\(marBottom)\" w:left=\"\(marLeft)\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/>")

        let documentXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>
            \(bodyContentXml)
            <w:sectPr>\(sectPrParts.joined())</w:sectPr>
          </w:body>
        </w:document>
        """

        let pngDefault = mediaEntries.isEmpty ? "" : "\n  <Default Extension=\"png\" ContentType=\"image/png\"/>"
        let contentTypesXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>\(pngDefault)
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
          <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\(extraOverrides)
        </Types>
        """

        let rootRelsXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        </Relationships>
        """

        let documentRelsXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          \(relsXmlItems.joined(separator: "\n  "))
        </Relationships>
        """

        let isoFmt = ISO8601DateFormatter()
        let nowIso = isoFmt.string(from: Date())
        let coreXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <dc:title>\(xmlEscape(title))</dc:title>
          <dc:creator>OfficeWord</dc:creator>
          <dcterms:created xsi:type="dcterms:W3CDTF">\(nowIso)</dcterms:created>
          <dcterms:modified xsi:type="dcterms:W3CDTF">\(nowIso)</dcterms:modified>
        </cp:coreProperties>
        """

        archive["[Content_Types].xml"] = Data(contentTypesXml.utf8)
        archive["_rels/.rels"] = Data(rootRelsXml.utf8)
        archive["docProps/core.xml"] = Data(coreXml.utf8)
        archive["word/document.xml"] = Data(documentXml.utf8)
        archive["word/styles.xml"] = Data(buildStylesXml().utf8)
        archive["word/numbering.xml"] = Data(buildNumberingXml(orderedNumIds: orderedNumIds).utf8)
        archive["word/_rels/document.xml.rels"] = Data(documentRelsXml.utf8)
        for (k, v) in mediaEntries {
            archive[k] = v
        }

        return try PureZip.write(entries: archive)
    }

    // MARK: - Private OpenXML Parsers
    private static func findEntry(_ entries: [String: Data], path: String) -> Data? {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let exact = entries[clean] { return exact }
        let lower = clean.lowercased()
        return entries.first { $0.key.lowercased() == lower }?.value
    }

    private static func resolveWordPath(_ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        let parts = ["word"] + target.split(separator: "/").map(String.init)
        var resolved: [String] = []
        for p in parts {
            if p == "." || p.isEmpty { continue }
            if p == ".." { _ = resolved.popLast() }
            else { resolved.append(p) }
        }
        return resolved.joined(separator: "/")
    }

    private static func parseRelationships(_ data: Data?) -> [String: (type: String, target: String)] {
        guard let data, let doc = try? XMLDocument(data: data, options: []), let root = doc.rootElement() else {
            return [:]
        }
        var out: [String: (String, String)] = [:]
        for rel in root.descendants(localName: "Relationship") {
            if let id = rel.attr("Id") {
                out[id] = (rel.attr("Type") ?? "", rel.attr("Target") ?? "")
            }
        }
        return out
    }

    private static func registerEmbeddedDocxFonts(entries: [String: Data]) {
        guard let ftData = findEntry(entries, path: "word/fontTable.xml"),
              let ftDoc = try? XMLDocument(data: ftData, options: []),
              let ftRoot = ftDoc.rootElement() else {
            return
        }
        let ftRels = parseRelationships(findEntry(entries, path: "word/_rels/fontTable.xml.rels"))
        let embedTags = ["embedRegular", "embedBold", "embedItalic", "embedBoldItalic"]
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("OfficeWordEmbeddedFonts")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        var toRegister: [URL] = []
        for fontEl in ftRoot.children(localName: "font") {
            let fontName = (fontEl.attr("name") ?? "font").replacingOccurrences(of: "/", with: "_")
            for tag in embedTags {
                guard let embedEl = fontEl.child(localName: tag),
                      let rId = embedEl.attr("id"),
                      let target = ftRels[rId]?.target else { continue }
                let path = resolveWordPath(target)
                guard var rawData = findEntry(entries, path: path), !rawData.isEmpty else { continue }
                if let fontKey = embedEl.attr("fontKey"), !fontKey.isEmpty {
                    rawData = deobfuscateOdttf(rawData, guidString: fontKey)
                }
                let outFile = cacheDir.appendingPathComponent("\(fontName)-\(tag)-\(rId).ttf")
                if !FileManager.default.fileExists(atPath: outFile.path) {
                    try? rawData.write(to: outFile, options: .atomic)
                }
                toRegister.append(outFile)
            }
        }
        if !toRegister.isEmpty {
            registerFontURLs(toRegister)
        }
    }

    private static func deobfuscateOdttf(_ data: Data, guidString: String) -> Data {
        let hex = guidString.filter { $0.isHexDigit }
        guard hex.count == 32, data.count >= 32 else { return data }
        var keyBytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            if let b = UInt8(String(hex[idx..<next]), radix: 16) {
                keyBytes.append(b)
            }
            idx = next
        }
        guard keyBytes.count == 16 else { return data }
        let reversedKey = Array(keyBytes.reversed())
        var out = data
        for i in 0..<32 {
            out[i] ^= reversedKey[i % 16]
        }
        return out
    }

    private static func parseThemeFonts(entries: [String: Data], rels: [String: (type: String, target: String)]) -> (major: String, minor: String) {
        var themePath = "word/theme/theme1.xml"
        for (_, rel) in rels {
            if rel.type.lowercased().hasSuffix("/theme") || rel.target.lowercased().contains("theme/") {
                themePath = resolveWordPath(rel.target)
                break
            }
        }
        guard let data = findEntry(entries, path: themePath),
              let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement(),
              let scheme = root.descendants(localName: "fontScheme").first else {
            return ("Calibri Light", "Calibri")
        }
        func pickFont(in containerName: String, fallback: String) -> String {
            guard let el = scheme.descendants(localName: containerName).first else { return fallback }
            if let latin = el.child(localName: "latin")?.attr("typeface")?.trimmingCharacters(in: .whitespaces), !latin.isEmpty {
                return latin
            }
            for f in el.children(localName: "font") {
                if f.attr("script")?.lowercased() == "latn",
                   let tf = f.attr("typeface")?.trimmingCharacters(in: .whitespaces),
                   !tf.isEmpty {
                    return tf
                }
            }
            return fallback
        }
        return (pickFont(in: "majorFont", fallback: "Calibri Light"), pickFont(in: "minorFont", fallback: "Calibri"))
    }

    private static func isToggleOn(_ el: XMLElement?) -> Bool? {
        guard let el else { return nil }
        guard let val = el.attr("val")?.lowercased() else { return true }
        return val != "0" && val != "false" && val != "off" && val != "none"
    }

    private static func extractRPr(_ el: XMLElement?, themeFonts: (major: String, minor: String) = ("Calibri Light", "Calibri")) -> RunProps {
        guard let el else { return RunProps() }
        var rp = RunProps()
        rp.rStyle = el.child(localName: "rStyle")?.attr("val")
        rp.bold = isToggleOn(el.child(localName: "b"))
        rp.italic = isToggleOn(el.child(localName: "i"))
        if let u = el.child(localName: "u") {
            let val = (u.attr("val") ?? "single").lowercased()
            rp.underline = val != "none" && val != "0" && val != "false"
        }
        if let st = el.child(localName: "strike") ?? el.child(localName: "dstrike") {
            rp.strike = isToggleOn(st)
        }
        if let va = el.child(localName: "vertAlign")?.attr("val")?.lowercased() {
            if va == "superscript" { rp.superscriptVal = 1 }
            else if va == "subscript" { rp.superscriptVal = -1 }
        }
        if let fonts = el.child(localName: "rFonts") {
            if let explicit = fonts.attr("ascii") ?? fonts.attr("hAnsi") ?? fonts.attr("cs"), !explicit.isEmpty {
                rp.fontFamily = explicit
            } else if let themeKey = fonts.attr("asciiTheme") ?? fonts.attr("hAnsiTheme") ?? fonts.attr("cstheme") ?? fonts.attr("csTheme") {
                let lower = themeKey.lowercased()
                if lower.hasPrefix("major") {
                    rp.fontFamily = themeFonts.major
                } else if lower.hasPrefix("minor") {
                    rp.fontFamily = themeFonts.minor
                }
            }
        }
        if let sz = el.child(localName: "sz")?.attr("val"), let half = Double(sz), half > 0 {
            rp.fontSizePt = CGFloat(half / 2.0)
        }
        if let colorVal = el.child(localName: "color")?.attr("val") {
            rp.color = NSColor.fromHex(colorVal)
        }
        if let hlVal = el.child(localName: "highlight")?.attr("val"), hlVal != "none" {
            rp.highlight = NSColor.fromHex(wordHighlightHex[hlVal] ?? hlVal)
        } else if let fill = el.child(localName: "shd")?.attr("fill"), fill.uppercased() != "FFFFFF" {
            rp.highlight = NSColor.fromHex(fill)
        }
        return rp
    }

    private static func extractPPr(_ el: XMLElement?, themeFonts: (major: String, minor: String) = ("Calibri Light", "Calibri")) -> ParaProps {
        guard let el else { return ParaProps() }
        var pp = ParaProps()
        pp.pStyle = el.child(localName: "pStyle")?.attr("val")
        if let jc = el.child(localName: "jc")?.attr("val")?.lowercased() {
            switch jc {
            case "center": pp.align = .center
            case "right", "end": pp.align = .right
            case "both", "distribute": pp.align = .justified
            case "left", "start": pp.align = .left
            default: break
            }
        }
        if let sp = el.child(localName: "spacing") {
            if let b = sp.attr("before"), let v = Double(b) { pp.spaceBeforePt = CGFloat(max(0, v) / 20.0) }
            if let a = sp.attr("after"), let v = Double(a) { pp.spaceAfterPt = CGFloat(max(0, v) / 20.0) }
            if let l = sp.attr("line"), let v = Double(l), v > 0 {
                let rule = (sp.attr("lineRule") ?? "auto").lowercased()
                if rule == "auto" {
                    pp.lineHeightMultiple = CGFloat(v / 240.0)
                } else if rule == "exact" {
                    let pt = CGFloat(v / 20.0)
                    pp.minLineHeightPt = pt
                    pp.maxLineHeightPt = pt
                } else if rule == "atleast" {
                    pp.minLineHeightPt = CGFloat(v / 20.0)
                }
            }
        }
        if let ind = el.child(localName: "ind") {
            if let l = ind.attr("left") ?? ind.attr("start"), let v = Double(l), v > 0 {
                pp.leftIndentPt = CGFloat(v / 20.0)
            }
            if let f = ind.attr("firstLine"), let v = Double(f), v > 0 {
                pp.firstLineIndentPt = CGFloat(v / 20.0)
            }
        }
        if let pbb = el.child(localName: "pageBreakBefore") {
            let val = pbb.attr("val")?.lowercased()
            pp.pageBreakBefore = (val == nil || val == "1" || val == "true" || val == "on")
        }
        if let ol = el.child(localName: "outlineLvl")?.attr("val"), let lvl = Int(ol) {
            pp.outlineLvl = lvl
        }
        if let bdr = el.child(localName: "pBdr") {
            if let b = bdr.child(localName: "bottom"), (b.attr("val") ?? "") != "none" { pp.hasBottomBorder = true }
            if let l = bdr.child(localName: "left"), (l.attr("val") ?? "") != "none" { pp.hasLeftBorder = true }
        }
        if let numPr = el.child(localName: "numPr"),
           let numId = numPr.child(localName: "numId")?.attr("val"),
           numId != "0" {
            pp.numId = numId
            pp.ilvl = max(0, min(8, Int(numPr.child(localName: "ilvl")?.attr("val") ?? "0") ?? 0))
        }
        if let rPr = el.child(localName: "rPr") {
            pp.rPr = extractRPr(rPr, themeFonts: themeFonts)
        }
        return pp
    }

    private struct TableStyleDef {
        var name: String = ""
        var pPr: ParaProps = ParaProps()
        var rPr: RunProps = RunProps()
        var cellMargins: CellMarginsPt = CellMarginsPt()
        var borderPt: CGFloat? = nil
        var borderColor: NSColor? = nil

        func merged(over parent: TableStyleDef?) -> TableStyleDef {
            TableStyleDef(
                name: name.isEmpty ? (parent?.name ?? "") : name,
                pPr: (parent?.pPr ?? ParaProps()).merged(with: pPr),
                rPr: (parent?.rPr ?? RunProps()).merged(with: rPr),
                cellMargins: (parent?.cellMargins ?? CellMarginsPt()).merged(with: cellMargins),
                borderPt: borderPt ?? parent?.borderPt,
                borderColor: borderColor ?? parent?.borderColor
            )
        }
    }

    private struct ParsedStyles {
        var defaultPPr: ParaProps = ParaProps()
        var defaultRPr: RunProps = RunProps()
        var defaultParagraphStyleId: String? = nil
        var defaultTableStyleId: String? = nil
        var styles: [String: (name: String, pPr: ParaProps, rPr: RunProps)] = [:]
        var tableStyles: [String: TableStyleDef] = [:]
    }

    private static func extractCellMarginsPt(_ el: XMLElement?) -> CellMarginsPt {
        guard let el else { return CellMarginsPt() }
        func dxaPt(_ names: [String]) -> CGFloat? {
            for name in names {
                guard let child = el.child(localName: name) else { continue }
                let unit = (child.attr("type") ?? "dxa").lowercased()
                if unit == "nil" { return 0 }
                if (unit == "dxa" || unit.isEmpty), let v = Double(child.attr("w") ?? "") {
                    return max(0, CGFloat(v / 20.0))
                }
            }
            return nil
        }
        return CellMarginsPt(
            top: dxaPt(["top"]),
            right: dxaPt(["right", "end"]),
            bottom: dxaPt(["bottom"]),
            left: dxaPt(["left", "start"])
        )
    }

    private static func extractTableBorders(_ el: XMLElement?) -> (pt: CGFloat?, color: NSColor?) {
        guard let el else { return (nil, nil) }
        var maxPt: CGFloat? = nil
        var firstColor: NSColor? = nil
        var anyVisible = false
        var anyExplicitNil = false
        for side in ["top", "left", "start", "bottom", "right", "end", "insideH", "insideV"] {
            guard let edge = el.child(localName: side) else { continue }
            let val = (edge.attr("val") ?? "").lowercased()
            if val == "none" || val == "nil" {
                anyExplicitNil = true
                continue
            }
            anyVisible = true
            let sz = Double(edge.attr("sz") ?? "4") ?? 4.0
            let pt = max(0.25, CGFloat(sz / 8.0))
            maxPt = max(maxPt ?? 0, pt)
            if firstColor == nil, let hex = edge.attr("color"), let c = NSColor.fromHex(hex) {
                firstColor = c
            }
        }
        if anyVisible { return (maxPt ?? 0.5, firstColor) }
        if anyExplicitNil { return (0, nil) }
        return (nil, nil)
    }

    private static func parseStyles(_ data: Data?, themeFonts: (major: String, minor: String) = ("Calibri Light", "Calibri")) -> ParsedStyles {
        var parsed = ParsedStyles()
        guard let data, let doc = try? XMLDocument(data: data, options: []), let root = doc.rootElement() else {
            return parsed
        }
        if let docDefaults = root.child(localName: "docDefaults") {
            if let r = docDefaults.descendants(localName: "rPr").first { parsed.defaultRPr = extractRPr(r, themeFonts: themeFonts) }
            if let p = docDefaults.descendants(localName: "pPr").first { parsed.defaultPPr = extractPPr(p, themeFonts: themeFonts) }
        }

        var raw: [String: (name: String, basedOn: String, pPr: ParaProps, rPr: RunProps)] = [:]
        var rawTables: [String: (basedOn: String, def: TableStyleDef)] = [:]
        for st in root.children(localName: "style") {
            guard let id = st.attr("styleId") else { continue }
            let type = (st.attr("type") ?? "paragraph").lowercased()
            let defaultAttr = (st.attr("default") ?? "").lowercased()
            let isDefault = (defaultAttr == "1" || defaultAttr == "true" || defaultAttr == "on")
            let name = st.child(localName: "name")?.attr("val") ?? ""
            let basedOn = st.child(localName: "basedOn")?.attr("val") ?? ""
            let pPr = extractPPr(st.child(localName: "pPr"), themeFonts: themeFonts)
            let rPr = extractRPr(st.child(localName: "rPr"), themeFonts: themeFonts)

            if isDefault {
                if type == "paragraph" && parsed.defaultParagraphStyleId == nil {
                    parsed.defaultParagraphStyleId = id
                } else if type == "table" && parsed.defaultTableStyleId == nil {
                    parsed.defaultTableStyleId = id
                }
            }

            if type == "table" {
                let tblPr = st.child(localName: "tblPr")
                let margins = extractCellMarginsPt(tblPr?.child(localName: "tblCellMar"))
                let borders = extractTableBorders(tblPr?.child(localName: "tblBorders"))
                rawTables[id] = (
                    basedOn,
                    TableStyleDef(name: name, pPr: pPr, rPr: rPr, cellMargins: margins, borderPt: borders.pt, borderColor: borders.color)
                )
            } else {
                raw[id] = (name, basedOn, pPr, rPr)
            }
        }

        func resolve(_ id: String, seen: Set<String> = []) -> (name: String, pPr: ParaProps, rPr: RunProps)? {
            if let hit = parsed.styles[id] { return hit }
            guard let item = raw[id], !seen.contains(id) else { return nil }
            var nextSeen = seen
            nextSeen.insert(id)
            let parent = item.basedOn.isEmpty ? nil : resolve(item.basedOn, seen: nextSeen)
            let mergedP = (parent?.pPr ?? ParaProps()).merged(with: item.pPr)
            let mergedR = (parent?.rPr ?? RunProps()).merged(with: item.rPr)
            let val = (item.name, mergedP, mergedR)
            parsed.styles[id] = val
            return val
        }
        for id in raw.keys { _ = resolve(id) }

        func resolveTable(_ id: String, seen: Set<String> = []) -> TableStyleDef? {
            if let hit = parsed.tableStyles[id] { return hit }
            guard let item = rawTables[id], !seen.contains(id) else { return nil }
            var nextSeen = seen
            nextSeen.insert(id)
            let parent = item.basedOn.isEmpty ? nil : resolveTable(item.basedOn, seen: nextSeen)
            let val = item.def.merged(over: parent)
            parsed.tableStyles[id] = val
            return val
        }
        for id in rawTables.keys { _ = resolveTable(id) }

        return parsed
    }

    private static func parseNumbering(_ data: Data?) -> [String: [Int: (numFmt: String, start: Int)]] {
        guard let data, let doc = try? XMLDocument(data: data, options: []), let root = doc.rootElement() else {
            return [:]
        }
        var abstracts: [String: [Int: (String, Int)]] = [:]
        for abs in root.children(localName: "abstractNum") {
            guard let absId = abs.attr("abstractNumId") else { continue }
            var levels: [Int: (String, Int)] = [:]
            for lvl in abs.children(localName: "lvl") {
                let ilvl = Int(lvl.attr("ilvl") ?? "0") ?? 0
                let fmt = lvl.child(localName: "numFmt")?.attr("val") ?? "bullet"
                let start = Int(lvl.child(localName: "start")?.attr("val") ?? "1") ?? 1
                levels[ilvl] = (fmt, start)
            }
            abstracts[absId] = levels
        }

        var nums: [String: [Int: (String, Int)]] = [:]
        for num in root.children(localName: "num") {
            guard let numId = num.attr("numId"),
                  let absId = num.child(localName: "abstractNumId")?.attr("val"),
                  let levels = abstracts[absId] else { continue }
            nums[numId] = levels
        }
        return nums
    }

    private static func parsePageSetup(_ sectPr: XMLElement?) -> DocPageSetup {
        var setup = DocPageSetup()
        guard let sectPr else { return setup }
        if let pgSz = sectPr.child(localName: "pgSz") {
            let w = Int(pgSz.attr("w") ?? "0") ?? 0
            let h = Int(pgSz.attr("h") ?? "0") ?? 0
            let orient = (pgSz.attr("orient") ?? "").lowercased()
            if orient == "landscape" || (w > h && w > 0 && h > 0) {
                setup.orientation = .landscape
            }
            let shortSide = min(w, h)
            let longSide = max(w, h)
            if abs(shortSide - 12240) < 160 && abs(longSide - 15840) < 160 {
                setup.size = .letter
            } else if abs(shortSide - 12240) < 160 && abs(longSide - 20160) < 200 {
                setup.size = .legal
            } else if abs(shortSide - 11906) < 160 && abs(longSide - 16838) < 160 {
                setup.size = .a4
            } else if w > 0 && h > 0 {
                setup.size = .a4
                setup.customSizePt = NSSize(width: CGFloat(shortSide) / 20.0, height: CGFloat(longSide) / 20.0)
            } else {
                setup.size = .a4
            }
        }
        if let pgMar = sectPr.child(localName: "pgMar") {
            let twipToMm: (String?, Double) -> Double = { str, fallback in
                guard let str, let v = Double(str) else { return fallback }
                return round((abs(v) / 56.6929) * 10.0) / 10.0
            }
            setup.marginTopMm = twipToMm(pgMar.attr("top"), 25.0)
            setup.marginRightMm = twipToMm(pgMar.attr("right"), 25.0)
            setup.marginBottomMm = twipToMm(pgMar.attr("bottom"), 25.0)
            setup.marginLeftMm = twipToMm(pgMar.attr("left"), 25.0)
        }
        return setup
    }

    private static func classifyBlockKind(styleId: String?, styleName: String?, pPr: ParaProps) -> String? {
        let id = (styleId ?? "").lowercased()
        let name = (styleName ?? "").lowercased()
        if id == "nospacing" || name == "no spacing" || name == "sin espaciado" { return "noSpacing" }
        if id == "title" || name == "title" { return "title" }
        if id == "subtitle" || name == "subtitle" { return "subtitle" }
        if id == "intensequote" || name == "intense quote" { return "intenseQuote" }
        if id.contains("quote") || name.contains("quote") || pPr.hasLeftBorder { return "quote" }
        if id == "caption" || name == "caption" { return "caption" }
        if id == "code" || name == "code" { return "code" }
        if id == "heading1" || name == "heading 1" || pPr.outlineLvl == 0 { return "h1" }
        if id == "heading2" || name == "heading 2" || pPr.outlineLvl == 1 { return "h2" }
        if id == "heading3" || name == "heading 3" || pPr.outlineLvl == 2 { return "h3" }
        if id == "heading4" || name == "heading 4" || pPr.outlineLvl == 3 { return "h4" }
        return nil
    }

    private static func buildStylesXml() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:docDefaults>
            <w:rPrDefault>
              <w:rPr>
                <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>
                <w:sz w:val="23"/><w:szCs w:val="23"/>
                <w:lang w:val="es-ES" w:eastAsia="en-US" w:bidi="ar-SA"/>
              </w:rPr>
            </w:rPrDefault>
            <w:pPrDefault>
              <w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr>
            </w:pPrDefault>
          </w:docDefaults>
          <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
          <w:style w:type="paragraph" w:styleId="NoSpacing">
            <w:name w:val="No Spacing"/><w:basedOn w:val="Normal"/><w:qFormat/>
            <w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Title">
            <w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
            <w:pPr><w:spacing w:before="80" w:after="160"/></w:pPr>
            <w:rPr><w:b/><w:color w:val="0F172A"/><w:sz w:val="52"/><w:szCs w:val="52"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Subtitle">
            <w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
            <w:pPr><w:spacing w:after="240"/></w:pPr>
            <w:rPr><w:i/><w:color w:val="475569"/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading1">
            <w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
            <w:pPr><w:keepNext/><w:spacing w:before="280" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr>
            <w:rPr><w:b/><w:color w:val="1E3A8A"/><w:sz w:val="40"/><w:szCs w:val="40"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading2">
            <w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
            <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr>
            <w:rPr><w:b/><w:color w:val="1E40AF"/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading3">
            <w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
            <w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr>
            <w:rPr><w:b/><w:color w:val="1F2937"/><w:sz w:val="25"/><w:szCs w:val="25"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading4">
            <w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
            <w:pPr><w:keepNext/><w:spacing w:before="160" w:after="80"/><w:outlineLvl w:val="3"/></w:pPr>
            <w:rPr><w:b/><w:i/><w:color w:val="334155"/><w:sz w:val="23"/><w:szCs w:val="23"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Quote">
            <w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
            <w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="10" w:color="64748B"/></w:pBdr><w:spacing w:before="120" w:after="120"/><w:ind w:left="360"/></w:pPr>
            <w:rPr><w:i/><w:color w:val="334155"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="IntenseQuote">
            <w:name w:val="Intense Quote"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
            <w:pPr><w:pBdr><w:top w:val="single" w:sz="6" w:space="6" w:color="2563EB"/><w:bottom w:val="single" w:sz="6" w:space="6" w:color="2563EB"/></w:pBdr><w:spacing w:before="200" w:after="200"/><w:jc w:val="center"/></w:pPr>
            <w:rPr><w:b/><w:i/><w:color w:val="1D4ED8"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Caption">
            <w:name w:val="caption"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
            <w:pPr><w:spacing w:before="40" w:after="120"/></w:pPr>
            <w:rPr><w:i/><w:color w:val="64748B"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Code">
            <w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:qFormat/>
            <w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F1F5F9"/><w:spacing w:before="120" w:after="120"/><w:ind w:left="240"/></w:pPr>
            <w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:color w:val="0F172A"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="ListParagraph">
            <w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/>
            <w:pPr><w:ind w:left="720"/></w:pPr>
          </w:style>
        </w:styles>
        """
    }

    private static func buildNumberingXml(orderedNumIds: [String]) -> String {
        let bullets = ["•", "◦", "▪", "•", "◦", "▪", "•", "◦", "▪"]
        let bulletLvls = bullets.enumerated().map { lvl, g in
            "<w:lvl w:ilvl=\"\(lvl)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(xmlEscape(g))\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 * (lvl + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }.joined(separator: "\n    ")

        let fmts = ["decimal", "lowerLetter", "lowerRoman", "decimal", "lowerLetter", "lowerRoman", "decimal", "lowerLetter", "lowerRoman"]
        let ordLvls = fmts.enumerated().map { lvl, fmt in
            "<w:lvl w:ilvl=\"\(lvl)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(fmt)\"/><w:lvlText w:val=\"%\(lvl + 1).\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 * (lvl + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }.joined(separator: "\n    ")

        let extraNums = orderedNumIds.map { id in
            "  <w:num w:numId=\"\(id)\"><w:abstractNumId w:val=\"2\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>
            \(bulletLvls)
          </w:abstractNum>
          <w:abstractNum w:abstractNumId="2"><w:multiLevelType w:val="hybridMultilevel"/>
            \(ordLvls)
          </w:abstractNum>
          <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
        \(extraNums)
        </w:numbering>
        """
    }

    // MARK: - Internal Bookmarks, Fields & Anchor Navigation
    private static func makeAnchorURL(_ anchor: String) -> URL? {
        let trimmed = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: "#\(encoded)") {
            return url
        }
        return nil
    }

    private static func makeExternalOrRelativeURL(_ target: String) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") {
            return makeAnchorURL(String(trimmed.dropFirst()))
        }
        if let url = URL(string: trimmed) { return url }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: encoded)
        }
        return nil
    }

    private static func parseFieldHyperlinkURL(from instr: String) -> URL? {
        let trimmed = instr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^HYPERLINK\b"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }

        var anchor: String?
        if let r = trimmed.range(of: #"(?:^|\s)\\l\s+(?:"([^"]+)"|([^\s\\]+))"#, options: .regularExpression) {
            let sub = String(trimmed[r])
            if let q = sub.range(of: #""([^"]+)""#, options: .regularExpression) {
                anchor = String(sub[q].dropFirst().dropLast())
            } else {
                anchor = sub.split(whereSeparator: { $0.isWhitespace }).last.map(String.init)
            }
        }

        let afterCmd = trimmed.replacingOccurrences(of: #"^(?i)HYPERLINK\s*"#, with: "", options: .regularExpression)
        var extTarget: String?
        if !afterCmd.hasPrefix("\\") {
            if afterCmd.hasPrefix("\"") {
                let rest = afterCmd.dropFirst()
                if let endQ = rest.firstIndex(of: "\"") {
                    extTarget = String(rest[..<endQ])
                }
            } else if let tok = afterCmd.split(whereSeparator: { $0.isWhitespace }).first, !tok.hasPrefix("\\") {
                extTarget = String(tok)
            }
        }

        if let ext = extTarget, !ext.isEmpty {
            let full = anchor.flatMap { a -> String in
                let enc = a.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? a
                return ext.contains("#") ? ext : "\(ext)#\(enc)"
            } ?? ext
            return makeExternalOrRelativeURL(full)
        }
        if let anchor {
            return makeAnchorURL(anchor)
        }
        return nil
    }

    /// Resolves an internal `.docx` anchor or TOC link click to the target paragraph range in `attributedString`.
    static func resolveAnchorLocation(
        anchor: String,
        linkText: String,
        sourceRange: NSRange,
        in attributedString: NSAttributedString
    ) -> NSRange? {
        let nsStr = attributedString.string as NSString
        guard nsStr.length > 0 else { return nil }
        let fullRange = NSRange(location: 0, length: nsStr.length)
        let cleanAnchor = anchor.trimmingCharacters(in: .whitespacesAndNewlines)

        func trimControlBreaks(_ range: NSRange) -> NSRange {
            var r = range
            while r.length > 0 {
                let head = nsStr.substring(with: NSRange(location: r.location, length: 1))
                if head == "\u{000C}" || head == "\n" || head == "\r" {
                    r.location += 1
                    r.length -= 1
                } else {
                    break
                }
            }
            while r.length > 0 {
                let tail = nsStr.substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1))
                if tail == "\n" || tail == "\r" || tail == "\u{000C}" {
                    r.length -= 1
                } else {
                    break
                }
            }
            return r
        }

        func targetHighlightRange(near location: Int) -> NSRange {
            let safeLoc = max(0, min(location, max(0, nsStr.length - 1)))
            let para = trimControlBreaks(nsStr.paragraphRange(for: NSRange(location: safeLoc, length: 0)))
            return para.length > 0 ? para : NSRange(location: safeLoc, length: 0)
        }

        // 1. Exact or case-insensitive bookmark match stored from `<w:bookmarkStart w:name="...">`
        if !cleanAnchor.isEmpty {
            var exactLoc: Int?
            var ciLoc: Int?
            attributedString.enumerateAttribute(.owBookmarks, in: fullRange, options: []) { val, subRange, stop in
                guard let names = val as? [String], !names.isEmpty else { return }
                if NSIntersectionRange(subRange, sourceRange).length > 0 { return }
                if names.contains(cleanAnchor) {
                    exactLoc = subRange.location
                    stop.pointee = true
                    return
                }
                if ciLoc == nil && names.contains(where: { $0.caseInsensitiveCompare(cleanAnchor) == .orderedSame }) {
                    ciLoc = subRange.location
                }
            }
            if let hit = exactLoc ?? ciLoc {
                return targetHighlightRange(near: hit)
            }
        }

        // 2. Fallback: match non-link headings/paragraphs by normalized TOC link title or slug anchor
        func normalizeKey(_ s: String, stripTrailingPageNumber: Bool = false) -> String {
            var work = s
            if stripTrailingPageNumber {
                work = work.replacingOccurrences(of: #"(?:\t+\s*|\s*\.{2,}\s*)\d{1,4}\s*$"#, with: "", options: .regularExpression)
            }
            work = work.replacingOccurrences(of: #"[\t\r\n\u{000C}]+"#, with: " ", options: .regularExpression)
            work = work.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            work = work.trimmingCharacters(in: .whitespacesAndNewlines)
            return work.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }

        func stripLeadingOutlineNumber(_ s: String) -> String {
            s.replacingOccurrences(of: #"^(?:\d+(?:\.\d+)*\.?\s+|[ivxlcdm]+\.\s+)"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let trimmedLinkText = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullSourcePara = nsStr.paragraphRange(for: NSRange(location: max(0, min(sourceRange.location, nsStr.length - 1)), length: 0))
        let sourceParaText = nsStr.substring(with: fullSourcePara)
        let primaryQueryText = trimmedLinkText.isEmpty ? sourceParaText : trimmedLinkText

        let linkKey = normalizeKey(primaryQueryText, stripTrailingPageNumber: true)
        let linkKeyLoose = normalizeKey(primaryQueryText.replacingOccurrences(of: #"\s+\d{1,4}\s*$"#, with: "", options: .regularExpression))
        let linkNoNumKey = stripLeadingOutlineNumber(linkKey)

        let isGeneratedIdAnchor = cleanAnchor.hasPrefix("_Toc") || cleanAnchor.hasPrefix("_Ref") || cleanAnchor.hasPrefix("_Hlk") || cleanAnchor.hasPrefix("_GoBack")
        let anchorKey = isGeneratedIdAnchor ? "" : normalizeKey(
            cleanAnchor.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        )

        var bestScore = 0
        var bestRange: NSRange?
        var pos = 0
        while pos < nsStr.length {
            let paraRange = nsStr.paragraphRange(for: NSRange(location: pos, length: 0))
            pos = NSMaxRange(paraRange)
            if NSIntersectionRange(paraRange, sourceRange).length > 0 { continue }

            let trimmedPara = trimControlBreaks(paraRange)
            guard trimmedPara.length > 0 else { continue }

            let paraText = nsStr.substring(with: trimmedPara)
            let paraKey = normalizeKey(paraText)
            guard !paraKey.isEmpty else { continue }

            // Skip paragraphs whose primary text is itself a TOC hyperlink
            var linkCharCount = 0
            attributedString.enumerateAttribute(.link, in: trimmedPara, options: []) { val, subRange, _ in
                if val != nil { linkCharCount += subRange.length }
            }
            if linkCharCount * 2 >= trimmedPara.length { continue }

            let kind = attributedString.attribute(.owBlockKind, at: trimmedPara.location, effectiveRange: nil) as? String ?? ""
            let isHeading = ["title", "subtitle", "h1", "h2", "h3", "h4"].contains(kind)
            let paraNoNumKey = stripLeadingOutlineNumber(paraKey)

            var score = 0
            if !linkKey.isEmpty && paraKey == linkKey {
                score = isHeading ? 100 : 90
            } else if !linkKeyLoose.isEmpty && paraKey == linkKeyLoose {
                score = isHeading ? 92 : 82
            } else if !linkNoNumKey.isEmpty && linkNoNumKey.count >= 3 && paraNoNumKey == linkNoNumKey {
                score = isHeading ? 85 : 75
            } else if !anchorKey.isEmpty && (paraKey == anchorKey || paraNoNumKey == anchorKey) {
                score = isHeading ? 80 : 70
            } else if !linkKey.isEmpty && linkKey.count >= 4 && paraKey.contains(linkKey) {
                score = isHeading ? 65 : 50
            } else if !linkNoNumKey.isEmpty && linkNoNumKey.count >= 4 && paraNoNumKey.hasPrefix(linkNoNumKey) {
                score = isHeading ? 60 : 45
            }

            if score > 0 {
                let isAfterSource = trimmedPara.location > sourceRange.location
                let ranked = score * 2 + (isAfterSource ? 1 : 0)
                if ranked > bestScore {
                    bestScore = ranked
                    bestRange = trimmedPara
                }
            }
        }
        return bestRange
    }
}
