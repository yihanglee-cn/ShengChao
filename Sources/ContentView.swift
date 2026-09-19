import SwiftUI
import AppKit
import AVFoundation

import CoreImage

/// 从 NSImage 提取平均色（主色调），用于全屏封面主题的暗色背景
func averageColor(of nsImage: NSImage) -> Color {
    guard let tiff = nsImage.tiffRepresentation,
          let ci = CIImage(data: tiff) else { return .black }
    let extent = ci.extent
    guard extent.width > 0, extent.height > 0 else { return .black }
    let filter = CIFilter(name: "CIAreaAverage", parameters: [
        kCIInputImageKey: ci,
        kCIInputExtentKey: CIVector(cgRect: extent)
    ])
    guard let out = filter?.outputImage else { return .black }
    var rgba: [UInt8] = [0, 0, 0, 255]
    CIContext().render(out, toBitmap: &rgba, rowBytes: 4,
                      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                      format: .RGBA8, colorSpace: nil)
    return Color(red: Double(rgba[0])/255, green: Double(rgba[1])/255,
                 blue: Double(rgba[2])/255, opacity: 1)
}

// MARK: - 主题（白天/夜晚）

enum AppTheme {
    case night, day

    var isDay: Bool { self == .day }

    var primaryText: Color { .white }
    var secondaryText: Color { .white.opacity(0.60) }
    var tertiaryText: Color { .white.opacity(0.45) }
    var glass: Glass {
        isDay ? .clear : .regular
    }
    var selectionFill: Color { Color.white.opacity(0.16) }
    var fieldFill: Color { Color.white.opacity(0.10) }
}

// MARK: - 液态玻璃开关（开=蓝，关=灰）

/// 自定义开关：完全自绘（轨道 + 滑块），颜色 100% 可控，
/// 开=蓝渐变、关=灰渐变，点击带弹簧动画，与液态玻璃风格统一。
struct GlassToggle<Label: View>: View {
    @Binding var isOn: Bool
    var help: String = ""
    @ViewBuilder var label: Label

    var body: some View {
        HStack(spacing: 8) {
            label
            GlassSwitchKnob(isOn: isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isOn.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(help.isEmpty ? "开关" : help)
        .accessibilityValue(isOn ? "开" : "关")
        .help(help)
    }
}

extension GlassToggle where Label == EmptyView {
    init(isOn: Binding<Bool>, help: String = "") {
        self._isOn = isOn
        self.help = help
        self.label = EmptyView()
    }
}

/// 自绘开关外观：40×22 轨道 + 16pt 白色滑块，开=蓝渐变、关=灰渐变
private struct GlassSwitchKnob: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            // 轨道
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isOn
                            ? [Color(red: 0.35, green: 0.62, blue: 1.0),
                               Color(red: 0.05, green: 0.35, blue: 0.95)]
                            : [Color(white: 0.58), Color(white: 0.42)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            // 滑块
            Circle()
                .fill(.white)
                .frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                .padding(3)
                .offset(x: isOn ? 18 : 0)
        }
        .frame(width: 40, height: 22, alignment: .leading)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.night
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - 记录播放栏小封面全局位置（大封面 Hero 动画的起点）

final class CoverFrameStore: ObservableObject {
    static let shared = CoverFrameStore()
    @Published var smallCoverFrame: CGRect = .zero
}

/// 列表滚动位置记忆（进详情返回后恢复滚动位置）
final class ScrollPositionStore {
    static let shared = ScrollPositionStore()
    var songListVisibleID: AudioTrack.ID?
    var favoritesVisibleID: AudioTrack.ID?
    var albumGridVisibleID: AlbumGroup.ID?
    var artistTracksVisibleID: AudioTrack.ID?
    private init() {}
}

// 大封面 Hero 动画时长（原 4s，提速 9.2 倍）
private let coverAnimationDuration: Double = 4.0 / 9.2

// 歌词面板：收集每行歌词的中心 y（用于按距面板中心的距离计算边缘模糊）
struct LyricMidKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - 液态玻璃主界面

struct ContentView: View {
    @ObservedObject private var library = AudioLibrary.shared
    @State private var selectedSidebar = "专辑"
    @State private var rotationAngle: Double = 0
    @State private var rotationTimer: Timer?
    @State private var showFullCover = false
    @State private var showLyrics = false
    @State private var coverVisible = false  // 大封面层可见性（关闭时延迟隐藏，保证回程动画可见）
    @State private var controlsVisible = true  // 全屏封面模式下控制区是否自动隐藏
    @State private var autoHideTask: Task<Void, Never>?
    
    @ObservedObject private var coverFrameStore = CoverFrameStore.shared
    @State private var coverSeekPosition: Double = 0
    @State private var coverIsDragging = false
    @State private var lyricMids: [Int: CGFloat] = [:]  // 每行歌词中心 y（边缘模糊用）
    @State private var volumeIndicatorVisible = false
    @State private var volumeIndicatorTask: Task<Void, Never>?
    @State private var keyMonitor: Any? = nil
    @Namespace private var coverNamespace
    @AppStorage("nightMode") private var nightMode = true
    @AppStorage("energySaving") private var energySaving = false
    @AppStorage("dynamicCoverEnabled") private var dynamicCoverEnabled = true
    @AppStorage("cover3DEnabled") private var cover3DEnabled = false
    @AppStorage("fullScreenCoverMode") private var fullScreenCoverMode = false
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    TopBar(library: library, showSettings: $showSettings)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 10)

                    if !library.statusMessage.isEmpty {
                        statusBar
                    }

                    HStack(spacing: 14) {
                        Sidebar(selected: $selectedSidebar, library: library)
                        MainArea(library: library, selectedSection: selectedSidebar)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)

                    NowPlayingBar(library: library,
                                  coverNamespace: coverNamespace,
                                  showFullCover: $showFullCover,
                                  coverVisible: $coverVisible)
                        .opacity(coverVisible ? 0 : 1)  // 全屏封面激活时隐藏整个底部控制栏
                        .animation(nil, value: coverVisible)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }

                // 大封面（常驻；背景淡入淡出，封面不透明只做位移动画）
                fullCoverOverlay
                    .zIndex(10)

                // 设置浮层（主窗口内，跟随窗口最小化）
                if showSettings {
                    SettingsPanel(showSettings: $showSettings)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .zIndex(30)
                }

