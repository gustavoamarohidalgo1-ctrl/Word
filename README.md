# OfficeWord

Procesador de texto **100 % nativo para macOS** (escrito en Swift + AppKit, **sin WebView, sin Electron y sin Node.js**), compilado como aplicación `.app` ligera (**33 MB** totales incluyendo un paquete integrado de **57 fuentes libres**, binario compilado de **856 KB**) con fidelidad real de lectura, edición y paginación para documentos de Microsoft Word (**`.docx`**).

## Características principales

- **Motor puro `.docx` (Office Open XML) en Swift:**
  - Lector y escritor nativo usando `Foundation.XMLDocument` + `PureZip` (`zlib` del sistema) mapeado directamente a `NSAttributedString`, `NSTextTable`, `NSTextList` y `NSTextAttachment`.
  - **Fidelidad de estilos y maquetación Word:** resuelve `w:docDefaults`, estilo de párrafo por defecto (`w:default="1"`, ej. *Normal*), cadenas `w:basedOn`, y **12 estilos de párrafo** (*Normal*, *Sin espaciado*, *Título*, *Subtítulo*, *Encabezado 1–4*, *Cita*, *Cita destacada*, *Pie de imagen*, *Código*).
  - **Tablas proporcionales:** lee `w:tblGrid/w:gridCol`, `w:tcW`, `w:tblW`, estilos de tabla (`Tablanormal`, `Tablaconcuadrcula`), márgenes reales de celda (`w:tblCellMar` / `w:tcMar`) y grosor exacto de bordes (`sz / 8.0`).
  - **Páginas y saltos fieles:** soporta papel estándar (`A4`, `Letter`, `Legal`), tamaños personalizados (`w:pgSz`), orientación vertical/horizontal, márgenes reales (`w:pgMar`), interlineados `auto`, `exact` y `atLeast`, y saltos de página compactos (`\u{000C}`).
  - **Índices / Tabla de Contenido interactiva:** soporta enlaces internos (`#ancla`, `HYPERLINK \l`, `<w:bookmarkStart>`) con salto directo a la página de destino al hacer clic y conservando el color normal del texto sin subrayado azul forzado.
- **Tipografía compatible con Microsoft Word:**
  - **57 archivos `.ttf` (22 familias libres):** incluye equivalentes métricos (`CoreText`) como `Carlito` (Calibri), `Caladea` (Cambria), `Inter` (Aptos), `EB Garamond` (Garamond), `Open Sans` (Segoe UI), `Libre Franklin` (Franklin Gothic), `Source Code Pro` (Consolas), `Arimo`, `Cousine`, `Tinos`, `Fira Sans`, `Gelasio`, `Lato`, `Libre Baskerville`, `Lora`, `Merriweather`, `Montserrat`, `Oswald`, `Playfair Display`, `Poppins`, `Raleway` y `Roboto`, conservando el nombre original de Word al leer y guardar `.docx`.
  - **Temas y fuentes incrustadas:** resuelve `word/theme/theme1.xml` (`majorFont`/`minorFont` y `w:asciiTheme`) y extrae/desofusca fuentes incrustadas `.odttf`/`.ttf`/`.otf` (`word/fontTable.xml`, estándar ECMA-376 XOR).
  - **Selector completo en la cinta:** muestra equivalentes de Microsoft Word y todas las fuentes instaladas en macOS + incluidas (**200+ familias**).
- **Formatos compatibles (macOS 12.0+):**
  - **Abrir:** `.docx`, `.doc`, `.rtf`, `.odt` (conversión vía `/usr/bin/textutil`), `.md`, `.html`, `.txt`.
  - **Guardar / Exportar:** `.docx`, `.pdf` (vectorial nativo mediante `NSPrintOperation`), `.rtf`, `.md`, `.html`, `.txt`.
- **Interfaz nativa macOS (AppKit):**
  - Cinta nativa con íconos SF Symbols (*Inicio*, *Insertar*, *Página*, además de pestañas contextuales para *Tabla* e *Imagen*).
  - **Hojas físicas multipágina reales** apiladas con separación visual, paginación continua con `NSLayoutManager`, regla superior en centímetros activable, zoom (`50%`–`200%`), encabezado/pie en vivo, contador de palabras/caracteres/páginas/tiempo de lectura, buscar y reemplazar nativo (`⌘F`) y cambio de apariencia claro/oscuro.

## Compilación y uso

Requiere únicamente Xcode Command Line Tools (`swiftc`, macOS 12.0+):

```bash
git clone https://github.com/gustavoamarohidalgo1-ctrl/Word.git
cd Word

# Compilar y firmar OfficeWord.app
bash build.sh

# Ejecutar la suite completa de pruebas nativas Swift (6 módulos)
bash test.sh

# Abrir la aplicación
open OfficeWord.app
```

También puedes abrir un documento directamente desde Terminal:

```bash
open -a OfficeWord.app ruta/al/documento.docx
```

## Estructura del proyecto

```text
Word/
├── .github/workflows/ci.yml      # Compilación y pruebas automáticas en macOS
├── Sources/
│   ├── PureZip.swift             # Lector/escritor ZIP puro en Swift + zlib
│   ├── DocxEngine.swift          # Parser/serializador OpenXML (.docx) nativo
│   ├── FormatConverters.swift    # Markdown, TXT, RTF, HTML y textutil (.doc/.odt)
│   ├── EditorTextView.swift      # Subclase NSTextView (tablas, listas, imágenes, impresión)
│   ├── RibbonView.swift          # Cinta AppKit con SF Symbols y pestañas contextuales
│   ├── MainWindowController.swift# Ventana, lienzo de papel, regla en cm y zoom
│   └── main.swift                # AppDelegate, menús macOS y ciclo de vida
├── Resources/
│   ├── Info.plist                # Metadatos macOS (com.gustavo.OfficeWord) y asociaciones
│   └── Fonts/                    # 57 fuentes libres compatibles con Microsoft Word
├── scripts/
│   └── make-icon.swift           # Generador nativo del ícono .icns
├── Tests/
│   └── DocxEngineTests.swift     # 6 suites de pruebas Swift (.docx, TOC, layout, PDF)
├── build.sh                      # Compila OfficeWord.app optimizada (-O) y firma ad-hoc
├── test.sh                       # Compila y ejecuta todas las pruebas Swift
├── LICENSE                       # Licencia MIT
└── .gitignore
```

## Atajos de teclado

| Atajo | Acción |
| --- | --- |
| `⌘N` | Nuevo documento |
| `⌘O` | Abrir documento |
| `⌘S` / `⇧⌘S` | Guardar / Guardar como |
| `⌘P` | Exportar a PDF |
| `⌘F` | Buscar y reemplazar |
| `⌘B` / `⌘I` / `⌘U` | Negrita / Cursiva / Subrayado |
| `⌘K` | Insertar enlace |
| `⌘Z` / `⇧⌘Z` | Deshacer / Rehacer |
| `⌘M` | Minimizar ventana |
| `Tab` / `⇧Tab` | Navegar celdas en tabla o sangría en listas |
