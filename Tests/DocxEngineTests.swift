import Cocoa

@main
struct DocxTestsRunner {
    static func check(_ cond: @autoclosure () -> Bool, _ message: String) {
        if !cond() {
            fputs("❌ Assertion failed: \(message)\n", stderr)
            exit(1)
        }
    }

    static func makeTinyPngData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 24,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.12, green: 0.45, blue: 0.85, alpha: 1.0).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 24, height: 16)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func testPureZip() throws {
        let payloadA = Data("Hola mundo comprimido 🚀 ".utf8) + Data(repeating: 65, count: 1024)
        let payloadB = Data("short".utf8)
        let entries: [String: Data] = [
            "folder/archivo-utf8-ñ.txt": payloadA,
            "small.txt": payloadB,
            "empty.bin": Data(),
        ]
        let zipData = try PureZip.write(entries: entries)
        let unpacked = try PureZip.read(data: zipData)
        check(unpacked.count == 3, "Expected 3 ZIP entries, got \(unpacked.count)")
        check(unpacked["folder/archivo-utf8-ñ.txt"] == payloadA, "Payload A mismatch")
        check(unpacked["small.txt"] == payloadB, "Payload B mismatch")
        check(unpacked["empty.bin"] == Data(), "Empty entry mismatch")

        let tmpZip = FileManager.default.temporaryDirectory.appendingPathComponent("ow-zip-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: tmpZip) }
        try zipData.write(to: tmpZip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", tmpZip.path]
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        try unzip.run()
        unzip.waitUntilExit()
        check(unzip.terminationStatus == 0, "unzip -t failed on PureZip archive")
        print("✔ PureZip round-trip & unzip -t passed")
    }

    static func testFormatConverters() throws {
        let mdInput = "# Título MD\n\nTexto **negrita** y *cursiva*.\n\n- Uno\n- Dos\n\n1. Primero\n2. Segundo\n"
        let attr = FormatConverters.readMarkdown(mdInput)
        check(attr.string.contains("Título MD"), "Markdown missing heading")
        check(attr.string.contains("Primero"), "Markdown missing ordered item")

        let mdOut = String(decoding: FormatConverters.writeMarkdown(attr), as: UTF8.self)
        check(mdOut.contains("# Título MD"), "Markdown write missing heading prefix")
        check(mdOut.contains("**negrita**"), "Markdown write missing bold markers")

        let plain = FormatConverters.readPlainText("Línea A\r\nLínea B")
        check(String(decoding: FormatConverters.writePlainText(plain), as: UTF8.self) == "Línea A\nLínea B\n", "PlainText mismatch")

        let rtf = try FormatConverters.writeRtf(attr)
        check(rtf.count > 20, "RTF write empty")
        let html = try FormatConverters.writeHtml(attr)
        let backHtml = try FormatConverters.readHtml(data: html)
        check(backHtml.string.contains("Título MD"), "HTML round-trip failed")
        print("✔ FormatConverters Markdown/Text/RTF/HTML tests passed")
    }

    static func testDocxRoundTrip() throws {
        let doc = NSMutableAttributedString()

        func appendPara(_ text: String, kind: String = "normal", bold: Bool = false, italic: Bool = false, align: NSTextAlignment = .left, color: NSColor? = nil, highlight: NSColor? = nil) {
            let cfg = DocxEngine.blockAttributes(for: kind)
            let ps = NSMutableParagraphStyle()
            ps.alignment = align
            ps.paragraphSpacingBefore = cfg.spaceBefore
            ps.paragraphSpacing = cfg.spaceAfter
            let font = DocxEngine.resolveFont(family: "Calibri", sizePt: cfg.font.pointSize, bold: bold || kind.hasPrefix("h"), italic: italic)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color ?? cfg.color,
                .paragraphStyle: ps,
            ]
            if kind != "normal" { attrs[.owBlockKind] = kind }
            if let highlight { attrs[.backgroundColor] = highlight }
            doc.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }

        appendPara("Informe Nativo", kind: "h1", align: .center)
        appendPara("Subtítulo", kind: "h2")
        appendPara("Párrafo en negrita y color.", bold: true, color: NSColor(srgbRed: 0.1, green: 0.4, blue: 0.8, alpha: 1.0), highlight: .yellow)

        // Bulleted & numbered lists
        let bulletPs = NSMutableParagraphStyle()
        bulletPs.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        doc.append(NSAttributedString(string: "\t•\tViñeta uno\n", attributes: [
            .font: DocxEngine.blockAttributes(for: "normal").font,
            .paragraphStyle: bulletPs,
        ]))

        let numPs = NSMutableParagraphStyle()
        numPs.textLists = [NSTextList(markerFormat: .decimal, options: 0)]
        doc.append(NSAttributedString(string: "\t1.\tPrimer paso\n", attributes: [
            .font: DocxEngine.blockAttributes(for: "normal").font,
            .paragraphStyle: numPs,
        ]))

        // Embedded image attachment
        let pngData = makeTinyPngData()
        if let img = NSImage(data: pngData) {
            let att = NSTextAttachment()
            att.image = img
            att.fileWrapper = FileWrapper(regularFileWithContents: pngData)
            att.fileWrapper?.preferredFilename = "sample.png"
            let imgStr = NSMutableAttributedString(attachment: att)
            imgStr.append(NSAttributedString(string: "\n", attributes: [.font: DocxEngine.blockAttributes(for: "normal").font]))
            doc.append(imgStr)
        }

        // Table
        let tbl = NSTextTable()
        tbl.numberOfColumns = 2
        for r in 0..<2 {
            for c in 0..<2 {
                let block = NSTextTableBlock(table: tbl, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(1.0, type: .absoluteValueType, for: .border)
                block.setBorderColor(.gray)
                block.setValue(50.0, type: .percentageValueType, for: .width)
                if r == 0 { block.backgroundColor = NSColor(srgbRed: 0.92, green: 0.95, blue: 1.0, alpha: 1.0) }
                let ps = NSMutableParagraphStyle()
                ps.textBlocks = [block]
                doc.append(NSAttributedString(string: "R\(r)C\(c)\n", attributes: [
                    .font: DocxEngine.blockAttributes(for: "normal").font,
                    .paragraphStyle: ps,
                ]))
            }
        }

        // Explicit page break
        let pbPs = NSMutableParagraphStyle()
        doc.append(NSAttributedString(string: "\u{000C}\n", attributes: [
            .font: DocxEngine.blockAttributes(for: "normal").font,
            .paragraphStyle: pbPs,
        ]))
        appendPara("Segunda página")

        var setup = DocPageSetup()
        setup.size = .letter
        setup.orientation = .landscape
        setup.marginTopMm = 20
        setup.marginLeftMm = 30

        let docxData = try DocxEngine.writeDocx(
            attributedString: doc,
            pageSetup: setup,
            title: "Informe Nativo",
            headerText: "Encabezado Nativo",
            footerText: "Pie Nativo"
        )

        let tmpDocx = FileManager.default.temporaryDirectory.appendingPathComponent("ow-test-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tmpDocx) }
        try docxData.write(to: tmpDocx)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", tmpDocx.path]
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        try unzip.run()
        unzip.waitUntilExit()
        check(unzip.terminationStatus == 0, "unzip -t failed on generated .docx")

        let parsed = try DocxEngine.readDocx(data: docxData)
        check(parsed.pageSetup.size == .letter, "Expected Letter size on round-trip")
        check(parsed.pageSetup.orientation == .landscape, "Expected landscape on round-trip")
        check(parsed.headerText.contains("Encabezado Nativo"), "Header round-trip mismatch: \(parsed.headerText)")
        check(parsed.footerText.contains("Pie Nativo"), "Footer round-trip mismatch: \(parsed.footerText)")

        let out = parsed.attributedString
        check(out.string.contains("Informe Nativo"), "Missing heading text")
        check(out.string.contains("R1C1"), "Missing table cell R1C1")
        check(out.string.contains("Segunda página"), "Missing second page text")

        var foundImage = false
        var foundTable = false
        var foundList = false
        let foundPageBreak = out.string.contains("\u{000C}")
        out.enumerateAttributes(in: NSRange(location: 0, length: out.length)) { attrs, _, _ in
            if let att = attrs[.attachment] as? NSTextAttachment, att.image != nil {
                foundImage = true
            }
            if let ps = attrs[.paragraphStyle] as? NSParagraphStyle {
                if !ps.textBlocks.isEmpty { foundTable = true }
                if !ps.textLists.isEmpty { foundList = true }
            }
        }
        check(foundImage, "Round-trip missing image NSTextAttachment")
        check(foundTable, "Round-trip missing NSTextTableBlock")
        check(foundList, "Round-trip missing NSTextList")
        check(foundPageBreak, "Round-trip missing pageBreak")

        // Cross-check generated .docx with macOS /usr/bin/textutil
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ow-tu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let docxFile = tmpDir.appendingPathComponent("out.docx")
        let htmlFile = tmpDir.appendingPathComponent("out.html")
        try docxData.write(to: docxFile)

        let tu = Process()
        tu.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        tu.arguments = ["-convert", "html", "-output", htmlFile.path, docxFile.path]
        try tu.run()
        tu.waitUntilExit()
        check(tu.terminationStatus == 0, "textutil failed on generated .docx")
        let htmlOut = try String(contentsOf: htmlFile, encoding: .utf8)
        check(htmlOut.contains("Informe Nativo") && htmlOut.contains("Primer paso"), "textutil HTML missing expected content")

        // Reverse check: read external .docx created by textutil
        let extDocx = tmpDir.appendingPathComponent("ext.docx")
        let extHtml = tmpDir.appendingPathComponent("ext.html")
        try "<html><body><h1>Externo Mac</h1><p>Contenido <b>real</b>.</p></body></html>".write(to: extHtml, atomically: true, encoding: .utf8)
        let tu2 = Process()
        tu2.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        tu2.arguments = ["-convert", "docx", "-output", extDocx.path, extHtml.path]
        try tu2.run()
        tu2.waitUntilExit()
        check(tu2.terminationStatus == 0, "textutil failed generating ext.docx")
        let extData = try Data(contentsOf: extDocx)
        let extParsed = try DocxEngine.readDocx(data: extData)
        check(extParsed.attributedString.string.contains("Externo Mac"), "readDocx failed on external textutil .docx")

        try verifyTrailingTableAndPdfExport()
        print("✔ DocxEngine round-trip (tables, images, lists, formatting, textutil, PDF) passed")
    }

    static func verifyTrailingTableAndPdfExport() throws {
        _ = NSApplication.shared
        let tv = EditorTextView()
        let setup = DocPageSetup()
        tv.frame = NSRect(x: 0, y: 0, width: setup.printableWidthPt, height: 600)
        tv.maxContentWidthPt = setup.printableWidthPt
        tv.textContainer?.containerSize = NSSize(width: setup.printableWidthPt, height: .greatestFiniteMagnitude)
        tv.textStorage?.setAttributedString(NSAttributedString(string: "Título de prueba\n"))
        tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
        tv.insertTable(rows: 2, cols: 2)
        tv.printHeaderText = "Encabezado PDF"
        tv.printFooterText = "Pie PDF"

        guard let storage = tv.textStorage else {
            fputs("❌ Missing textStorage\n", stderr); exit(1)
        }

        // Write .docx ending right in a table and confirm readDocx appends safe trailing paragraph
        let docxBytes = try DocxEngine.writeDocx(attributedString: storage, pageSetup: setup, title: "TablaFinal")
        let parsed = try DocxEngine.readDocx(data: docxBytes)
        let parsedStr = parsed.attributedString
        check(parsedStr.length > 0, "Parsed trailing-table doc is empty")
        let lastPs = parsedStr.attribute(.paragraphStyle, at: parsedStr.length - 1, effectiveRange: nil) as? NSParagraphStyle
        check(lastPs?.textBlocks.isEmpty ?? true, "readDocx should end with non-table paragraph after trailing table")

        // Verify vector PDF export via NSPrintOperation
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let used = tv.layoutManager?.usedRect(for: tv.textContainer!) ?? tv.bounds
        let printRect = NSRect(x: 0, y: 0, width: setup.printableWidthPt, height: max(200, used.height + 20))
        let pdfData = NSMutableData()
        let pi = NSPrintInfo.shared.copy() as! NSPrintInfo
        pi.paperSize = setup.effectivePageSizePt
        pi.isHorizontallyCentered = false
        pi.isVerticallyCentered = false
        let op = NSPrintOperation.pdfOperation(with: tv, inside: printRect, to: pdfData, printInfo: pi)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        let ok = op.run()
        check(ok && pdfData.length > 500, "NSPrintOperation PDF export produced empty output")
        let header = String(decoding: (pdfData as Data).prefix(5), as: UTF8.self)
        check(header == "%PDF-", "Expected %PDF- header, got \(header)")

        // Verify pageBreakBefore and paragraph-level sectPr section breaks + multi-container pagination
        let customDocXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>Portada</w:t></w:r></w:p>
            <w:p><w:pPr><w:pageBreakBefore/></w:pPr><w:r><w:t>Índice</w:t></w:r></w:p>
            <w:p><w:pPr><w:sectPr><w:type w:val="nextPage"/></w:sectPr></w:pPr><w:r><w:t>Fin sección</w:t></w:r></w:p>
            <w:p><w:r><w:t>Capítulo 1</w:t></w:r></w:p>
            <w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>
          </w:body>
        </w:document>
        """
        let customZip = try PureZip.write(entries: ["word/document.xml": Data(customDocXml.utf8)])
        let customParsed = try DocxEngine.readDocx(data: customZip)
        let customStr = customParsed.attributedString.string
        let breakCount = customStr.filter { $0 == "\u{000C}" }.count
        check(breakCount == 2, "Expected 2 page breaks from pageBreakBefore + sectPr, got \(breakCount)")

        let pagStorage = NSTextStorage(attributedString: customParsed.attributedString)
        let pagLM = NSLayoutManager()
        pagStorage.addLayoutManager(pagLM)
        var tcs: [NSTextContainer] = []
        for _ in 0..<3 {
            let tc = NSTextContainer(containerSize: NSSize(width: 450, height: 650))
            pagLM.addTextContainer(tc)
            _ = EditorTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 650), textContainer: tc)
            tcs.append(tc)
        }
        for tc in tcs { pagLM.ensureLayout(for: tc) }
        let p0 = (pagStorage.string as NSString).substring(with: pagLM.characterRange(forGlyphRange: pagLM.glyphRange(for: tcs[0]), actualGlyphRange: nil))
        let p1 = (pagStorage.string as NSString).substring(with: pagLM.characterRange(forGlyphRange: pagLM.glyphRange(for: tcs[1]), actualGlyphRange: nil))
        let p2 = (pagStorage.string as NSString).substring(with: pagLM.characterRange(forGlyphRange: pagLM.glyphRange(for: tcs[2]), actualGlyphRange: nil))
        check(p0.contains("Portada") && !p0.contains("Índice"), "Page 0 should only contain Portada, got: \(p0)")
        check(p1.contains("Índice") && p1.contains("Fin sección") && !p1.contains("Capítulo 1"), "Page 1 mismatch: \(p1)")
        check(p2.contains("Capítulo 1"), "Page 2 should contain Capítulo 1, got: \(p2)")
    }

    static func testTypographyThemesEmbeddedFontsAndStyles() throws {
        // 1. Registro de fuentes incluidas y catálogo amplio (Word + macOS)
        DocxEngine.registerBundledFonts()
        let allFamilies = DocxEngine.allDisplayFontFamilies()
        check(allFamilies.count > 180, "Expected >180 font families, got \(allFamilies.count)")
        for required in ["Carlito", "Caladea", "Inter", "EB Garamond", "Lato", "Roboto"] {
            check(allFamilies.contains(where: { $0.caseInsensitiveCompare(required) == .orderedSame }),
                  "Missing bundled font family: \(required)")
        }

        // 2. Equivalentes métricos exactos y conservación del nombre lógico de Word
        let pairs: [(word: String, sub: String)] = [
            ("Calibri", "Carlito"),
            ("Cambria", "Caladea"),
            ("Aptos", "Inter"),
            ("Garamond", "EB Garamond"),
        ]
        for pair in pairs {
            let res = DocxEngine.resolveFontAndSource(family: pair.word, sizePt: 11.5, bold: false, italic: false)
            check(res.font.familyName == pair.sub,
                  "Expected \(pair.word) -> \(pair.sub), got \(res.font.familyName ?? "nil")")
            check(res.logicalName == pair.word,
                  "Expected logical name \(pair.word), got \(res.logicalName ?? "nil")")
        }

        // Round-trip conservando "Calibri" y "Aptos" en el .docx aunque se renderice con Carlito / Inter
        let attr = NSMutableAttributedString()
        let calibri = DocxEngine.resolveFontAndSource(family: "Calibri", sizePt: 11.5, bold: false, italic: false)
        let aptos = DocxEngine.resolveFontAndSource(family: "Aptos", sizePt: 12, bold: true, italic: false)
        attr.append(NSAttributedString(string: "Texto Calibri\n", attributes: [
            .font: calibri.font,
            .owFontName: calibri.logicalName ?? "",
        ]))
        attr.append(NSAttributedString(string: "Texto Aptos\n", attributes: [
            .font: aptos.font,
            .owFontName: aptos.logicalName ?? "",
        ]))
        let fontZipData = try DocxEngine.writeDocx(attributedString: attr, pageSetup: DocPageSetup(), title: "FontsTest")
        let rtEntries = try PureZip.read(data: fontZipData)
        let rtDocXml = String(data: rtEntries["word/document.xml"] ?? Data(), encoding: .utf8) ?? ""
        check(rtDocXml.contains("Calibri") && rtDocXml.contains("Aptos"),
              "Expected logical Word font names preserved in document.xml")
        let fontParsed = try DocxEngine.readDocx(data: fontZipData)
        let f0 = fontParsed.attributedString.attribute(.owFontName, at: 0, effectiveRange: nil) as? String
        check(f0 == "Calibri", "Expected round-tripped .owFontName == Calibri, got \(f0 ?? "nil")")

        // 3. Lectura de theme1.xml (majorFont / minorFont + w:asciiTheme)
        let themeXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Custom">
          <a:themeElements>
            <a:fontScheme name="CustomFonts">
              <a:majorFont><a:latin typeface="Georgia"/></a:majorFont>
              <a:minorFont><a:latin typeface="Cambria"/></a:minorFont>
            </a:fontScheme>
          </a:themeElements>
        </a:theme>
        """
        let relsXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rIdT1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
        </Relationships>
        """
        let themedDocXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:rPr><w:rFonts w:asciiTheme="majorHAnsi"/></w:rPr><w:t>Título Tema</w:t></w:r></w:p>
            <w:p><w:r><w:rPr><w:rFonts w:asciiTheme="minorHAnsi"/></w:rPr><w:t>Cuerpo Tema</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let themedZip = try PureZip.write(entries: [
            "word/theme/theme1.xml": Data(themeXml.utf8),
            "word/_rels/document.xml.rels": Data(relsXml.utf8),
            "word/document.xml": Data(themedDocXml.utf8),
        ])
        let themedParsed = try DocxEngine.readDocx(data: themedZip)
        let themedAttr = themedParsed.attributedString
        let majorIdx = (themedAttr.string as NSString).range(of: "Título Tema").location
        let minorIdx = (themedAttr.string as NSString).range(of: "Cuerpo Tema").location
        let majorFont = themedAttr.attribute(.font, at: majorIdx, effectiveRange: nil) as? NSFont
        let minorFont = themedAttr.attribute(.font, at: minorIdx, effectiveRange: nil) as? NSFont
        let minorLogical = themedAttr.attribute(.owFontName, at: minorIdx, effectiveRange: nil) as? String
        check(majorFont?.familyName == "Georgia", "Expected majorHAnsi -> Georgia, got \(majorFont?.familyName ?? "nil")")
        check(minorFont?.familyName == "Caladea" && minorLogical == "Cambria",
              "Expected minorHAnsi Cambria -> Caladea, got \(minorFont?.familyName ?? "nil") / \(minorLogical ?? "nil")")

        // 4. Desofuscación .odttf (ECMA-376 XOR) y extracción de word/fontTable.xml
        let carlitoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Fonts/Carlito-Regular.ttf")
        let rawTtf = try Data(contentsOf: carlitoURL)
        let keyHex: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00]
        let reversedKey = Array(keyHex.reversed())
        var odttf = rawTtf
        for i in 0..<32 { odttf[i] ^= reversedKey[i % 16] }

        let ftXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:fonts xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:font w:name="TestEmbedCarlito">
            <w:embedRegular r:id="rIdF1" w:fontKey="{11223344-5566-7788-99AA-BBCCDDEEFF00}"/>
          </w:font>
        </w:fonts>
        """
        let ftRelsXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rIdF1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/font" Target="fonts/font1.odttf"/>
        </Relationships>
        """
        let embedCacheFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeWordEmbeddedFonts/TestEmbedCarlito-embedRegular-rIdF1.ttf")
        try? FileManager.default.removeItem(at: embedCacheFile)
        let embedZip = try PureZip.write(entries: [
            "word/document.xml": Data(themedDocXml.utf8),
            "word/fontTable.xml": Data(ftXml.utf8),
            "word/_rels/fontTable.xml.rels": Data(ftRelsXml.utf8),
            "word/fonts/font1.odttf": odttf,
        ])
        _ = try DocxEngine.readDocx(data: embedZip)
        let extractedTtf = try Data(contentsOf: embedCacheFile)
        check(extractedTtf == rawTtf, "Deobfuscated .odttf should match original Carlito-Regular.ttf byte-for-byte")

        // 5. Round-trip de los estilos ampliados de bloque
        let stylesToTest = ["noSpacing", "h4", "intenseQuote", "caption", "code"]
        let styledAttr = NSMutableAttributedString()
        for kind in stylesToTest {
            let cfg = DocxEngine.fullBlockStyle(for: kind)
            let ps = NSMutableParagraphStyle()
            ps.paragraphSpacingBefore = cfg.spaceBefore
            ps.paragraphSpacing = cfg.spaceAfter
            ps.lineHeightMultiple = cfg.lineSpacing
            ps.alignment = cfg.align
            ps.headIndent = cfg.leftIndent
            ps.firstLineHeadIndent = cfg.leftIndent
            var attrs: [NSAttributedString.Key: Any] = [
                .font: cfg.font,
                .owFontName: cfg.logicalFontName,
                .foregroundColor: cfg.color,
                .paragraphStyle: ps,
                .owBlockKind: kind,
            ]
            if let bg = cfg.backgroundColor { attrs[.backgroundColor] = bg }
            styledAttr.append(NSAttributedString(string: "Bloque \(kind)\n", attributes: attrs))
        }
        let styledDocx = try DocxEngine.writeDocx(attributedString: styledAttr, pageSetup: DocPageSetup(), title: "StylesTest")
        let styledRead = try DocxEngine.readDocx(data: styledDocx).attributedString
        let styledNS = styledRead.string as NSString
        for kind in stylesToTest {
            let loc = styledNS.range(of: "Bloque \(kind)").location
            check(loc != NSNotFound, "Missing paragraph for style \(kind)")
            let gotKind = styledRead.attribute(.owBlockKind, at: loc, effectiveRange: nil) as? String
            check(gotKind == kind, "Expected round-tripped block kind \(kind), got \(gotKind ?? "nil")")
        }

        print("✔ Typography, themes, .odttf embedded fonts & 12 styles tests passed")
    }

    static func testInternalTocLinksAndBookmarks() throws {
        // Simula un Índice Word real: <w:hyperlink w:anchor>, fldSimple HYPERLINK \l, fldChar HYPERLINK \l,
        // marcadores <w:bookmarkStart>, anclas con espacios/acentos y fallback por título
        let tocDocXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>
            <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Índice</w:t></w:r></w:p>
            <w:sdt><w:sdtContent>
              <w:p>
                <w:pPr><w:pStyle w:val="TOC1"/></w:pPr>
                <w:hyperlink w:anchor="_Toc101"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr><w:t>Introducción</w:t></w:r></w:hyperlink>
                <w:r><w:tab/><w:t>3</w:t></w:r>
              </w:p>
              <w:p>
                <w:fldSimple w:instr=" HYPERLINK \\l &quot;Diseño del Sistema&quot; "><w:r><w:t>Diseño del Sistema</w:t></w:r></w:fldSimple>
                <w:r><w:tab/><w:t>4</w:t></w:r>
              </w:p>
              <w:p>
                <w:r><w:fldChar w:fldCharType="begin"/></w:r>
                <w:r><w:instrText> HYPERLINK \\l "_TocRotoSinMarcador" </w:instrText></w:r>
                <w:r><w:fldChar w:fldCharType="separate"/></w:r>
                <w:r><w:t>Conclusión final</w:t></w:r>
                <w:r><w:fldChar w:fldCharType="end"/></w:r>
                <w:r><w:tab/><w:t>17</w:t></w:r>
              </w:p>
            </w:sdtContent></w:sdt>
            <w:p><w:pPr><w:pageBreakBefore/><w:pStyle w:val="Heading1"/></w:pPr><w:bookmarkStart w:id="1" w:name="_Toc101"/><w:r><w:t>Introducción</w:t></w:r><w:bookmarkEnd w:id="1"/></w:p>
            <w:p><w:r><w:t>Contenido inicial.</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:bookmarkStart w:id="2" w:name="Diseño del Sistema"/><w:r><w:t>Diseño del Sistema</w:t></w:r><w:bookmarkEnd w:id="2"/></w:p>
            <w:p><w:r><w:t>Detalles de arquitectura.</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Conclusión final</w:t></w:r></w:p>
            <w:p><w:r><w:t>Texto de cierre. </w:t></w:r><w:hyperlink r:id="rIdExt1"><w:r><w:t>Sitio externo</w:t></w:r></w:hyperlink></w:p>
          </w:body>
        </w:document>
        """
        let tocStylesXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:style w:type="character" w:styleId="Hyperlink">
            <w:name w:val="Hyperlink"/>
            <w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="TOC1">
            <w:name w:val="toc 1"/>
          </w:style>
        </w:styles>
        """
        let tocRelsXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rIdExt1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com" TargetMode="External"/>
        </Relationships>
        """

        let zipData = try PureZip.write(entries: [
            "word/document.xml": Data(tocDocXml.utf8),
            "word/styles.xml": Data(tocStylesXml.utf8),
            "word/_rels/document.xml.rels": Data(tocRelsXml.utf8),
        ])
        let parsed = try DocxEngine.readDocx(data: zipData)
        let attr = parsed.attributedString
        let nsStr = attr.string as NSString

        // 0. Verificar apariencia: enlaces TOC en color normal sin subrayado; enlaces web en azul subrayado; EditorTextView sin sobrescribir linkTextAttributes
        let l1CheckLoc = nsStr.range(of: "Introducción").location
        let tocFg = (attr.attribute(.foregroundColor, at: l1CheckLoc, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        let tocUnderline = attr.attribute(.underlineStyle, at: l1CheckLoc, effectiveRange: nil)
        check(tocFg != nil && tocFg!.blueComponent < 0.30,
              "TOC link should render in normal text color, got blue=\(String(describing: tocFg?.blueComponent))")
        check(tocUnderline == nil, "TOC link should NOT be underlined by default")

        let extLoc = nsStr.range(of: "Sitio externo").location
        let extFg = (attr.attribute(.foregroundColor, at: extLoc, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        let extUnderline = attr.attribute(.underlineStyle, at: extLoc, effectiveRange: nil) as? Int
        check(extFg != nil && extFg!.blueComponent > 0.80 && extUnderline == NSUnderlineStyle.single.rawValue,
              "External link should stay blue and underlined, got blue=\(String(describing: extFg?.blueComponent)) underline=\(String(describing: extUnderline))")

        let checkTV = EditorTextView()
        check(checkTV.linkTextAttributes?[.foregroundColor] == nil && checkTV.linkTextAttributes?[.underlineStyle] == nil,
              "EditorTextView linkTextAttributes should not force blue/underline on internal TOC links")

        // 1. Verificar que los 3 enlaces del índice existen y tienen #ancla
        var r1 = NSRange()
        let l1Loc = nsStr.range(of: "Introducción").location
        let link1 = attr.attribute(.link, at: l1Loc, effectiveRange: &r1) as? URL
        check(link1?.absoluteString == "#_Toc101", "Expected #_Toc101, got \(link1?.absoluteString ?? "nil")")

        var r2 = NSRange()
        let l2Loc = nsStr.range(of: "Diseño del Sistema").location
        let link2 = attr.attribute(.link, at: l2Loc, effectiveRange: &r2) as? URL
        let dec2 = link2?.fragment?.removingPercentEncoding
        check(dec2 == "Diseño del Sistema", "Expected decoded anchor 'Diseño del Sistema', got \(dec2 ?? "nil")")

        var r3 = NSRange()
        let l3Loc = nsStr.range(of: "Conclusión final").location
        let link3 = attr.attribute(.link, at: l3Loc, effectiveRange: &r3) as? URL
        check(link3?.absoluteString == "#_TocRotoSinMarcador", "Expected fldChar #_TocRotoSinMarcador, got \(link3?.absoluteString ?? "nil")")

        // 2. Resolución hacia destino real (NO hacia el mismo enlace del índice)
        let hit1 = DocxEngine.resolveAnchorLocation(anchor: "_Toc101", linkText: "Introducción", sourceRange: r1, in: attr)
        check(hit1 != nil && hit1!.location > r3.location, "Hit 1 should jump past TOC to Introducción heading")
        check(hit1.map { nsStr.substring(with: $0) } == "Introducción", "Hit 1 text mismatch")

        let hit2 = DocxEngine.resolveAnchorLocation(anchor: "Diseño del Sistema", linkText: "Diseño del Sistema", sourceRange: r2, in: attr)
        check(hit2 != nil && hit2!.location > hit1!.location, "Hit 2 should jump to Diseño del Sistema heading")
        check(hit2.map { nsStr.substring(with: $0) } == "Diseño del Sistema", "Hit 2 text mismatch")

        // 3. Fallback por texto del título cuando falta bookmarkStart en el .docx
        let hit3 = DocxEngine.resolveAnchorLocation(anchor: "_TocRotoSinMarcador", linkText: "Conclusión final", sourceRange: r3, in: attr)
        check(hit3 != nil && hit3!.location > hit2!.location, "Hit 3 fallback should jump to Conclusión final heading")
        check(hit3.map { nsStr.substring(with: $0) } == "Conclusión final", "Hit 3 text mismatch")

        // 4. Round-trip writeDocx -> readDocx debe conservar w:anchor y bookmarkStart
        let rtData = try DocxEngine.writeDocx(attributedString: attr, pageSetup: DocPageSetup(), title: "TocTest")
        let rtEntries = try PureZip.read(data: rtData)
        let rtXml = String(data: rtEntries["word/document.xml"] ?? Data(), encoding: .utf8) ?? ""
        check(rtXml.contains(#"w:anchor="_Toc101""#), "writeDocx should emit w:anchor instead of external rel")
        check(rtXml.contains(#"w:name="_Toc101""#), "writeDocx should preserve bookmarkStart w:name")
        let rtParsed = try DocxEngine.readDocx(data: rtData).attributedString
        let rtHit1 = DocxEngine.resolveAnchorLocation(anchor: "_Toc101", linkText: "Introducción", sourceRange: NSRange(location: 0, length: 0), in: rtParsed)
        check(rtHit1 != nil, "Round-tripped TOC anchor should resolve cleanly")

        print("✔ Internal TOC hyperlinks, fields, bookmarks & anchor resolution tests passed")
    }

    static func testExactLayoutMetricsDefaultStyleAndTables() throws {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let docRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
        // Normal (default="1") overrides docDefaults font/spacing; ExplicitNoAfter omits spacing;
        // Tablanormal sets default table margins (0 vertical, 108 dxa horizontal) and borderless;
        // Tablaconcuadrcula inherits Tablanormal and adds after=0, line=240, borders sz=4 (0.5pt)
        let stylesXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:docDefaults>
            <w:rPrDefault><w:rPr><w:rFonts w:ascii="Cambria"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>
            <w:pPrDefault><w:pPr><w:spacing w:after="200" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>
          </w:docDefaults>
          <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
            <w:name w:val="Normal"/>
            <w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr>
            <w:rPr><w:rFonts w:ascii="Georgia"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="CompactLine">
            <w:name w:val="Compact Line"/>
            <w:pPr><w:spacing w:after="0" w:line="300" w:lineRule="exact"/></w:pPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="AtLeastLine">
            <w:name w:val="At Least Line"/>
            <w:pPr><w:spacing w:after="0" w:line="320" w:lineRule="atLeast"/></w:pPr>
          </w:style>
          <w:style w:type="table" w:default="1" w:styleId="Tablanormal">
            <w:name w:val="Normal Table"/>
            <w:tblPr>
              <w:tblCellMar>
                <w:top w:w="0" w:type="dxa"/>
                <w:left w:w="108" w:type="dxa"/>
                <w:bottom w:w="0" w:type="dxa"/>
                <w:right w:w="108" w:type="dxa"/>
              </w:tblCellMar>
            </w:tblPr>
          </w:style>
          <w:style w:type="table" w:styleId="Tablaconcuadrcula">
            <w:name w:val="Table Grid"/>
            <w:basedOn w:val="Tablanormal"/>
            <w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>
            <w:tblPr>
              <w:tblBorders>
                <w:top w:val="single" w:sz="4" w:space="0" w:color="334155"/>
                <w:left w:val="single" w:sz="4" w:space="0" w:color="334155"/>
                <w:bottom w:val="single" w:sz="4" w:space="0" w:color="334155"/>
                <w:right w:val="single" w:sz="4" w:space="0" w:color="334155"/>
              </w:tblBorders>
            </w:tblPr>
          </w:style>
        </w:styles>
        """
        let docXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>Párrafo sin pStyle explícito</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="CompactLine"/></w:pPr><w:r><w:t>ExactLine15</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="AtLeastLine"/></w:pPr><w:r><w:t>AtLeastLine16</w:t></w:r></w:p>
            <w:p><w:r><w:br w:type="page"/></w:r></w:p>
            <w:p><w:r><w:t>Después de salto</w:t></w:r></w:p>
            <w:tbl>
              <w:tblPr>
                <w:tblStyle w:val="Tablaconcuadrcula"/>
                <w:tblW w:w="8000" w:type="dxa"/>
              </w:tblPr>
              <w:tblGrid>
                <w:gridCol w:w="2000"/>
                <w:gridCol w:w="6000"/>
              </w:tblGrid>
              <w:tr>
                <w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>Col1</w:t></w:r></w:p></w:tc>
                <w:tc><w:tcPr><w:tcW w:w="6000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>Col2</w:t></w:r></w:p></w:tc>
              </w:tr>
            </w:tbl>
            <w:sectPr>
              <w:pgSz w:w="9979" w:h="14173"/>
              <w:pgMar w:top="-1134" w:right="1134" w:bottom="-1134" w:left="1134"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """
        let data = try PureZip.write(entries: [
            "[Content_Types].xml": Data(contentTypes.utf8),
            "_rels/.rels": Data(rels.utf8),
            "word/_rels/document.xml.rels": Data(docRels.utf8),
            "word/styles.xml": Data(stylesXml.utf8),
            "word/document.xml": Data(docXml.utf8),
        ])
        let parsed = try DocxEngine.readDocx(data: data)
        let attr = parsed.attributedString
        let nsStr = attr.string as NSString

        // 1. Default paragraph style (Normal -> Georgia, 11.0pt, after=6pt, line=1.10x)
        let p1Range = nsStr.range(of: "Párrafo sin pStyle explícito")
        let p1Font = attr.attribute(.font, at: p1Range.location, effectiveRange: nil) as? NSFont
        let p1Ps = attr.attribute(.paragraphStyle, at: p1Range.location, effectiveRange: nil) as? NSParagraphStyle
        check(p1Font?.fontName.lowercased().contains("georgia") == true,
              "Expected omitted pStyle to inherit default Normal Georgia font, got \(p1Font?.fontName ?? "nil")")
        check(abs((p1Font?.pointSize ?? 0) - 11.0) < 0.01,
              "Expected 11.0pt font size, got \(p1Font?.pointSize ?? 0)")
        check(abs((p1Ps?.paragraphSpacing ?? -1) - 6.0) < 0.1,
              "Expected Normal after=6pt, got \(p1Ps?.paragraphSpacing ?? -1)")
        check(abs((p1Ps?.lineHeightMultiple ?? 0) - 1.1) < 0.05,
              "Expected Normal line=1.10x, got \(p1Ps?.lineHeightMultiple ?? 0)")

        // 2. lineRule="exact" & "atLeast"
        let exactLoc = nsStr.range(of: "ExactLine15").location
        let exactPs = attr.attribute(.paragraphStyle, at: exactLoc, effectiveRange: nil) as? NSParagraphStyle
        check(abs((exactPs?.minimumLineHeight ?? 0) - 15.0) < 0.1 && abs((exactPs?.maximumLineHeight ?? 0) - 15.0) < 0.1,
              "Expected exact 15pt line height, got min=\(exactPs?.minimumLineHeight ?? 0) max=\(exactPs?.maximumLineHeight ?? 0)")
        let atLeastLoc = nsStr.range(of: "AtLeastLine16").location
        let atLeastPs = attr.attribute(.paragraphStyle, at: atLeastLoc, effectiveRange: nil) as? NSParagraphStyle
        check(abs((atLeastPs?.minimumLineHeight ?? 0) - 16.0) < 0.1 && (atLeastPs?.maximumLineHeight ?? -1) == 0,
              "Expected atLeast 16pt min / 0 max line height")

        // 3. Page break glyph uses compact 1pt style and does not create an empty extra break page near bottom
        let pbRange = nsStr.range(of: "\u{000C}")
        check(pbRange.location != NSNotFound, "Missing page break character")
        let pbFont = attr.attribute(.font, at: pbRange.location, effectiveRange: nil) as? NSFont
        let pbPs = attr.attribute(.paragraphStyle, at: pbRange.location, effectiveRange: nil) as? NSParagraphStyle
        check((pbFont?.pointSize ?? 99) <= 1.5 && (pbPs?.maximumLineHeight ?? 99) <= 1.5 && (pbPs?.paragraphSpacing ?? 99) == 0,
              "Page break should use 1pt height and 0 spacing")

        // Trailing page break near bottom of a 720pt page container must NOT spawn an empty blank page
        let breakTestAttr = NSMutableAttributedString(
            string: String(repeating: "Linea\n", count: 44),
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        let pbOnlyPs = NSMutableParagraphStyle()
        pbOnlyPs.paragraphSpacing = 0
        pbOnlyPs.minimumLineHeight = 1
        pbOnlyPs.maximumLineHeight = 1
        breakTestAttr.append(NSAttributedString(string: "\u{000C}", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
            .paragraphStyle: pbOnlyPs,
        ]))
        breakTestAttr.append(NSAttributedString(string: "Página dos\n", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        let lm = NSLayoutManager()
        let ts = NSTextStorage(attributedString: breakTestAttr)
        ts.addLayoutManager(lm)
        let c1 = NSTextContainer(containerSize: NSSize(width: 470, height: 610))
        c1.lineFragmentPadding = 0
        let c2 = NSTextContainer(containerSize: NSSize(width: 470, height: 610))
        c2.lineFragmentPadding = 0
        let c3 = NSTextContainer(containerSize: NSSize(width: 470, height: 610))
        c3.lineFragmentPadding = 0
        lm.addTextContainer(c1)
        lm.addTextContainer(c2)
        lm.addTextContainer(c3)
        lm.ensureLayout(for: c3)
        let g2 = lm.characterRange(forGlyphRange: lm.glyphRange(for: c2), actualGlyphRange: nil)
        let c2Text = (ts.string as NSString).substring(with: g2)
        check(c2Text.contains("Página dos"), "Page break near container bottom spilled blank intermediate page: c2='\(c2Text)'")

        // 4. Table proportional gridCol widths, cell margins, border sz/8, and table spacing override
        let c1Loc = nsStr.range(of: "Col1").location
        let c2Loc = nsStr.range(of: "Col2").location
        let c1Ps = attr.attribute(.paragraphStyle, at: c1Loc, effectiveRange: nil) as? NSParagraphStyle
        let c2Ps = attr.attribute(.paragraphStyle, at: c2Loc, effectiveRange: nil) as? NSParagraphStyle
        let b1 = c1Ps.flatMap { $0.textBlocks.first as? NSTextTableBlock }
        let b2 = c2Ps.flatMap { $0.textBlocks.first as? NSTextTableBlock }
        check(abs((b1?.value(for: .width) ?? 0) - 25.0) < 0.5 && abs((b2?.value(for: .width) ?? 0) - 75.0) < 0.5,
              "Expected 25%/75% gridCol table widths, got \(b1?.value(for: .width) ?? 0) / \(b2?.value(for: .width) ?? 0)")
        check(abs((b1?.width(for: .padding, edge: .minY) ?? -1) - 0.0) < 0.05 &&
              abs((b1?.width(for: .padding, edge: .minX) ?? -1) - 5.4) < 0.1,
              "Expected 0pt top and 5.4pt left cell margin from Tablanormal")
        check(abs((b1?.width(for: .border, edge: .minY) ?? -1) - 0.5) < 0.05,
              "Expected 0.5pt border from sz=4, got \(b1?.width(for: .border, edge: .minY) ?? -1)")
        check(abs((c1Ps?.paragraphSpacing ?? -1) - 0.0) < 0.05,
              "Expected Tablaconcuadrcula to override Normal spaceAfter to 0pt, got \(c1Ps?.paragraphSpacing ?? -1)")

        // 5. Custom pgSz & negative pgMar round-trip
        check(parsed.pageSetup.customSizePt != nil, "Expected customSizePt for 9979x14173")
        check(abs((parsed.pageSetup.customSizePt?.width ?? 0) - 498.95) < 0.2,
              "Expected ~498.95pt custom width, got \(parsed.pageSetup.customSizePt?.width ?? 0)")
        check(abs(parsed.pageSetup.marginTopMm - 20.0) < 0.1 && abs(parsed.pageSetup.marginBottomMm - 20.0) < 0.1,
              "Expected negative pgMar -1134 twips -> 20.0mm, got T=\(parsed.pageSetup.marginTopMm) B=\(parsed.pageSetup.marginBottomMm)")
        let rtCustom = try DocxEngine.writeDocx(attributedString: attr, pageSetup: parsed.pageSetup, title: "CustomSize")
        let reparsedCustom = try DocxEngine.readDocx(data: rtCustom)
        check(abs(reparsedCustom.pageSetup.effectivePageSizePt.width - parsed.pageSetup.effectivePageSizePt.width) < 0.5,
              "Custom page size round-trip width mismatch")

        // 6. Omitted spacing & omitted sz fallback inside minimal doc without styles.xml
        let minimalDocXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>Minimal</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let minimalData = try PureZip.write(entries: [
            "[Content_Types].xml": Data(contentTypes.utf8),
            "_rels/.rels": Data(rels.utf8),
            "word/document.xml": Data(minimalDocXml.utf8),
        ])
        let minParsed = try DocxEngine.readDocx(data: minimalData).attributedString
        let minFont = minParsed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let minPs = minParsed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        check(abs((minFont?.pointSize ?? 0) - 11.0) < 0.01 && abs((minPs?.paragraphSpacing ?? -1) - 0.0) < 0.01,
              "Expected 11.0pt fallback and 0pt omitted spaceAfter, got \(minFont?.pointSize ?? 0)pt / \(minPs?.paragraphSpacing ?? -1)pt")

        print("✔ Exact layout metrics, default style inheritance, custom page sizes & proportional tables tests passed")
    }

    static func main() {
        do {
            try testPureZip()
            try testFormatConverters()
            try testDocxRoundTrip()
            try testTypographyThemesEmbeddedFontsAndStyles()
            try testInternalTocLinksAndBookmarks()
            try testExactLayoutMetricsDefaultStyleAndTables()
            print("✅ ALL SWIFT NATIVE TESTS PASSED")
        } catch {
            fputs("❌ Test exception: \(error)\n", stderr)
            exit(1)
        }
    }
}
