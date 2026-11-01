import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: WallpaperController!
    private var statusItem: NSStatusItem!

    private static let aerialsDir = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer")

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = WallpaperController()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "LiveWall")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Priority: CLI argument > last used video > a random downloaded Apple aerial.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            controller.load(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } else if let path = UserDefaults.standard.string(forKey: "videoPath"),
                  FileManager.default.fileExists(atPath: path) {
            controller.load(URL(fileURLWithPath: path))
        } else if let aerial = Self.findAerials().randomElement() {
            controller.load(aerial)
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let url = controller.videoURL {
            let current = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
            current.isEnabled = false
            menu.addItem(current)
            menu.addItem(.separator())
        }

        menu.addItem(item(controller.userPaused ? "Resume" : "Pause", #selector(togglePause), "p"))
        menu.addItem(item("Choose Video…", #selector(chooseVideo), "o"))
        let aerial = item("Random Apple Aerial", #selector(randomAerial), "r")
        aerial.isEnabled = !Self.findAerials().isEmpty
        menu.addItem(aerial)

        let speed = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        let speeds = NSMenu()
        for rate: Float in [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2] {
            let option = item(rate == 1 ? "Normal" : "\(rate.formatted())×", #selector(setSpeed(_:)))
            option.representedObject = rate
            option.state = controller.speed == rate ? .on : .off
            speeds.addItem(option)
        }
        speed.submenu = speeds
        menu.addItem(speed)
        menu.addItem(.separator())

        let battery = item("Pause on Battery", #selector(toggleBattery))
        battery.state = controller.pauseOnBattery ? .on : .off
        menu.addItem(battery)

        let sync = item("Sync Static Wallpaper", #selector(toggleSync))
        sync.state = controller.syncStaticWallpaper ? .on : .off
        sync.toolTip = "Set the real desktop picture to the video's first frame, so Mission Control matches."
        menu.addItem(sync)

        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = Bundle.main.bundleIdentifier != nil
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit LiveWall", #selector(NSApplication.terminate(_:)), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
    }

    @objc private func togglePause() { controller.userPaused.toggle() }
    @objc private func toggleBattery() { controller.pauseOnBattery.toggle() }
    @objc private func toggleSync() { controller.syncStaticWallpaper.toggle() }
    @objc private func setSpeed(_ sender: NSMenuItem) {
        if let rate = sender.representedObject as? Float { controller.speed = rate }
    }

    @objc private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            controller.load(url)
        }
    }

    @objc private func randomAerial() {
        let others = Self.findAerials().filter { $0 != controller.videoURL }
        if let url = others.randomElement() { controller.load(url) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Apple's Aerial wallpapers that macOS has already downloaded (System Settings → Wallpaper).
    private static func findAerials() -> [URL] {
        guard let e = FileManager.default.enumerator(at: aerialsDir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "mov" }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
