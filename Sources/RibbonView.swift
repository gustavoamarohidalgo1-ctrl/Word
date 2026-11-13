import Cocoa

protocol RibbonDelegate: AnyObject {
    func ribbonDidRequestNew()
    func ribbonDidRequestOpen()
    func ribbonDidRequestSave(saveAs: Bool)
    func ribbonDidRequestExportPdf()
    func ribbonDidRequestExportFormat(_ ext: String)
    func ribbonDidRequestUndo()
    func ribbonDidRequestRedo()
    func ribbonDidRequestFind()
    func ribbonDidToggleTheme()

    func ribbonDidSelectBlockKind(_ kind: String)
    func ribbonDidSelectFontFamily(_ family: String)
    func ribbonDidSelectFontSize(_ pt: CGFloat)
    func ribbonDidToggleBold()
    func ribbonDidToggleItalic()
    func ribbonDidToggleUnderline()
    func ribbonDidToggleStrike()
    func ribbonDidToggleSuperscript(_ val: Int)
    func ribbonDidSelectTextColor(_ color: NSColor)
    func ribbonDidSelectHighlightColor(_ color: NSColor?)
    func ribbonDidClearFormatting()
    func ribbonDidSelectAlignment(_ align: NSTextAlignment)
    func ribbonDidToggleList(ordered: Bool)
    func ribbonDidAdjustIndent(delta: CGFloat)
    func ribbonDidSelectLineSpacing(_ mult: CGFloat)

    func ribbonDidRequestInsertTable()
    func ribbonDidRequestInsertImage()
    func ribbonDidRequestInsertLink()
    func ribbonDidRequestInsertRule()
    func ribbonDidRequestInsertPageBreak()
    func ribbonDidRequestInsertDate()
    func ribbonDidRequestHeaderFooter()

    func ribbonDidChangePaperSize(_ size: PaperSize)
    func ribbonDidChangeOrientation(_ orient: PageOrientation)
    func ribbonDidChangeMargins(preset: String)
    func ribbonDidToggleRuler()

    func ribbonDidTableAction(_ action: String)
    func ribbonDidTableCellColor(_ color: NSColor?)
    func ribbonDidImageResize(fraction: CGFloat)
    func ribbonDidImageDelete()
}

final class RibbonView: NSView {
    weak var delegate: RibbonDelegate?

    private let tabsStack = NSStackView()
    private let panelsContainer = NSView()
    private let statusLabel = NSTextField(labelWithString: "Guardado")
    private let dirtyBadge = NSTextField(labelWithString: "●")
    private let titleLabel = NSTextField(labelWithString: "Documento sin título.docx")

    private var tabButtons: [String: NSButton] = [:]
    private var panels: [String: NSView] = [:]
    private var activeTab = "home"

    // Home controls synced with selection
    private let stylePopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private var boldBtn: NSButton!
    private var italicBtn: NSButton!
    private var underlineBtn: NSButton!
    private var strikeBtn: NSButton!
    private var supBtn: NSButton!
    private var subBtn: NSButton!
    private let colorWell = NSColorWell()
    private let highlightPopup = NSPopUpButton()
    private let alignSeg = NSSegmentedControl()
    private var ulBtn: NSButton!
    private var olBtn: NSButton!
    private let lineSpacingPopup = NSPopUpButton()

    // Page controls synced with document setup
    private let paperPopup = NSPopUpButton()
    private let orientPopup = NSPopUpButton()
    private let marginPopup = NSPopUpButton()

