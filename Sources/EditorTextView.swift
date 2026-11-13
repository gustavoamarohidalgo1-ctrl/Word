import Cocoa

final class CenteredClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let docView = documentView {
            if docView.frame.width < rect.width {
                rect.origin.x = floor((docView.frame.width - rect.width) / 2.0)
            }
            if docView.frame.height < rect.height {
                rect.origin.y = floor((docView.frame.height - rect.height) / 2.0)
            }
        }
        return rect
    }
}

final class PaperSheetView: NSView {
    weak var editorView: NSTextView?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 3
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(srgbRed: 0.82, green: 0.85, blue: 0.90, alpha: 1.0).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if let tv = editorView {
            window?.makeFirstResponder(tv)
            let pt = tv.convert(event.locationInWindow, from: nil)
            let idx = tv.characterIndexForInsertion(at: pt)
            tv.setSelectedRange(NSRange(location: idx, length: 0))
        }
    }
}

final class DeskCanvasView: NSView {
    override var isFlipped: Bool { true }
}

final class EditorTextView: NSTextView {
    var onFileDropURL: ((URL) -> Void)?
    var onContextNeedsRefresh: (() -> Void)?
    var onMoveAcrossPage: ((EditorTextView, Int) -> Void)?
    var maxContentWidthPt: CGFloat = 450
    var maxContentHeightPt: CGFloat = 700
    var printHeaderText: String = ""
    var printFooterText: String = ""

    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 450, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        self.init(frame: NSRect(x: 0, y: 0, width: 450, height: 600), textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonSetup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonSetup()
    }

