import SwiftUI
import AppKit
import CoreImage

// MARK: - 全局鼠标位置（3D 封面视差驱动，全屏范围）

final class ParallaxStore: ObservableObject {
    static let shared = ParallaxStore()
    @Published var mousePosition: CGPoint = .zero  // 归一化 -1..1（屏幕中心为 0，y 向上）
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private init() {
        // 本地 monitor：app 激活时能收到全屏任意位置的 mouseMoved（频率高、跟手）
        // 全局 monitor 的 mouseMoved 事件频率极低，会导致位移滞后
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateFromScreenMouse()
            return event
        }
    }

    private func updateFromScreenMouse() {
        let loc = NSEvent.mouseLocation  // 全局屏幕坐标（左下原点）
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        // 灵敏度：分母 /2.5 让鼠标移动更敏感（接近原型窗口映射手感）
        let nx = ((loc.x - f.midX) / (f.width / 2.5)).clamped(-1, 1)
        let ny = ((loc.y - f.midY) / (f.height / 2.5)).clamped(-1, 1)
        // 指数平滑（高频事件下轻平滑，跟手）
        mousePosition = CGPoint(x: mousePosition.x + (nx - mousePosition.x) * 0.5,
                                y: mousePosition.y + (ny - mousePosition.y) * 0.5)
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, lo), hi)
    }
}

// MARK: - 3D 封面入口（深度图缓存 → 推理 → 视差渲染）

/// 负责深度图的获取：专辑文件夹缓存优先，无则推理生成并缓存。
/// 深度图就绪前显示原封面。
struct ParallaxCover3DView: View {
    let cover: NSImage
    let albumFolder: URL?
    @State private var depth: CGImage?

    var body: some View {
        Group {
            if let depth {
                ParallaxCoverView(cover: effectiveCover, depth: depth)
            } else {
                Image(nsImage: effectiveCover)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task {
            guard depth == nil, let folder = albumFolder else {
                return
            }
            // 1. 缓存优先
            if let cached = DepthEngine.shared.loadCachedDepth(forAlbumFolder: folder) {
                depth = cached
                return
            }
            // 2. 推理生成（后台线程，不阻塞 UI）——用文件夹封面（与原型同源）
            guard let cg = effectiveCover.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return
            }
            let d = await Task.detached(priority: .userInitiated) {
                DepthEngine.shared.depthImage(from: cg)
            }.value
            guard let d else {
                return
            }
            depth = d
            DepthEngine.shared.saveDepthCache(d, forAlbumFolder: folder)
        }
    }

    /// 显示/推理用图：优先文件夹封面（cover.jpg 等，与 Python 原型同源），无则用内嵌 artwork
    private var effectiveCover: NSImage {
        if let folder = albumFolder, let path = AudioLibrary.findFolderArtworkPath(in: folder) {
            return ArtworkCache.shared.image(forPath: path) ?? cover
        }
        return cover
    }
}

// MARK: - 3D 视差封面视图

/// 封面 + 深度图 → Core Image GPU 视差渲染，鼠标位置（全屏）驱动视角。
struct ParallaxCoverView: View {
    let cover: NSImage
    let depth: CGImage
    @ObservedObject private var store = ParallaxStore.shared
    @State private var rendered: NSImage?
    /// 深度图标准差（自适应强度用：层次平的封面自动加强位移）
    @State private var depthStd: Float = 0.18
    // CIContext 缓存：每帧创建会初始化 GPU 上下文（卡顿元凶）
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(cover: NSImage, depth: CGImage) {
        self.cover = cover
        self.depth = depth
        _depthStd = State(initialValue: Self.computeDepthStd(depth))
    }

    /// 自适应强度：目标 std 0.18（层次丰富的封面），平缓封面放大 0.6~2.5 倍
    private var strengthScale: CGFloat {
        guard depthStd > 0.02 else { return 1.0 }
        return CGFloat(min(max(0.18 / depthStd, 0.6), 2.5))
    }

    /// 计算灰度深度图标准差（stride 采样，快）
    private static func computeDepthStd(_ depth: CGImage) -> Float {
        guard let provider = depth.dataProvider, let data = provider.data as Data? else { return 0.18 }
        let raw = [UInt8](data)
        var sum: Float = 0
        var sumSq: Float = 0
        var n: Float = 0
        var i = 0
        while i < raw.count {
            let v = Float(raw[i]) / 255.0
            sum += v
            sumSq += v * v
            n += 1
            i += 4
        }
        guard n > 0 else { return 0.18 }
        let mean = sum / n
        let variance = max(sumSq / n - mean * mean, 0)
        return sqrt(variance)
    }

    private let kernel = CIKernel(source: """
        kernel vec4 parallaxKernel(sampler image, sampler depth, vec2 mouse) {
            vec2 uv = samplerCoord(image);
            vec2 imgSize = samplerSize(image);
            float d = sample(depth, uv).x;
            float dc = (d - 0.5) * 2.0;
            vec2 offset = vec2(dc) * mouse * 0.033 * imgSize;
            return sample(image, uv + offset);
        }
    """)

    var body: some View {
        Group {
            if let rendered {
                Image(nsImage: rendered)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(nsImage: cover)
                    .resizable()
                    .scaledToFill()
            }
        }
        .onChange(of: store.mousePosition) { _ in
            render()
        }
        .onAppear { render() }
    }

    private func render() {
        guard let kernel, let coverCG = cover.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        // 低分辨率渲染（解决卡顿）：封面裁成 1:1 方形，最长边缩到 768
        let maxDim: CGFloat = 768
        let cw = CGFloat(coverCG.width), ch = CGFloat(coverCG.height)
        let side = min(cw, ch)
        let cropRect = CGRect(x: (cw - side) / 2, y: (ch - side) / 2, width: side, height: side)
        let scale = maxDim / side
        // 先裁方再缩放，并把 extent 归零（避免 createCGImage 输出偏移）
        let ci = CIImage(cgImage: coverCG)
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // 深度图缩到同尺寸（kernel 内同坐标采样）
        let depthRaw = CIImage(cgImage: depth)
        let depthCI = depthRaw.transformed(by: CGAffineTransform(scaleX: maxDim / depthRaw.extent.width,
                                                                y: maxDim / depthRaw.extent.height))
        // 屏幕坐标 y 向上，CI 坐标 y 向下：取反；并乘自适应强度（层次平的封面放大位移）
        let mouseScale = strengthScale
        let mouse = CIVector(x: store.mousePosition.x * mouseScale, y: -store.mousePosition.y * mouseScale)
        guard let out = kernel.apply(extent: ci.extent,
                                     roiCallback: { _, rect in rect },
                                     arguments: [ci, depthCI, mouse]) else {
            return
        }
        let ctx = Self.ciContext
        guard let cg = ctx.createCGImage(out, from: ci.extent) else {
            return
        }
        rendered = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