    private let styleKeys = ["normal", "noSpacing", "title", "subtitle", "h1", "h2", "h3", "h4", "quote", "intenseQuote", "caption", "code"]
    private let styleTitles = [
        "Normal", "Sin espaciado", "Título", "Subtítulo",
        "Encabezado 1", "Encabezado 2", "Encabezado 3", "Encabezado 4",
        "Cita", "Cita destacada", "Pie de imagen", "Código",
    ]
    private var fontFamilies: [String] = []
    private let fontSizes: [CGFloat] = [8, 9, 10, 10.5, 11, 11.5, 12, 13, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        wantsLayer = true

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.alignment = .leading
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 1. Top Header Bar
        let topBar = makeTopBar()
        rootStack.addArrangedSubview(topBar)
        topBar.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        // 2. Tab Strip
        let tabStrip = makeTabStrip()
        rootStack.addArrangedSubview(tabStrip)
        tabStrip.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        // 3. Tool Panels Container
        panelsContainer.translatesAutoresizingMaskIntoConstraints = false
        panelsContainer.heightAnchor.constraint(equalToConstant: 42).isActive = true
        rootStack.addArrangedSubview(panelsContainer)
        panelsContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        rootStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        buildHomePanel()
        buildInsertPanel()
        buildPagePanel()
        buildTablePanel()
        buildImagePanel()

        selectTab("home")
    }

