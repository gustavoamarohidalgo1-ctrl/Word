import Cocoa
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, RibbonDelegate {
    private let ribbon = RibbonView()
    private let scrollView = NSScrollView()
    private let deskView = DeskCanvasView()
    private let rulerView = PaperRulerView()
    private var showRuler = false

    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private var paperViews: [PaperSheetView] = []
    private var headerLabels: [NSTextField] = []
    private var footerLabels: [NSTextField] = []
    private var pageTextViews: [EditorTextView] = []
    private weak var activePageView: EditorTextView?
    var textView: EditorTextView { activePageView ?? pageTextViews[0] }
    private var isUpdatingPages = false

    // Status bar
    private let statsLabel = NSTextField(labelWithString: "Página 1 de 1  •  0 palabras  •  0 caracteres  •  < 1 min lectura")
    private var cachedWords = 0
    private var cachedChars = 0
    private var cachedReadStr = "< 1 min lectura"
    private let zoomSlider = NSSlider(value: 100, minValue: 50, maxValue: 200, target: nil, action: nil)
    private let zoomButton = NSButton(title: "100%", target: nil, action: nil)

    // Document state
    private var fileURL: URL?
    private var fileNameBase = "Documento sin título"
    private var fileExt = "docx"
    private var isDirty = false
    private var isDarkAppearance = false
    private var pageSetup = DocPageSetup()
    private var headerText = ""
    private var footerText = ""

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Documento sin título.docx — OfficeWord"
        win.minSize = NSSize(width: 820, height: 540)
        win.center()
        self.init(window: win)
        win.delegate = self
        setupLayout()
        resetToBlankDocument()
    }

    private func setupLayout() {
        guard let contentView = window?.contentView else { return }

        ribbon.delegate = self
        ribbon.translatesAutoresizingMaskIntoConstraints = false

        // ScrollView with centered clip view and magnification zoom
        let clipView = CenteredClipView()
        clipView.drawsBackground = true
        scrollView.contentView = clipView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 2.0
        scrollView.magnification = 1.0
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        deskView.frame = NSRect(x: 0, y: 0, width: 800, height: 1000)
        textStorage.addLayoutManager(layoutManager)
        activePageView = appendPage()

        rulerView.isHidden = true
        deskView.addSubview(rulerView)

        scrollView.documentView = deskView

        // Status bar
        let statusBar = makeStatusBar()

        contentView.addSubview(ribbon)
        contentView.addSubview(scrollView)
        contentView.addSubview(statusBar)

        NSLayoutConstraint.activate([
            ribbon.topAnchor.constraint(equalTo: contentView.topAnchor),
            ribbon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            ribbon.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: ribbon.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScrollOrZoomChanged),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )
        updateDeskThemeColors()
    }

    private func makeStatusBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(sep)

        statsLabel.font = .systemFont(ofSize: 11)
        statsLabel.textColor = .secondaryLabelColor

        let zoomOutBtn = NSButton(title: "−", target: self, action: #selector(onZoomOut))
        zoomOutBtn.bezelStyle = .inline
        zoomOutBtn.font = .systemFont(ofSize: 12, weight: .bold)

        zoomSlider.controlSize = .mini
        zoomSlider.target = self
        zoomSlider.action = #selector(onZoomSliderChanged)
        zoomSlider.translatesAutoresizingMaskIntoConstraints = false
        zoomSlider.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let zoomInBtn = NSButton(title: "+", target: self, action: #selector(onZoomIn))
        zoomInBtn.bezelStyle = .inline
        zoomInBtn.font = .systemFont(ofSize: 12, weight: .bold)

        zoomButton.bezelStyle = .inline
        zoomButton.font = .systemFont(ofSize: 11, weight: .medium)
        zoomButton.target = self
        zoomButton.action = #selector(onZoomReset)

        let rightStack = NSStackView(views: [zoomOutBtn, zoomSlider, zoomInBtn, zoomButton])
        rightStack.spacing = 4
        rightStack.alignment = .centerY

        let row = NSStackView(views: [statsLabel, NSView(), rightStack])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        row.alignment = .centerY
        bar.addSubview(row)

        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: bar.topAnchor),
            sep.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: bar.trailingAnchor),

            row.topAnchor.constraint(equalTo: sep.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    // MARK: - Layout & Paper Geometry
    func windowDidResize(_ notification: Notification) {
        updateStatsAndPaperLayout()
    }

    private func updateDeskThemeColors() {
        let dark = isDarkAppearance || (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let deskColor = dark
            ? NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1.0)
            : NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 1.0)
        scrollView.backgroundColor = deskColor
        scrollView.contentView.backgroundColor = deskColor
    }

    private func appendPage() -> EditorTextView {
        let pagePt = pageSetup.effectivePageSizePt
        let margins = pageSetup.marginsPt
        let printableW = pageSetup.printableWidthPt
        let printableH = max(200, pagePt.height - margins.top - margins.bottom)

        let tc = NSTextContainer(containerSize: NSSize(width: printableW, height: printableH))
        tc.widthTracksTextView = false
        tc.heightTracksTextView = false
        tc.lineFragmentPadding = 0
        layoutManager.addTextContainer(tc)

        let tv = EditorTextView(frame: NSRect(x: margins.left, y: margins.top, width: printableW, height: printableH), textContainer: tc)
        tv.delegate = self
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.maxContentWidthPt = printableW
        tv.maxContentHeightPt = printableH
        tv.printHeaderText = headerText
        tv.printFooterText = footerText
        tv.onFileDropURL = { [weak self] url in
            self?.confirmAndOpen(url: url)
        }
        tv.onContextNeedsRefresh = { [weak self] in
            guard let self else { return }
            self.ribbon.syncWithSelection(in: self.textView)
            self.updateStatsAndPaperLayout()
        }
        tv.onMoveAcrossPage = { [weak self] senderTV, dir in
            self?.handleMoveAcrossPage(from: senderTV, direction: dir)
        }

        let paper = PaperSheetView(frame: NSRect(x: 0, y: 0, width: pagePt.width, height: pagePt.height))
        paper.editorView = tv

        let hdr = NSTextField(labelWithString: "")
        hdr.font = .systemFont(ofSize: 9.5)
        hdr.textColor = NSColor(srgbRed: 0.45, green: 0.50, blue: 0.58, alpha: 1)
        hdr.alignment = .right
        paper.addSubview(hdr)

        let ftr = NSTextField(labelWithString: "")
        ftr.font = .systemFont(ofSize: 9.5)
        ftr.textColor = NSColor(srgbRed: 0.45, green: 0.50, blue: 0.58, alpha: 1)
        ftr.alignment = .center
        paper.addSubview(ftr)

        paper.addSubview(tv)
        deskView.addSubview(paper)

        paperViews.append(paper)
        headerLabels.append(hdr)
        footerLabels.append(ftr)
        pageTextViews.append(tv)
        return tv
    }

    private func removeLastPage() {
        guard pageTextViews.count > 1 else { return }
        let tv = pageTextViews.removeLast()
        let paper = paperViews.removeLast()
        headerLabels.removeLast()
        footerLabels.removeLast()
        if activePageView === tv {
            activePageView = pageTextViews.last
        }
        if let tc = tv.textContainer, let idx = layoutManager.textContainers.firstIndex(of: tc) {
            layoutManager.removeTextContainer(at: idx)
        }
        paper.removeFromSuperview()
    }

    private func pageIndex(forCharacterLocation loc: Int) -> Int {
        guard !pageTextViews.isEmpty else { return 0 }
        let len = textStorage.length
        if len == 0 { return 0 }
        if loc >= len {
            if let extraTC = layoutManager.extraLineFragmentTextContainer,
               let idx = pageTextViews.firstIndex(where: { $0.textContainer === extraTC }) {
                return idx
            }
            for i in stride(from: pageTextViews.count - 1, through: 0, by: -1) {
                if let tc = pageTextViews[i].textContainer, layoutManager.glyphRange(for: tc).length > 0 {
                    return i
                }
            }
            return 0
        }
        let gIdx = layoutManager.glyphIndexForCharacter(at: max(0, loc))
        let tc = layoutManager.textContainer(forGlyphAt: gIdx, effectiveRange: nil, withoutAdditionalLayout: true)
        if let tc, let idx = pageTextViews.firstIndex(where: { $0.textContainer === tc }) {
            return idx
        }
        return 0
    }

    private func handleMoveAcrossPage(from senderTV: EditorTextView, direction: Int) {
        guard let idx = pageTextViews.firstIndex(of: senderTV) else { return }
        if direction > 0 && idx + 1 < pageTextViews.count {
            let nextTV = pageTextViews[idx + 1]
            guard let nextTC = nextTV.textContainer else { return }
            let gr = layoutManager.glyphRange(for: nextTC)
            let charLoc: Int
            if gr.length > 0 {
                charLoc = layoutManager.characterIndexForGlyph(at: gr.location)
            } else if layoutManager.extraLineFragmentTextContainer === nextTC {
                charLoc = textStorage.length
            } else {
                return
            }
            activePageView = nextTV
            window?.makeFirstResponder(nextTV)
            nextTV.setSelectedRange(NSRange(location: charLoc, length: 0))
            nextTV.scrollRangeToVisible(NSRange(location: charLoc, length: 0))
            updateCurrentPageStatus(currentPage: idx + 2)
        } else if direction < 0 && idx > 0 {
            let prevTV = pageTextViews[idx - 1]
            guard let prevTC = prevTV.textContainer else { return }
            let gr = layoutManager.glyphRange(for: prevTC)
            guard gr.length > 0 else { return }
            let lastGlyph = NSMaxRange(gr) - 1
            let charLoc = layoutManager.characterIndexForGlyph(at: lastGlyph)
            activePageView = prevTV
            window?.makeFirstResponder(prevTV)
            prevTV.setSelectedRange(NSRange(location: charLoc, length: 0))
            prevTV.scrollRangeToVisible(NSRange(location: charLoc, length: 0))
            updateCurrentPageStatus(currentPage: idx)
        }
    }

    private func updateCurrentPageStatus(currentPage: Int) {
        let total = max(1, pageTextViews.count)
        statsLabel.stringValue = "Página \(currentPage) de \(total)  •  \(cachedWords) palabras  •  \(cachedChars) caracteres  •  \(cachedReadStr)"
    }

    private func updateStatsAndPaperLayout() {
        guard !isUpdatingPages else { return }
        isUpdatingPages = true
        defer { isUpdatingPages = false }

        if pageTextViews.isEmpty {
            activePageView = appendPage()
        }

        let pagePt = pageSetup.effectivePageSizePt
        let margins = pageSetup.marginsPt
        let printableW = pageSetup.printableWidthPt
        let printableH = max(200, pagePt.height - margins.top - margins.bottom)

        for tv in pageTextViews {
            tv.maxContentWidthPt = printableW
            tv.maxContentHeightPt = printableH
            tv.printHeaderText = headerText
            tv.printFooterText = footerText
            if let tc = tv.textContainer {
                tc.widthTracksTextView = false
                tc.heightTracksTextView = false
                if tc.containerSize.width != printableW || tc.containerSize.height != printableH {
                    tc.containerSize = NSSize(width: printableW, height: printableH)
                }
            }
        }

        // Grow containers until all glyphs and any trailing newline / form-feed fit
        layoutManager.ensureLayout(for: pageTextViews[0].textContainer!)
        var guardSteps = 0
        var prevEndGlyph = -1
        while guardSteps < 600 {
            guardSteps += 1
            let lastTC = pageTextViews[pageTextViews.count - 1].textContainer!
            layoutManager.ensureLayout(for: lastTC)
            let gr = layoutManager.glyphRange(for: lastTC)
            let endGlyph = NSMaxRange(gr)
            let totalGlyphs = layoutManager.numberOfGlyphs

            let needsMoreForGlyphs = endGlyph < totalGlyphs
            let endsBreakOrNewline = textStorage.string.hasSuffix("\u{000C}") || textStorage.string.hasSuffix("\n")
            let needsExtraPage = (endGlyph == totalGlyphs && textStorage.length > 0 && layoutManager.extraLineFragmentTextContainer == nil && endsBreakOrNewline)

            if needsMoreForGlyphs || needsExtraPage {
                if !needsExtraPage && endGlyph <= prevEndGlyph && pageTextViews.count > 1 {
                    break
                }
                prevEndGlyph = endGlyph
                _ = appendPage()
            } else {
                break
            }
        }

        // Trim unused trailing pages down to minimum 1
        while pageTextViews.count > 1 {
            let lastTC = pageTextViews[pageTextViews.count - 1].textContainer!
            layoutManager.ensureLayout(for: lastTC)
            let gr = layoutManager.glyphRange(for: lastTC)
            let hasExtra = (layoutManager.extraLineFragmentTextContainer === lastTC)
            if gr.length == 0 && !hasExtra {
                removeLastPage()
            } else {
                break
            }
        }

        // Stack physical PaperSheetViews vertically with desk gaps
        let pageGap: CGFloat = 22
        let topPad: CGFloat = showRuler ? 30 : 24
        let pageCount = pageTextViews.count
        let totalPapersH = CGFloat(pageCount) * pagePt.height + CGFloat(max(0, pageCount - 1)) * pageGap

        let clipW = max(scrollView.contentSize.width / max(0.5, scrollView.magnification), pagePt.width + 48)
        let clipH = max(scrollView.contentSize.height / max(0.5, scrollView.magnification), topPad + totalPapersH + 28)

        deskView.frame = NSRect(x: 0, y: 0, width: max(clipW, pagePt.width + 48), height: max(clipH, topPad + totalPapersH + 28))
        let paperX = floor((deskView.frame.width - pagePt.width) / 2.0)

        rulerView.isHidden = !showRuler
        if showRuler {
            rulerView.frame = NSRect(x: paperX, y: 6, width: pagePt.width, height: 18)
            rulerView.leftMarginPt = margins.left
            rulerView.rightMarginPt = margins.right
            rulerView.needsDisplay = true
        }

        let hdrTrimEmpty = headerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ftrTrimEmpty = footerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        for i in 0..<pageCount {
            let py = topPad + CGFloat(i) * (pagePt.height + pageGap)
            paperViews[i].frame = NSRect(x: paperX, y: py, width: pagePt.width, height: pagePt.height)
            pageTextViews[i].frame = NSRect(x: margins.left, y: margins.top, width: printableW, height: printableH)

            headerLabels[i].isHidden = hdrTrimEmpty
            headerLabels[i].stringValue = headerText
            headerLabels[i].frame = NSRect(x: margins.left, y: max(8, margins.top - 22), width: printableW, height: 16)

            footerLabels[i].isHidden = ftrTrimEmpty
            footerLabels[i].stringValue = footerText
            footerLabels[i].frame = NSRect(x: margins.left, y: pagePt.height - max(18, margins.bottom - 14), width: printableW, height: 16)
        }

        let sel = textView.selectedRange()
        let curIdx = pageIndex(forCharacterLocation: sel.location)
        let targetTV = pageTextViews[curIdx]
        activePageView = targetTV
        if window?.firstResponder is EditorTextView && window?.firstResponder !== targetTV {
            window?.makeFirstResponder(targetTV)
            targetTV.scrollRangeToVisible(sel)
        }

        // Update document word/char counts
        let str = textStorage.string
        let plain = str.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedWords = plain.isEmpty ? 0 : plain.split { $0.isWhitespace || $0.isNewline }.count
        cachedChars = str.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\u{000C}", with: "").count
        let readMin = max(1, Int(ceil(Double(cachedWords) / 200.0)))
        cachedReadStr = cachedWords < 120 ? "< 1 min lectura" : "\(readMin) min lectura"
        updateCurrentPageStatus(currentPage: curIdx + 1)
    }

    private func setDirty(_ dirty: Bool) {
        isDirty = dirty
        let displayTitle = "\(fileNameBase).\(fileExt)"
        window?.title = "\(displayTitle) — OfficeWord"
        window?.isDocumentEdited = dirty
        ribbon.updateDocumentMeta(title: displayTitle, dirty: dirty)
    }

    // MARK: - NSTextViewDelegate
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let urlObj = link as? URL
        let rawStr = (urlObj?.absoluteString ?? (link as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawStr.isEmpty else { return true }

        // External URI schemes (http, https, mailto, file, etc.)
        if let urlObj, let scheme = urlObj.scheme?.lowercased(), !scheme.isEmpty {
            NSWorkspace.shared.open(urlObj)
            return true
        }

        // Internal bookmark / TOC anchor (`#...` or scheme-less anchor)
        if rawStr.hasPrefix("#") || !rawStr.contains(".") || rawStr.contains(" ") {
            let rawAnchor = urlObj?.fragment ?? (rawStr.hasPrefix("#") ? String(rawStr.dropFirst()) : rawStr)
            let anchor = (rawAnchor.removingPercentEncoding ?? rawAnchor).trimmingCharacters(in: .whitespacesAndNewlines)

            var effRange = NSRange(location: max(0, min(charIndex, max(0, textStorage.length - 1))), length: 0)
            if charIndex >= 0 && charIndex < textStorage.length {
                _ = textStorage.attribute(.link, at: charIndex, effectiveRange: &effRange)
            }
            let clickedText = effRange.length > 0 ? (textStorage.string as NSString).substring(with: effRange) : ""

            if let targetRange = DocxEngine.resolveAnchorLocation(
                anchor: anchor,
                linkText: clickedText,
                sourceRange: effRange,
                in: textStorage
            ) {
                navigateToCharacterRange(targetRange)
            } else {
                NSSound.beep()
                statsLabel.stringValue = "No se encontró el destino en el documento (\(anchor.isEmpty ? clickedText : anchor))"
            }
            return true
        }

        if let webURL = URL(string: "https://\(rawStr)") {
            NSWorkspace.shared.open(webURL)
        }
        return true
    }

    private func navigateToCharacterRange(_ targetRange: NSRange) {
        guard textStorage.length > 0, !pageTextViews.isEmpty else { return }
        let targetLoc = max(0, min(targetRange.location, textStorage.length - 1))
        let idx = pageIndex(forCharacterLocation: targetLoc)
        guard idx >= 0, idx < pageTextViews.count else { return }
        let targetTV = pageTextViews[idx]
        guard let tc = targetTV.textContainer else { return }

        layoutManager.ensureLayout(for: tc)
        let gIdx = layoutManager.glyphIndexForCharacter(at: targetLoc)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: gIdx, effectiveRange: nil)
        let rectInDesk = targetTV.convert(lineRect, to: deskView)

        let clipView = scrollView.contentView
        let maxY = max(0, deskView.bounds.height - clipView.bounds.height)
        let desiredY = min(maxY, max(0, rectInDesk.minY - 40))
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: desiredY))
        scrollView.reflectScrolledClipView(clipView)

        isUpdatingPages = true
        activePageView = targetTV
        window?.makeFirstResponder(targetTV)
        targetTV.setSelectedRange(NSRange(location: targetLoc, length: 0))
        isUpdatingPages = false

        updateCurrentPageStatus(currentPage: idx + 1)
        ribbon.syncWithSelection(in: targetTV)

        if targetRange.length > 0 {
            let safeLen = min(targetRange.length, max(0, textStorage.length - targetLoc))
            if safeLen > 0 {
                targetTV.showFindIndicator(for: NSRange(location: targetLoc, length: safeLen))
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        setDirty(true)
        updateStatsAndPaperLayout()
        ribbon.syncWithSelection(in: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isUpdatingPages else { return }
        if let senderTV = notification.object as? EditorTextView,
           window?.firstResponder === senderTV {
            let targetIdx = pageIndex(forCharacterLocation: senderTV.selectedRange().location)
            let targetTV = pageTextViews[targetIdx]
            activePageView = targetTV
            if targetTV !== senderTV {
                isUpdatingPages = true
                window?.makeFirstResponder(targetTV)
                targetTV.scrollRangeToVisible(targetTV.selectedRange())
                isUpdatingPages = false
            }
            updateCurrentPageStatus(currentPage: targetIdx + 1)
            ribbon.syncWithSelection(in: targetTV)
        }
    }

    // MARK: - Document Lifecycle & File I/O
    func resetToBlankDocument() {
        fileURL = nil
        fileNameBase = "Documento sin título"
        fileExt = "docx"
        pageSetup = DocPageSetup()
        headerText = ""
        footerText = ""

        let def = DocxEngine.blockAttributes(for: "normal")
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacing = 6
        ps.lineHeightMultiple = 1.15
        textStorage.setAttributedString(NSAttributedString(string: "", attributes: [
            .font: def.font,
            .foregroundColor: def.color,
            .paragraphStyle: ps,
        ]))
        updateStatsAndPaperLayout()
        pageTextViews[0].typingAttributes = [
            .font: def.font,
            .foregroundColor: def.color,
            .paragraphStyle: ps,
        ]
        ribbon.updatePageSetup(pageSetup)
        setDirty(false)
        scrollView.contentView.scroll(.zero)
        window?.makeFirstResponder(pageTextViews[0])
    }

    func confirmDiscardIfDirty() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "¿Guardar cambios en «\(fileNameBase).\(fileExt)»?"
        alert.informativeText = "Si no guardas, perderás los cambios recientes."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "No guardar")
        alert.addButton(withTitle: "Cancelar")
        alert.alertStyle = .warning
        let res = alert.runModal()
        if res == .alertFirstButtonReturn {
            return saveDocument(saveAs: false)
        }
        return res == .alertSecondButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmDiscardIfDirty()
    }

    func openFileDialog() {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let exts = ["docx", "doc", "rtf", "odt", "md", "txt", "html", "htm"]
        panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        guard let win = window else { return }
        panel.beginSheetModal(for: win) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openDocument(at: url)
        }
    }

    func confirmAndOpen(url: URL) {
        guard confirmDiscardIfDirty() else { return }
        openDocument(at: url)
    }

    func openDocument(at url: URL) {
        let ext = url.pathExtension.lowercased()
        let baseName = url.deletingPathExtension().lastPathComponent

        do {
            if ext == "docx" {
                let data = try Data(contentsOf: url)
                let parsed = try DocxEngine.readDocx(data: data)
                applyLoadedDocument(parsed, url: url, baseName: baseName, ext: "docx")
            } else if ["doc", "rtf", "odt"].contains(ext) {
                let convertedData = try FormatConverters.convertLegacyToDocxData(url: url)
                let parsed = try DocxEngine.readDocx(data: convertedData)
                // Legacy binary .doc/.odt opens safely without overwriting original binary on Save unless user picks path
                let targetURL: URL? = nil
                applyLoadedDocument(parsed, url: targetURL, baseName: baseName, ext: "docx")
            } else if ext == "md" {
                let str = try String(contentsOf: url, encoding: .utf8)
                textStorage.setAttributedString(FormatConverters.readMarkdown(str))
                fileURL = url
                fileNameBase = baseName
                fileExt = "md"
                setDirty(false)
            } else if ext == "html" || ext == "htm" {
                let data = try Data(contentsOf: url)
                textStorage.setAttributedString(try FormatConverters.readHtml(data: data))
                fileURL = url
                fileNameBase = baseName
                fileExt = "html"
                setDirty(false)
            } else {
                let str = try String(contentsOf: url, encoding: .utf8)
                textStorage.setAttributedString(FormatConverters.readPlainText(str))
                fileURL = url
                fileNameBase = baseName
                fileExt = ext.isEmpty ? "txt" : ext
                setDirty(false)
            }
            let pagePt = pageSetup.effectivePageSizePt
            let margins = pageSetup.marginsPt
            let firstTV = pageTextViews[0]
            firstTV.maxContentWidthPt = pageSetup.printableWidthPt
            firstTV.maxContentHeightPt = max(200, pagePt.height - margins.top - margins.bottom)
            firstTV.clampOversizedAttachments()
            updateStatsAndPaperLayout()
            firstTV.setSelectedRange(NSRange(location: 0, length: 0))
            activePageView = firstTV
            scrollView.contentView.scroll(.zero)
            ribbon.syncWithSelection(in: firstTV)
            window?.makeFirstResponder(firstTV)
        } catch {
            showError(title: "No se pudo abrir el documento", message: error.localizedDescription)
        }
    }

    private func applyLoadedDocument(_ parsed: ParsedDocxDocument, url: URL?, baseName: String, ext: String) {
        pageSetup = parsed.pageSetup
        headerText = parsed.headerText
        footerText = parsed.footerText
        fileURL = url
        fileNameBase = baseName
        fileExt = ext
        textStorage.setAttributedString(parsed.attributedString)
        ribbon.updatePageSetup(pageSetup)
        setDirty(false)
    }

    @discardableResult
    func saveDocument(saveAs: Bool, forceExt: String? = nil) -> Bool {
        let targetExt = forceExt ?? (["docx", "rtf", "md", "html", "txt"].contains(fileExt) ? fileExt : "docx")
        if !saveAs && forceExt == nil, let url = fileURL {
            return writeDocument(to: url, ext: targetExt)
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(fileNameBase).\(targetExt)"
        if let ut = UTType(filenameExtension: targetExt) {
            panel.allowedContentTypes = [ut]
        }
        guard panel.runModal() == .OK, let chosenURL = panel.url else {
            return false
        }
        let chosenExt = chosenURL.pathExtension.isEmpty ? targetExt : chosenURL.pathExtension.lowercased()
        let success = writeDocument(to: chosenURL, ext: chosenExt)
        if success && forceExt == nil {
            fileURL = chosenURL
            fileNameBase = chosenURL.deletingPathExtension().lastPathComponent
            fileExt = chosenExt
            setDirty(false)
        }
        return success
    }

    private func writeDocument(to url: URL, ext: String) -> Bool {
        let storage = textStorage
        do {
            let data: Data
            switch ext {
            case "docx":
                data = try DocxEngine.writeDocx(
                    attributedString: storage,
                    pageSetup: pageSetup,
                    title: fileNameBase,
                    headerText: headerText,
                    footerText: footerText
                )
            case "rtf":
                data = try FormatConverters.writeRtf(storage)
            case "md":
                data = FormatConverters.writeMarkdown(storage)
            case "html", "htm":
                data = try FormatConverters.writeHtml(storage)
            default:
                data = FormatConverters.writePlainText(storage)
            }
            try data.write(to: url, options: .atomic)
            if fileURL == url { setDirty(false) }
            return true
        } catch {
            showError(title: "Error al guardar", message: error.localizedDescription)
            return false
        }
    }

    func exportPdf() {
        guard let win = window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(fileNameBase).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: win) { [weak self] response in
            guard let self, response == .OK, let targetURL = panel.url else { return }
            let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
            printInfo.jobDisposition = .save
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = targetURL
            printInfo.paperSize = self.pageSetup.effectivePageSizePt
            printInfo.orientation = self.pageSetup.orientation == .landscape ? .landscape : .portrait
            let m = self.pageSetup.marginsPt
            printInfo.topMargin = m.top
            printInfo.rightMargin = m.right
            printInfo.bottomMargin = m.bottom
            printInfo.leftMargin = m.left
            printInfo.isHorizontallyCentered = false
            printInfo.isVerticallyCentered = false

            let printableW = self.pageSetup.printableWidthPt
            let printableH = max(200, self.pageSetup.effectivePageSizePt.height - m.top - m.bottom)
            let pStorage = NSTextStorage(attributedString: self.textStorage)
            let pLM = NSLayoutManager()
            pStorage.addLayoutManager(pLM)
            let pTC = NSTextContainer(containerSize: NSSize(width: printableW, height: .greatestFiniteMagnitude))
            pTC.widthTracksTextView = false
            pTC.lineFragmentPadding = 0
            pLM.addTextContainer(pTC)
            let printView = EditorTextView(frame: NSRect(x: 0, y: 0, width: printableW, height: printableH), textContainer: pTC)
            printView.isVerticallyResizable = true
            printView.isHorizontallyResizable = false
            printView.printHeaderText = self.headerText
            printView.printFooterText = self.footerText
            pLM.ensureLayout(for: pTC)
            let used = pLM.usedRect(for: pTC)
            printView.setFrameSize(NSSize(width: printableW, height: max(printableH, ceil(used.height))))

            let op = NSPrintOperation(view: printView, printInfo: printInfo)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            op.run()
        }
    }

    // MARK: - Zoom Actions
    private func setZoom(_ pct: Double) {
        let clamped = max(50, min(200, round(pct)))
        scrollView.magnification = CGFloat(clamped / 100.0)
        zoomSlider.doubleValue = clamped
        zoomButton.title = "\(Int(clamped))%"
        updateStatsAndPaperLayout()
    }

    @objc private func onScrollOrZoomChanged() {
        let pct = round(Double(scrollView.magnification) * 100.0)
        zoomSlider.doubleValue = pct
        zoomButton.title = "\(Int(pct))%"
    }

    @objc private func onZoomSliderChanged() { setZoom(zoomSlider.doubleValue) }
    @objc private func onZoomIn() { setZoom(zoomSlider.doubleValue + 10) }
    @objc private func onZoomOut() { setZoom(zoomSlider.doubleValue - 10) }
    @objc private func onZoomReset() { setZoom(100) }

    // MARK: - RibbonDelegate
    func ribbonDidRequestNew() {
        if confirmDiscardIfDirty() { resetToBlankDocument() }
    }
    func ribbonDidRequestOpen() { openFileDialog() }
    func ribbonDidRequestSave(saveAs: Bool) { saveDocument(saveAs: saveAs) }
    func ribbonDidRequestExportPdf() { exportPdf() }
    func ribbonDidRequestExportFormat(_ ext: String) { saveDocument(saveAs: true, forceExt: ext) }
    func ribbonDidRequestUndo() { textView.undoManager?.undo() }
    func ribbonDidRequestRedo() { textView.undoManager?.redo() }
    func ribbonDidRequestFind() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performFindPanelAction(item)
    }
    func ribbonDidToggleTheme() {
        isDarkAppearance.toggle()
        window?.appearance = NSAppearance(named: isDarkAppearance ? .darkAqua : .aqua)
        updateDeskThemeColors()
        rulerView.needsDisplay = true
    }

    func ribbonDidSelectBlockKind(_ kind: String) {
        textView.applyBlockKind(kind)
        window?.makeFirstResponder(textView)
    }
    func ribbonDidSelectFontFamily(_ family: String) {
        textView.applyFontFamily(family)
        window?.makeFirstResponder(textView)
    }
    func ribbonDidSelectFontSize(_ pt: CGFloat) {
        textView.applyFontSize(pt)
        window?.makeFirstResponder(textView)
    }
    func ribbonDidToggleBold() { textView.toggleFontTrait(.boldFontMask); window?.makeFirstResponder(textView) }
    func ribbonDidToggleItalic() { textView.toggleFontTrait(.italicFontMask); window?.makeFirstResponder(textView) }
    func ribbonDidToggleUnderline() { textView.toggleUnderline(); window?.makeFirstResponder(textView) }
    func ribbonDidToggleStrike() { textView.toggleStrikethrough(); window?.makeFirstResponder(textView) }
    func ribbonDidToggleSuperscript(_ val: Int) { textView.toggleSuperscript(val); window?.makeFirstResponder(textView) }
    func ribbonDidSelectTextColor(_ color: NSColor) { textView.applyTextColor(color); window?.makeFirstResponder(textView) }
    func ribbonDidSelectHighlightColor(_ color: NSColor?) { textView.applyHighlightColor(color); window?.makeFirstResponder(textView) }
    func ribbonDidClearFormatting() { textView.clearFormatting(); window?.makeFirstResponder(textView) }
    func ribbonDidSelectAlignment(_ align: NSTextAlignment) { textView.applyParagraphAlignment(align); window?.makeFirstResponder(textView) }
    func ribbonDidToggleList(ordered: Bool) { textView.toggleList(ordered: ordered); window?.makeFirstResponder(textView) }
    func ribbonDidAdjustIndent(delta: CGFloat) { textView.adjustIndent(delta: delta); window?.makeFirstResponder(textView) }
    func ribbonDidSelectLineSpacing(_ mult: CGFloat) { textView.applyLineSpacing(mult); window?.makeFirstResponder(textView) }

    func ribbonDidRequestInsertTable() {
        let alert = NSAlert()
        alert.messageText = "Insertar tabla"
        alert.informativeText = "Elige el número de filas y columnas:"
        let rowsField = NSTextField(string: "3")
        let colsField = NSTextField(string: "3")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Filas:"), rowsField],
            [NSTextField(labelWithString: "Columnas:"), colsField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.setFrameSize(NSSize(width: 220, height: 54))
        alert.accessoryView = grid
        alert.addButton(withTitle: "Insertar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            let r = Int(rowsField.stringValue) ?? 3
            let c = Int(colsField.stringValue) ?? 3
            textView.insertTable(rows: r, cols: c)
            window?.makeFirstResponder(textView)
        }
    }

    func ribbonDidRequestInsertImage() {
        guard let win = window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .bmp, .heic]
        panel.beginSheetModal(for: win) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.textView.insertImage(from: url)
            self.window?.makeFirstResponder(self.textView)
        }
    }

    func ribbonDidRequestInsertLink() {
        let alert = NSAlert()
        alert.messageText = "Insertar enlace"
        let selStr = (textView.string as NSString).substring(with: textView.selectedRange())
        let textField = NSTextField(string: selStr)
        textField.placeholderString = "Texto a mostrar"
        let urlField = NSTextField(string: "https://")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Texto:"), textField],
            [NSTextField(labelWithString: "URL:"), urlField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.setFrameSize(NSSize(width: 300, height: 54))
        alert.accessoryView = grid
        alert.addButton(withTitle: "Insertar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            let urlStr = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: urlStr), !urlStr.isEmpty, urlStr != "https://" {
                let label = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                textView.insertHyperlink(text: label.isEmpty ? urlStr : label, url: url)
            }
        }
    }

    func ribbonDidRequestInsertRule() { textView.insertHorizontalRule(); window?.makeFirstResponder(textView) }
    func ribbonDidRequestInsertPageBreak() { textView.insertPageBreak(); window?.makeFirstResponder(textView) }
    func ribbonDidRequestInsertDate() { textView.insertCurrentDate(); window?.makeFirstResponder(textView) }

    func ribbonDidRequestHeaderFooter() {
        let alert = NSAlert()
        alert.messageText = "Encabezado y Pie de página"
        let hdrField = NSTextField(string: headerText)
        hdrField.placeholderString = "Encabezado (opcional)"
        let ftrField = NSTextField(string: footerText)
        ftrField.placeholderString = "Pie de página (opcional)"
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Encabezado:"), hdrField],
            [NSTextField(labelWithString: "Pie:"), ftrField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.setFrameSize(NSSize(width: 320, height: 56))
        alert.accessoryView = grid
        alert.addButton(withTitle: "Aplicar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            headerText = hdrField.stringValue
            footerText = ftrField.stringValue
            setDirty(true)
            updateStatsAndPaperLayout()
        }
    }

    private func refreshPageGeometryAndClamp() {
        let pagePt = pageSetup.effectivePageSizePt
        let margins = pageSetup.marginsPt
        textView.maxContentWidthPt = pageSetup.printableWidthPt
        textView.maxContentHeightPt = max(200, pagePt.height - margins.top - margins.bottom)
        textView.clampOversizedAttachments()
        setDirty(true)
        updateStatsAndPaperLayout()
        window?.makeFirstResponder(textView)
    }

    func ribbonDidChangePaperSize(_ size: PaperSize) {
        pageSetup.size = size
        pageSetup.customSizePt = nil
        refreshPageGeometryAndClamp()
    }

    func ribbonDidChangeOrientation(_ orient: PageOrientation) {
        pageSetup.orientation = orient
        refreshPageGeometryAndClamp()
    }

    func ribbonDidChangeMargins(preset: String) {
        switch preset {
        case "narrow":
            pageSetup.marginTopMm = 12.7; pageSetup.marginRightMm = 12.7
            pageSetup.marginBottomMm = 12.7; pageSetup.marginLeftMm = 12.7
        case "wide":
            pageSetup.marginTopMm = 35; pageSetup.marginRightMm = 35
            pageSetup.marginBottomMm = 35; pageSetup.marginLeftMm = 35
        default:
            pageSetup.marginTopMm = 25; pageSetup.marginRightMm = 25
            pageSetup.marginBottomMm = 25; pageSetup.marginLeftMm = 25
        }
        refreshPageGeometryAndClamp()
    }

    func ribbonDidToggleRuler() {
        showRuler.toggle()
        updateStatsAndPaperLayout()
        window?.makeFirstResponder(textView)
    }

    func ribbonDidTableAction(_ action: String) {
        switch action {
        case "rowAbove": textView.addTableRow(below: false)
        case "rowBelow": textView.addTableRow(below: true)
        case "colLeft": textView.addTableColumn(after: false)
        case "colRight": textView.addTableColumn(after: true)
        case "delRow": textView.deleteTableRow()
        case "delCol": textView.deleteTableColumn()
        case "delTable": textView.deleteCurrentTable()
        default: break
        }
        window?.makeFirstResponder(textView)
    }

    func ribbonDidTableCellColor(_ color: NSColor?) {
        textView.setCurrentCellBackground(color)
        window?.makeFirstResponder(textView)
    }

    func ribbonDidImageResize(fraction: CGFloat) {
        textView.resizeSelectedImage(widthFraction: fraction)
        window?.makeFirstResponder(textView)
    }

    func ribbonDidImageDelete() {
        textView.deleteSelectedImage()
        window?.makeFirstResponder(textView)
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Aceptar")
        alert.runModal()
    }
}

