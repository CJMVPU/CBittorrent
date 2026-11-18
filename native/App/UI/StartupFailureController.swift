import AppKit

/// The only main window when the engine/profile cannot be opened at launch.
final class StartupFailureController: NSWindowController, NSWindowDelegate {
    init(error: Error) {
        let window = NSWindow(contentRect: DeckLayout.window,
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "CBittorrent"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.tabbingMode = .disallowed
        window.contentMinSize = DeckLayout.window.size
        window.contentMaxSize = window.contentMinSize
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
        let surface = WindowDeck(showsStatus: false)
        window.contentView = surface
        let titlebar = TitlebarView(frame: DeckLayout.title)
        titlebar.addSubview(WindowControlButtons(frame: NSRect(x: 12, y: 2, width: 50, height: 24)))
        let icon = NSImageView(frame: NSRect(x: 80, y: 2, width: 24, height: 24))
        icon.image = NSApp.applicationIconImage
        titlebar.addSubview(icon)
        surface.addSubview(titlebar)
        let heading = Titanium.label("无法打开 CBittorrent", size: 22)
        heading.frame = NSRect(x: 40, y: 76, width: 820, height: 36)
        surface.page.addSubview(heading)
        let body = NSTextView(frame: NSRect(x: 40, y: 136, width: 800, height: 300))
        body.string = error.localizedDescription
        body.font = Titanium.font(13)
        body.textColor = Titanium.text
        body.isEditable = false
        body.drawsBackground = false
        surface.page.addSubview(body)
        let quit = ActionButton("退出", frame: NSRect(x: 760, y: 488, width: 100, height: 32)) { NSApp.terminate(nil) }
        quit.active = true
        quit.fitWidthToContent(keepingTrailingEdge: true)
        surface.page.addSubview(quit)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
}