    private func makeTopBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let badge = NSTextField(labelWithString: "W")
        badge.alignment = .center
        badge.font = .systemFont(ofSize: 13, weight: .heavy)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        badge.layer?.cornerRadius = 6
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 24).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 24).isActive = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle

        dirtyBadge.font = .systemFont(ofSize: 10)
        dirtyBadge.textColor = .systemOrange
        dirtyBadge.isHidden = true

        let leftStack = NSStackView(views: [badge, titleLabel, dirtyBadge])
        leftStack.spacing = 8
        leftStack.alignment = .centerY

        let newBtn = makeBarButton(title: "Nuevo", symbol: "doc.badge.plus", action: #selector(onNew))
        let openBtn = makeBarButton(title: "Abrir", symbol: "folder", action: #selector(onOpen))
        let saveBtn = makeBarButton(title: "Guardar", symbol: "square.and.arrow.down", action: #selector(onSave))
        saveBtn.bezelColor = .controlAccentColor
        saveBtn.keyEquivalent = ""
        let saveAsBtn = makeBarButton(title: "Guardar como", symbol: nil, action: #selector(onSaveAs))
        let pdfBtn = makeBarButton(title: "PDF", symbol: "doc.richtext", action: #selector(onPdf))
        let undoBtn = makeIconButton(symbol: "arrow.uturn.backward", tooltip: "Deshacer (⌘Z)", action: #selector(onUndo))
        let redoBtn = makeIconButton(symbol: "arrow.uturn.forward", tooltip: "Rehacer (⇧⌘Z)", action: #selector(onRedo))
        let findBtn = makeIconButton(symbol: "magnifyingglass", tooltip: "Buscar y reemplazar (⌘F)", action: #selector(onFind))
        let themeBtn = makeIconButton(symbol: "circle.lefthalf.filled", tooltip: "Cambiar apariencia claro/oscuro", action: #selector(onTheme))

        let rightStack = NSStackView(views: [
            newBtn, openBtn, saveBtn, saveAsBtn, pdfBtn,
            makeVDivider(), undoBtn, redoBtn, findBtn, makeVDivider(), themeBtn
        ])
        rightStack.spacing = 4
        rightStack.alignment = .centerY

        let container = NSStackView(views: [leftStack, NSView(), rightStack])
        container.translatesAutoresizingMaskIntoConstraints = false
        container.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        container.alignment = .centerY
        bar.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: bar.topAnchor),
            container.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    private func makeTabStrip() -> NSView {
        let strip = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.heightAnchor.constraint(equalToConstant: 28).isActive = true

        tabsStack.orientation = .horizontal
        tabsStack.spacing = 4
        tabsStack.alignment = .centerY

        let defs: [(String, String, Bool)] = [
            ("home", "Inicio", false),
            ("insert", "Insertar", false),
            ("page", "Página", false),
            ("table", "Tabla", true),
            ("image", "Imagen", true),
        ]

        for (key, label, isCtx) in defs {
            let btn = NSButton(title: label, target: self, action: #selector(onTabClick(_:)))
            btn.bezelStyle = .recessed
            btn.setButtonType(.pushOnPushOff)
            btn.font = .systemFont(ofSize: 12, weight: .semibold)
            btn.identifier = NSUserInterfaceItemIdentifier(key)
            btn.isHidden = isCtx
            if isCtx { btn.contentTintColor = .systemBlue }
            tabButtons[key] = btn
            tabsStack.addArrangedSubview(btn)
        }

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let row = NSStackView(views: [tabsStack, NSView(), statusLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 2, right: 14)
        row.alignment = .centerY
        strip.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: strip.topAnchor),
            row.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
        ])
        return strip
    }

    private func addPanel(key: String, views: [NSView]) {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: holder.topAnchor),
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])

        panels[key] = holder
        panelsContainer.addSubview(holder)
        NSLayoutConstraint.activate([
            holder.topAnchor.constraint(equalTo: panelsContainer.topAnchor),
            holder.leadingAnchor.constraint(equalTo: panelsContainer.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: panelsContainer.trailingAnchor),
            holder.bottomAnchor.constraint(equalTo: panelsContainer.bottomAnchor),
        ])
    }

    private func buildHomePanel() {
        stylePopup.addItems(withTitles: styleTitles)
        stylePopup.controlSize = .small
        stylePopup.font = .systemFont(ofSize: 12)
        stylePopup.target = self
        stylePopup.action = #selector(onStyleChanged)
        stylePopup.widthAnchor.constraint(equalToConstant: 132).isActive = true

        populateFontPopup()
        fontPopup.controlSize = .small
        fontPopup.font = .systemFont(ofSize: 12)
        (fontPopup.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        fontPopup.target = self
        fontPopup.action = #selector(onFontChanged)
        fontPopup.widthAnchor.constraint(equalToConstant: 162).isActive = true

        sizePopup.addItems(withTitles: fontSizes.map { $0 == floor($0) ? "\(Int($0))" : "\($0)" })
        sizePopup.selectItem(withTitle: "11.5")
        sizePopup.controlSize = .small
        sizePopup.font = .systemFont(ofSize: 12)
        sizePopup.target = self
        sizePopup.action = #selector(onSizeChanged)

        boldBtn = makeToggleIconButton(symbol: "bold", tooltip: "Negrita (⌘B)", action: #selector(onBold))
        italicBtn = makeToggleIconButton(symbol: "italic", tooltip: "Cursiva (⌘I)", action: #selector(onItalic))
        underlineBtn = makeToggleIconButton(symbol: "underline", tooltip: "Subrayado (⌘U)", action: #selector(onUnderline))
        strikeBtn = makeToggleIconButton(symbol: "strikethrough", tooltip: "Tachado", action: #selector(onStrike))
        supBtn = makeToggleIconButton(symbol: "textformat.superscript", tooltip: "Superíndice", action: #selector(onSup))
        subBtn = makeToggleIconButton(symbol: "textformat.subscript", tooltip: "Subíndice", action: #selector(onSub))

        colorWell.color = NSColor(srgbRed: 0.07, green: 0.09, blue: 0.15, alpha: 1)
        colorWell.target = self
        colorWell.action = #selector(onColorChanged)
        colorWell.toolTip = "Color de texto"
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 32).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        if #available(macOS 13.0, *) {
            colorWell.colorWellStyle = .minimal
        }

        highlightPopup.addItems(withTitles: ["Resaltar", "Sin resaltado", "Amarillo", "Verde", "Cian", "Rosa", "Azul"])
        highlightPopup.pullsDown = true
        highlightPopup.controlSize = .small
        highlightPopup.font = .systemFont(ofSize: 11.5)
        highlightPopup.target = self
        highlightPopup.action = #selector(onHighlightSelected)

        let clearBtn = makeIconButton(symbol: "eraser", tooltip: "Borrar formato", action: #selector(onClearFormat))

        alignSeg.segmentCount = 4
        let alignIcons = ["text.alignleft", "text.aligncenter", "text.alignright", "text.justify"]
        for (idx, sym) in alignIcons.enumerated() {
            alignSeg.setImage(NSImage(systemSymbolName: sym, accessibilityDescription: nil), forSegment: idx)
            alignSeg.setWidth(26, forSegment: idx)
        }
        alignSeg.selectedSegment = 0
        alignSeg.controlSize = .small
        alignSeg.target = self
        alignSeg.action = #selector(onAlignChanged)

        ulBtn = makeToggleIconButton(symbol: "list.bullet", tooltip: "Lista con viñetas", action: #selector(onBulletList))
        olBtn = makeToggleIconButton(symbol: "list.number", tooltip: "Lista numerada", action: #selector(onNumberList))
        let outdentBtn = makeIconButton(symbol: "decrease.indent", tooltip: "Disminuir sangría", action: #selector(onOutdent))
        let indentBtn = makeIconButton(symbol: "increase.indent", tooltip: "Aumentar sangría", action: #selector(onIndent))

        lineSpacingPopup.addItems(withTitles: ["1.0", "1.15", "1.5", "2.0"])
        lineSpacingPopup.selectItem(withTitle: "1.15")
        lineSpacingPopup.controlSize = .small
        lineSpacingPopup.font = .systemFont(ofSize: 11.5)
        lineSpacingPopup.toolTip = "Interlineado"
        lineSpacingPopup.target = self
        lineSpacingPopup.action = #selector(onLineSpacingChanged)

        addPanel(key: "home", views: [
            stylePopup, fontPopup, sizePopup,
            makeVDivider(),
            boldBtn, italicBtn, underlineBtn, strikeBtn, supBtn, subBtn,
            colorWell, highlightPopup, clearBtn,
            makeVDivider(),
            alignSeg,
            makeVDivider(),
            ulBtn, olBtn, outdentBtn, indentBtn, lineSpacingPopup,
        ])
    }

    private func buildInsertPanel() {
        addPanel(key: "insert", views: [
            makeBarButton(title: "Tabla…", symbol: "tablecells", action: #selector(onInsertTable)),
            makeBarButton(title: "Imagen…", symbol: "photo", action: #selector(onInsertImage)),
            makeBarButton(title: "Enlace…", symbol: "link", action: #selector(onInsertLink)),
            makeVDivider(),
            makeBarButton(title: "Línea", symbol: "minus", action: #selector(onInsertRule)),
            makeBarButton(title: "Salto de página", symbol: "doc.plaintext", action: #selector(onInsertPageBreak)),
            makeBarButton(title: "Fecha", symbol: "calendar", action: #selector(onInsertDate)),
            makeBarButton(title: "Encabezado y Pie…", symbol: "rectangle.topthird.inset.filled", action: #selector(onHeaderFooter)),
        ])
    }

    private func buildPagePanel() {
        paperPopup.addItems(withTitles: ["A4 (210 × 297 mm)", "Carta (Letter)", "Oficio (Legal)"])
        paperPopup.controlSize = .small
        paperPopup.target = self
        paperPopup.action = #selector(onPaperChanged)

        orientPopup.addItems(withTitles: ["Vertical", "Horizontal"])
        orientPopup.controlSize = .small
        orientPopup.target = self
        orientPopup.action = #selector(onOrientChanged)

        marginPopup.addItems(withTitles: ["Márgenes: Normal (25 mm)", "Márgenes: Estrecho (12.7 mm)", "Márgenes: Ancho (35 mm)"])
        marginPopup.controlSize = .small
        marginPopup.target = self
        marginPopup.action = #selector(onMarginsChanged)

        let rulerBtn = makeBarButton(title: "Regla", symbol: "ruler", action: #selector(onToggleRuler))

        let expLabel = NSTextField(labelWithString: "Exportar:")
        expLabel.font = .systemFont(ofSize: 11.5)
        expLabel.textColor = .secondaryLabelColor

        let expDocx = makeExportButton(title: ".docx", ext: "docx")
        let expRtf = makeExportButton(title: ".rtf", ext: "rtf")
        let expMd = makeExportButton(title: ".md", ext: "md")
        let expHtml = makeExportButton(title: ".html", ext: "html")
        let expTxt = makeExportButton(title: ".txt", ext: "txt")

        addPanel(key: "page", views: [
            paperPopup, orientPopup, marginPopup, rulerBtn,
            makeVDivider(),
            expLabel, expDocx, expRtf, expMd, expHtml, expTxt,
        ])
    }

    private func buildTablePanel() {
        let cellColorPopup = NSPopUpButton()
        cellColorPopup.pullsDown = true
        cellColorPopup.addItems(withTitles: ["Fondo celda", "Sin fondo", "Gris suave", "Azul suave", "Amarillo suave", "Verde suave"])
        cellColorPopup.controlSize = .small
        cellColorPopup.target = self
        cellColorPopup.action = #selector(onTableCellColor(_:))

        addPanel(key: "table", views: [
            makeTableActionBtn(title: "+ Fila arriba", id: "rowAbove"),
            makeTableActionBtn(title: "+ Fila abajo", id: "rowBelow"),
            makeTableActionBtn(title: "+ Columna izq.", id: "colLeft"),
            makeTableActionBtn(title: "+ Columna der.", id: "colRight"),
            makeVDivider(),
            cellColorPopup,
            makeTableActionBtn(title: "- Fila", id: "delRow", destructive: true),
            makeTableActionBtn(title: "- Columna", id: "delCol", destructive: true),
            makeTableActionBtn(title: "Eliminar tabla", id: "delTable", destructive: true),
        ])
    }

    private func buildImagePanel() {
        let lbl = NSTextField(labelWithString: "Ancho de imagen:")
        lbl.font = .systemFont(ofSize: 11.5)
        lbl.textColor = .secondaryLabelColor

        let b25 = makeImgSizeBtn(title: "25%", tag: 25)
        let b50 = makeImgSizeBtn(title: "50%", tag: 50)
        let b75 = makeImgSizeBtn(title: "75%", tag: 75)
        let b100 = makeImgSizeBtn(title: "100%", tag: 100)
        let delBtn = makeBarButton(title: "Eliminar imagen", symbol: "trash", action: #selector(onImgDelete))
        delBtn.contentTintColor = .systemRed

        addPanel(key: "image", views: [lbl, b25, b50, b75, b100, makeVDivider(), delBtn])
    }

    // MARK: - Public Sync API
    func selectTab(_ key: String) {
        activeTab = key
        for (k, btn) in tabButtons {
            btn.state = k == key ? .on : .off
        }
        for (k, panel) in panels {
            panel.isHidden = k != key
        }
    }

    func updateDocumentMeta(title: String, dirty: Bool) {
        titleLabel.stringValue = title
        dirtyBadge.isHidden = !dirty
        statusLabel.stringValue = dirty ? "Sin guardar" : "Guardado"
    }

    func updatePageSetup(_ setup: DocPageSetup) {
        switch setup.size {
        case .a4: paperPopup.selectItem(at: 0)
        case .letter: paperPopup.selectItem(at: 1)
        case .legal: paperPopup.selectItem(at: 2)
        }
        orientPopup.selectItem(at: setup.orientation == .portrait ? 0 : 1)
        if abs(setup.marginLeftMm - 12.7) < 2 { marginPopup.selectItem(at: 1) }
        else if abs(setup.marginLeftMm - 35) < 2 { marginPopup.selectItem(at: 2) }
        else { marginPopup.selectItem(at: 0) }
    }

    func syncWithSelection(in textView: EditorTextView) {
        let storage = textView.textStorage
        let sel = textView.selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if let storage, storage.length > 0 {
            let loc = min(sel.location, storage.length - 1)
            attrs = storage.attributes(at: loc, effectiveRange: nil)
        } else {
            attrs = textView.typingAttributes
        }

        if let font = attrs[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            boldBtn.state = traits.contains(.boldFontMask) ? .on : .off
            italicBtn.state = traits.contains(.italicFontMask) ? .on : .off
            let displayFamily = (attrs[.owFontName] as? String) ?? font.familyName
            if let displayFamily {
                if let idx = fontPopup.itemArray.firstIndex(where: {
                    $0.isEnabled && !$0.isSeparatorItem && $0.title.caseInsensitiveCompare(displayFamily) == .orderedSame
                }) {
                    fontPopup.selectItem(at: idx)
                } else if let menu = fontPopup.menu {
                    let customItem = NSMenuItem(title: displayFamily, action: nil, keyEquivalent: "")
                    menu.addItem(customItem)
                    fontPopup.select(customItem)
                }
            }
            let closest = fontSizes.enumerated().min(by: { abs($0.element - font.pointSize) < abs($1.element - font.pointSize) })?.offset ?? 5
            sizePopup.selectItem(at: closest)
        }

        underlineBtn.state = ((attrs[.underlineStyle] as? Int) ?? 0) != 0 ? .on : .off
        strikeBtn.state = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0 ? .on : .off
        let sup = (attrs[.superscript] as? NSNumber)?.intValue ?? 0
        supBtn.state = sup > 0 ? .on : .off
        subBtn.state = sup < 0 ? .on : .off

        if let fg = attrs[.foregroundColor] as? NSColor {
            colorWell.color = fg
        }

        let blockKind = (attrs[.owBlockKind] as? String) ?? "normal"
        if let idx = styleKeys.firstIndex(of: blockKind) {
            stylePopup.selectItem(at: idx)
        } else {
            stylePopup.selectItem(at: 0)
        }

        if let ps = attrs[.paragraphStyle] as? NSParagraphStyle {
            switch ps.alignment {
            case .center: alignSeg.selectedSegment = 1
            case .right: alignSeg.selectedSegment = 2
            case .justified: alignSeg.selectedSegment = 3
            default: alignSeg.selectedSegment = 0
            }
            if let list = ps.textLists.first {
                let isOrd = list.markerFormat != .disc && list.markerFormat != .circle && list.markerFormat != .square
                ulBtn.state = isOrd ? .off : .on
                olBtn.state = isOrd ? .on : .off
            } else {
                ulBtn.state = .off
                olBtn.state = .off
            }
        }

        let inTable = textView.activeTableContext() != nil
        let hasImg = textView.selectedImageAttachment() != nil
        tabButtons["table"]?.isHidden = !inTable
        tabButtons["image"]?.isHidden = !hasImg

        if hasImg && activeTab != "image" {
            selectTab("image")
        } else if !hasImg && activeTab == "image" {
            selectTab(inTable ? "table" : "home")
        } else if !inTable && activeTab == "table" {
            selectTab("home")
        }
    }

    // MARK: - Control Factories
    private func makeBarButton(title: String, symbol: String?, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11.5, weight: .medium)
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            btn.image = img
            btn.imagePosition = .imageLeading
        }
        return btn
    }

    private func makeIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let btn = NSButton(title: "", target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.toolTip = tooltip
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        btn.imagePosition = .imageOnly
        return btn
    }

    private func makeToggleIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let btn = makeIconButton(symbol: symbol, tooltip: tooltip, action: action)
        btn.setButtonType(.pushOnPushOff)
        return btn
    }

    private func makeExportButton(title: String, ext: String) -> NSButton {
        let btn = NSButton(title: title, target: self, action: #selector(onExportFormat(_:)))
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.identifier = NSUserInterfaceItemIdentifier(ext)
        return btn
    }

    private func makeTableActionBtn(title: String, id: String, destructive: Bool = false) -> NSButton {
        let btn = NSButton(title: title, target: self, action: #selector(onTableAction(_:)))
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.identifier = NSUserInterfaceItemIdentifier(id)
        if destructive { btn.contentTintColor = .systemRed }
        return btn
    }

    private func makeImgSizeBtn(title: String, tag: Int) -> NSButton {
        let btn = NSButton(title: title, target: self, action: #selector(onImgSize(_:)))
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.tag = tag
        return btn
    }

    private func makeVDivider() -> NSView {
        let div = NSBox()
        div.boxType = .separator
        div.translatesAutoresizingMaskIntoConstraints = false
        div.widthAnchor.constraint(equalToConstant: 1).isActive = true
        div.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return div
    }

    // MARK: - Actions
    @objc private func onTabClick(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue { selectTab(key) }
    }

    @objc private func onNew() { delegate?.ribbonDidRequestNew() }
    @objc private func onOpen() { delegate?.ribbonDidRequestOpen() }
    @objc private func onSave() { delegate?.ribbonDidRequestSave(saveAs: false) }
    @objc private func onSaveAs() { delegate?.ribbonDidRequestSave(saveAs: true) }
    @objc private func onPdf() { delegate?.ribbonDidRequestExportPdf() }
    @objc private func onUndo() { delegate?.ribbonDidRequestUndo() }
    @objc private func onRedo() { delegate?.ribbonDidRequestRedo() }
    @objc private func onFind() { delegate?.ribbonDidRequestFind() }
    @objc private func onTheme() { delegate?.ribbonDidToggleTheme() }

    @objc private func onStyleChanged() {
        let idx = stylePopup.indexOfSelectedItem
        if idx >= 0 && idx < styleKeys.count {
            delegate?.ribbonDidSelectBlockKind(styleKeys[idx])
        }
    }

    private func populateFontPopup() {
        fontPopup.autoenablesItems = false
        fontPopup.removeAllItems()
        guard let menu = fontPopup.menu else { return }

        let wordHeader = makeFontSectionHeader("— Equivalentes de Microsoft Word —")
        menu.addItem(wordHeader)
        for name in DocxEngine.wordFontNames {
            menu.addItem(NSMenuItem(title: name, action: nil, keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())
        let allFonts = DocxEngine.allDisplayFontFamilies()
        fontFamilies = allFonts
        menu.addItem(makeFontSectionHeader("— Todas las fuentes (macOS + incluidas: \(allFonts.count)) —"))
        for name in allFonts {
            menu.addItem(NSMenuItem(title: name, action: nil, keyEquivalent: ""))
        }

        if let defaultIdx = fontPopup.itemArray.firstIndex(where: {
            $0.isEnabled && !$0.isSeparatorItem && $0.title == "Calibri"
        }) {
            fontPopup.selectItem(at: defaultIdx)
        }
    }

    private func makeFontSectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
    }

    @objc private func onFontChanged() {
        if let item = fontPopup.selectedItem, item.isEnabled, !item.isSeparatorItem {
            delegate?.ribbonDidSelectFontFamily(item.title)
        }
    }

    @objc private func onSizeChanged() {
        let idx = sizePopup.indexOfSelectedItem
        if idx >= 0 && idx < fontSizes.count {
            delegate?.ribbonDidSelectFontSize(fontSizes[idx])
        }
    }

    @objc private func onBold() { delegate?.ribbonDidToggleBold() }
    @objc private func onItalic() { delegate?.ribbonDidToggleItalic() }
    @objc private func onUnderline() { delegate?.ribbonDidToggleUnderline() }
    @objc private func onStrike() { delegate?.ribbonDidToggleStrike() }
    @objc private func onSup() { delegate?.ribbonDidToggleSuperscript(1) }
    @objc private func onSub() { delegate?.ribbonDidToggleSuperscript(-1) }
    @objc private func onColorChanged() { delegate?.ribbonDidSelectTextColor(colorWell.color) }

    @objc private func onHighlightSelected() {
        let idx = highlightPopup.indexOfSelectedItem
        let colors: [NSColor?] = [
            nil,
            nil,
            NSColor(srgbRed: 0.996, green: 0.94, blue: 0.54, alpha: 1),
            NSColor(srgbRed: 0.73, green: 0.97, blue: 0.82, alpha: 1),
            NSColor(srgbRed: 0.65, green: 0.95, blue: 0.99, alpha: 1),
            NSColor(srgbRed: 0.96, green: 0.82, blue: 0.99, alpha: 1),
            NSColor(srgbRed: 0.75, green: 0.86, blue: 0.996, alpha: 1),
        ]
        if idx >= 1 && idx < colors.count {
            delegate?.ribbonDidSelectHighlightColor(colors[idx])
        }
    }

    @objc private func onClearFormat() { delegate?.ribbonDidClearFormatting() }

    @objc private func onAlignChanged() {
        let map: [NSTextAlignment] = [.left, .center, .right, .justified]
        let idx = alignSeg.selectedSegment
        if idx >= 0 && idx < map.count {
            delegate?.ribbonDidSelectAlignment(map[idx])
        }
    }

    @objc private func onBulletList() { delegate?.ribbonDidToggleList(ordered: false) }
    @objc private func onNumberList() { delegate?.ribbonDidToggleList(ordered: true) }
    @objc private func onOutdent() { delegate?.ribbonDidAdjustIndent(delta: -18) }
    @objc private func onIndent() { delegate?.ribbonDidAdjustIndent(delta: 18) }

    @objc private func onLineSpacingChanged() {
        if let title = lineSpacingPopup.selectedItem?.title, let val = Double(title) {
            delegate?.ribbonDidSelectLineSpacing(CGFloat(val))
        }
    }

    @objc private func onInsertTable() { delegate?.ribbonDidRequestInsertTable() }
    @objc private func onInsertImage() { delegate?.ribbonDidRequestInsertImage() }
    @objc private func onInsertLink() { delegate?.ribbonDidRequestInsertLink() }
    @objc private func onInsertRule() { delegate?.ribbonDidRequestInsertRule() }
    @objc private func onInsertPageBreak() { delegate?.ribbonDidRequestInsertPageBreak() }
    @objc private func onInsertDate() { delegate?.ribbonDidRequestInsertDate() }
    @objc private func onHeaderFooter() { delegate?.ribbonDidRequestHeaderFooter() }

    @objc private func onPaperChanged() {
        let sizes: [PaperSize] = [.a4, .letter, .legal]
        let idx = paperPopup.indexOfSelectedItem
        if idx >= 0 && idx < sizes.count { delegate?.ribbonDidChangePaperSize(sizes[idx]) }
    }

    @objc private func onOrientChanged() {
        delegate?.ribbonDidChangeOrientation(orientPopup.indexOfSelectedItem == 1 ? .landscape : .portrait)
    }

    @objc private func onMarginsChanged() {
        let presets = ["normal", "narrow", "wide"]
        let idx = marginPopup.indexOfSelectedItem
        if idx >= 0 && idx < presets.count { delegate?.ribbonDidChangeMargins(preset: presets[idx]) }
    }

    @objc private func onToggleRuler() { delegate?.ribbonDidToggleRuler() }

    @objc private func onExportFormat(_ sender: NSButton) {
        if let ext = sender.identifier?.rawValue { delegate?.ribbonDidRequestExportFormat(ext) }
    }

    @objc private func onTableAction(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { delegate?.ribbonDidTableAction(id) }
    }

    @objc private func onTableCellColor(_ sender: NSPopUpButton) {
        let colors: [NSColor?] = [
            nil,
            nil,
            NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.94, green: 0.96, blue: 1.0, alpha: 1),
            NSColor(srgbRed: 0.996, green: 0.976, blue: 0.765, alpha: 1),
            NSColor(srgbRed: 0.925, green: 0.99, blue: 0.96, alpha: 1),
        ]
        let idx = sender.indexOfSelectedItem
        if idx >= 1 && idx < colors.count {
            delegate?.ribbonDidTableCellColor(colors[idx])
        }
    }

    @objc private func onImgSize(_ sender: NSButton) {
        delegate?.ribbonDidImageResize(fraction: CGFloat(sender.tag) / 100.0)
    }

    @objc private func onImgDelete() { delegate?.ribbonDidImageDelete() }
}
