import Foundation
import AppKit

// MARK: - 深度推理引擎（C 桥接层封装）

/// 用 Depth Anything V2 Small（int8 ONNX）从封面图生成深度图。
/// 深度图缓存到专辑文件夹 cover3d_depth.png，下次直接读取。
final class DepthEngine {
    static let shared = DepthEngine()

    private var ctx: UnsafeMutableRawPointer?
    private var loaded = false
    private var loadLock = NSLock()

    let inputSize = 518

    private init() {}

    /// 模型路径（app bundle Resources）
    private var modelPath: String {
        Bundle.main.path(forResource: "cover3d_model", ofType: "onnx") ?? ""
    }

    // MARK: - 会话管理

    func ensureLoaded() -> Bool {
        if loaded { return true }
        loadLock.lock()
        defer { loadLock.unlock() }
        if loaded { return true }
        let path = modelPath
        guard !path.isEmpty else { return false }
        var out: UnsafeMutableRawPointer?
        let rc = path.withCString { depth_create($0, &out) }
        guard rc == 0, let out else { return false }
        ctx = out
        loaded = true
        return true
    }

    // MARK: - 深度图缓存（专辑文件夹）

    /// 缓存路径：专辑文件夹/cover3d_depth.png（v2：基于文件夹封面，与原型同源）
    func cachedDepthURL(forAlbumFolder folder: URL) -> URL {
        folder.appendingPathComponent("cover3d_depth_v2.png")
    }

    /// 读缓存深度图（存在且有效则返回）
    func loadCachedDepth(forAlbumFolder folder: URL) -> CGImage? {
        let url = cachedDepthURL(forAlbumFolder: folder)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let img = NSImage(data: data),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return cg
    }

    /// 写深度图缓存
    func saveDepthCache(_ cgImage: CGImage, forAlbumFolder folder: URL) {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: cachedDepthURL(forAlbumFolder: folder))
    }

    // MARK: - 推理

    /// 从封面生成深度图（灰度，近=亮）。失败返回 nil。
    func depthImage(from cover: CGImage) -> CGImage? {
        guard ensureLoaded(), let ctx else { return nil }
        let size = inputSize
        let count = size * size * 3

        // 1. 缩放封面到 518×518 RGB
        guard let resized = Self.resizeRGB(cover, to: size) else { return nil }

        // 2. 像素 → float32 + ImageNet 归一化（显式 .RGBA8 渲染读取，无字节序/翻转歧义）
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        let ci = CIImage(cgImage: resized)
        let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
        ciCtx.render(ci, toBitmap: &buf, rowBytes: size * 4,
                     bounds: CGRect(x: 0, y: 0, width: size, height: size),
                     format: CIFormat.RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var pixels = [Float](repeating: 0, count: count)
        let mean: [Float] = [0.485, 0.456, 0.406]
        let std: [Float] = [0.229, 0.224, 0.225]
        for y in 0..<size {
            for x in 0..<size {
                let o = y * size * 4 + x * 4
                let r = Float(buf[o]) / 255.0
                let g = Float(buf[o + 1]) / 255.0
                let b = Float(buf[o + 2]) / 255.0
                // NCHW 布局（ONNX 模型要求 channel 在最外层；HWC 会导致深度完全错乱）
                pixels[0 * size * size + y * size + x] = (r - mean[0]) / std[0]
                pixels[1 * size * size + y * size + x] = (g - mean[1]) / std[1]
                pixels[2 * size * size + y * size + x] = (b - mean[2]) / std[2]
            }
        }

        // 3. 推理
        var depth = [Float](repeating: 0, count: size * size)
        let rc = pixels.withUnsafeBytes { inBuf in
            depth.withUnsafeMutableBytes { outBuf in
                depth_run(ctx, inBuf.baseAddress?.assumingMemoryBound(to: Float.self),
                          Int32(size), outBuf.baseAddress?.assumingMemoryBound(to: Float.self))
            }
        }
        guard rc == 0 else { return nil }

        // 4. 归一化 + 灰度图
        var dmin = Float.greatestFiniteMagnitude
        var dmax = -Float.greatestFiniteMagnitude
        for v in depth {
            if v < dmin { dmin = v }
            if v > dmax { dmax = v }
        }
        let range = max(dmax - dmin, 1e-6)
        var gray = [UInt8](repeating: 0, count: size * size)
        for i in 0..<gray.count {
            gray[i] = UInt8(clamping: Int(((depth[i] - dmin) / range) * 255))
        }
        guard let grayData = CFDataCreate(nil, gray, gray.count),
              let provider2 = CGDataProvider(data: grayData) else { return nil }
        return CGImage(width: size, height: size,
                       bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: size,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider2,
                       decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// 缩放 CGImage 到 size×size RGB（用 CIImage 变换，无 CGContext 坐标翻转问题）
    private static func resizeRGB(_ image: CGImage, to size: Int) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let w = ci.extent.width, h = ci.extent.height
        guard w > 0, h > 0 else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(size) / w,
                                                          y: CGFloat(size) / h))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: size, height: size))
    }
}
