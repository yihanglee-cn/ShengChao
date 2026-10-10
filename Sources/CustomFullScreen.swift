import AppKit
import Combine

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
/// 还有个坑：带刘海的内建屏上，AppKit 会把「带标题栏窗口」的顶边压到摄像头那一行之下
/// （`NSWindow.constrainFrameRect(_:toScreen:)` 的默认实现把刘海那一行当安全区，
/// 本机实测：titled 窗口 setFrame 会被压回 visibleFrame，非 titled 窗口才放行）。
/// Apple 文档写明「子类可以覆写该方法来取消约束」，但 SwiftUI 的窗口不是我们的子类，
/// 所以在自绘全屏期间临时替换 NSWindow 的该方法实现，只对声潮主窗口放行（见下方）。
///
/// 窗口保持 `.titled`（标题栏透明 + 内容铺满，SwiftUI 的 hiddenTitleBar 就是这样）：
/// AppKit 里非 titled 窗口的 canBecomeKey 是 false（本机实测），那样一旦窗口失去焦点
/// 就再也拿不回键盘，播放器最要紧的空格键会直接失效。
///
/// 四角缺口：titled 窗口由系统画成圆角（AppKit 没有公开的圆角接口，抹图层 cornerRadius
/// 也没用——本机实测），屏幕是直角时四个角就会露出后面的桌面。做法是把窗口铺成
/// 「屏幕外扩 overscan 的一圈」，让窗口自己的圆角（连同红绿灯）落到屏幕外面去；
/// 多出来的那一圈对 App 不可见，界面按 overscan 内缩同样的距离，可见布局仍与屏幕严丝合缝。
/// 本机截图实测：外扩后四角覆盖率 100%，且 canBecomeKey 仍为 true。
final class CustomFullScreen: ObservableObject {
    static let shared = CustomFullScreen()

    /// 屏幕外扩的一圈（点）。要大于系统给窗口的圆角半径（本机实测约 18pt），取 24 留余量。
    private static let overscanAmount: CGFloat = 24

    /// 当前是否处于自绘全屏。窗口尺寸 / 位置记忆要据此跳过全屏帧，否则会把铺满屏幕的矩形记成窗口尺寸。
    private(set) var isActive = false

    /// 全屏时界面要内缩的距离（外面那一圈在屏幕外，见类型注释）。ContentView 用它做 padding。
    @Published private(set) var overscan: CGFloat = 0

    private weak var window: NSWindow?
    private var savedFrame: NSRect = .zero
    private var savedPresentationOptions: NSApplication.PresentationOptions = []
    private var savedMovable = true
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var bypassInstalled = false
    private var bypassLogged = false
    private var isReassertingFrame = false

    private init() {}

