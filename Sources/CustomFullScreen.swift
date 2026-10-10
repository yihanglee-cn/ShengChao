import AppKit

// MARK: - 自绘全屏（传统全屏）

/// 为什么不用绿色按钮那个系统全屏：带刘海的内建屏上，macOS 的原生全屏空间会给菜单栏
/// 预留顶端那一行（就是刘海所在的那一行），系统在那一条上画黑边、App 内容整块下移，
/// 而「覆盖全屏窗口的 frame 去包含刘海区」没有公开 API（Apple HIG 把这类需求归到
/// custom full screen：自己做全屏、自己安排安全区，IINA 等播放器也是这么做的）。
/// 所以这里自己实现全屏：
///
///   · 菜单栏与 Dock 改成自动隐藏（鼠标移到屏幕顶端 / 底端仍能唤出）
///   · 窗口铺成整块 screen.frame（不是 visibleFrame），刘海左右两侧因此都能用上
///
/// 刘海本体是摄像头，物理上没有像素：顶栏中间本来就留空，左右两簇内容不会被挡。
///
/// 窗口保持 `.titled`（标题栏透明 + 内容铺满，SwiftUI 的 hiddenTitleBar 就是这样）：
/// AppKit 里 borderless 窗口的 canBecomeKey 是 false，切成 borderless 后键盘事件就收不到了，
/// 所以不能照搬「全屏时把窗口变 borderless」那套做法。
final class CustomFullScreen {
    static let shared = CustomFullScreen()

    /// 当前是否处于自绘全屏。窗口尺寸 / 位置记忆要据此跳过全屏帧，否则会把铺满屏幕的矩形记成窗口尺寸。
    private(set) var isActive = false

    private weak var window: NSWindow?
    private var savedFrame: NSRect = .zero
    private var savedPresentationOptions: NSApplication.PresentationOptions = []
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    private init() {}

    /// 窗口当前是否处于全屏：系统原生全屏（别处窗口仍可能用）或声潮自绘全屏
    static func isFullScreen(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.fullScreen) || shared.isActive
    }

    // MARK: - 接管主窗口

    /// 把主窗口的绿色按钮接管成自绘全屏的开关，并关掉系统原生全屏。
    /// 可重复调用（HostWindowProbe 在窗口变化时会反复回调）。
    func install(on window: NSWindow) {
        self.window = window
        disableNativeFullScreen(on: window)
        hookZoomButton(on: window)
        installKeyMonitor()
    }

    /// 去掉原生全屏：否则 ⌃⌘F / 菜单里的「进入全屏」会绕过这里，又走回系统全屏、顶端照样留黑边
    private func disableNativeFullScreen(on window: NSWindow) {
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
    }

    /// 绿按钮的默认动作是发给窗口的 `_setNeedsZoom:`（窗口支持全屏时它走的就是系统全屏），换成自己的入口
    private func hookZoomButton(on window: NSWindow) {
        guard let zoom = window.standardWindowButton(.zoomButton) else { return }
        zoom.target = self
        zoom.action = #selector(zoomButtonClicked(_:))
    }

    @objc private func zoomButtonClicked(_ sender: NSButton) {
        toggle(sender.window ?? window)
    }

    /// ⌃⌘F：系统全屏的标准快捷键，这里也指向自绘全屏（绿按钮那条路万一没接上时的兜底入口）
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == 3,                       // F
                  event.modifierFlags.contains(.control),
                  event.modifierFlags.contains(.command) else { return event }
            self.toggle(self.window)
            return nil
        }
    }

    // MARK: - 进入 / 退出

    func toggle(_ window: NSWindow?) {
        guard let window else { return }
        if isActive {
            exit()
        } else {
            enter(window)
        }
    }

    private func enter(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        savedFrame = window.frame
        savedPresentationOptions = NSApp.presentationOptions
        isActive = true

        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        hookZoomButton(on: window)
        startObservingScreenChanges()
    }

    private func exit() {
        guard isActive, let window else { return }
        isActive = false

        NSApp.presentationOptions = savedPresentationOptions
        window.setFrame(restoredFrame(), display: true)
        hookZoomButton(on: window)
        stopObservingScreenChanges()
    }

    /// 退出时回到进入前的矩形；期间若换过显示器 / 改过分辨率，按可见区域钳制回来
    private func restoredFrame() -> NSRect {
        let target = NSScreen.screens.first { $0.visibleFrame.intersects(savedFrame) }
            ?? window?.screen
            ?? NSScreen.main
        guard let visible = target?.visibleFrame else { return savedFrame }

        var frame = savedFrame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
        return frame
    }

    // MARK: - 全屏期间换屏 / 改分辨率

    private func startObservingScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.isActive,
                  let window = self.window,
                  let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(screen.frame, display: true)
        }
    }

    private func stopObservingScreenChanges() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }
}