                if showFullCover && !fullScreenCoverMode {
                    // 「词」按钮（全屏封面模式默认显示歌词，不需要切换）
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showLyrics.toggle()
                        }
                    } label: {
                        Text("词")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(.clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(24)
                    .position(x: geo.size.width - 46, y: 46 - windowTopInset)
                    .zIndex(20)
                }
            }
            .background(backgroundView)
        }
        .environment(\.theme, nightMode ? .night : .day)
        .onChange(of: library.isPlaying) { playing in
            if playing && !energySaving {
                startRotation()
            } else {
                stopRotation()
            }
        }
        .onChange(of: energySaving) { saving in
            if saving {
                stopRotation()
                rotationAngle = 0
            } else if library.isPlaying {
                startRotation()
            }
        }
        .onChange(of: showFullCover) { showing in
            if !showing {
                controlsVisible = true
                autoHideTask?.cancel()
                
            }
            if showing {
                coverVisible = true
                showLyrics = true   // 打开播放页时自动显示歌词
            } else {
                // 等关闭动画结束再隐藏大封面层，让回程动画可见
                DispatchQueue.main.asyncAfter(deadline: .now() + coverAnimationDuration + 0.15) {
                    if !showFullCover {
                        coverVisible = false
                    }
                }
            }
        }
        .onAppear {
            // app 失去焦点时自动恢复鼠标（防止切换到其他应用鼠标消失）
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                
            }
            // 窗口最小化时也恢复鼠标
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMiniaturizeNotification,
                object: nil,
                queue: .main
            ) { _ in
                
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // 文本输入框聚焦时不拦截，空格/方向键正常输入
                if let fr = NSApp.keyWindow?.firstResponder,
                   fr is NSTextView || fr is NSTextField {
                    return event
                }
                let flags = event.modifierFlags
                if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
                    return event
                }
                switch event.keyCode {
                case 49:  // 空格
                    library.togglePlay()
                    return nil
                case 123: // 左方向键
                    library.previous()
                    return nil
                case 124: // 右方向键
                    library.next()
                    return nil
                case 126: // 上方向键：音量 +5%
                    library.volume = min(1.0, library.volume + 0.05)
                    showVolumeIndicator()
                    return nil
                case 125: // 下方向键：音量 -5%
                    library.volume = max(0.0, library.volume - 0.05)
                    showVolumeIndicator()
                    return nil
                case 37: // L：切换歌词面板（同大封面右上角「词」按钮）
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showLyrics.toggle()
                    }
                    return nil
                case 6: // Z：打开/关闭大封面（同点击播放栏小封面 / 点击空白关闭）
                    withAnimation(.easeInOut(duration: coverAnimationDuration)) {
                        if showFullCover {
                            showFullCover = false
                            showLyrics = false
                        } else {
                            showFullCover = true
                        }
                    }
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let m = keyMonitor {
                NSEvent.removeMonitor(m)
                keyMonitor = nil
            }
        }
    }

    private func startRotation() {
        guard !energySaving else { return }
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            rotationAngle = (rotationAngle + 0.3).truncatingRemainder(dividingBy: 360)
        }
    }

    // 大封面界面：方向键调音量时在顶端显示音量胶囊，1.6s 后自动淡出
    private func showVolumeIndicator() {
        guard showFullCover else { return }
        volumeIndicatorTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            volumeIndicatorVisible = true
        }
        volumeIndicatorTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.35)) {
                volumeIndicatorVisible = false
            }
        }
    }

    private func stopRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }

    @ViewBuilder
    private var backgroundView: some View {
        if let artwork = library.currentTrack?.artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 22)
                .overlay(Color.black.opacity(0.6))
                .scaleEffect(1.5)
                .rotationEffect(.degrees(rotationAngle))
                .compositingGroup()
                .ignoresSafeArea()
        } else {
            Background()
        }
    }

    @ViewBuilder
    private var fullCoverOverlay: some View {
        GeometryReader { geo in
            let wf = geo.frame(in: .global)
            // 封面中心位置：显示时在窗口中央（有歌词时左移），隐藏时在小封面原位置
            // 小封面位置捕获失败时兜底为窗口左下角（播放栏封面位置）
            let sc = coverFrameStore.smallCoverFrame
            let hasSmall = sc.width > 1 && sc.height > 1
            let startX = hasSmall ? sc.midX : (wf.origin.x + 59)
            let startY = hasSmall ? sc.midY : (wf.origin.y + wf.height - 57)
            let coverX: CGFloat = (showFullCover ? wf.width / 2 : startX - wf.origin.x) - (showLyrics ? 300 : 0)
            let coverY: CGFloat = showFullCover ? wf.height / 2 - 55 : startY - wf.origin.y
            ZStack {
                // 背景（慢慢淡入淡出，逐渐盖住主界面玻璃栏）
                // 必须显式约束到窗口尺寸：resizable Image + maxWidth/maxHeight .infinity
                // 会取图片像素理想尺寸（如 1342×1342）导致溢出 ZStack，翻转 .position 坐标系
                Group {
                    if fullScreenCoverMode, let fullArt = library.currentTrack?.artwork {
                        // 底层：封面模糊铺满全屏，右侧歌词区背景
                        Color.black
                        Image(nsImage: fullArt)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 60)
                            .overlay(Color.black.opacity(0.4))
                        // 上层：左侧正方形封面完整清晰，右缘渐变淡出到模糊背景
                        Image(nsImage: fullArt)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.height, height: geo.size.height)
                            .mask(
                                LinearGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: .black, location: 0),
                                        .init(color: .black, location: 0.75),
                                        .init(color: .clear, location: 1)
                                    ]),
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    } else {
                        backgroundView
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .opacity(showFullCover ? 1 : 0)
                .animation(.easeInOut(duration: coverAnimationDuration), value: showFullCover)

                // 封面（Hero 动画：全程不透明，只做移动+缩放）
                // HeroCover：scaleEffect 平滑放大（视频层不跳变），视觉圆角 10→22 不变
                Group {
                    if cover3DEnabled, let art = library.currentTrack?.artwork {
                        // 3D 封面：封面 + 深度图视差（鼠标全屏驱动）
                        // .id() 按专辑文件夹强制重建——否则 SwiftUI 复用视图时 @State depth 残留上一张专辑的深度
                        ParallaxCover3DView(cover: art,
                                            albumFolder: library.currentTrack?.url.deletingLastPathComponent())
                            .id(library.currentTrack?.url.deletingLastPathComponent().path ?? "no-folder")
                    } else if dynamicCoverEnabled, let dyn = library.currentTrack?.dynamicCoverURL {
                        DynamicCoverView(url: dyn)
                    } else {
                        CoverArtwork(artwork: library.currentTrack?.artworkThumbnail,
                                     fallbackName: library.currentTrack?.title ?? "music",
                                     size: 578)
                    }
                }
                .modifier(HeroCover(progress: showFullCover ? 1 : 0))
                .opacity(fullScreenCoverMode ? 0 : (coverVisible ? 1 : 0))
                .animation(nil, value: coverVisible)
                .position(x: coverX, y: coverY)
                .animation(.easeInOut(duration: coverAnimationDuration), value: showFullCover)
                .shadow(color: .black.opacity(0.45), radius: 42, y: 18)

                // 封面下方：歌名 + 进度条 + 播放控制按钮（紧贴封面底边，且不超出窗口）
                fullPlayerControls
                    .opacity((coverVisible && (fullScreenCoverMode ? controlsVisible : true)) ? 1 : 0)
                    .animation(.easeInOut(duration: 0.3), value: controlsVisible)
                    .allowsHitTesting(coverVisible && (!fullScreenCoverMode || controlsVisible))
                    .zIndex(10)
                    .position(x: fullScreenCoverMode ? wf.width / 2 : coverX,
                              y: showFullCover ? wf.height - 55 : wf.height - 65)
                    .animation(.easeInOut(duration: coverAnimationDuration), value: showFullCover)

                // 歌名/歌手/专辑（全屏封面模式下固定显示在歌词上方，不随控制区隐藏）
                if showFullCover && fullScreenCoverMode, let track = library.currentTrack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("\(track.artist) · \(track.album)")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    .frame(width: max(480, wf.width - 40 - (wf.width / 2 + 60)), alignment: .leading)
                    .position(x: wf.width / 2 + 60 + max(480, wf.width - 40 - (wf.width / 2 + 60)) / 2, y: 70)
                    .zIndex(5)
                }

                // 歌词（右侧，纵向充满窗口，向右扩展）
                if showLyrics {
                    let lyricsLeft = wf.width / 2 + 60
                    let lyricsWidth = max(480, wf.width - 40 - lyricsLeft)
                    // 全屏封面模式下歌词从歌名下方（y=130）开始，避免重叠
                    let topInset: CGFloat = fullScreenCoverMode ? 130 : 0
                    let lyricHeight = wf.height - topInset
                    lyricsPanel(height: lyricHeight)
                        .frame(width: lyricsWidth, height: lyricHeight)
                        .position(x: lyricsLeft + lyricsWidth / 2, y: topInset + lyricHeight / 2)
                        .transition(.opacity)
                        .onTapGesture { }
                }

                // 音量指示胶囊（顶端居中偏下，调音量时出现）
                volumeIndicator
                    .position(x: wf.width / 2, y: 66 - windowTopInset)
                    .zIndex(30)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard fullScreenCoverMode, showFullCover else { return }
            switch phase {
            case .active:
                // 鼠标移动：显示控制区，重置 2 秒自动隐藏
                controlsVisible = true
                
                autoHideTask?.cancel()
                autoHideTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !Task.isCancelled {
                        controlsVisible = false
                        
                    }
                }
            case .ended:
                controlsVisible = true
                
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: coverAnimationDuration)) {
                showFullCover = false
                showLyrics = false
            }
            
        }
        .allowsHitTesting(showFullCover)
        .ignoresSafeArea()
    }

            private var theme: AppTheme { nightMode ? .night : .day }

    // 窗口化时顶部标题栏高度（全屏为 0），「词」按钮用它保持相对窗口最顶边的固定位置
    private var windowTopInset: CGFloat {
        guard let window = NSApp.windows.first(where: { $0.title == "声潮" }) else { return 0 }
        let clr = window.contentLayoutRect
        return max(0, window.frame.height - (clr.origin.y + clr.height))
    }

    // 封面下方进度条（可拖动 seek）
    private var coverProgressBar: some View {
        let duration = library.currentTrack?.duration ?? 0
        return HStack(spacing: 12) {
            Text(library.formatTime(library.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.75))
                .frame(width: 48, alignment: .leading)

            Slider(value: $coverSeekPosition, in: 0...max(1, duration),
                   onEditingChanged: { editing in
                coverIsDragging = editing
                if !editing {
                    library.seek(to: coverSeekPosition)
                }
            })
            .tint(.white)

            Text(library.formatTime(duration))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.75))
                .frame(width: 48, alignment: .trailing)
        }
        .frame(width: 578)
        .onChange(of: library.currentTime) { t in
            if !coverIsDragging {
                coverSeekPosition = t
            }
        }
    }

    // 播放页完整控制区：歌名 + 进度条 + 随机/上下首/播放/循环
    @ViewBuilder
    private var fullPlayerControls: some View {
        VStack(spacing: 14) {
            // 歌名/艺术家（全屏封面模式下单独固定显示在歌词上方，这里不重复）
            if !fullScreenCoverMode {
                VStack(spacing: 4) {
                    Text(library.currentTrack?.title ?? "")
                        .font(.title2.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(library.currentTrack.map { "\($0.artist) — \($0.album)" } ?? "")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .id(library.currentTrack?.id)
            }

            // 进度条（复用）
            coverProgressBar

            // 控制按钮：播放模式 / 上一首 / 播放暂停 / 下一首
            HStack(spacing: 26) {
                Button { library.cyclePlaybackMode() } label: {
                    Image(systemName: library.playbackMode == .one ? "repeat.1" :
                                          library.playbackMode == .shuffle ? "shuffle" : "repeat")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(library.playbackMode == .off ? .white.opacity(0.45) : .white)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)

                Button { library.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)

                Button { library.togglePlay() } label: {
                    Image(systemName: library.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .glassEffect(.clear, in: Circle())
                }
                .buttonStyle(.plain)

                Button { library.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)

                if showFullCover && fullScreenCoverMode, let track = library.currentTrack {
                    Button { library.toggleFavorite(track) } label: {
                        Image(systemName: library.isFavorite(track) ? "heart.fill" : "heart")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(library.isFavorite(track) ? .red : .white.opacity(0.8))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 578)
        .contentShape(Rectangle())
        .onTapGesture { }   // 吞掉点击，不触发关闭播放页
    }

    // 音量指示胶囊（大封面界面顶端）
    private var volumeIndicator: some View {
        HStack(spacing: 10) {
            Image(systemName: library.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Text("\(Int(library.volume * 100))%")
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(.white)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(Color.white)
                        .frame(width: max(0, geo.size.width * CGFloat(library.volume)))
                }
            }
            .frame(width: 90, height: 5)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .opacity(volumeIndicatorVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: volumeIndicatorVisible)
        .allowsHitTesting(false)
    }

    // 歌词面板（右侧，纵向充满窗口；越靠近上/下边缘的歌词越模糊）
    private func lyricsPanel(height: CGFloat) -> some View {
        let lines = library.currentTrack?.lyrics ?? []
        let halfHeight = height / 2
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 44) {
                    if lines.isEmpty {
                        Text("暂无歌词")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            let isCurrent = index == currentLyricIndex
                            Text(line.text)
                                .font(.system(size: isCurrent ? 56 : 28,
                                              weight: isCurrent ? .semibold : .regular))
                                .foregroundColor(.white.opacity(isCurrent ? 1.0 : 0.4))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // 背景测量真实位置（长句自动换行后按整块中心计算模糊）
                                .background(
                                    GeometryReader { g in
                                        Color.clear.preference(
                                            key: LyricMidKey.self,
                                            value: [index: g.frame(in: .named("lyricsPanel")).midY]
                                        )
                                    }
                                )
                                .blur(radius: lyricBlur(for: index, half: halfHeight))
                                .opacity(lyricFade(for: index, half: halfHeight))
                                .animation(.spring(response: 0.45, dampingFraction: 0.6), value: isCurrent)
                                .id(index)
                        }
                    }
                }
                .onPreferenceChange(LyricMidKey.self) { dict in
                    lyricMids = dict
                }
                // 顶部/底部留出半屏高度的空白，保证高亮行（含第一行/最后一行）始终能滚动到面板中央
                .padding(.top, max(halfHeight - 32, 24))
                .padding(.bottom, max(halfHeight - 32, 24))
            }
            .coordinateSpace(name: "lyricsPanel")
            .onChange(of: currentLyricIndex) { _ in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.55, blendDuration: 0.2)) {
                    proxy.scrollTo(currentLyricIndex, anchor: .center)
                }
            }
            .onAppear {
                proxy.scrollTo(currentLyricIndex, anchor: .center)
            }
        }
    }

    // 某行歌词距面板垂直中心的归一化距离（0=正中，1=上/下边缘），中间 60% 完全清晰
    private func lyricEdge(for index: Int, half: CGFloat) -> CGFloat {
        guard let midY = lyricMids[index] else { return 0 }
        let dist = abs(midY - half) / max(half, 1)
        return max(0, dist - 0.6) / 0.4
    }

    private func lyricBlur(for index: Int, half: CGFloat) -> CGFloat {
        let e = lyricEdge(for: index, half: half)
        return min(12.0, e * e * 14)
    }

    private func lyricFade(for index: Int, half: CGFloat) -> Double {
        let e = lyricEdge(for: index, half: half)
        return 1.0 - min(0.85, e * 0.9)
    }

    // 当前应高亮的歌词行索引（按播放时间定位；整轨 CUE 歌要加上 startOffset）
    // 提前 0.5 秒高亮：下一句在其时间戳前 0.5s 就开始显示
    private var currentLyricIndex: Int {
        guard let lines = library.currentTrack?.lyrics, !lines.isEmpty else { return 0 }
        let time = library.currentTime + (library.currentTrack?.startOffset ?? 0) + 0.5
        var idx = 0
        for (i, line) in lines.enumerated() where line.time <= time {
            idx = i
        }
        return idx
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !library.statusMessage.isEmpty {
                HStack(spacing: 8) {
                    if library.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Text(library.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            ForEach(library.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(warning.hasPrefix("✅") ? .green.opacity(0.9) : .yellow.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }
}

// MARK: - 背景（彩色光斑）

struct Background: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.08, blue: 0.22),
                         Color(red: 0.16, green: 0.10, blue: 0.30),
                         Color(red: 0.08, green: 0.12, blue: 0.24)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            Circle()
                .fill(LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom))
                .frame(width: 380, height: 380)
                .blur(radius: 90)
                .offset(x: -320, y: -220)
                .opacity(0.75)

            Circle()
                .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                .frame(width: 360, height: 360)
                .blur(radius: 90)
                .offset(x: 340, y: -180)
                .opacity(0.7)

            Circle()
                .fill(LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom))
                .frame(width: 300, height: 300)
                .blur(radius: 90)
                .offset(x: -80, y: 320)
                .opacity(0.6)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 顶栏

struct TopBar: View {
    @ObservedObject var library: AudioLibrary
    @Binding var showSettings: Bool
    @AppStorage("nightMode") private var nightMode = true
    @State private var showVersion = false
    private var theme: AppTheme { nightMode ? .night : .day }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0.0"
    }

    var body: some View {
        HStack {
            Button {
                showVersion.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Text("声潮")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Text("SOUND WAVE")
                        .font(.caption2.weight(.semibold))
                        .tracking(2)
                        .foregroundStyle(theme.secondaryText)
                        .padding(.leading, 4)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showVersion, arrowEdge: .top) {
                HStack(spacing: 8) {
                    Text("声潮")
                        .font(.headline)
                    Text("版本 \(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }

            Spacer()

            HStack(spacing: 10) {
                // 自定义点击手势（避开 SwiftUI ButtonGesture 的崩溃路径），原玻璃外观
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                    Text("扫描音乐")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .glassEffect(in: Capsule())
                .contentShape(Capsule())
                .onTapGesture {
                    library.chooseFolder()
                }
                .help("扫描音乐")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        nightMode.toggle()
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(nightMode ? theme.secondaryText : theme.primaryText)
                            .frame(width: 30, height: 30)
                            .background {
                                if !nightMode {
                                    Capsule().fill(theme.selectionFill)
                                }
                            }
                        Image(systemName: "moon.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(nightMode ? theme.primaryText : theme.secondaryText)
                            .frame(width: 30, height: 30)
                            .background {
                                if nightMode {
                                    Capsule().fill(theme.selectionFill)
                                }
                            }
                    }
                    .padding(2)
                    .glassEffect(in: Capsule())
                }
                .buttonStyle(.plain)
                .help(nightMode ? "切换到白天模式" : "切换到夜晚模式")

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSettings.toggle()
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("设置")
            }
        }
    }
}

// MARK: - 设置浮层（主窗口内）

struct SettingsPanel: View {
    @Binding var showSettings: Bool
    @AppStorage("nightMode") private var nightMode = true
    @AppStorage("energySaving") private var energySaving = false
    @AppStorage("dynamicCoverEnabled") private var dynamicCoverEnabled = true
    @AppStorage("cover3DEnabled") private var cover3DEnabled = false
    @AppStorage("fullScreenCoverMode") private var fullScreenCoverMode = false
    @State private var hoveringClose = false
            private var theme: AppTheme { nightMode ? .night : .day }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 透明背景：点击外部关闭
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSettings = false
                    }
                }

            // 设置面板本体
            VStack(spacing: 18) {
                // 行 1：节能模式
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("节能模式")
                            .foregroundStyle(theme.primaryText)
                        Text("关闭背景专辑封面旋转")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $energySaving)
                        .toggleStyle(.switch)
                        .tint(.blue)
                        .accentColor(.blue)
                        .help("节能模式")
                        .onChange(of: energySaving) { _, newValue in
                            if newValue { cover3DEnabled = false }
                        }
                }

                // 行 2：动态封面
                HStack(spacing: 12) {
                    Text("动态封面")
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: 12)
                    Toggle("", isOn: $dynamicCoverEnabled)
                        .toggleStyle(.switch)
                        .tint(.blue)
                        .accentColor(.blue)
                        .help("动态封面")
                        .onChange(of: dynamicCoverEnabled) { _, newValue in
                            if newValue { cover3DEnabled = false }
                        }
                }

                // 行 3：3D 封面
                HStack(spacing: 12) {
                    Text("3D 封面")
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: 12)
                    Toggle("", isOn: $cover3DEnabled)
                        .toggleStyle(.switch)
                        .tint(.blue)
                        .accentColor(.blue)
                        .help("3D 封面")
                        .onChange(of: cover3DEnabled) { _, newValue in
                            if newValue { dynamicCoverEnabled = false }
                        }
                }

                // 行 4：全屏封面
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全屏封面")
                            .foregroundStyle(theme.primaryText)
                        Text("专辑图铺满播放页，右侧歌词加遮罩")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $fullScreenCoverMode)
                        .toggleStyle(.switch)
                        .tint(.blue)
                        .accentColor(.blue)
                        .help("全屏封面")
                }
            }
            .padding(20)
            .frame(width: 300)
            .glassEffect(theme.glass, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .topTrailing) {
                closeButton
            }
            .padding(.top, 60)  // 距离顶部：TopBar 高度 + 间距
            .padding(.trailing, 20)
        }
        .ignoresSafeArea()
    }

    private var closeButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showSettings = false
            }
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
        .padding(3)
        .help("关闭设置")
    }
}

