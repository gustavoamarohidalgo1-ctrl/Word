import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainController: MainWindowController?
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        let controller = MainWindowController()
        mainController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let pendingURL {
            self.pendingURL = nil
            controller.openDocument(at: pendingURL)
            return
        }

        for arg in CommandLine.arguments.dropFirst() {
            if !arg.hasPrefix("-") && FileManager.default.fileExists(atPath: arg) {
                controller.openDocument(at: URL(fileURLWithPath: arg))
                break
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let controller = mainController {
            controller.confirmAndOpen(url: url)
        } else {
            pendingURL = url
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = mainController else { return .terminateNow }
        return controller.confirmDiscardIfDirty() ? .terminateNow : .terminateCancel
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Acerca de OfficeWord", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ocultar OfficeWord", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Salir de OfficeWord", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File menu
        let fileItem = NSMenuItem(title: "Archivo", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "Archivo")
        fileMenu.addItem(withTitle: "Nuevo", action: #selector(menuNew), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Abrir…", action: #selector(menuOpen), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Guardar", action: #selector(menuSave), keyEquivalent: "s")
        let saveAs = NSMenuItem(title: "Guardar como…", action: #selector(menuSaveAs), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Exportar a PDF…", action: #selector(menuPdf), keyEquivalent: "p")
        fileItem.submenu = fileMenu

        // Edit menu
        let editItem = NSMenuItem(title: "Edición", action: nil, keyEquivalent: "")
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edición")
        editMenu.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Rehacer", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: "Buscar y reemplazar…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        editMenu.addItem(findItem)
        editItem.submenu = editMenu

        // Format menu
        let fmtItem = NSMenuItem(title: "Formato", action: nil, keyEquivalent: "")
        mainMenu.addItem(fmtItem)
        let fmtMenu = NSMenu(title: "Formato")
        fmtMenu.addItem(withTitle: "Negrita", action: #selector(menuBold), keyEquivalent: "b")
        fmtMenu.addItem(withTitle: "Cursiva", action: #selector(menuItalic), keyEquivalent: "i")
        fmtMenu.addItem(withTitle: "Subrayado", action: #selector(menuUnderline), keyEquivalent: "u")
        fmtMenu.addItem(.separator())
        fmtMenu.addItem(withTitle: "Insertar enlace…", action: #selector(menuLink), keyEquivalent: "k")
        fmtItem.submenu = fmtMenu

        // Window menu
        let winItem = NSMenuItem(title: "Ventana", action: nil, keyEquivalent: "")
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Ventana")
        winMenu.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = winMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func menuNew() { mainController?.ribbonDidRequestNew() }
    @objc private func menuOpen() { mainController?.openFileDialog() }
    @objc private func menuSave() { mainController?.saveDocument(saveAs: false) }
    @objc private func menuSaveAs() { mainController?.saveDocument(saveAs: true) }
    @objc private func menuPdf() { mainController?.exportPdf() }
    @objc private func menuBold() { mainController?.textView.toggleFontTrait(.boldFontMask) }
    @objc private func menuItalic() { mainController?.textView.toggleFontTrait(.italicFontMask) }
    @objc private func menuUnderline() { mainController?.textView.toggleUnderline() }
    @objc private func menuLink() { mainController?.ribbonDidRequestInsertLink() }
}

DocxEngine.registerBundledFonts()

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