    private func commonSetup() {
        isRichText = true
        importsGraphics = true
        allowsImageEditing = true
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        usesFontPanel = true
        isContinuousSpellCheckingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        drawsBackground = false
        insertionPointColor = NSColor.systemBlue
        linkTextAttributes = [.cursor: NSCursor.pointingHand]

        let def = DocxEngine.blockAttributes(for: "normal")
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacing = 6
        ps.lineHeightMultiple = 1.15
        defaultParagraphStyle = ps
        typingAttributes = [
            .font: def.font,
            .foregroundColor: def.color,
            .paragraphStyle: ps,
        ]
        font = def.font
        textColor = def.color

        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    // MARK: - Visual Indicators (Quotes) & Cross-Page Navigation
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard NSGraphicsContext.currentContextDrawingToScreen(),
              let storage = textStorage,
              let layoutManager = layoutManager,
              let container = textContainer else {
            return
        }

        let containerGlyphs = layoutManager.glyphRange(for: container)
        guard containerGlyphs.length > 0 else { return }
        let containerChars = layoutManager.characterRange(forGlyphRange: containerGlyphs, actualGlyphRange: nil)

        storage.enumerateAttribute(.owBlockKind, in: containerChars, options: []) { val, range, _ in
            guard let kind = val as? String, (kind == "quote" || kind == "intenseQuote") else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let clipped = NSIntersectionRange(glyphRange, containerGlyphs)
            guard clipped.length > 0 else { return }
            let rect = layoutManager.boundingRect(forGlyphRange: clipped, in: container)
            guard rect.height > 0, rect.intersects(dirtyRect) else { return }
            let bar = NSRect(x: 6, y: rect.minY + 2, width: 3, height: max(12, rect.height - 4))
            let barColor = (kind == "intenseQuote")
                ? NSColor(srgbRed: 0.15, green: 0.39, blue: 0.92, alpha: 0.9)
                : NSColor(srgbRed: 0.39, green: 0.45, blue: 0.55, alpha: 0.85)
            barColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func moveDown(_ sender: Any?) {
        let before = selectedRange()
        super.moveDown(sender)
        if selectedRange() == before {
            onMoveAcrossPage?(self, 1)
        }
    }

    override func moveUp(_ sender: Any?) {
        let before = selectedRange()
        super.moveUp(sender)
        if selectedRange() == before {
            onMoveAcrossPage?(self, -1)
        }
    }

    override func drawPageBorder(with borderSize: NSSize) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: NSColor(srgbRed: 0.42, green: 0.47, blue: 0.54, alpha: 1.0),
        ]
        let hdr = printHeaderText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hdr.isEmpty {
            let s = hdr as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: borderSize.width - sz.width - 42, y: 24), withAttributes: attrs)
        }
        let ftr = printFooterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ftr.isEmpty {
            let s = ftr as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: (borderSize.width - sz.width) / 2, y: borderSize.height - 38), withAttributes: attrs)
        }
    }

    // MARK: - Drag & Drop / Paste
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first {
            let ext = first.pathExtension.lowercased()
            let docExts: Set<String> = ["docx", "doc", "rtf", "odt", "md", "txt", "html", "htm"]
            if docExts.contains(ext) {
                onFileDropURL?(first)
                return true
            }
            let imgExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp", "heic"]
            if imgExts.contains(ext) {
                insertImage(from: first)
                return true
            }
        }
        return super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb), pb.string(forType: .string) == nil {
            insertNSImage(img)
            return
        }
        super.paste(sender)
        clampOversizedAttachments()
    }

    func clampOversizedAttachments() {
        guard let storage = textStorage else { return }
        let safeMaxH = max(120, maxContentHeightPt - 16)
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { val, _, _ in
            guard let att = val as? NSTextAttachment else { return }
            let img = att.image ?? att.fileWrapper?.regularFileContents.flatMap { NSImage(data: $0) }
            guard let img else { return }
            if att.image == nil { att.image = img }
            var sz = att.bounds.size
            if sz.width <= 1 || sz.height <= 1 {
                sz = img.size
            }
            if sz.width > maxContentWidthPt && sz.width > 0 {
                let ratio = maxContentWidthPt / sz.width
                sz = CGSize(width: maxContentWidthPt, height: sz.height * ratio)
            }
            if sz.height > safeMaxH && sz.height > 0 {
                let ratio = safeMaxH / sz.height
                sz = CGSize(width: sz.width * ratio, height: safeMaxH)
            }
            att.bounds = CGRect(x: 0, y: 0, width: sz.width, height: sz.height)
        }
        layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
    }

    // MARK: - Smart Keyboard Handling (Lists & Tables)
    override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage else { super.insertNewline(sender); return }
        let sel = selectedRange()
        let nsStr = storage.string as NSString
        let paraRange = nsStr.paragraphRange(for: NSRange(location: sel.location, length: 0))

        guard paraRange.location < storage.length,
              let ps = storage.attribute(.paragraphStyle, at: paraRange.location, effectiveRange: nil) as? NSParagraphStyle,
              let textList = ps.textLists.first else {
            super.insertNewline(sender)
            // Reset heading block kind to normal on Enter at end of heading
            let newSel = selectedRange()
            if newSel.location < storage.length {
                let nextPara = (storage.string as NSString).paragraphRange(for: NSRange(location: newSel.location, length: 0))
                if let kind = storage.attribute(.owBlockKind, at: nextPara.location, effectiveRange: nil) as? String,
                   kind != "normal" && kind != "quote" {
                    let bodyLen = (storage.string as NSString).substring(with: nextPara).trimmingCharacters(in: .newlines).count
                    if bodyLen == 0 {
                        let def = DocxEngine.blockAttributes(for: "normal")
                        let normalPs = NSMutableParagraphStyle()
                        normalPs.paragraphSpacing = 6
                        normalPs.lineHeightMultiple = 1.15
                        storage.removeAttribute(.owBlockKind, range: nextPara)
                        storage.addAttributes([.font: def.font, .foregroundColor: def.color, .paragraphStyle: normalPs], range: nextPara)
                        typingAttributes = [.font: def.font, .foregroundColor: def.color, .paragraphStyle: normalPs]
                    }
                }
            }
            return
        }

        let paraStr = nsStr.substring(with: paraRange)
        let strippedBody = paraStr
            .replacingOccurrences(of: #"^\t[^\t\n]{1,14}\t"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .newlines)

        if strippedBody.isEmpty {
            // Exit list cleanly
            let cleanPs = (ps.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            cleanPs.textLists = []
            cleanPs.headIndent = 0
            cleanPs.firstLineHeadIndent = 0
            cleanPs.tabStops = []
            if shouldChangeText(in: paraRange, replacementString: "\n") {
                storage.replaceCharacters(in: paraRange, with: "\n")
                storage.addAttribute(.paragraphStyle, value: cleanPs, range: NSRange(location: paraRange.location, length: 1))
                didChangeText()
                setSelectedRange(NSRange(location: paraRange.location, length: 0))
                typingAttributes[.paragraphStyle] = cleanPs
            }
            return
        }

        // Continue list on next line
        let isOrdered = textList.markerFormat != .disc && textList.markerFormat != .circle && textList.markerFormat != .square
        var nextMarker = "•"
        if isOrdered {
            var currentNum = 1
            if let m = try? NSRegularExpression(pattern: #"^\t(\d+)\.\t"#).firstMatch(in: paraStr, range: NSRange(location: 0, length: (paraStr as NSString).length)) {
                currentNum = Int((paraStr as NSString).substring(with: m.range(at: 1))) ?? 1
            }
            nextMarker = "\(currentNum + 1)."
        }

        var attrs = typingAttributes
        attrs[.paragraphStyle] = ps
        let insertion = NSAttributedString(string: "\n\t\(nextMarker)\t", attributes: attrs)
        if shouldChangeText(in: sel, replacementString: insertion.string) {
            storage.replaceCharacters(in: sel, with: insertion)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + insertion.length, length: 0))
        }
    }

    override func insertTab(_ sender: Any?) {
        if let ctx = activeTableContext() {
            moveToTableCell(ctx: ctx, forward: true)
            return
        }
        if indentActiveList(delta: 20) {
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if let ctx = activeTableContext() {
            moveToTableCell(ctx: ctx, forward: false)
            return
        }
        if indentActiveList(delta: -20) {
            return
        }
        super.insertBacktab(sender)
    }

    private func indentActiveList(delta: CGFloat) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let loc = min(selectedRange().location, storage.length - 1)
        let paraRange = (storage.string as NSString).paragraphRange(for: NSRange(location: loc, length: 0))
        guard let ps = storage.attribute(.paragraphStyle, at: paraRange.location, effectiveRange: nil) as? NSParagraphStyle,
              !ps.textLists.isEmpty else {
            return false
        }
        let nextPs = (ps.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        let newHead = max(28, min(188, nextPs.headIndent + delta))
        nextPs.headIndent = newHead
        nextPs.firstLineHeadIndent = newHead - 28
        nextPs.tabStops = [
            NSTextTab(textAlignment: .right, location: newHead - 6),
            NSTextTab(textAlignment: .left, location: newHead),
        ]
        storage.addAttribute(.paragraphStyle, value: nextPs, range: paraRange)
        didChangeText()
        return true
    }

    // MARK: - Formatting Actions
    func toggleFontTrait(_ trait: NSFontTraitMask) {
        let sel = selectedRange()
        let fm = NSFontManager.shared
        if sel.length == 0 {
            let curFont = (typingAttributes[.font] as? NSFont) ?? DocxEngine.blockAttributes(for: "normal").font
            let hasTrait = fm.traits(of: curFont).contains(trait)
            let nextFont = hasTrait ? fm.convert(curFont, toNotHaveTrait: trait) : fm.convert(curFont, toHaveTrait: trait)
            typingAttributes[.font] = nextFont
            onContextNeedsRefresh?()
            return
        }
        guard let storage = textStorage else { return }
        let sample = (storage.attribute(.font, at: sel.location, effectiveRange: nil) as? NSFont) ?? DocxEngine.blockAttributes(for: "normal").font
        let shouldAdd = !fm.traits(of: sample).contains(trait)
        if shouldChangeText(in: sel, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: sel, options: []) { val, subRange, _ in
                let f = (val as? NSFont) ?? sample
                let updated = shouldAdd ? fm.convert(f, toHaveTrait: trait) : fm.convert(f, toNotHaveTrait: trait)
                storage.addAttribute(.font, value: updated, range: subRange)
            }
            storage.endEditing()
            didChangeText()
            onContextNeedsRefresh?()
        }
    }

    func toggleUnderline() {
        toggleNumericAttribute(.underlineStyle, onValue: NSUnderlineStyle.single.rawValue)
    }

    func toggleStrikethrough() {
        toggleNumericAttribute(.strikethroughStyle, onValue: NSUnderlineStyle.single.rawValue)
    }

    func toggleSuperscript(_ value: Int) {
        let sel = selectedRange()
        if sel.length == 0 {
            let cur = (typingAttributes[.superscript] as? NSNumber)?.intValue ?? 0
            typingAttributes[.superscript] = cur == value ? nil : NSNumber(value: value)
            onContextNeedsRefresh?()
            return
        }
        guard let storage = textStorage else { return }
        let cur = (storage.attribute(.superscript, at: sel.location, effectiveRange: nil) as? NSNumber)?.intValue ?? 0
        let nextVal: Any? = cur == value ? nil : NSNumber(value: value)
        if shouldChangeText(in: sel, replacementString: nil) {
            if let nextVal {
                storage.addAttribute(.superscript, value: nextVal, range: sel)
            } else {
                storage.removeAttribute(.superscript, range: sel)
            }
            didChangeText()
            onContextNeedsRefresh?()
        }
    }

    private func toggleNumericAttribute(_ key: NSAttributedString.Key, onValue: Int) {
        let sel = selectedRange()
        if sel.length == 0 {
            let cur = (typingAttributes[key] as? Int) ?? 0
            typingAttributes[key] = cur != 0 ? 0 : onValue
            onContextNeedsRefresh?()
            return
        }
        guard let storage = textStorage else { return }
        let cur = (storage.attribute(key, at: sel.location, effectiveRange: nil) as? Int) ?? 0
        let newVal = cur != 0 ? 0 : onValue
        if shouldChangeText(in: sel, replacementString: nil) {
            if newVal == 0 {
                storage.removeAttribute(key, range: sel)
            } else {
                storage.addAttribute(key, value: newVal, range: sel)
            }
            didChangeText()
            onContextNeedsRefresh?()
        }
    }

    func applyFontFamily(_ familyName: String) {
        let sel = selectedRange()
        let fm = NSFontManager.shared
        if sel.length == 0 {
            let cur = (typingAttributes[.font] as? NSFont) ?? DocxEngine.blockAttributes(for: "normal").font
            let traits = fm.traits(of: cur)
            let resolved = DocxEngine.resolveFontAndSource(
                family: familyName,
                sizePt: cur.pointSize,
                bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask)
            )
            typingAttributes[.font] = resolved.font
            if let logical = resolved.logicalName {
                typingAttributes[.owFontName] = logical
            } else {
                typingAttributes.removeValue(forKey: .owFontName)
            }
            return
        }
        guard let storage = textStorage else { return }
        if shouldChangeText(in: sel, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: sel, options: []) { val, subRange, _ in
                let cur = (val as? NSFont) ?? DocxEngine.blockAttributes(for: "normal").font
                let traits = fm.traits(of: cur)
                let resolved = DocxEngine.resolveFontAndSource(
                    family: familyName,
                    sizePt: cur.pointSize,
                    bold: traits.contains(.boldFontMask),
                    italic: traits.contains(.italicFontMask)
                )
                storage.addAttribute(.font, value: resolved.font, range: subRange)
                if let logical = resolved.logicalName {
                    storage.addAttribute(.owFontName, value: logical, range: subRange)
                } else {
                    storage.removeAttribute(.owFontName, range: subRange)
                }
            }
            storage.endEditing()
            didChangeText()
            onContextNeedsRefresh?()
        }
    }

    func applyFontSize(_ sizePt: CGFloat) {
        let sel = selectedRange()
        let fm = NSFontManager.shared
        if sel.length == 0 {
            let cur = (typingAttributes[.font] as? NSFont) ?? DocxEngine.blockAttributes(for: "normal").font
            typingAttributes[.font] = fm.convert(cur, toSize: sizePt)
            return
        }
        guard let storage = textStorage else { return }
        if shouldChangeText(in: sel, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: sel, options: []) { val, subRange, _ in
                let cur = (val as? NSFont) ?? DocxEngine.blockAttributes(for: "normal").font
                storage.addAttribute(.font, value: fm.convert(cur, toSize: sizePt), range: subRange)
            }
            storage.endEditing()
            didChangeText()
            onContextNeedsRefresh?()
        }
    }

    func applyTextColor(_ color: NSColor) {
        let sel = selectedRange()
        if sel.length == 0 {
            typingAttributes[.foregroundColor] = color
            return
        }
        guard let storage = textStorage else { return }
        if shouldChangeText(in: sel, replacementString: nil) {
            storage.addAttribute(.foregroundColor, value: color, range: sel)
            didChangeText()
        }
    }

    func applyHighlightColor(_ color: NSColor?) {
        let sel = selectedRange()
        if sel.length == 0 {
            typingAttributes[.backgroundColor] = color
            return
        }
        guard let storage = textStorage else { return }
        if shouldChangeText(in: sel, replacementString: nil) {
            if let color {
                storage.addAttribute(.backgroundColor, value: color, range: sel)
            } else {
                storage.removeAttribute(.backgroundColor, range: sel)
            }
            didChangeText()
        }
    }

    func clearFormatting() {
        let sel = selectedRange()
        let def = DocxEngine.fullBlockStyle(for: "normal")
        guard sel.length > 0, let storage = textStorage else {
            typingAttributes[.font] = def.font
            typingAttributes[.owFontName] = def.logicalFontName
            typingAttributes[.foregroundColor] = def.color
            typingAttributes[.backgroundColor] = nil
            typingAttributes[.underlineStyle] = nil
            typingAttributes[.strikethroughStyle] = nil
            typingAttributes[.superscript] = nil
            typingAttributes[.owBlockKind] = nil
            return
        }
        if shouldChangeText(in: sel, replacementString: nil) {
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: sel)
            storage.removeAttribute(.underlineStyle, range: sel)
            storage.removeAttribute(.strikethroughStyle, range: sel)
            storage.removeAttribute(.superscript, range: sel)
            storage.removeAttribute(.owBlockKind, range: sel)
            storage.addAttributes([
                .font: def.font,
                .owFontName: def.logicalFontName,
                .foregroundColor: def.color,
            ], range: sel)
            storage.endEditing()
            didChangeText()
            onContextNeedsRefresh?()
        }
    }

    func applyBlockKind(_ kind: String) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        let nsStr = storage.string as NSString
        let paraRange = nsStr.paragraphRange(for: sel)
        let cfg = DocxEngine.fullBlockStyle(for: kind)

        if shouldChangeText(in: paraRange, replacementString: nil) {
            storage.beginEditing()
            let curPs = (paraRange.location < storage.length
                ? storage.attribute(.paragraphStyle, at: paraRange.location, effectiveRange: nil) as? NSParagraphStyle
                : nil)
            let ps = (curPs?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            ps.paragraphSpacingBefore = cfg.spaceBefore
            ps.paragraphSpacing = cfg.spaceAfter
            ps.lineHeightMultiple = cfg.lineSpacing
            ps.alignment = cfg.align
            if ps.textLists.isEmpty {
                ps.headIndent = cfg.leftIndent
                ps.firstLineHeadIndent = cfg.leftIndent
            }

            if paraRange.length > 0 {
                storage.addAttributes([
                    .font: cfg.font,
                    .owFontName: cfg.logicalFontName,
                    .foregroundColor: cfg.color,
                    .paragraphStyle: ps,
                ], range: paraRange)
                if let bg = cfg.backgroundColor {
                    storage.addAttribute(.backgroundColor, value: bg, range: paraRange)
                } else if kind == "code" || cfg.backgroundColor == nil {
                    storage.removeAttribute(.backgroundColor, range: paraRange)
                }
                if kind == "normal" {
                    storage.removeAttribute(.owBlockKind, range: paraRange)
                } else {
                    storage.addAttribute(.owBlockKind, value: kind, range: paraRange)
                }
            }
            storage.endEditing()
            typingAttributes[.font] = cfg.font
            typingAttributes[.owFontName] = cfg.logicalFontName
            typingAttributes[.foregroundColor] = cfg.color
            typingAttributes[.paragraphStyle] = ps
            if let bg = cfg.backgroundColor {
                typingAttributes[.backgroundColor] = bg
            } else {
                typingAttributes.removeValue(forKey: .backgroundColor)
            }
            if kind == "normal" { typingAttributes.removeValue(forKey: .owBlockKind) }
            else { typingAttributes[.owBlockKind] = kind }
            didChangeText()
            onContextNeedsRefresh?()
        }
    }

    func applyParagraphAlignment(_ alignment: NSTextAlignment) {
        mutateSelectedParagraphStyles { ps in
            ps.alignment = alignment
        }
    }

    func applyLineSpacing(_ multiple: CGFloat) {
        mutateSelectedParagraphStyles { ps in
            ps.lineHeightMultiple = multiple
        }
    }

    func adjustIndent(delta: CGFloat) {
        mutateSelectedParagraphStyles { ps in
            ps.headIndent = max(0, min(200, ps.headIndent + delta))
            ps.firstLineHeadIndent = max(0, min(200, ps.firstLineHeadIndent + delta))
        }
    }

    private func mutateSelectedParagraphStyles(_ transform: (NSMutableParagraphStyle) -> Void) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        let nsStr = storage.string as NSString
        let paraRange = nsStr.paragraphRange(for: sel)

        if storage.length == 0 || paraRange.length == 0 {
            let ps = (typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            transform(ps)
            typingAttributes[.paragraphStyle] = ps
            onContextNeedsRefresh?()
            return
        }

        if shouldChangeText(in: paraRange, replacementString: nil) {
            storage.beginEditing()
            var pos = paraRange.location
            while pos < NSMaxRange(paraRange) {
                let singlePara = nsStr.paragraphRange(for: NSRange(location: pos, length: 0))
                let curPs = storage.attribute(.paragraphStyle, at: singlePara.location, effectiveRange: nil) as? NSParagraphStyle
                let nextPs = (curPs?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                transform(nextPs)
                storage.addAttribute(.paragraphStyle, value: nextPs, range: singlePara)
                pos = NSMaxRange(singlePara)
            }
            storage.endEditing()
            didChangeText()
            onContextNeedsRefresh?()
        }
    }

    func toggleList(ordered: Bool) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        let nsStr = storage.string as NSString
        if storage.length == 0 {
            let marker = ordered ? "1." : "•"
            let ps = NSMutableParagraphStyle()
            ps.textLists = [NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)]
            ps.headIndent = 28
            ps.firstLineHeadIndent = 0
            ps.tabStops = [
                NSTextTab(textAlignment: .right, location: 22),
                NSTextTab(textAlignment: .left, location: 28),
            ]
            var attrs = typingAttributes
            attrs[.paragraphStyle] = ps
            let item = NSAttributedString(string: "\t\(marker)\t\n", attributes: attrs)
            if shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: item.string) {
                storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: item)
                didChangeText()
                setSelectedRange(NSRange(location: item.length - 1, length: 0))
            }
            return
        }

        let fullRange = nsStr.paragraphRange(for: sel)
        var itemNum = 1
        if shouldChangeText(in: fullRange, replacementString: nil) {
            storage.beginEditing()
            var pos = fullRange.location
            var endLimit = NSMaxRange(fullRange)
            while pos < endLimit {
                let singlePara = (storage.string as NSString).paragraphRange(for: NSRange(location: pos, length: 0))
                let curPs = storage.attribute(.paragraphStyle, at: singlePara.location, effectiveRange: nil) as? NSParagraphStyle
                let hasList = !(curPs?.textLists.isEmpty ?? true)
                let paraStr = (storage.string as NSString).substring(with: singlePara)

                if hasList {
                    let cleanPs = (curPs?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    cleanPs.textLists = []
                    cleanPs.headIndent = 0
                    cleanPs.firstLineHeadIndent = 0
                    cleanPs.tabStops = []
                    storage.addAttribute(.paragraphStyle, value: cleanPs, range: singlePara)
                    if let m = try? NSRegularExpression(pattern: #"^\t[^\t\n]{1,14}\t"#).firstMatch(in: paraStr, range: NSRange(location: 0, length: (paraStr as NSString).length)) {
                        let delRange = NSRange(location: singlePara.location, length: m.range.length)
                        storage.replaceCharacters(in: delRange, with: "")
                        endLimit -= m.range.length
                        pos = NSMaxRange(singlePara) - m.range.length
                        continue
                    }
                } else {
                    let nextPs = (curPs?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    nextPs.textLists = [NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)]
                    nextPs.headIndent = 28
                    nextPs.firstLineHeadIndent = 0
                    nextPs.tabStops = [
                        NSTextTab(textAlignment: .right, location: 22),
                        NSTextTab(textAlignment: .left, location: 28),
                    ]
                    storage.addAttribute(.paragraphStyle, value: nextPs, range: singlePara)
                    let marker = ordered ? "\(itemNum)." : "•"
                    itemNum += 1
                    let prefix = "\t\(marker)\t"
                    let attrs = storage.attributes(at: singlePara.location, effectiveRange: nil)
                    storage.insert(NSAttributedString(string: prefix, attributes: attrs), at: singlePara.location)
                    endLimit += (prefix as NSString).length
                    pos = NSMaxRange(singlePara) + (prefix as NSString).length
                    continue
                }
                pos = NSMaxRange(singlePara)
            }
            storage.endEditing()
            didChangeText()
            onContextNeedsRefresh?()
        }
    }

    // MARK: - Insertions (Table, Image, Link, Page Break, HR, Date)
    func insertTable(rows: Int, cols: Int) {
        let rCount = max(1, min(20, rows))
        let cCount = max(1, min(12, cols))
        let table = NSTextTable()
        table.numberOfColumns = cCount
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)

        let out = NSMutableAttributedString()
        let def = DocxEngine.blockAttributes(for: "normal")
        let headerFont = DocxEngine.resolveFont(family: "Calibri", sizePt: 11, bold: true, italic: false)

        for r in 0..<rCount {
            for c in 0..<cCount {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setValue(CGFloat(100.0 / Double(cCount)), type: .percentageValueType, for: .width)
                block.setWidth(1.0, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor(srgbRed: 0.80, green: 0.84, blue: 0.89, alpha: 1))
                block.setWidth(6.0, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(6.0, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(4.0, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(4.0, type: .absoluteValueType, for: .padding, edge: .maxY)
                if r == 0 {
                    block.backgroundColor = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1)
                }
                let ps = NSMutableParagraphStyle()
                ps.textBlocks = [block]
                let cellText = r == 0 ? "Columna \(c + 1)\n" : "\n"
                out.append(NSAttributedString(string: cellText, attributes: [
                    .font: r == 0 ? headerFont : def.font,
                    .foregroundColor: def.color,
                    .paragraphStyle: ps,
                ]))
            }
        }
        // Trailing normal paragraph below table so cursor can always escape table
        let normalPs = NSMutableParagraphStyle()
        normalPs.paragraphSpacing = 6
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: def.font, .foregroundColor: def.color, .paragraphStyle: normalPs
        ]))

        let sel = selectedRange()
        if let storage = textStorage, shouldChangeText(in: sel, replacementString: out.string) {
            storage.replaceCharacters(in: sel, with: out)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location, length: 0))
            onContextNeedsRefresh?()
        }
    }

    func activeTableContext() -> (table: NSTextTable, block: NSTextTableBlock, tableRange: NSRange)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let loc = min(selectedRange().location, storage.length - 1)
        guard let ps = storage.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle,
              let block = ps.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first else {
            return nil
        }
        let table = block.table
        let tableId = ObjectIdentifier(table)
        var start = loc
        var end = loc
        while start > 0 {
            let prevPs = storage.attribute(.paragraphStyle, at: start - 1, effectiveRange: nil) as? NSParagraphStyle
            if let b = prevPs?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first, ObjectIdentifier(b.table) == tableId {
                start -= 1
            } else {
                break
            }
        }
        while end < storage.length {
            let nextPs = storage.attribute(.paragraphStyle, at: end, effectiveRange: nil) as? NSParagraphStyle
            if let b = nextPs?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first, ObjectIdentifier(b.table) == tableId {
                end += 1
            } else {
                break
            }
        }
        return (table, block, NSRange(location: start, length: end - start))
    }

    private func moveToTableCell(ctx: (table: NSTextTable, block: NSTextTableBlock, tableRange: NSRange), forward: Bool) {
        guard let storage = textStorage else { return }
        let nsStr = storage.string as NSString
        var cellRanges: [(row: Int, col: Int, range: NSRange)] = []
        var pos = ctx.tableRange.location
        while pos < NSMaxRange(ctx.tableRange) {
            let pr = nsStr.paragraphRange(for: NSRange(location: pos, length: 0))
            if let ps = storage.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle,
               let b = ps.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                if cellRanges.last?.row != b.startingRow || cellRanges.last?.col != b.startingColumn {
                    cellRanges.append((b.startingRow, b.startingColumn, pr))
                }
            }
            pos = NSMaxRange(pr)
        }

        if let curIdx = cellRanges.firstIndex(where: { $0.row == ctx.block.startingRow && $0.col == ctx.block.startingColumn }) {
            let targetIdx = forward ? curIdx + 1 : curIdx - 1
            if targetIdx >= 0 && targetIdx < cellRanges.count {
                let targetRange = cellRanges[targetIdx].range
                setSelectedRange(NSRange(location: targetRange.location, length: 0))
                onContextNeedsRefresh?()
            } else if forward && curIdx == cellRanges.count - 1 {
                addTableRow(below: true)
            }
        }
    }

    func addTableRow(below: Bool) {
        guard let ctx = activeTableContext(), let storage = textStorage else { return }
        rebuildTable(ctx: ctx) { cells, rows, cols in
            var next = cells
            let insertRow = below ? ctx.block.startingRow + 1 : ctx.block.startingRow
            next = next.map { item in
                if item.row >= insertRow {
                    return (item.row + 1, item.col, item.bg, item.content)
                }
                return item
            }
            for c in 0..<cols {
                next.append((insertRow, c, nil, NSAttributedString(string: "\n", attributes: [
                    .font: DocxEngine.blockAttributes(for: "normal").font,
                    .foregroundColor: DocxEngine.blockAttributes(for: "normal").color,
                ])))
            }
            return (next, rows + 1, cols)
        }
        _ = storage
    }

    func addTableColumn(after: Bool) {
        guard let ctx = activeTableContext() else { return }
        rebuildTable(ctx: ctx) { cells, rows, cols in
            let insertCol = after ? ctx.block.startingColumn + 1 : ctx.block.startingColumn
            var next = cells.map { item in
                item.col >= insertCol ? (item.row, item.col + 1, item.bg, item.content) : item
            }
            for r in 0..<rows {
                next.append((r, insertCol, r == 0 ? NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1) : nil,
                             NSAttributedString(string: "\n", attributes: [
                                .font: DocxEngine.blockAttributes(for: "normal").font,
                                .foregroundColor: DocxEngine.blockAttributes(for: "normal").color,
                             ])))
            }
            return (next, rows, cols + 1)
        }
    }

    func deleteTableRow() {
        guard let ctx = activeTableContext() else { return }
        rebuildTable(ctx: ctx) { cells, rows, cols in
            if rows <= 1 { return ([], 0, 0) }
            let delRow = ctx.block.startingRow
            let filtered = cells.filter { $0.row != delRow }.map { item in
                item.row > delRow ? (item.row - 1, item.col, item.bg, item.content) : item
            }
            return (filtered, rows - 1, cols)
        }
    }

    func deleteTableColumn() {
        guard let ctx = activeTableContext() else { return }
        rebuildTable(ctx: ctx) { cells, rows, cols in
            if cols <= 1 { return ([], 0, 0) }
            let delCol = ctx.block.startingColumn
            let filtered = cells.filter { $0.col != delCol }.map { item in
                item.col > delCol ? (item.row, item.col - 1, item.bg, item.content) : item
            }
            return (filtered, rows, cols - 1)
        }
    }

    func deleteCurrentTable() {
        guard let ctx = activeTableContext(), let storage = textStorage else { return }
        if shouldChangeText(in: ctx.tableRange, replacementString: "") {
            storage.replaceCharacters(in: ctx.tableRange, with: "")
            didChangeText()
            onContextNeedsRefresh?()
        }
    }

    func setCurrentCellBackground(_ color: NSColor?) {
        guard let ctx = activeTableContext(), let storage = textStorage else { return }
        ctx.block.backgroundColor = color
        storage.edited(.editedAttributes, range: ctx.tableRange, changeInLength: 0)
        didChangeText()
    }

    private func rebuildTable(
        ctx: (table: NSTextTable, block: NSTextTableBlock, tableRange: NSRange),
        transform: ([(row: Int, col: Int, bg: NSColor?, content: NSAttributedString)], Int, Int) -> ([(row: Int, col: Int, bg: NSColor?, content: NSAttributedString)], Int, Int)
    ) {
        guard let storage = textStorage else { return }
        let nsStr = storage.string as NSString
        var cells: [(row: Int, col: Int, bg: NSColor?, content: NSAttributedString)] = []
        var maxRow = 0
        var maxCol = ctx.table.numberOfColumns

        var pos = ctx.tableRange.location
        while pos < NSMaxRange(ctx.tableRange) {
            let pr = nsStr.paragraphRange(for: NSRange(location: pos, length: 0))
            if let ps = storage.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle,
               let b = ps.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                cells.append((b.startingRow, b.startingColumn, b.backgroundColor, storage.attributedSubstring(from: pr)))
                maxRow = max(maxRow, b.startingRow)
                maxCol = max(maxCol, b.startingColumn + 1)
            }
            pos = NSMaxRange(pr)
        }

        let (newCells, newRows, newCols) = transform(cells, maxRow + 1, maxCol)
        if newRows == 0 || newCols == 0 {
            deleteCurrentTable()
            return
        }

        let newTable = NSTextTable()
        newTable.numberOfColumns = newCols
        newTable.collapsesBorders = true
        newTable.setContentWidth(100, type: .percentageValueType)

        let built = NSMutableAttributedString()
        for r in 0..<newRows {
            for c in 0..<newCols {
                let matching = newCells.filter { $0.row == r && $0.col == c }
                let block = NSTextTableBlock(table: newTable, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setValue(CGFloat(100.0 / Double(newCols)), type: .percentageValueType, for: .width)
                block.setWidth(1.0, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor(srgbRed: 0.80, green: 0.84, blue: 0.89, alpha: 1))
                block.setWidth(6.0, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(6.0, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(4.0, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(4.0, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.backgroundColor = matching.first?.bg

                let cellContent = NSMutableAttributedString()
                if matching.isEmpty {
                    cellContent.append(NSAttributedString(string: "\n", attributes: [
                        .font: DocxEngine.blockAttributes(for: "normal").font,
                        .foregroundColor: DocxEngine.blockAttributes(for: "normal").color,
                    ]))
                } else {
                    for item in matching { cellContent.append(item.content) }
                }
                let existingPs = cellContent.length > 0
                    ? (cellContent.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                    : nil
                let ps = existingPs ?? NSMutableParagraphStyle()
                ps.textBlocks = [block]
                cellContent.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: cellContent.length))
                built.append(cellContent)
            }
        }

        if shouldChangeText(in: ctx.tableRange, replacementString: built.string) {
            storage.replaceCharacters(in: ctx.tableRange, with: built)
            didChangeText()
            setSelectedRange(NSRange(location: ctx.tableRange.location, length: 0))
            onContextNeedsRefresh?()
        }
    }

    func selectedImageAttachment() -> (attachment: NSTextAttachment, range: NSRange)? {
        guard let storage = textStorage else { return nil }
        let sel = selectedRange()
        guard sel.length == 1, sel.location < storage.length else { return nil }
        if let att = storage.attribute(.attachment, at: sel.location, effectiveRange: nil) as? NSTextAttachment {
            return (att, sel)
        }
        return nil
    }

    func insertImage(from url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        insertNSImage(img)
    }

    func insertNSImage(_ img: NSImage) {
        var wPt = img.size.width > 1 ? img.size.width : 320
        var hPt = img.size.height > 1 ? img.size.height : 200
        let maxW = min(maxContentWidthPt, 420)
        if wPt > maxW {
            let ratio = maxW / wPt
            wPt = maxW
            hPt *= ratio
        }
        let maxH = max(120, maxContentHeightPt - 16)
        if hPt > maxH {
            let ratio = maxH / hPt
            hPt = maxH
            wPt *= ratio
        }
        let att = NSTextAttachment()
        att.image = img
        att.bounds = CGRect(x: 0, y: 0, width: wPt, height: hPt)
        let attrStr = NSAttributedString(attachment: att)
        let sel = selectedRange()
        if let storage = textStorage, shouldChangeText(in: sel, replacementString: attrStr.string) {
            storage.replaceCharacters(in: sel, with: attrStr)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            onContextNeedsRefresh?()
        }
    }

    func resizeSelectedImage(widthFraction: CGFloat) {
        guard let (att, range) = selectedImageAttachment(),
              let img = att.image,
              let storage = textStorage else { return }
        var targetW = max(36, maxContentWidthPt * widthFraction)
        let ratio = img.size.width > 0 ? img.size.height / img.size.width : 0.65
        var targetH = targetW * ratio
        let safeMaxH = max(120, maxContentHeightPt - 16)
        if targetH > safeMaxH && targetH > 0 {
            let s = safeMaxH / targetH
            targetW *= s
            targetH = safeMaxH
        }
        att.bounds = CGRect(x: 0, y: 0, width: targetW, height: targetH)
        storage.edited(.editedAttributes, range: range, changeInLength: 0)
        layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        didChangeText()
        onContextNeedsRefresh?()
    }

    func deleteSelectedImage() {
        guard let (_, range) = selectedImageAttachment(), let storage = textStorage else { return }
        if shouldChangeText(in: range, replacementString: "") {
            storage.replaceCharacters(in: range, with: "")
            didChangeText()
            onContextNeedsRefresh?()
        }
    }

    func insertHyperlink(text: String, url: URL) {
        var attrs = typingAttributes
        attrs[.link] = url
        attrs[.foregroundColor] = NSColor(srgbRed: 0.15, green: 0.39, blue: 0.92, alpha: 1)
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        let linkAttr = NSAttributedString(string: text, attributes: attrs)
        let sel = selectedRange()
        if let storage = textStorage, shouldChangeText(in: sel, replacementString: linkAttr.string) {
            storage.replaceCharacters(in: sel, with: linkAttr)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + linkAttr.length, length: 0))
        }
    }

    func insertHorizontalRule() {
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.paragraphSpacingBefore = 6
        ps.paragraphSpacing = 6
        let hr = NSAttributedString(string: "\n────────────────────────────────────────\n", attributes: [
            .font: DocxEngine.resolveFont(family: "Calibri", sizePt: 10, bold: false, italic: false),
            .foregroundColor: NSColor(srgbRed: 0.78, green: 0.82, blue: 0.88, alpha: 1),
            .paragraphStyle: ps,
            .owBlockKind: "hr",
        ])
        let sel = selectedRange()
        if let storage = textStorage, shouldChangeText(in: sel, replacementString: hr.string) {
            storage.replaceCharacters(in: sel, with: hr)
            didChangeText()
        }
    }

    func insertPageBreak() {
        var attrs = typingAttributes
        attrs[.owBlockKind] = "pageBreak"
        let pb = NSAttributedString(string: "\u{000C}", attributes: attrs)
        let sel = selectedRange()
        if let storage = textStorage, shouldChangeText(in: sel, replacementString: pb.string) {
            storage.replaceCharacters(in: sel, with: pb)
            didChangeText()
            onContextNeedsRefresh?()
        }
    }

    func insertCurrentDate() {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "es_ES")
        fmt.dateStyle = .long
        let str = fmt.string(from: Date())
        let sel = selectedRange()
        if let storage = textStorage, shouldChangeText(in: sel, replacementString: str) {
            storage.replaceCharacters(in: sel, with: NSAttributedString(string: str, attributes: typingAttributes))
            didChangeText()
        }
    }
}