// MARK: - 设置窗口（旧版，保留兼容）

struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> FloatingWindowConfiguratorView {
        let view = FloatingWindowConfiguratorView()
        view.onAttach = { window in
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            // 固定：不可拖动（isMovable=false），并定位到主窗口右上角设置按钮下方
            window.isMovableByWindowBackground = false
            window.isMovable = false
            // 全屏时也显示在声潮主界面上（加入所有 Space + 全屏辅助 + 浮层级别）
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.remove(.titled)
            window.styleMask.remove(.fullSizeContentView)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            
            // 定位：设置窗口右边缘 = 主窗口内容面板右边缘；
            // 上边缘 = 设置按钮下边（56pt）+ 下方 14pt = 70
            if let main = NSApp.windows.first(where: { $0 != window && $0.isVisible }),
               let content = main.contentView {
                // contentView 的屏幕坐标 = 大圆角矩形内容面板的实际边界
                let contentFrame = main.convertToScreen(content.bounds)
                let w = window.frame.width
                let h = window.frame.height
                let x = contentFrame.maxX - w
                let y = contentFrame.maxY - h - 70
                window.setFrameOrigin(NSPoint(x: x, y: y))
                
                // 监听主窗口最小化事件：主窗口最小化时，设置窗口也隐藏
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willMiniaturizeNotification,
                    object: main,
                    queue: .main
                ) { _ in
                    window.orderOut(nil)
                }
                
                // 监听主窗口取消最小化事件：主窗口恢复时，设置窗口也恢复
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: main,
                    queue: .main
                ) { _ in
                    window.orderFront(nil)
                }
            }
            
            // 设置窗口失去焦点时自动关闭（点击外部即关闭，类似下拉菜单）
            // 用通知监听，不覆盖 SwiftUI 原有的 window delegate
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { _ in
                // 延迟一下，避免点击设置按钮 toggle 时立即关闭
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    window.close()
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: FloatingWindowConfiguratorView, context: Context) {}
}

