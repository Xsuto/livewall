import AppKit
import AVFoundation
import IOKit.ps

/// Owns one window per screen, a shared looping player, and the pause/resume policy.
@MainActor
final class WallpaperController {
    private var windows: [WallpaperWindow] = []
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var powerSource: CFRunLoopSource?
    private var screensAsleep = false

    private(set) var videoURL: URL?

    /// User-requested pause from the menu.
    var userPaused = false { didSet { updatePlayback() } }

    var pauseOnBattery: Bool {
        get { UserDefaults.standard.object(forKey: "pauseOnBattery") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "pauseOnBattery"); updatePlayback() }
    }

    /// Playback rate; 1 is normal speed.
    var speed: Float {
        get { UserDefaults.standard.object(forKey: "speed") as? Float ?? 1 }
        set {
            UserDefaults.standard.set(newValue, forKey: "speed")
            player.defaultRate = newValue
            if player.rate != 0 { player.rate = newValue }
        }
    }

    var syncStaticWallpaper: Bool {
        get { UserDefaults.standard.object(forKey: "syncStaticWallpaper") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "syncStaticWallpaper")
            if newValue, let videoURL { setStaticWallpaper(from: videoURL) }
        }
    }

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.defaultRate = speed  // play() starts at this rate

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true; self?.updatePlayback() }
        }
        wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false; self?.updatePlayback() }
        }
        // Spaces switches can change what's covering the desktop.
        wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePlayback() }
        }

        observePowerSource()
        rebuildWindows()
    }

    // MARK: - Video

    func load(_ url: URL) {
        videoURL = url
        UserDefaults.standard.set(url.path, forKey: "videoPath")

        looper?.disableLooping()
        player.removeAllItems()
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        updatePlayback()

        if syncStaticWallpaper { setStaticWallpaper(from: url) }
    }

    // MARK: - Windows

    private func rebuildWindows() {
        windows.forEach { $0.player = nil; $0.orderOut(nil); $0.close() }
        windows = NSScreen.screens.map { screen in
            let window = WallpaperWindow(screen: screen)
            window.player = player
            window.orderBack(nil)
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePlayback() }
            }
            return window
        }
        updatePlayback()
    }

    // MARK: - Playback policy

    private func updatePlayback() {
        let anyVisible = windows.contains { $0.occlusionState.contains(.visible) }
        let blockedByBattery = pauseOnBattery && Self.isOnBattery()
        let shouldPlay = videoURL != nil && !userPaused && !screensAsleep && anyVisible && !blockedByBattery

        if shouldPlay, player.rate == 0 {
            player.play()
        } else if !shouldPlay, player.rate != 0 {
            player.pause()
        }
    }

    var isPlaying: Bool { player.rate != 0 }

    // MARK: - Power

    private func observePowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<WallpaperController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.updatePlayback() }
        }, context)?.takeRetainedValue() else { return }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPSBatteryPowerValue
    }

    // MARK: - Static wallpaper sync

    /// Sets the real desktop picture to the video's first frame so Mission Control,
    /// Space transitions and the menu bar tint match the live wallpaper.
    private func setStaticWallpaper(from url: URL) {
        Task {
            guard let cgImage = await Self.firstFrame(of: url) else { return }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }

            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LiveWall", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Unique name each time: macOS caches desktop pictures by URL.
            let file = dir.appendingPathComponent("frame-\(Int(Date().timeIntervalSince1970)).png")
            try? data.write(to: file)

            // Clean up older frames.
            if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for f in old where f.lastPathComponent.hasPrefix("frame-") && f != file {
                    try? FileManager.default.removeItem(at: f)
                }
            }

            for screen in NSScreen.screens {
                try? NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true])
            }
        }
    }

    private nonisolated static func firstFrame(of url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: .zero).image
    }
}
