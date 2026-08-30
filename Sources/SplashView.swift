import SwiftUI
import AppKit

// MARK: - 启动动画

/// 全屏启动动画（总时长 2s）：
/// 0.0-0.4s 背景图淡入 → 0.3-0.7s 中央 logo 淡入 →
/// 1.5-2.0s logo 与背景同时淡出（主界面浮现）→ 2.0s 窗口关闭
struct SplashView: View {
    @State private var bgVisible = false
    @State private var logoVisible = false

    var body: some View {
        ZStack {
            Background()
                .opacity(bgVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.4), value: bgVisible)

            VStack(spacing: 30) {
                // 与原 logo 完全一致的 waveform 波形（全白）
                Image(systemName: "waveform")
                    .font(.system(size: 220, weight: .medium))
                    .foregroundStyle(.white)
                // SOUND WAVE 字样
                Text("SOUND WAVE")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .kerning(8)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .opacity(logoVisible ? 1 : 0)
            .scaleEffect(logoVisible ? 1 : 0.9)
            .animation(.easeInOut(duration: 0.4), value: logoVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // 1. 背景淡入
            withAnimation(.easeOut(duration: 0.4)) { bgVisible = true }
            // 2. logo 淡入
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeInOut(duration: 0.4)) { logoVisible = true }
            }
            // 3. logo 与背景一起淡出（主界面浮现）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    logoVisible = false
                    bgVisible = false
                }
            }
        }
    }
}

/// 启动窗口控制器：全屏无边框窗口覆盖主界面，2s 后关闭
final class SplashWindowController {
    static let shared = SplashWindowController()
    private var window: NSWindow?

    func show() {
        guard window == nil else { return }
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let win = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.ignoresMouseEvents = true
        win.contentView = NSHostingView(rootView: SplashView())
        win.setFrame(screen, display: true)
        win.orderFrontRegardless()
        window = win

        // 先隐藏主界面（避免动画开始前闪现），动画末尾交叉淡入
        let others = NSApp.windows.filter { $0 != win }
        for w in others { w.alphaValue = 0 }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak win] in
            guard let win else { return }
            for w in NSApp.windows where w != win {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.5
                    w.animator().alphaValue = 1
                })
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak win] in
            guard let win else { return }
            win.orderOut(nil)
        }
    }
}