    /// 窗口当前是否处于全屏：系统原生全屏（别处窗口仍可能用）或声潮自绘全屏
    static func isFullScreen(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.fullScreen) || shared.isActive
    }

    /// 自绘全屏时窗口该占的矩形：屏幕四周各外扩一圈
    private func fullScreenFrame(for screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let over = Self.overscanAmount
        return NSRect(x: frame.minX - over, y: frame.minY - over,
                      width: frame.width + over * 2, height: frame.height + over * 2)
    }

    // MARK: - 接管主窗口

    /// 把主窗口的绿色按钮接管成自绘全屏的开关，并关掉系统原生全屏。
    /// 可重复调用（HostWindowProbe 在窗口变化时会反复回调）。
    func install(on window: NSWindow) {
        self.window = window
        disableNativeFullScreen(on: window)
        hookZoomButton(on: window)
        installKeyMonitor()
        log("接管窗口 frame=\(fmt(window.frame)) styleMask=\(window.styleMask.rawValue) collectionBehavior=\(window.collectionBehavior.rawValue) 屏幕=\(describe(window.screen))")
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
        log("绿按钮被点击")
        toggle(sender.window ?? window)
    }

    /// ⌃⌘F（系统全屏的标准快捷键）与 Esc 都指向自绘全屏的开关。
    /// 全屏时窗口比屏幕大一圈，红绿灯被推到屏幕外（也显式隐藏了），这两个快捷键就是出口。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 3,                                   // F（⌃⌘F）
               event.modifierFlags.contains(.control),
               event.modifierFlags.contains(.command) {
                self.toggle(self.window)
                return nil
            }
            if event.keyCode == 53, self.isActive {                  // Esc：退出自绘全屏
                self.exit()
                return nil
            }
            return event
        }
    }

    // MARK: - 解除刘海屏对窗口顶边的约束

    /// 只对「声潮主窗口 + 自绘全屏进行中」放行，其它窗口 / 其它时候原样交给系统实现
    fileprivate func shouldBypassFrameConstraint(for window: NSWindow) -> Bool {
        guard isActive, window === self.window else { return false }
        if !bypassLogged {
            bypassLogged = true
            log("constrainFrameRect 已放行：\(fmt(window.frame))")
        }
        return true
    }

    /// 临时替换 NSWindow 的 constrainFrameRect 实现（进入时装上、退出时还原），
    /// 换掉之后我们的实现里再调同名方法就是原来的系统实现
    private func setFrameConstraintBypass(_ enabled: Bool) {
        guard enabled != bypassInstalled,
              let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:))),
              let replacement = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.sc_constrainFrameRect(_:to:))) else { return }
        method_exchangeImplementations(original, replacement)
        bypassInstalled = enabled
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
        savedMovable = window.isMovable
        isActive = true
        bypassLogged = false
        overscan = Self.overscanAmount          // 界面整体内缩，让可见布局仍与屏幕严丝合缝

        setFrameConstraintBypass(true)
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        window.isMovable = false
        setTrafficLights(hidden: true, in: window)
        let target = fullScreenFrame(for: screen)
        window.setFrame(target, display: true)
        window.makeKeyAndOrderFront(nil)
        hookZoomButton(on: window)
        startObserving()
        log("进入自绘全屏 目标=\(fmt(target)) 实际=\(fmt(window.frame)) presentation=\(NSApp.presentationOptions.rawValue) isKey=\(window.isKeyWindow) \(describe(screen))")

        // 系统可能在这一拍之后又把窗口顶下来（刘海安全区），补一次并留痕
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak window] in
            guard let self, let window, self.isActive else { return }
            guard window.frame != self.fullScreenFrame(for: window.screen ?? screen) else { return }
            self.log("0.2s 后窗口被挪动：\(fmt(window.frame))，补一次")
            self.reassertFrame(window, to: window.screen ?? screen)
        }
    }

    private func exit() {
        guard isActive, let window else { return }
        isActive = false
        overscan = 0
        setFrameConstraintBypass(false)
        stopObserving()

        NSApp.presentationOptions = savedPresentationOptions
        window.isMovable = savedMovable
        setTrafficLights(hidden: false, in: window)
        let target = restoredFrame()
        window.setFrame(target, display: true)
        hookZoomButton(on: window)
        log("退出自绘全屏 目标=\(fmt(target)) 实际=\(fmt(window.frame)) presentation=\(NSApp.presentationOptions.rawValue)")
    }

    /// 全屏时窗口把红绿灯推到屏幕外了，这里再显式隐藏，免得万一被谁挪回来还能点到
    private func setTrafficLights(hidden: Bool, in window: NSWindow) {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = hidden
        }
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

    // MARK: - 全屏期间盯住窗口 frame

    private func startObserving() {
        guard self.window != nil, observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSApplication.didChangeScreenParametersNotification,
                                          NSWindow.didResizeNotification,
                                          NSWindow.didMoveNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isActive, let window = self.window,
                      let screen = window.screen ?? NSScreen.main else { return }
                self.reassertFrame(window, to: screen)
            })
        }
    }

    private func stopObserving() {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    /// 全屏期间窗口必须始终铺满当前屏幕（外扩一圈的矩形）：被系统顶下来、被误拖 / 误缩放都拉回来
    private func reassertFrame(_ window: NSWindow, to screen: NSScreen) {
        let target = fullScreenFrame(for: screen)
        guard !isReassertingFrame, window.frame != target else { return }
        isReassertingFrame = true
        window.setFrame(target, display: true)
        isReassertingFrame = false
    }

    // MARK: - 排查用日志（写 ~/Library/Logs/声潮-全屏.log，只记进入 / 退出这些关键点）

    private func describe(_ screen: NSScreen?) -> String {
        guard let screen else { return "屏幕=nil" }
        return "屏幕 frame=\(fmt(screen.frame)) visible=\(fmt(screen.visibleFrame)) 刘海安全区=\(screen.safeAreaInsets.top) 左右刘海区=\(String(describing: screen.auxiliaryTopLeftArea))/\(String(describing: screen.auxiliaryTopRightArea))"
    }

    private func fmt(_ rect: NSRect) -> String {
        String(format: "(%.0f,%.0f,%.0f,%.0f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    private func log(_ message: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("声潮-全屏.log")
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            let size = (try? handle.seekToEnd()) ?? 0
            if size > 64 * 1024 { try? handle.truncate(atOffset: 0) }   // 超过 64KB 从头覆盖
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

private extension NSWindow {
    /// 替换 constrainFrameRect 用的实现：自绘全屏期间让主窗口的 frame 原样通过。
    /// 装上替换之后，这里再调 sc_constrainFrameRect 走的就是系统原来的实现。
    @objc func sc_constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if CustomFullScreen.shared.shouldBypassFrameConstraint(for: self) { return frameRect }
        return sc_constrainFrameRect(frameRect, to: screen)
    }
}