struct SettingsView: View {
    @ObservedObject private var library = AudioLibrary.shared
    @AppStorage("nightMode") private var nightMode = true
    @AppStorage("energySaving") private var energySaving = false
    @AppStorage("dynamicCoverEnabled") private var dynamicCoverEnabled = true
    @AppStorage("cover3DEnabled") private var cover3DEnabled = false
    @AppStorage("fullScreenCoverMode") private var fullScreenCoverMode = false
    @AppStorage("settingsWindowOpen") private var settingsWindowOpen = false
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hoveringClose = false
    @State private var hoverReady = false
            private var theme: AppTheme { nightMode ? .night : .day }

    var body: some View {
        VStack(spacing: 18) {
            // 行 1：节能模式（文字左、开关右）
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("节能模式")
                        .foregroundStyle(theme.primaryText)
                    Text("关闭背景专辑封面旋转")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $energySaving)
                    .toggleStyle(.switch)
                    .tint(.blue)
                    .accentColor(.blue)
                    .help("节能模式")
                    .onChange(of: energySaving) { _, newValue in
                        if newValue { cover3DEnabled = false }  // 节能开启时自动关闭 3D 封面
                    }
            }

            // 行 2：动态封面
            HStack(spacing: 12) {
                Text("动态封面")
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 12)
                Toggle("", isOn: $dynamicCoverEnabled)
                    .toggleStyle(.switch)
                    .tint(.blue)
                    .accentColor(.blue)
                    .help("动态封面")
                    .onChange(of: dynamicCoverEnabled) { _, newValue in
                        if newValue { cover3DEnabled = false }
                    }
            }

            // 行 3：3D 封面
            HStack(spacing: 12) {
                Text("3D 封面")
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 12)
                Toggle("", isOn: $cover3DEnabled)
                    .toggleStyle(.switch)
                    .tint(.blue)
                    .accentColor(.blue)
                    .help("3D 封面")
                    .onChange(of: cover3DEnabled) { _, newValue in
                        if newValue { dynamicCoverEnabled = false }
                    }
            }

            // 行 4：全屏封面
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("全屏封面")
                        .foregroundStyle(theme.primaryText)
                    Text("专辑图铺满播放页，右侧歌词加遮罩")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $fullScreenCoverMode)
                    .toggleStyle(.switch)
                    .tint(.blue)
                    .accentColor(.blue)
                    .help("全屏封面")
            }
        }
        .padding(20)
        .frame(width: 300)
        .glassEffect(theme.glass, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topTrailing) {
            closeButton
        }
        .padding(8)
        .background(SettingsWindowConfigurator())
    }

    // 关闭按钮：与悬浮窗一致（红点 + x，鼠标靠近出现、远离消失）
    private var closeButton: some View {
        Button {
            dismissWindow(id: "settings")
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
        .background(HoverDetector { hoveringClose = hoverReady && $0 })
        .animation(.easeInOut(duration: 0.15), value: hoveringClose)
        .padding(3)
        .help("关闭设置")
        // 挂载 0.5s 后才启用 hover 检测（避免窗口出现瞬间误触发鼠标进入导致闪现）
        .onAppear {
            settingsWindowOpen = true
            hoverReady = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                hoverReady = true
            }
        }
        .onDisappear {
            settingsWindowOpen = false
        }
    }
}

