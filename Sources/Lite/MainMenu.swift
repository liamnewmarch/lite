import AppKit

/// Menus built in code (no nib/storyboard without Xcode). Key equivalents on menu
/// items are how Cmd-T/Cmd-W/Cmd-Q etc. reach the app; actions route through the
/// responder chain (key window → window controller → app delegate).
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window   // AppKit adds tab/window items here automatically
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Lite")
        menu.addItem(item("About Lite", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.openSettings(_:)), ","))
        menu.addItem(item("Reload Configuration", #selector(AppDelegate.reloadConfig(_:)), ",", [.command, .shift]))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = item("Services", nil)
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide Lite", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Lite", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "Shell")
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        menu.addItem(item("New Tab", #selector(NSResponder.newWindowForTab(_:)), "t"))
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Close Window", #selector(TerminalWindowController.closeWindowGroup(_:)), "w", [.command, .shift]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Toggle Debug Overlay", #selector(TerminalView.toggleDebugOverlay(_:)), "d", [.command, .option]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "{", [.command, .shift]))
        menu.addItem(item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "}", [.command, .shift]))
        let tabs = NSMenu(title: "Select Tab")
        for n in 1...9 {
            let t = item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(TerminalWindowController.selectTabByNumber(_:)), "\(n)")
            t.tag = n
            tabs.addItem(t)
        }
        let tabsItem = item("Select Tab", nil)
        tabsItem.submenu = tabs
        menu.addItem(tabsItem)
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