final class PaperRulerView: NSView {
    var leftMarginPt: CGFloat = 70.87
    var rightMarginPt: CGFloat = 70.87

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let marginBg = isDark
            ? NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1.0)
            : NSColor(srgbRed: 0.85, green: 0.87, blue: 0.91, alpha: 1.0)
        let activeBg = isDark
            ? NSColor(srgbRed: 0.17, green: 0.20, blue: 0.26, alpha: 1.0)
            : NSColor(srgbRed: 0.98, green: 0.99, blue: 1.0, alpha: 1.0)
        let borderColor = isDark
            ? NSColor(srgbRed: 0.26, green: 0.30, blue: 0.38, alpha: 1.0)
            : NSColor(srgbRed: 0.78, green: 0.81, blue: 0.87, alpha: 1.0)
        let tickColor = isDark
            ? NSColor(srgbRed: 0.60, green: 0.65, blue: 0.74, alpha: 1.0)
            : NSColor(srgbRed: 0.42, green: 0.47, blue: 0.56, alpha: 1.0)

        let path = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        marginBg.setFill()
        path.fill()

        let activeW = max(0, bounds.width - leftMarginPt - rightMarginPt)
        let activeRect = NSRect(x: leftMarginPt, y: 1, width: activeW, height: bounds.height - 2)
        activeBg.setFill()
        activeRect.fill()

        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        // Metric ruler ticks (cm) anchored at leftMarginPt (0 cm)
        let ptPerCm: CGFloat = 72.0 / 2.54
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: tickColor,
        ]
        tickColor.setStroke()

        let startIndex = -Int(floor(leftMarginPt / (ptPerCm / 2.0)))
        let endIndex = Int(floor((bounds.width - leftMarginPt) / (ptPerCm / 2.0)))
        for halfStep in startIndex...endIndex {
            let x = leftMarginPt + CGFloat(halfStep) * (ptPerCm / 2.0)
            guard x > 3 && x < bounds.width - 3 else { continue }
            let isWholeCm = (halfStep % 2 == 0)
            let tickH: CGFloat = isWholeCm ? 7 : 4
            let line = NSBezierPath()
            line.move(to: NSPoint(x: floor(x) + 0.5, y: bounds.height - tickH))
            line.line(to: NSPoint(x: floor(x) + 0.5, y: bounds.height - 1))
            line.lineWidth = isWholeCm ? 1.0 : 0.75
            line.stroke()

            if isWholeCm && halfStep >= 0 {
                let cm = halfStep / 2
                if cm > 0 {
                    ("\(cm)" as NSString).draw(at: NSPoint(x: floor(x) - 3, y: 1), withAttributes: labelAttrs)
                }
            }
        }
    }
}