// MARK: - 侧边栏

struct Sidebar: View {
    @Binding var selected: String
    @ObservedObject var library: AudioLibrary
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }
    @State private var playlistsExpanded = false
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("音乐资料库")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ForEach(sidebarItems, id: \.name) { item in
                if item.name == "播放列表" {
                    playlistItem(item)
                    if playlistsExpanded {
                        playlistSubItems
                    }
                } else {
                    Button {
                        selected = item.name
                        library.activeSidebar = item.name
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .frame(width: 20)
                            Text(item.name)
                            Spacer()
                        }
                        .font(.body)
                        .foregroundStyle(selected == item.name ? theme.primaryText : theme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background {
                            if selected == item.name {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(theme.selectionFill)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("存储设备")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(theme.primaryText)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Macintosh HD")
                            .font(.footnote)
                            .foregroundStyle(theme.primaryText)
                        Text("1.2 TB · 无损音乐库")
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                }
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.fieldFill)
                }
            }
            .padding(14)
        }
        .frame(width: 210)
        .glassEffect(theme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .alert("新建播放列表", isPresented: $showNewPlaylistAlert) {
            TextField("播放列表名称", text: $newPlaylistName)
            Button("创建") {
                library.createPlaylist(name: newPlaylistName)
                newPlaylistName = ""
            }
            Button("取消", role: .cancel) { newPlaylistName = "" }
        }
    }

    private func playlistItem(_ item: (name: String, icon: String)) -> some View {
        Button {
            selected = item.name
            library.activeSidebar = item.name
            withAnimation { playlistsExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .frame(width: 20)
                Text(item.name)
                Spacer()
                Image(systemName: playlistsExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .font(.body)
        .foregroundStyle(selected == item.name ? theme.primaryText : theme.secondaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            if selected == item.name {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.selectionFill)
            }
        }
        .buttonStyle(.plain)
    }

    private var playlistSubItems: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(library.playlists) { playlist in
                Button {
                    library.selectedPlaylist = playlist
                    selected = "播放列表"
                    library.activeSidebar = "播放列表"
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .frame(width: 20)
                        Text(playlist.name)
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.body)
                    .foregroundStyle(library.selectedPlaylist?.id == playlist.id ? theme.primaryText : theme.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background {
                        if library.selectedPlaylist?.id == playlist.id {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.selectionFill)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Button {
                showNewPlaylistAlert = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .frame(width: 20)
                    Text("新建播放列表")
                    Spacer()
                }
                .font(.body)
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 7)
                .padding(.leading, 12)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 主内容区

struct MainArea: View {
    @ObservedObject var library: AudioLibrary
    let selectedSection: String
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }

    var body: some View {
        Group {
            switch selectedSection {
            case "歌曲":
                SongListView(library: library)
            case "最近播放":
                RecentListView(library: library)
            case "艺术家":
                ArtistListView(library: library)
            case "收藏":
                FavoritesView(library: library)
            case "播放列表":
                PlaylistView(library: library)
            default:
                ZStack {
                    if library.albums.isEmpty {
                        EmptyLibraryView(library: library)
                    } else {
                        // 网格永远留在底层，仅透明度切换 → 滚动位置自然保留
                        AlbumGridView(library: library)
                            .opacity(library.selectedAlbum == nil ? 1 : 0)
                            .allowsHitTesting(library.selectedAlbum == nil)
                    }
                    // 详情页透明，露出主区域玻璃背景，视觉与列表一致
                    if let album = library.selectedAlbum {
                        AlbumDetailView(album: album, library: library)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(theme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - 空状态

struct EmptyLibraryView: View {
    @ObservedObject var library: AudioLibrary
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(theme.secondaryText)
            Text("曲库还是空的")
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Text("扫描电脑或外接存储里的无损音乐\n当前支持 FLAC / ALAC / WAV / AIFF / MP3 / AAC")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.secondaryText)
            // 系统自带液态玻璃效果按钮（自定义手势避开 ButtonGesture 崩溃路径）
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                Text("扫描音乐")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .glassEffect(in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                library.chooseFolder()
            }
            .help("扫描音乐")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 专辑网格

struct AlbumGridView: View {
    @ObservedObject var library: AudioLibrary
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }
    @State private var position = ScrollPosition(idType: AlbumGroup.ID.self)

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("专辑")
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(theme.primaryText)
                        Text("\(library.albums.count) 张专辑 · \(library.tracks.count) 首歌曲")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                }

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(library.albums) { album in
                        AlbumCard(album: album, onPlay: {
                            library.playAlbum(album)
                        })
                        .contentShape(Rectangle())
                        .onTapGesture {
                            library.selectedAlbum = album
                        }
                        .contextMenu {
                            Button {
                                library.chooseCustomArtwork(for: album.id)
                            } label: {
                                Label("更换封面…", systemImage: "photo")
                            }
                            Button {
                                Task { await library.downloadLyrics(for: album) }
                            } label: {
                                if library.lyricsDownloading && library.lyricsDownloadAlbumID == album.id {
                                    Label("正在添加歌词…", systemImage: "arrow.down.circle")
                                } else {
                                    Label("添加歌词…", systemImage: "text.quote")
                                }
                            }
                            .disabled(library.lyricsDownloading)
                        }
                    }
                }
            }
            .padding(18)
            .scrollTargetLayout()
        }
        .background(ScrollbarStyler())
        .scrollPosition($position)
        .onChange(of: position.viewID(type: AlbumGroup.ID.self)) { _, newID in
            if let newID {
                ScrollPositionStore.shared.albumGridVisibleID = newID
            }
        }
        .onAppear {
            if let id = ScrollPositionStore.shared.albumGridVisibleID {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    position.scrollTo(id: id, anchor: .top)
                }
            }
        }
    }
}

// MARK: - 专辑卡片

struct AlbumCard: View {
    let album: AlbumGroup
    var onPlay: () -> Void = {}
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverArtwork(artwork: album.artworkThumbnail, fallbackName: album.name, size: 44)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Button(action: onPlay) {
                        Image(systemName: "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text("\(album.artist) · \(album.tracks.count) 首")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - 封面（真实图或渐变占位）

struct CoverArtwork: View {
    let artwork: NSImage?
    let fallbackName: String
    let size: CGFloat

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: gradientFor(fallbackName),
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
    }
}

func gradientFor(_ name: String) -> [Color] {
    let palettes: [[Color]] = [
        [.indigo, .purple], [.pink, .orange], [.teal, .cyan],
        [.blue, .mint], [.orange, .red], [.yellow, .orange],
        [.cyan, .blue], [.red, .brown]
    ]
    let h = abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palettes.count
    return palettes[h]
}

// MARK: - 动态封面（cover.mp4 视频播放）

/// Hero 封面动画修饰符：固定 578 尺寸 + scaleEffect 缩放（对 NSViewRepresentable
/// 视频层，frame 尺寸动画会跳变，scaleEffect 是纯图层变换，平滑且开/关对称）。
/// 视觉圆角随进度 10 → 22 线性渐变（与 frame 动画版一致），corner 做缩放补偿：
/// corner × scale = visualCorner，clip 跟随缩放，无跳变、无切角。
struct HeroCover: Animatable, ViewModifier {
    var progress: CGFloat  // 0 = 播放栏小封面形态，1 = 全屏大封面
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let scale = (54.0 / 578.0) + (1.0 - 54.0 / 578.0) * progress
        let visualCorner = 10.0 + (22.0 - 10.0) * progress  // 视觉圆角：10 → 22
        let corner = visualCorner / scale  // 缩放补偿：缩放后视觉圆角恒 = visualCorner
        return content
            .frame(width: 578, height: 578)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .scaleEffect(scale)
    }
}

/// 共享播放器：小封面与大封面共用一个 AVPlayer，保证进度同步、
/// 开/关大封面 Hero 动画画面一致（各视图只挂自己的 AVPlayerLayer）。
final class DynamicCoverManager {
    static let shared = DynamicCoverManager()
    private var player: AVPlayer?
    private var currentURL: URL?
    private var endObserver: NSObjectProtocol?
    private var refCount = 0

    /// 视图挂接时调用（小封面/大封面各挂一次）；无人使用时自动暂停省电
    func attach() {
        refCount += 1
    }

    func detach() {
        refCount -= 1
        if refCount <= 0 {
            refCount = 0
            player?.pause()
        }
    }

    /// 返回播放给定动态封面的共享 AVPlayer（同一 URL 复用，换 URL 换片）
    func player(for url: URL) -> AVPlayer? {
        if url != currentURL {
            currentURL = url
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            let p = AVPlayer()
            p.isMuted = true
            p.volume = 0
            p.actionAtItemEnd = .none
            let item = AVPlayerItem(url: url)
            p.replaceCurrentItem(with: item)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                guard let self, let p = self.player else { return }
                p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                p.play()
            }
            player = p
            p.play()
        }
        if player?.timeControlStatus != .playing, refCount > 0 {
            player?.play()
        }
        return player
    }
}

/// 播放文件夹里的动态封面视频：静音、循环、裁剪填充，随曲目切换自动换片。
struct DynamicCoverView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> VideoPlayerNSView {
        VideoPlayerNSView(url: url)
    }

    func updateNSView(_ nsView: VideoPlayerNSView, context: Context) {
        nsView.setURL(url)
    }
}

final class VideoPlayerNSView: NSView {
    private var playerLayer: AVPlayerLayer?
    private var currentURL: URL?

    init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        DynamicCoverManager.shared.attach()
        let layer = AVPlayerLayer(player: DynamicCoverManager.shared.player(for: url))
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        self.layer?.addSublayer(layer)
        playerLayer = layer
        currentURL = url
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setURL(_ url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        playerLayer?.player = DynamicCoverManager.shared.player(for: url)
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }

    deinit {
        DynamicCoverManager.shared.detach()
        playerLayer?.removeFromSuperlayer()
    }
}

// MARK: - 专辑详情（曲目列表）

struct AlbumDetailView: View {
    let album: AlbumGroup
    @ObservedObject var library: AudioLibrary
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Button {
                        library.selectedAlbum = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)

                    CoverArtwork(artwork: album.artworkThumbnail, fallbackName: album.name, size: 60)
                        .frame(width: 90, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.name)
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(theme.primaryText)
                        Text("\(album.artist) · \(album.tracks.count) 首")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                }

                LazyVStack(spacing: 6) {
                    ForEach(album.tracks) { track in
                        TrackRow(track: track, library: library)
                    }
                }
            }
            .padding(18)
        }
        .background(ScrollbarStyler())
    }
}

