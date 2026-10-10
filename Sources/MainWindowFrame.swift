import AppKit

// MARK: - 主窗口尺寸 / 位置记忆

/// 记住主窗口的大小与位置：关掉再打开，回到关闭前的样子。
///
/// 不依赖 AppKit 的「窗口自动保存名」：SwiftUI 会在场景刷新时把自己那套按
/// 场景类型拼出来的保存名重新装回窗口（改版时键名还会变），自定义保存名因此
/// 只读得到、写不进去，用户新调过的尺寸记不住。这里改成自己监听窗口的移动 /
/// 缩放，防抖后写进固定键；启动时读回，并按屏幕可见区域钳制。
final class MainWindowFrame {
    static let shared = MainWindowFrame()

    /// 固定键，不受 SwiftUI 场景类型变化影响
    private static let key = "mainWindowFrame"

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var saveTask: Task<Void, Never>?

    private init() {}

    /// 首次拿到宿主窗口：读回上次的矩形，并开始跟踪后续的移动 / 缩放
    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // 换窗口时先摘掉旧窗口的监听，避免挂在已销毁的窗口上
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        // 关掉 AppKit 自带的窗口记忆，避免两套机制互相覆盖
        window.setFrameAutosaveName("")

        if let saved = UserDefaults.standard.string(forKey: Self.key) {
            let frame = NSRectFromString(saved)
            if frame.width > 0, frame.height > 0 {
                window.setFrame(constrain(frame), display: true)
            }
        }

        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.scheduleSave()
            })
        }
    }

    /// 立即落盘：退出前调用，避免防抖还没到就退出
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        write()
    }

    /// 拖动 / 缩放过程中会连续触发，等停下来再写，避免频繁落盘
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self.write()
        }
    }

    private func write() {
        // 全屏时窗口铺满整块屏幕，记下来会覆盖掉窗口模式下的尺寸
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.key)
    }

    /// 钳制回可见区域，并保证不小于内容最小尺寸
    /// （换分辨率、拔掉外接屏后，上次的位置可能已经在屏幕外）
    private func constrain(_ frame: NSRect) -> NSRect {
        guard let window else { return frame }
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }

        let minFrame = window.frameRect(forContentRect:
            NSRect(origin: .zero, size: window.contentMinSize)).size
        let width = min(max(frame.width, minFrame.width), visible.width)
        let height = min(max(frame.height, minFrame.height), visible.height)
        let x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - width))
        let y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - height))
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
