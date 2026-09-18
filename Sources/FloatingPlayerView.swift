import SwiftUI
import AppKit

// MARK: - 主窗口显隐（用 NSWindow，比 dismissWindow 更可靠）

enum WindowManager {
    static func setMainWindowVisible(_ visible: Bool) {
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                if window.title == "悬浮窗" || window.level == .floating { continue }
                if visible {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    window.orderOut(nil)
                }
            }
            if visible {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}

// MARK: - 窗口配置（透明背景 + 无标题栏 + 可拖动）

final class FloatingWindowConfiguratorView: NSView {
    var onAttach: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }
        // 延迟到下一轮 runloop，确保 SwiftUI 完成窗口设置后再配置（重开窗口时也可靠）
        DispatchQueue.main.async {
            self.onAttach?(window)
        }
    }
}

struct FloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> FloatingWindowConfiguratorView {
        let view = FloatingWindowConfiguratorView()
        view.onAttach = { window in
            Self.configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: FloatingWindowConfiguratorView, context: Context) {}

    static func configure(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.remove(.titled)
        window.styleMask.remove(.fullSizeContentView)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.level = .floating
    }
}

// MARK: - 悬浮迷你播放器

// 非 key 窗口也能可靠触发的 hover 检测（NSTrackingArea + .activeAlways）
final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

struct HoverDetector: NSViewRepresentable {
    var onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        let v = HoverTrackingView()
        v.onHoverChange = onHoverChange
        return v
    }

    func updateNSView(_ nsView: HoverTrackingView, context: Context) {
        nsView.onHoverChange = onHoverChange
    }
}

struct FloatingPlayerView: View {
    @ObservedObject private var library = AudioLibrary.shared
    @AppStorage("nightMode") private var nightMode = true
    @AppStorage("floatingOpen") private var floatingOpen = false
    @AppStorage("dynamicCoverEnabled") private var dynamicCoverEnabled = true
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hoveringClose = false
    private var theme: AppTheme { nightMode ? .night : .day }

    private var glass: Glass {
        nightMode ? .regular : .clear
    }

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if dynamicCoverEnabled, let dyn = library.currentTrack?.dynamicCoverURL {
                    DynamicCoverView(url: dyn)
                } else {
                    CoverArtwork(artwork: library.currentTrack?.artworkThumbnail,
                                 fallbackName: library.currentTrack?.title ?? "music",
                                 size: 52)
                }
            }
            .frame(width: 200, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(spacing: 2) {
                Text(library.currentTrack?.title ?? "未在播放")
                    .font(.title3)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(library.currentTrack.map { $0.artist } ?? "选择一首歌开始播放")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            HStack(spacing: 24) {
                Button { library.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 46, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(library.tracks.isEmpty)

                Button { library.togglePlay() } label: {
                    Image(systemName: library.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title.weight(.bold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 60, height: 60)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(library.currentTrack == nil)

                Button { library.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 46, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(library.tracks.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 224)
        .glassEffect(glass, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(alignment: .topLeading) {
            closeButton
        }
        .background(FloatingWindowConfigurator())
        .gesture(WindowDragGesture())
        .onAppear {
            floatingOpen = true
            WindowManager.setMainWindowVisible(false)
        }
        .onDisappear {
            floatingOpen = false
            WindowManager.setMainWindowVisible(true)
        }
    }

    private var closeButton: some View {
        Button {
            floatingOpen = false
            dismissWindow(id: "floating")
        } label: {
            Circle()
                .fill(Color(red: 1.0, green: 0.373, blue: 0.341))
                .frame(width: 12, height: 12)
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(Color(red: 0.42, green: 0.05, blue: 0.05))
                )
                .opacity(hoveringClose ? 1 : 0)
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .background(HoverDetector { hoveringClose = $0 })
        .animation(.easeInOut(duration: 0.15), value: hoveringClose)
        .padding(12)
        .help("关闭悬浮窗")
    }
}