// MARK: - 曲目行（复用）

struct TrackRow: View {
    let track: AudioTrack
    @ObservedObject var library: AudioLibrary
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                library.playTrack(track)
            } label: {
                HStack(spacing: 12) {
                    if let art = track.artworkThumbnail {
                        Image(nsImage: art)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: library.currentTrack?.id == track.id
                              ? "speaker.wave.2.fill" : "music.note")
                            .foregroundStyle(library.currentTrack?.id == track.id
                                             ? theme.primaryText : theme.secondaryText)
                            .frame(width: 40, height: 40)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.body)
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(library.formatTime(track.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                library.toggleFavorite(track)
            } label: {
                Image(systemName: library.isFavorite(track) ? "heart.fill" : "heart")
                    .foregroundStyle(library.isFavorite(track) ? .red : theme.secondaryText)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            if library.currentTrack?.id == track.id {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.selectionFill)
            }
        }
        .contextMenu {
            if !library.playlists.isEmpty {
                Menu("加入播放列表") {
                    ForEach(library.playlists) { playlist in
                        Button(playlist.name) {
                            library.addToPlaylist(track, playlist)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 播放列表曲目行

struct PlaylistTrackRow: View {
    let track: AudioTrack
    let playlist: Playlist
    @ObservedObject var library: AudioLibrary
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                library.playTrack(track)
            } label: {
                HStack(spacing: 12) {
                    if let art = track.artworkThumbnail {
                        Image(nsImage: art)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: library.currentTrack?.id == track.id
                              ? "speaker.wave.2.fill" : "music.note")
                            .foregroundStyle(library.currentTrack?.id == track.id
                                             ? theme.primaryText : theme.secondaryText)
                            .frame(width: 40, height: 40)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.body)
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(library.formatTime(track.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                library.removeFromPlaylist(track, playlist)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            if library.currentTrack?.id == track.id {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.selectionFill)
            }
        }
    }
}

// MARK: - 歌曲列表

struct SongListView: View {
    @ObservedObject var library: AudioLibrary
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }
    @State private var searchText = ""
    @State private var position = ScrollPosition(idType: AudioTrack.ID.self)

    private var filteredTracks: [AudioTrack] {
        guard !searchText.isEmpty else { return library.tracks }
        return library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText) ||
            $0.album.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("歌曲")
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(theme.primaryText)
                        Text("\(library.tracks.count) 首歌曲")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(theme.secondaryText)
                        TextField("搜索歌曲", text: $searchText)
                            .textFieldStyle(.plain)
                            .foregroundStyle(theme.primaryText)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 220, height: 34)
                    .glassEffect(in: Capsule())
                }

                if filteredTracks.isEmpty {
                    Text(searchText.isEmpty ? "曲库为空，点击右上角「扫描音乐」导入" : "没有匹配的歌曲")
                        .foregroundStyle(theme.secondaryText)
                        .padding(.top, 20)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredTracks) { track in
                            TrackRow(track: track, library: library)
                        }
                    }
                }
            }
            .padding(18)
            .scrollTargetLayout()
        }
        .background(ScrollbarStyler())
        .scrollPosition($position)
        .onChange(of: position.viewID(type: AudioTrack.ID.self)) { _, newID in
            if searchText.isEmpty, let newID {
                ScrollPositionStore.shared.songListVisibleID = newID
            }
        }
        .onAppear {
            if let id = ScrollPositionStore.shared.songListVisibleID {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    position.scrollTo(id: id, anchor: .top)
                }
            }
        }
    }
}

