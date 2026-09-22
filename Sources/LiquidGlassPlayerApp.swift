import SwiftUI
import AppKit

// MARK: - 数据模型（演示用，后续接真实扫描）

struct Album: Identifiable {
    let id = UUID()
    let name: String
    let artist: String
    let year: String
    let coverColors: [Color]
    let symbol: String
}

struct Track: Identifiable {
    let id = UUID()
    let title: String
    let artist: String
    let album: String
    let duration: String
}

// MARK: - 演示数据

let demoAlbums: [Album] = [
    Album(name: "Midnight Sessions", artist: "Aurora Waves", year: "2024",
          coverColors: [.indigo, .purple], symbol: "moon.stars.fill"),
    Album(name: "Neon Bloom", artist: "Velvet Circuit", year: "2023",
          coverColors: [.pink, .orange], symbol: "sparkles"),
    Album(name: "Northern Lights", artist: "Polar Echo", year: "2025",
          coverColors: [.teal, .cyan], symbol: "wand.and.stars"),
    Album(name: "Velvet Hour", artist: "The Nightjars", year: "2022",
          coverColors: [.red, .brown], symbol: "music.note"),
    Album(name: "Coastal Drift", artist: "Sea Glass", year: "2024",
          coverColors: [.blue, .mint], symbol: "water.waves"),
    Album(name: "Ember & Ash", artist: "Pyre", year: "2023",
          coverColors: [.orange, .red], symbol: "flame.fill"),
    Album(name: "Paper Lanterns", artist: "Ink & Oak", year: "2021",
          coverColors: [.yellow, .orange], symbol: "lightbulb.fill"),
    Album(name: "Frostline", artist: "Glacier", year: "2025",
          coverColors: [.cyan, .blue], symbol: "snowflake"),
]

let sidebarItems: [(name: String, icon: String)] = [
    ("最近播放", "clock"),
    ("歌曲", "music.note"),
    ("专辑", "square.stack"),
    ("艺术家", "person.2"),
    ("收藏", "heart"),
    ("播放列表", "list.bullet"),
]

let nowPlayingTrack = Track(
    title: "Midnight Bloom",
    artist: "Aurora Waves",
    album: "Midnight Sessions",
    duration: "4:32"
)

// MARK: - App 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // 每次启动重置悬浮窗开关，避免与真实窗口状态不同步
        UserDefaults.standard.set(false, forKey: "floatingOpen")
        // 启动时自动恢复曲库：磁盘缓存秒开 + 后台增量扫描（无需手动重新扫描）
        Task { @MainActor in
            await AudioLibrary.shared.autoRestore()
        }
    }
}

@main
struct LiquidGlassPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(UIScaleOption.storageKey) private var uiScaleRaw = UIScaleOption.standard.rawValue

    private var uiScale: UIScaleOption { UIScaleOption(rawValue: uiScaleRaw) ?? .standard }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.uiScale, uiScale)
        }
        .windowStyle(.hiddenTitleBar)
        // 首次启动的窗口尺寸随档位放大，避免大档位下内容被挤压
        .defaultSize(width: 1150 * uiScale.factor, height: 740 * uiScale.factor)
        .windowResizability(.contentMinSize)

        Window("悬浮窗", id: "floating") {
            FloatingPlayerView()
                .environment(\.uiScale, uiScale)
        }
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .windowResizability(.contentSize)

        Window("设置", id: "settings") {
            SettingsView()
                .environment(\.uiScale, uiScale)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