// MARK: - 最近播放

struct RecentListView: View {
    @ObservedObject var library: AudioLibrary
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("最近播放")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(theme.primaryText)
                Text("\(library.recentTracks.count) 首")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)

                if library.recentTracks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock")
                            .font(.system(size: 40))
                            .foregroundStyle(theme.tertiaryText)
                        Text("还没有播放记录")
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(library.recentTracks) { track in
                            TrackRow(track: track, library: library)
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(ScrollbarStyler())
    }
}

// MARK: - 艺术家列表

struct ArtistListView: View {
    @ObservedObject var library: AudioLibrary
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }
    @State private var selectedArtist: String?

    private var artistNames: [String] {
        Set(library.tracks.map { $0.artist })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var selectedTracks: [AudioTrack] {
        guard let artist = selectedArtist else { return [] }
        return library.tracks.filter { $0.artist == artist }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let artist = selectedArtist {
                    HStack(spacing: 12) {
                        Button {
                            selectedArtist = nil
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(artist)
                                .font(.largeTitle.weight(.bold))
                                .foregroundStyle(theme.primaryText)
                            Text("\(selectedTracks.count) 首歌曲")
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                    }

                    LazyVStack(spacing: 6) {
                        ForEach(selectedTracks) { track in
                            TrackRow(track: track, library: library)
                        }
                    }
                } else {
                    Text("艺术家")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(theme.primaryText)
                    Text("\(artistNames.count) 位艺术家")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)

                    LazyVStack(spacing: 6) {
                        ForEach(artistNames, id: \.self) { artist in
                            Button {
                                selectedArtist = artist
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(theme.primaryText)
                                    Text(artist)
                                        .font(.body)
                                        .foregroundStyle(theme.primaryText)
                                    Spacer()
                                    Text("\(library.tracks.filter { $0.artist == artist }.count) 首")
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryText)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(theme.fieldFill)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(ScrollbarStyler())
    }
}

// MARK: - 收藏

struct FavoritesView: View {
    @ObservedObject var library: AudioLibrary
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("收藏")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(theme.primaryText)
                Text("\(library.favoriteTracks.count) 首歌曲")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)

                if library.favoriteTracks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "heart")
                            .font(.system(size: 40))
                            .foregroundStyle(theme.tertiaryText)
                        Text("还没有收藏的歌曲\n在歌曲列表点击右侧的心形图标收藏")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(library.favoriteTracks) { track in
                            TrackRow(track: track, library: library)
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(ScrollbarStyler())
    }
}

// MARK: - 播放列表视图

struct PlaylistView: View {
    @ObservedObject var library: AudioLibrary
    @AppStorage("nightMode") private var nightMode = true
            private var theme: AppTheme { nightMode ? .night : .day }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let playlist = library.selectedPlaylist {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 36))
                            .foregroundStyle(theme.primaryText)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.name)
                                .font(.largeTitle.weight(.bold))
                                .foregroundStyle(theme.primaryText)
                            Text("\(library.tracks(in: playlist).count) 首歌曲")
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                        Button {
                            library.deletePlaylist(playlist)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }

                    let playlistTracks = library.tracks(in: playlist)
                    if playlistTracks.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40))
                                .foregroundStyle(theme.tertiaryText)
                            Text("播放列表是空的\n在歌曲列表右键歌曲加入播放列表")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(playlistTracks) { track in
                                PlaylistTrackRow(track: track, playlist: playlist, library: library)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundStyle(theme.tertiaryText)
                        Text("选择或新建一个播放列表")
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding(18)
        }
    }
}

// MARK: - 正在播放栏

struct NowPlayingBar: View {
    @ObservedObject var library: AudioLibrary
    var coverNamespace: Namespace.ID
    @Binding var showFullCover: Bool
    @Binding var coverVisible: Bool
    @AppStorage("nightMode") private var nightMode = true
    @AppStorage("dynamicCoverEnabled") private var dynamicCoverEnabled = true
            private var theme: AppTheme { nightMode ? .night : .day }
    @State private var seekPosition: Double = 0
    @State private var isDragging = false
    @State private var isVolumeDragging = false

    var body: some View {
        HStack(spacing: 0) {
            // 左栏：封面 + 歌曲信息
            HStack(spacing: 14) {
                Group {
                    if dynamicCoverEnabled, let dyn = library.currentTrack?.dynamicCoverURL {
                        DynamicCoverView(url: dyn)
                    } else {
                        CoverArtwork(artwork: library.currentTrack?.artworkThumbnail,
                                     fallbackName: library.currentTrack?.title ?? "music",
                                     size: 28)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .opacity(coverVisible ? 0 : 1)  // 大封面激活期间隐藏小封面（关闭动画结束后再现）
                    .animation(nil, value: coverVisible)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear {
                                CoverFrameStore.shared.smallCoverFrame = g.frame(in: .global)
                            }
                            .onChange(of: g.frame(in: .global)) { newFrame in
                                CoverFrameStore.shared.smallCoverFrame = newFrame
                            }
                    })
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: coverAnimationDuration)) {
                            showFullCover = true
                        }
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(library.currentTrack?.title ?? "未在播放")
                        .font(.headline)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .id(library.currentTrack?.id)  // 切歌时强制重建（防御 UI 不刷新）
                    HStack(spacing: 6) {
                        Text(library.currentTrack.map { "\($0.artist) — \($0.album)" } ?? "选择一首歌曲开始播放")
                            .lineLimit(1)
                        if let sr = library.currentTrack?.sampleRateText {
                            Text("· \(sr)")
                                .foregroundStyle(theme.tertiaryText)
                        }
                        if let bd = library.currentTrack?.bitDepthText {
                            Text("· \(bd)")
                                .foregroundStyle(theme.tertiaryText)
                        }
                        if let br = library.liveBitrate, br > 0 {
                            Text("· \(br) kbps")
                                .foregroundStyle(theme.tertiaryText)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .id(library.currentTrack?.id)  // 切歌时强制重建
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 中栏：播放控制（固定中央，圆形液态玻璃）
            HStack(spacing: 24) {
                Button { library.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 48, height: 48)
                        .glassEffect(.clear, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(library.tracks.isEmpty)

                Button { library.togglePlay() } label: {
                    Image(systemName: library.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title.weight(.bold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 62, height: 62)
                        .glassEffect(.clear, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(library.currentTrack == nil)

                Button { library.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 48, height: 48)
                        .glassEffect(.clear, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(library.tracks.isEmpty)
            }
            .frame(width: 215)

            // 右栏：进度（可拖动） + 音量
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    Text(library.formatTime(library.currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                    VStack(spacing: 3) {
                        if isDragging {
                            Text(library.formatTime(seekPosition))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .glassEffect(in: Capsule())
                                .transition(.opacity)
                        }
                        Slider(value: $seekPosition, in: 0...max(1, duration), onEditingChanged: { editing in
                            isDragging = editing
                            if !editing {
                                library.seek(to: seekPosition)
                            }
                        })
                        .frame(width: 140)
                        .tint(Color(white: 0.75))
                    }
                    .animation(.easeInOut(duration: 0.15), value: isDragging)
                    Text(library.formatTime(library.currentTrack?.duration ?? 0))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }

                HStack(spacing: 8) {
                    Image(systemName: library.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(theme.secondaryText)
                    VStack(spacing: 3) {
                        if isVolumeDragging {
                            Text("\(Int(library.volume * 100))%")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .glassEffect(in: Capsule())
                                .transition(.opacity)
                        }
                        Slider(value: $library.volume, in: 0...1, onEditingChanged: { editing in
                            isVolumeDragging = editing
                        })
                        .frame(width: 80)
                        .tint(Color(white: 0.75))
                    }
                    .animation(.easeInOut(duration: 0.15), value: isVolumeDragging)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: library.currentTime) { t in
                if !isDragging {
                    seekPosition = t
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(theme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var duration: Double {
        library.currentTrack?.duration ?? 0
    }
}
