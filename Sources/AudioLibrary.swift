import Foundation
import AVFoundation
import CoreMedia
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AudioToolbox
import CoreGraphics

// MARK: - 封面降采样工具

/// 将大图降采样到 maxDimension 以内，大幅降低内存占用
/// 4096x4096 → 512x512，内存占用从 64MB 降到 4MB
func downsampleImage(_ image: NSImage, maxDimension: CGFloat = 512) -> NSImage {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return image
    }
    let width = CGFloat(cgImage.width)
    let height = CGFloat(cgImage.height)
    let maxSide = max(width, height)
    guard maxSide > maxDimension else { return image }
    
    let scale = maxDimension / maxSide
    let newWidth = Int(width * scale)
    let newHeight = Int(height * scale)
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: newWidth,
        height: newHeight,
        bitsPerComponent: 8,
        bytesPerRow: newWidth * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return image }
    
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
    
    guard let resizedCG = context.makeImage() else { return image }
    return NSImage(cgImage: resizedCG, size: NSSize(width: newWidth, height: newHeight))
}

// MARK: - 封面缓存（按需加载，自动淘汰）

/// 按 key 缓存已解码的封面图，限制内存占用，自动淘汰最久未使用的
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, NSImage>()
    
    private init() {
        // 最多缓存 100 张封面，约 100MB 上限
        cache.countLimit = 100
        cache.totalCostLimit = 100 * 1024 * 1024
    }
    
    /// 从 Data 解码并缓存（内嵌封面用）
    func image(forKey key: String, data: Data) -> NSImage? {
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard let img = NSImage(data: data) else { return nil }
        // 估算内存占用：宽 × 高 × 4字节(RGBA)
        let cost = Int(img.size.width * img.size.height * 4)
        cache.setObject(img, forKey: key as NSString, cost: cost)
        return img
    }
    
    /// 从文件路径加载并缓存（文件夹封面用）
    func image(forPath path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        let cost = Int(img.size.width * img.size.height * 4)
        cache.setObject(img, forKey: path as NSString, cost: cost)
        return img
    }
    
    /// 获取缩略图（用于列表/小卡片，省内存）
    /// - Parameters:
    ///   - key: 缓存 key
    ///   - data: 原始封面数据
    ///   - maxSize: 缩略图最大边长（点）
    func thumbnail(forKey key: String, data: Data, maxSize: CGFloat = 200) -> NSImage? {
        let thumbKey = "\(key)_thumb_\(Int(maxSize))"
        if let cached = cache.object(forKey: thumbKey as NSString) {
            return cached
        }
        guard let img = NSImage(data: data) else { return nil }
        let resized = downsampleImage(img, maxDimension: maxSize)
        let cost = Int(resized.size.width * resized.size.height * 4)
        cache.setObject(resized, forKey: thumbKey as NSString, cost: cost)
        return resized
    }
    
    /// 获取文件夹封面的缩略图
    func thumbnail(forPath path: String, maxSize: CGFloat = 200) -> NSImage? {
        let thumbKey = "\(path)_thumb_\(Int(maxSize))"
        if let cached = cache.object(forKey: thumbKey as NSString) {
            return cached
        }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        let resized = downsampleImage(img, maxDimension: maxSize)
        let cost = Int(resized.size.width * resized.size.height * 4)
        cache.setObject(resized, forKey: thumbKey as NSString, cost: cost)
        return resized
    }
    
    /// 清除所有缓存
    func clear() {
        cache.removeAllObjects()
    }
}

// MARK: - 数据模型

struct AudioTrack: Identifiable {
    let id: UUID
    let url: URL
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let artworkData: Data?      // 内嵌封面原始数据（JPEG 压缩格式）
    let artworkPath: String?    // 文件夹封面路径（优先于 artworkData）
    let bitrate: Int
    let sampleRate: Double
    let bitDepth: Int
    let startOffset: Double
    let lyrics: [LyricsLine]?
    let dynamicCoverURL: URL?
    let trackNumber: Int?

    /// 按需获取封面图（走缓存，不提前解码）
    var artwork: NSImage? {
        if let path = artworkPath {
            return ArtworkCache.shared.image(forPath: path)
        }
        if let data = artworkData {
            return ArtworkCache.shared.image(forKey: url.path, data: data)
        }
        return nil
    }
    
    /// 缩略图（用于列表/小卡片，省内存）
    var artworkThumbnail: NSImage? {
        if let path = artworkPath {
            return ArtworkCache.shared.thumbnail(forPath: path)
        }
        if let data = artworkData {
            return ArtworkCache.shared.thumbnail(forKey: url.path, data: data)
        }
        return nil
    }

    init(id: UUID = UUID(), url: URL, title: String, artist: String, album: String,
         duration: Double, artworkData: Data? = nil, artworkPath: String? = nil,
         bitrate: Int, sampleRate: Double = 0,
         bitDepth: Int = 0, startOffset: Double = 0, lyrics: [LyricsLine]? = nil,
         dynamicCoverURL: URL? = nil, trackNumber: Int? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkData = artworkData
        self.artworkPath = artworkPath
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.startOffset = startOffset
        self.lyrics = lyrics
        self.dynamicCoverURL = dynamicCoverURL
        self.trackNumber = trackNumber
    }

    /// 采样率显示文本，如 "44.1 kHz"、"96 kHz"
    var sampleRateText: String? {
        guard sampleRate > 0 else { return nil }
        let kHz = sampleRate / 1000.0
        if abs(kHz.rounded() - kHz) < 0.001 {
            return "\(Int(kHz.rounded())) kHz"
        }
        return String(format: "%.1f kHz", kHz)
    }

    /// 位深显示文本，如 "16 bit"、"24 bit"
    var bitDepthText: String? {
        guard bitDepth > 0 else { return nil }
        return "\(bitDepth) bit"
    }
}

struct AlbumGroup: Identifiable {
    let id: UUID
    let name: String
    let artist: String
    let artworkData: Data?      // 内嵌封面原始数据
    let artworkPath: String?    // 文件夹封面路径
    let tracks: [AudioTrack]
    let folderURL: URL?
    let dynamicCoverURL: URL?

    /// 按需获取封面图（走缓存，不提前解码）
    var artwork: NSImage? {
        if let path = artworkPath {
            return ArtworkCache.shared.image(forPath: path)
        }
        if let data = artworkData {
            return ArtworkCache.shared.image(forKey: "album_\(id.uuidString)", data: data)
        }
        // 兜底：从第一首有封面的曲目取
        if let track = tracks.first(where: { $0.artworkData != nil || $0.artworkPath != nil }) {
            return track.artwork
        }
        return nil
    }
    
    /// 缩略图（用于专辑列表，省内存）
    var artworkThumbnail: NSImage? {
        if let path = artworkPath {
            return ArtworkCache.shared.thumbnail(forPath: path)
        }
        if let data = artworkData {
            return ArtworkCache.shared.thumbnail(forKey: "album_\(id.uuidString)", data: data)
        }
        if let track = tracks.first(where: { $0.artworkData != nil || $0.artworkPath != nil }) {
            return track.artworkThumbnail
        }
        return nil
    }

    init(id: UUID = UUID(), name: String, artist: String,
         artworkData: Data? = nil, artworkPath: String? = nil,
         tracks: [AudioTrack], folderURL: URL? = nil, dynamicCoverURL: URL? = nil) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artworkData = artworkData
        self.artworkPath = artworkPath
        self.tracks = tracks
        self.folderURL = folderURL
        self.dynamicCoverURL = dynamicCoverURL
    }
}

// MARK: - 播放列表

struct Playlist: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var trackKeys: [String]
}

// MARK: - 音频库（扫描 + 播放）

@MainActor
final class AudioLibrary: ObservableObject {
    static let shared = AudioLibrary()
    @Published var albums: [AlbumGroup] = []
    @Published var tracks: [AudioTrack] = []
    @Published var currentTrack: AudioTrack?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var isScanning = false
    @Published var statusMessage = ""
    @Published var warnings: [String] = []
    @Published var selectedAlbum: AlbumGroup?
    @Published var liveBitrate: Int?
    @Published var lyricsDownloading = false
    @Published var lyricsDownloadAlbumID: UUID?
    @Published var volume: Double = 0.6 {
        didSet { playerNode.volume = Float(volume) }
    }
    @Published var playQueue: [AudioTrack] = []
    enum PlaybackMode: String { case off, all, one, shuffle }
    @Published var playbackMode: PlaybackMode = {
        if let s = UserDefaults.standard.string(forKey: "playbackMode"),
           let m = PlaybackMode(rawValue: s) { return m }
        return .off
    }() {
        didSet { UserDefaults.standard.set(playbackMode.rawValue, forKey: "playbackMode") }
    }
    @Published var activeSidebar = "歌曲"  // 当前侧边栏上下文（决定上下切歌的队列来源）
    @Published var recentTracks: [AudioTrack] = []
    @Published var favoriteKeys: Set<String> = []
    @Published var playlists: [Playlist] = []
    @Published var selectedPlaylist: Playlist?

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "favoriteTracks") {
            favoriteKeys = Set(saved)
        }
        if let data = UserDefaults.standard.data(forKey: "playlists"),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = decoded
        }
        setupEngine()
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    // MARK: - 播放引擎（AVAudioEngine 直连播放节点 → 主混音器）

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// 引擎配置变化（音频设备切换）通知观察者
    private var configChangeObserver: NSObjectProtocol?
    /// 配置变化处理节流时间戳（同一变化可能连发多个通知）
    private var lastConfigChangeHandled: TimeInterval = 0

    private func setupEngine() {
        // 监听音频输出设备切换（扬声器 ↔ 音箱）：输出格式变化后已调度 buffer 失配，
        // 需从当前进度按新格式重新调度。
        // object 绑定本引擎：AVAudioEngineConfigurationChange 的 object 是 engine，
        // 避免收到系统里其他 app 引擎的配置变化通知（误触发导致播放中断/爆音）。
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleEngineConfigChange()
            }
        }

        engine.attach(playerNode)
        _ = engine.mainMixerNode
        // 第一阶段：无输入源的图先启动，让输出格式按当前设备协商完成
        engine.prepare()
        try? engine.start()
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        // 停止后按设备格式显式连接（format: nil 会锁定旧格式，设备切换后失配）
        engine.stop()
        engine.connect(playerNode, to: engine.mainMixerNode, format: outFormat)
        engine.prepare()
        try? engine.start()
        engineReady = true
        // 若启动瞬间用户已点播放，引擎就绪后自动补播
        if let pending = pendingTrack {
            pendingTrack = nil
            play(pending)
        }
    }

    /// 音频输出设备切换（扬声器 ↔ 音箱）后：playerNode 连接格式仍锁定旧设备采样率，
    /// 需重建连接（按新设备格式显式 connect），再从当前进度重新调度恢复播放。
    @MainActor
    private func handleEngineConfigChange() {
        guard engineReady else { return }
        // 节流：一次设备切换可能连发多个通知，0.5s 内只处理一次
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastConfigChangeHandled < 0.5 { return }
        lastConfigChangeHandled = now

        // 关键：先使旧的播完回调失效——engine/playerNode 停止会触发已调度
        // buffer 的 completion（误判"播完"→ 自动切到下一首），必须抢先更新令牌；
        // 且可能有旧回调先于本函数排队执行，令牌之外用切换标志兜底
        scheduleToken = UUID()
        isDeviceSwitching = true
        defer { isDeviceSwitching = false }

        let track = currentTrack
        let wasPlaying = playerNode.isPlaying
        let resumeTime = currentTime
        let savedVolume = playerNode.volume

        // 停引擎 → 重建播放节点连接（输出格式按新设备重新协商）
        if engine.isRunning { engine.stop() }
        playerNode.stop()
        engine.detach(playerNode)
        engine.attach(playerNode)
        // 第一阶段：无输入源的图先启动，拿新设备输出格式
        engine.prepare()
        do {
            try engine.start()
        } catch {
            warnings = ["音频设备切换失败：\(error.localizedDescription)"]
            return
        }
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        // 停止后按新设备格式显式连接（format: nil 会沿用旧格式 → 播放失配）
        engine.stop()
        engine.connect(playerNode, to: engine.mainMixerNode, format: outFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            warnings = ["音频设备切换失败：\(error.localizedDescription)"]
            return
        }

        guard let track else { return }
        // 从当前进度重新调度（scheduleSegment 用重建后的 playerNode 输出格式）
        do {
            let file = try AVAudioFile(forReading: track.url)
            let sampleRate = file.processingFormat.sampleRate
            let clamped = max(0, min(resumeTime, max(track.duration, 0)))
            playerNode.stop()
            let startFrame = AVAudioFramePosition((track.startOffset + clamped) * sampleRate)
            // 与 seek 一致：frameCount 用分轨剩余帧数（CUE 分轨不越界）
            let remaining = AVAudioFramePosition((track.duration - clamped) * sampleRate)
            let frameCount = AVAudioFramePosition(max(0, min(remaining, file.length - startFrame)))

            let token = UUID()
            scheduleToken = token
            scheduleSegment(file: file, startFrame: startFrame,
                            frameCount: frameCount) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.scheduleToken == token else { return }
                    self.advanceOrStop()
                }
            }
            playerNode.volume = savedVolume
            scheduleStartTime = clamped
            currentTime = clamped
            if wasPlaying {
                playerNode.play()
                isPlaying = true
            }
        } catch {
            warnings = ["设备切换后无法继续播放：\(track.title)"]
        }
    }

    /// 引擎初始化完成标志
    private var engineReady = false
    /// 引擎就绪前用户请求播放的曲目
    private var pendingTrack: AudioTrack?
    /// 设备切换进行中：禁止播完回调切歌（stop/engine 停止会触发 completion，
    /// 且可能有旧回调先于切换处理排队执行——令牌之外的第二道防线）
    private var isDeviceSwitching = false

    private var progressTimer: Timer?
    private var bitrateProfile: [(time: Double, bitrate: Double)] = []
    private var profileTask: Task<Void, Never>?
    /// 当前 schedule 令牌：切歌/seek 时递增，防止旧播完回调误触发
    private var scheduleToken = UUID()

    // 当前 macOS 原生可解码的格式
    private static let supportedExtensions: Set<String> = [
        "flac", "m4a", "alac", "wav", "wave", "aiff", "aif", "aifc", "caf",
        "mp3", "aac", "m4b", "m4r", "mp2"
    ]

    // 完整音频格式清单（含暂不支持的，用于"遗漏检查"）
    private static let allAudioExtensions: Set<String> = [
        "flac", "m4a", "alac", "wav", "wave", "aiff", "aif", "aifc", "caf",
        "mp3", "aac", "m4b", "m4r", "mp2",
        "ape", "wv", "dsf", "dff", "tta", "tak", "shn",
        "ogg", "oga", "opus", "wma", "mpc", "mka", "amr", "3gp", "webm", "aax"
    ]

    // MARK: - 扫描

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "扫描此文件夹"
        panel.message = "选择包含无损音乐的文件夹"
        panel.directoryURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            Task { await scan(roots: [url]) }
        }
    }

    func scan(roots: [URL]) async {
        isScanning = true
        warnings = []
        statusMessage = "正在扫描…"
        defer { isScanning = false }

        // 1. 收集音频文件 + CUE 文件（后台线程，避免阻塞主线程出菊花）
        let (audioFiles, cueFiles) = await Task.detached(priority: .userInitiated) { () -> ([URL], [URL]) in
            var audio: [URL] = []
            var cue: [URL] = []
            for root in roots {
                audio.append(contentsOf: Self.collectFiles(in: root, extensions: Self.allAudioExtensions))
                cue.append(contentsOf: Self.collectFiles(in: root, extensions: ["cue"]))
            }
            audio = Array(Set(audio.map { $0.standardizedFileURL }))
            return (audio, cue)
        }.value

        // 2. 解析 CUE，把整轨文件展开成分轨曲目
        var cueTracks: [AudioTrack] = []
        var cueHandledAudio: Set<URL> = []
        for cueURL in cueFiles {
            guard let sheet = CueParser.parse(fileURL: cueURL) else { continue }
            let dir = cueURL.deletingLastPathComponent()
            let audioURL = dir.appendingPathComponent(sheet.audioFileName)
            guard FileManager.default.fileExists(atPath: audioURL.path),
                  let full = await Self.loadTrack(url: audioURL) else { continue }

            cueHandledAudio.insert(audioURL.standardizedFileURL)
            let totalDuration = full.duration
            let artworkData = full.artworkData
            let artworkPath = Self.findFolderArtworkPath(in: dir)
            let dynamicCover = Self.findFolderDynamicCover(in: dir)
            let bitrate = full.bitrate
            let albumName = sheet.albumTitle.isEmpty ? dir.lastPathComponent : sheet.albumTitle
            let albumArtist = sheet.albumArtist

            for (i, t) in sheet.tracks.enumerated() {
                let start = max(0, t.startTime)
                let end = i + 1 < sheet.tracks.count
                    ? max(start, sheet.tracks[i + 1].startTime)
                    : totalDuration
                let dur = max(0, end - start)
                let title = t.title.isEmpty ? "Track \(i + 1)" : t.title
                let artist = t.performer.isEmpty
                    ? (albumArtist.isEmpty ? "未知艺术家" : albumArtist)
                    : t.performer
                // 整轨歌词按本曲区间 [start, end) 过滤：只保留属于当前分轨的歌词行
                // （时间戳保持绝对时间，与 currentLyricIndex 的 currentTime+startOffset 定位一致）
                let trackLyrics = (full.lyrics ?? []).filter {
                    $0.time >= start - 0.01 && $0.time < end
                }
                cueTracks.append(AudioTrack(url: audioURL, title: title, artist: artist,
                                            album: albumName, duration: dur,
                                            artworkData: artworkData, artworkPath: artworkPath,
                                            bitrate: bitrate,
                                            sampleRate: full.sampleRate, bitDepth: full.bitDepth,
                                            startOffset: start, lyrics: trackLyrics,
                                            dynamicCoverURL: dynamicCover,
                                            trackNumber: i + 1))
            }
        }

        // 3. 分轨文件（非 CUE 整轨）并发读元数据
        let standaloneFiles = audioFiles.filter { !cueHandledAudio.contains($0) }
        let standaloneResults = await Self.loadTracksConcurrently(standaloneFiles)
        var allTracks = standaloneResults.compactMap { $0 } + cueTracks

        // 4. 文件夹封面兜底（内嵌封面缺失时，读文件夹里的图）+ 动态封面（cover.mp4）
        allTracks = allTracks.map { track in
            let dir = track.url.deletingLastPathComponent()
            let dyn = track.dynamicCoverURL ?? Self.findFolderDynamicCover(in: dir)
            let hasArtwork = track.artworkData != nil || track.artworkPath != nil
            if hasArtwork && dyn != nil {
                return AudioTrack(id: track.id, url: track.url, title: track.title,
                                  artist: track.artist, album: track.album,
                                  duration: track.duration,
                                  artworkData: track.artworkData, artworkPath: track.artworkPath,
                                  bitrate: track.bitrate, sampleRate: track.sampleRate,
                                  bitDepth: track.bitDepth, startOffset: track.startOffset,
                                  lyrics: track.lyrics, dynamicCoverURL: dyn,
                                  trackNumber: track.trackNumber)
            }
            guard !hasArtwork, let artPath = Self.findFolderArtworkPath(in: dir) else { return track }
            return AudioTrack(id: track.id, url: track.url, title: track.title,
                              artist: track.artist, album: track.album,
                              duration: track.duration, artworkPath: artPath,
                              bitrate: track.bitrate, sampleRate: track.sampleRate,
                              bitDepth: track.bitDepth, startOffset: track.startOffset,
                              lyrics: track.lyrics, dynamicCoverURL: dyn,
                              trackNumber: track.trackNumber)
        }

        // 5. 分组 + 排序
        let grouped = Dictionary(grouping: allTracks) { $0.album.isEmpty ? "未知专辑" : $0.album }
        let sortedAlbums = grouped.map { (name, groupTracks) -> AlbumGroup in
            let sortedTracks = groupTracks.sorted { Self.trackBefore($0, $1) }
            let artworkData = sortedTracks.first(where: { $0.artworkData != nil })?.artworkData
            let artworkPath = sortedTracks.first(where: { $0.artworkPath != nil })?.artworkPath
            let dynamicCover = sortedTracks.first(where: { $0.dynamicCoverURL != nil })?.dynamicCoverURL
            let artist = sortedTracks.first?.artist ?? "未知艺术家"
            let folderURL = sortedTracks.first?.url.deletingLastPathComponent()
            return AlbumGroup(name: name, artist: artist,
                              artworkData: artworkData, artworkPath: artworkPath,
                              tracks: sortedTracks, folderURL: folderURL,
                              dynamicCoverURL: dynamicCover)
        }.sorted { $0.name < $1.name }

        albums = sortedAlbums
        tracks = allTracks.sorted {
            if $0.album != $1.album { return $0.album < $1.album }
            return Self.trackBefore($0, $1)
        }
        playQueue = tracks
        selectedAlbum = nil

        // 6. 汇总 + 遗漏检查
        statusMessage = "扫描完成：\(allTracks.count) 首 · \(sortedAlbums.count) 张专辑"
        if warnings.isEmpty {
            warnings.append("✅ 未发现遗漏，全部音乐已入库（含 CUE 分轨）")
        }
    }

    // MARK: - 文件收集

    /// 曲目顺序比较：CUE startOffset（绝对定位）> trackNumber（内嵌标签）>
    /// 文件名前缀数字（如 "01. xxx"、"3-xxx"）> 标题字典序兜底
    private static nonisolated func trackBefore(_ a: AudioTrack, _ b: AudioTrack) -> Bool {
        if a.startOffset != b.startOffset { return a.startOffset < b.startOffset }
        let na = trackOrder(a)
        let nb = trackOrder(b)
        if na != nb { return na < nb }
        return a.title < b.title
    }

    private static nonisolated func trackOrder(_ track: AudioTrack) -> Int {
        if let n = track.trackNumber { return n }
        let name = track.url.deletingPathExtension().lastPathComponent
        if let m = name.range(of: #"^\s*(\d+)"#, options: .regularExpression),
           let n = Int(name[m]) { return n }
        return Int.max
    }

    private static nonisolated func collectFiles(in directory: URL, extensions: Set<String>) -> [URL] {
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else {
            return []
        }
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
               values.isRegularFile == true {
                result.append(url)
            }
        }
        return result
    }

    // 文件夹里的封面图路径（同目录 + 子目录如"封面"/"cover"/"Artwork"）
    static nonisolated func findFolderArtworkPath(in dir: URL) -> String? {
        // 1. 同目录
        if let path = artworkPathInDir(dir) { return path }

        // 2. 子目录（优先名字含封面/cover/artwork 的子目录）
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return nil }
        let keywords = ["封面", "cover", "artwork", "covers", "封套", "art", "图片", "front"]
        let sorted = subdirs.sorted { a, b in
            let ka = keywords.contains { a.lastPathComponent.lowercased().contains($0.lowercased()) }
            let kb = keywords.contains { b.lastPathComponent.lowercased().contains($0.lowercased()) }
            if ka != kb { return ka }
            return a.path < b.path
        }
        for sub in sorted {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let path = artworkPathInDir(sub) { return path }
        }
        return nil
    }

    private static nonisolated func artworkPathInDir(_ dir: URL) -> String? {
        let preferred = ["cover", "folder", "front", "album", "artwork"]
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let images = items.filter {
            let ext = $0.pathExtension.lowercased()
            let name = $0.deletingPathExtension().lastPathComponent.lowercased()
            return ["jpg", "jpeg", "png", "webp", "heic"].contains(ext)
                && !name.hasPrefix("cover3d_depth")  // 排除 3D 深度缓存（黑白深度图不能当封面）
        }
        for name in preferred {
            if let match = images.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == name
            }) {
                return match.path
            }
        }
        return images.first?.path
    }

    // 文件夹里的动态封面（cover.mp4，同目录 + 子目录如"封面"/"cover"/"Artwork"）
    private static nonisolated func findFolderDynamicCover(in dir: URL) -> URL? {
        // 1. 同目录
        if let v = dynamicCoverInDir(dir) { return v }

        // 2. 子目录（优先名字含封面/cover/artwork 的子目录）
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return nil }
        let keywords = ["封面", "cover", "artwork", "covers", "封套", "art", "图片", "front"]
        let sorted = subdirs.sorted { a, b in
            let ka = keywords.contains { a.lastPathComponent.lowercased().contains($0.lowercased()) }
            let kb = keywords.contains { b.lastPathComponent.lowercased().contains($0.lowercased()) }
            if ka != kb { return ka }
            return a.path < b.path
        }
        for sub in sorted {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let v = dynamicCoverInDir(sub) { return v }
        }
        return nil
    }

    private static nonisolated func dynamicCoverInDir(_ dir: URL) -> URL? {
        let preferred = ["cover", "folder", "front", "album", "artwork"]
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let videos = items.filter { ["mp4", "m4v", "mov"].contains($0.pathExtension.lowercased()) }
        for name in preferred {
            if let match = videos.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == name
            }) {
                return match
            }
        }
        return videos.first
    }

    // MARK: - 并发元数据读取

    private static nonisolated func loadTracksConcurrently(_ files: [URL]) async -> [AudioTrack?] {
        guard !files.isEmpty else { return [] }
        var results: [AudioTrack?] = []
        await withTaskGroup(of: AudioTrack?.self) { group in
            let concurrency = min(16, files.count)
            var iterator = files.makeIterator()
            func addNext() {
                if let url = iterator.next() {
                    group.addTask { await loadTrack(url: url) }
                }
            }
            for _ in 0..<concurrency { addNext() }
            for await track in group {
                results.append(track)
                addNext()
            }
        }
        return results
    }

    // MARK: - 从文件名/文件夹名推断元数据（无内嵌 tag 时兜底）

    private static nonisolated func cleanTitle(_ filename: String) -> String {
        var t = (filename as NSString).deletingPathExtension
        if let range = t.range(of: #"^\s*\d+\s*[.\-––]\s*"#, options: .regularExpression) {
            t = String(t[range.upperBound...])
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static nonisolated func inferAlbumArtist(from folderName: String) -> (artist: String, album: String) {
        var name = folderName

        // 去掉开头年份/序号前缀，如 "[2005]"、"2005 "、"2005-"
        if let r = name.range(of: #"^[\[(]?\d{4}[\])]?\s*[-—––]?\s*"#, options: .regularExpression) {
            let stripped = String(name[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { name = stripped }
        }

        // 去掉结尾的方括号/圆括号标签（可能多个）
        var changed = true
        while changed {
            changed = false
            if let r = name.range(of: #"\s*\[[^\]]*\]\s*$"#, options: .regularExpression) {
                name = String(name[..<r.lowerBound]); changed = true
            }
            if let r = name.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
                name = String(name[..<r.lowerBound]); changed = true
            }
        }

        name = name.trimmingCharacters(in: .whitespaces)

        // 《专辑》模式
        if let start = name.firstIndex(of: "《"), let end = name.firstIndex(of: "》"), start < end {
            let artist = String(name[..<start]).trimmingCharacters(in: .whitespaces)
            let album = String(name[name.index(after: start)..<end])
            return (artist, album)
        }
        // "艺术家 - 专辑" 模式
        if let dash = name.firstIndex(of: "-") {
            let artist = String(name[..<dash]).trimmingCharacters(in: .whitespaces)
            let album = String(name[name.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
            return (artist, album)
        }
        // 只有专辑名
        return ("", name)
    }

    private static nonisolated func loadTrack(url: URL) async -> AudioTrack? {
        let asset = AVURLAsset(url: url)
        // 默认从文件名/文件夹名推断（无内嵌 tag 时兜底）
        let folderName = url.deletingLastPathComponent().lastPathComponent
        let inferred = inferAlbumArtist(from: folderName)
        var title = cleanTitle(url.lastPathComponent)
        var artist = inferred.artist.isEmpty ? "未知艺术家" : inferred.artist
        var album = inferred.album.isEmpty ? folderName : inferred.album
        var artworkData: Data?
        var trackNumber: Int?
        var duration: Double = 0
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        do {
            let cmTime = try await asset.load(.duration)
            duration = cmTime.seconds.isFinite ? cmTime.seconds : 0
        } catch {
            return nil // 读不到时长，不是有效音频
        }

        // 内嵌 tag 优先覆盖（用全量 metadata：部分 FLAC 的 vorbis 注释/封面
        // 在 commonMetadata 过滤后读不到，全量里 commonKey 映射仍然正确）
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                switch item.commonKey {
                case .commonKeyTitle:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { title = v }
                case .commonKeyArtist:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { artist = v }
                case .commonKeyAlbumName:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { album = v }
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue) {
                        artworkData = data  // 只存原始数据，显示时再解码
                    }
                default:
                    // 曲目号：FLAC vorbis 的 TRACKNUMBER / ID3 TRCK（可能是 "5/12" 格式）
                    if let key = item.key as? String,
                       ["TRACKNUMBER", "TRCK"].contains(key.uppercased()),
                       let v = try? await item.load(.stringValue) {
                        let num = v.split(separator: "/").first.map(String.init) ?? v
                        trackNumber = Int(num.trimmingCharacters(in: .whitespaces))
                    }
                    break
                }
            }
        }

        let bitrate = duration > 0 ? Int(Double(fileSize) * 8.0 / duration / 1000.0) : 0
        let fmt = Self.readAudioFormat(url: url)
        // 外部同名 .lrc 优先；缺失时读取音频内嵌歌词（ID3 USLT / iTunes ©lyr / FLAC LYRICS）
        var lyrics = LyricsParser.loadLyrics(for: url)
        if lyrics == nil {
            lyrics = await LyricsParser.loadEmbeddedLyrics(url: url, duration: duration)
        }
        return AudioTrack(url: url, title: title, artist: artist, album: album,
                          duration: duration, artworkData: artworkData,
                          bitrate: bitrate,
                          sampleRate: fmt.sampleRate, bitDepth: fmt.bitDepth,
                          lyrics: lyrics, trackNumber: trackNumber)
    }

    /// 读取文件的采样率（Hz）与位深（bit）
    private static nonisolated func readAudioFormat(url: URL) -> (sampleRate: Double, bitDepth: Int) {
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr,
              let file = audioFile else {
            return (0, 0)
        }
        defer { AudioFileClose(file) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd) == noErr else {
            return (0, 0)
        }

        let sampleRate = asbd.mSampleRate
        var bitDepth = Int(asbd.mBitsPerChannel)

        // 无损压缩格式（FLAC / ALAC）的位深在 magic cookie 里，mBitsPerChannel 恒为 0
        if asbd.mFormatID == kAudioFormatFLAC {
            if let bd = Self.flacBitDepth(url: url) { bitDepth = bd }
        } else if asbd.mFormatID == kAudioFormatAppleLossless {
            if let bd = Self.alacBitDepth(file: file) { bitDepth = bd }
        }
        return (sampleRate, bitDepth)
    }

    /// 从 FLAC 文件头解析 STREAMINFO 得到位深
    private static nonisolated func flacBitDepth(url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // "fLaC" 魔数
        guard let magic = try? handle.read(upToCount: 4),
              [UInt8](magic) == [0x66, 0x4c, 0x61, 0x43] else { return nil }
        while true {
            guard let headerData = try? handle.read(upToCount: 4), headerData.count == 4 else { return nil }
            let header = [UInt8](headerData)
            let isLast = (header[0] & 0x80) != 0
            let type = Int(header[0] & 0x7f)
            let length = (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            if type == 0 {
                guard let data = try? handle.read(upToCount: length), data.count >= 18 else { return nil }
                let b = [UInt8](data)
                // bits per sample: 5 位，跨 byte 12 / 13
                let bitsPerSample = Int(((b[12] & 0x01) << 4) | (b[13] >> 4))
                return bitsPerSample + 1
            }
            if isLast { return nil }
            _ = try? handle.read(upToCount: length)
        }
    }

    /// 从 ALAC magic cookie 解析位深
    private static nonisolated func alacBitDepth(file: AudioFileID) -> Int? {
        var size: UInt32 = 0
        var writable: UInt32 = 0
        guard AudioFileGetPropertyInfo(file, kAudioFilePropertyMagicCookieData, &size, &writable) == noErr,
              size > 5 else { return nil }
        var cookie = [UInt8](repeating: 0, count: Int(size))
        guard AudioFileGetProperty(file, kAudioFilePropertyMagicCookieData, &size, &cookie) == noErr else {
            return nil
        }
        return Int(cookie[5])
    }

    // MARK: - 播放

    /// 将文件的一段（含格式转换）调度到播放节点。
    /// 源文件可能是任意采样率/声道（如单声道 FLAC、96kHz WAV），
    /// 统一经 AVAudioConverter 转为播放节点输出格式后再 scheduleBuffer，
    /// 避免 scheduleSegment 对声道/采样率不匹配崩溃。
    private func scheduleSegment(file: AVAudioFile,
                                 startFrame: AVAudioFramePosition,
                                 frameCount: AVAudioFramePosition,
                                 completion: @escaping () -> Void) {
        let srcFormat = file.processingFormat
        let dstFormat = playerNode.outputFormat(forBus: 0)
        let needsConversion = srcFormat != dstFormat

        // 定位到起始帧
        file.framePosition = startFrame
        let remainingFrames = min(frameCount, file.length - startFrame)

        guard remainingFrames > 0 else {
            completion()
            return
        }

        let capacity: AVAudioFrameCount = 16384
        var scheduled = AVAudioFramePosition(0)

        if !needsConversion {
            // 格式相同：直接分块读取调度（最后一块挂播完回调）
            var lastBuf: AVAudioPCMBuffer?
            while scheduled < remainingFrames {
                let toRead = AVAudioFrameCount(min(Int(capacity), Int(remainingFrames - scheduled)))
                guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: toRead) else {
                    completion()
                    return
                }
                do {
                    try file.read(into: srcBuf, frameCount: toRead)
                } catch {
                    completion()
                    return
                }
                guard srcBuf.frameLength > 0 else { break }
                scheduled += AVAudioFramePosition(srcBuf.frameLength)
                if let prev = lastBuf {
                    playerNode.scheduleBuffer(prev, at: nil, options: [], completionHandler: nil)
                }
                lastBuf = srcBuf
            }
            if let lastBuf {
                playerNode.scheduleBuffer(lastBuf, at: nil, options: [],
                                          completionHandler: completion)
            } else {
                completion()
            }
            return
        }

        // 需要格式转换：AVAudioConverter 逐块转换调度
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            completion()
            return
        }
        var finished = false
        var completionAttached = false
        while !finished {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else {
                completion()
                return
            }
            outBuf.frameLength = 0
            var convErr: NSError?
            let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
                let toRead = AVAudioFrameCount(min(Int(capacity), Int(remainingFrames - scheduled)))
                guard toRead > 0,
                      let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: toRead) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: srcBuf, frameCount: toRead)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                scheduled += AVAudioFramePosition(srcBuf.frameLength)
                guard srcBuf.frameLength > 0 else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return srcBuf
            }
            if status == .error || convErr != nil {
                if !completionAttached { completion() }
                return
            }
            if outBuf.frameLength > 0 {
                if status == .endOfStream {
                    playerNode.scheduleBuffer(outBuf, at: nil, options: [], completionHandler: completion)
                    completionAttached = true
                } else {
                    playerNode.scheduleBuffer(outBuf, at: nil, options: [], completionHandler: nil)
                }
            }
            // .inputRanDry：输入耗尽但 converter 内部缓冲可能未 flush 完，继续循环
            if status == .endOfStream {
                finished = true
            }
        }
        // 最后一段音频可能以 .haveData/.inputRanDry 输出（.endOfStream 返回空）→
        // 播完回调未挂上：补一个 0 帧 buffer 排在队列末尾挂回调，
        // 最后一段播完的瞬间触发（不会提前切歌）
        if !completionAttached {
            if let tail = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: 1) {
                tail.frameLength = 0
                playerNode.scheduleBuffer(tail, at: nil, options: [], completionHandler: completion)
            } else {
                completion()
            }
        }
    }

    func play(_ track: AudioTrack) {
        // 歌词兜底：缓存为空或缺失时实时读取外部 .lrc（如刚用「添加歌词」下载的场景；
        // CUE 分轨按 [start, end) 区间过滤，区间内无歌词则不显示）
        let effectiveTrack: AudioTrack
        if (track.lyrics?.isEmpty ?? true), let fresh = LyricsParser.loadLyrics(for: track.url) {
            let filtered = fresh.filter {
                $0.time >= track.startOffset - 0.01 && $0.time < track.startOffset + track.duration
            }
            let use = (filtered.isEmpty && track.startOffset == 0) ? fresh : filtered
            effectiveTrack = AudioTrack(id: track.id, url: track.url, title: track.title,
                                        artist: track.artist, album: track.album,
                                        duration: track.duration,
                                        artworkData: track.artworkData, artworkPath: track.artworkPath,
                                        bitrate: track.bitrate, sampleRate: track.sampleRate,
                                        bitDepth: track.bitDepth, startOffset: track.startOffset,
                                        lyrics: use, dynamicCoverURL: track.dynamicCoverURL,
                                        trackNumber: track.trackNumber)
        } else {
            effectiveTrack = track
        }

        // 引擎未就绪时暂存，就绪后自动播放
        guard engineReady else {
            pendingTrack = effectiveTrack
            return
        }
        // 记录最近播放（去重、插到最前、限 50 首）
        recentTracks.removeAll { $0.id == effectiveTrack.id }
        recentTracks.insert(effectiveTrack, at: 0)
        if recentTracks.count > 50 {
            recentTracks = Array(recentTracks.prefix(50))
        }

        do {
            playerNode.stop()
            let file = try AVAudioFile(forReading: effectiveTrack.url)
            let srcFormat = file.processingFormat
            let sampleRate = srcFormat.sampleRate

            // CUE 整轨：从 startOffset 处开始，播本轨时长
            let startFrame = AVAudioFramePosition(effectiveTrack.startOffset * sampleRate)
            let trackFrames = AVAudioFramePosition(effectiveTrack.duration * sampleRate)
            let frameCount = AVAudioFramePosition(max(0, min(trackFrames, file.length - startFrame)))

            let token = UUID()
            scheduleToken = token
            scheduleSegment(file: file, startFrame: startFrame,
                            frameCount: frameCount) { [weak self] in
                // 播完回调（音频线程）→ 主线程处理，且校验令牌避免误触发
                DispatchQueue.main.async {
                    guard let self, self.scheduleToken == token else { return }
                    self.advanceOrStop()
                }
            }
            playerNode.volume = Float(volume)
            playerNode.play()

            currentTrack = effectiveTrack
            isPlaying = true
            currentTime = 0
            scheduleStartTime = 0
            liveBitrate = effectiveTrack.bitrate
            startProfileParsing(for: effectiveTrack)
            startProgressTimer()
        } catch {
            warnings = ["无法播放：\(effectiveTrack.title)（该格式暂不支持）"]
        }
    }

    func togglePlay() {
        guard currentTrack != nil else { return }
        if playerNode.isPlaying {
            playerNode.pause()
            isPlaying = false
            stopProgressTimer()
        } else {
            playerNode.play()
            isPlaying = true
            startProgressTimer()
        }
    }

    func seek(to time: Double) {
        guard let track = currentTrack else { return }
        let clamped = max(0, min(time, max(track.duration, 0)))
        let wasPlaying = playerNode.isPlaying
        do {
            let file = try AVAudioFile(forReading: track.url)
            let sampleRate = file.processingFormat.sampleRate
            playerNode.stop()
            let startFrame = AVAudioFramePosition((track.startOffset + clamped) * sampleRate)
            // 关键：frameCount 用「分轨剩余帧数」而非分轨总帧数——
            // 否则 seek 到分轨后半段后会越过分轨末尾（CUE 分轨进度条错乱、切歌时机错误）
            let remaining = AVAudioFramePosition((track.duration - clamped) * sampleRate)
            let frameCount = AVAudioFramePosition(max(0, min(remaining, file.length - startFrame)))

            let token = UUID()
            scheduleToken = token
            scheduleSegment(file: file, startFrame: startFrame,
                            frameCount: frameCount) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.scheduleToken == token else { return }
                    self.advanceOrStop()
                }
            }
            playerNode.volume = Float(volume)
            playerNode.play()
            currentTime = clamped
            scheduleStartTime = clamped
            // 保持原播放状态：seek 前暂停则 seek 后仍暂停（位置已更新）
            if !wasPlaying {
                playerNode.pause()
                isPlaying = false
            } else if !isPlaying {
                isPlaying = true
                startProgressTimer()
            }
        } catch {
            warnings = ["无法定位：\(track.title)"]
        }
    }

    func playAlbum(_ album: AlbumGroup, startingTrack: AudioTrack? = nil) {
        playQueue = album.tracks
        let first = startingTrack ?? album.tracks.first
        if let t = first { play(t) }
    }

    func playTrack(_ track: AudioTrack) {
        // 按当前侧边栏决定切歌队列：
        // 歌曲 → 全部歌曲列表顺序；播放列表 → 当前播放列表顺序；
        // 收藏 → 收藏列表顺序；其他（专辑等）→ 所属专辑顺序
        switch activeSidebar {
        case "歌曲":
            playQueue = tracks
        case "播放列表":
            if let pl = selectedPlaylist {
                playQueue = tracks(in: pl)
            } else {
                playQueue = [track]
            }
        case "收藏":
            playQueue = favoriteTracks.isEmpty ? [track] : favoriteTracks
        default:
            if let album = albums.first(where: { $0.tracks.contains(where: { $0.id == track.id }) }) {
                playQueue = album.tracks
            } else {
                playQueue = [track]
            }
        }
        play(track)
    }

    func next() {
        guard !playQueue.isEmpty else { return }
        if playbackMode == .shuffle, playQueue.count > 1 {
            var candidates = playQueue
            if let current = currentTrack,
               let idx = playQueue.firstIndex(where: { $0.id == current.id }) {
                candidates.remove(at: idx)
            }
            play(candidates.randomElement() ?? playQueue[0])
            return
        }
        guard let current = currentTrack,
              let idx = playQueue.firstIndex(where: { $0.id == current.id }) else {
            play(playQueue[0]); return
        }
        if idx + 1 < playQueue.count {
            play(playQueue[idx + 1])
        } else if playbackMode == .all {
            play(playQueue[0])
        }
    }

    /// 循环切换播放模式：off → all → one → shuffle → off
    func cyclePlaybackMode() {
        switch playbackMode {
        case .off: playbackMode = .all
        case .all: playbackMode = .one
        case .one: playbackMode = .shuffle
        case .shuffle: playbackMode = .off
        }
    }

    func previous() {
        guard !playQueue.isEmpty else { return }
        guard let current = currentTrack,
              let idx = playQueue.firstIndex(where: { $0.id == current.id }) else {
            play(playQueue[0]); return
        }
        play(playQueue[max(0, idx - 1)])
    }

    func hasNext() -> Bool {
        guard !playQueue.isEmpty else { return false }
        if playbackMode == .shuffle { return playQueue.count > 1 }
        if playbackMode == .all { return true }
        guard let current = currentTrack,
              let idx = playQueue.firstIndex(where: { $0.id == current.id }) else { return false }
        return idx + 1 < playQueue.count
    }

    private func advanceOrStop() {
        // 设备切换期间禁止切歌（切换处理会重新调度当前歌曲）
        guard !isDeviceSwitching else { return }
        if playbackMode == .one, let t = currentTrack {
            play(t)
            return
        }
        if hasNext() {
            next()
        } else {
            isPlaying = false
            stopProgressTimer()
        }
    }

    /// 本次 schedule 在轨道内的起始秒（seek 后为 seek 位置；progressTimer 用它换算）
    private var scheduleStartTime: Double = 0

    // MARK: - 进度

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // AVAudioPlayerNode 的播放位置：playerTime(forNodeTime:) 相对 schedule 起点
                if let nodeTime = self.playerNode.lastRenderTime,
                   let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime) {
                    let seconds = Double(playerTime.sampleTime) / playerTime.sampleRate
                    // 进度 = 本次 schedule 起始位置 + 已播时长（seek 后不跳回 0）
                    self.currentTime = self.scheduleStartTime + max(0, seconds)
                    let offset = self.currentTrack?.startOffset ?? 0
                    let absolute = offset + self.currentTime

                    if !self.bitrateProfile.isEmpty {
                        self.liveBitrate = Self.bitrate(at: absolute, in: self.bitrateProfile)
                    }
                }

                // 播放被中断（如音频设备问题）：恢复主线程状态
                if !self.playerNode.isPlaying && self.isPlaying {
                    self.isPlaying = false
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - 实时码率

    private func startProfileParsing(for track: AudioTrack) {
        bitrateProfile = []
        profileTask?.cancel()
        let url = track.url
        profileTask = Task.detached(priority: .utility) {
            let profile = await Self.buildBitrateProfile(url: url)
            await MainActor.run {
                self.bitrateProfile = profile
            }
        }
    }

    private static nonisolated func buildBitrateProfile(url: URL) async -> [(time: Double, bitrate: Double)] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { return [] }

        var profile: [(time: Double, bitrate: Double)] = []
        while let buffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let duration = CMSampleBufferGetDuration(buffer).seconds
            let byteCount = CMSampleBufferGetTotalSampleSize(buffer)
            guard duration > 0, byteCount > 0, pts.isFinite, duration.isFinite else { continue }
            let bitrate = Double(byteCount) * 8.0 / duration / 1000.0
            profile.append((pts, bitrate))
        }
        return profile
    }

    private static nonisolated func bitrate(at time: Double, in profile: [(time: Double, bitrate: Double)]) -> Int {
        var low = 0
        var high = profile.count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if profile[mid].time <= time {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return Int(profile[answer].bitrate)
    }

    // MARK: - 右键选封面

    func chooseCustomArtwork(for albumID: UUID) {
        guard let album = albums.first(where: { $0.id == albumID }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "设为封面"
        panel.message = "从专辑文件夹选择一张图作为封面"
        if let folder = album.folderURL {
            panel.directoryURL = folder
        }
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            setCustomArtwork(for: albumID, image: img)
        }
    }

    private func setCustomArtwork(for albumID: UUID, image: NSImage) {
        // 把用户选择的封面转成 JPEG data 存起来
        var data: Data? = nil
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
        albums = albums.map { album in
            guard album.id == albumID else { return album }
            return AlbumGroup(id: album.id, name: album.name, artist: album.artist,
                              artworkData: data, tracks: album.tracks, folderURL: album.folderURL)
        }
        if selectedAlbum?.id == albumID {
            selectedAlbum = albums.first(where: { $0.id == albumID })
        }
    }

    // MARK: - 自动补齐歌词（lrclib.net）

    /// 为专辑中缺少 .lrc 的曲目从 lrclib.net 下载歌词，保存到音频文件同名 .lrc。
    /// 分轨专辑逐首查询；CUE 整轨专辑按专辑名查询整轨歌词。
    func downloadLyrics(for album: AlbumGroup) async {
        guard !lyricsDownloading else { return }
        lyricsDownloading = true
        lyricsDownloadAlbumID = album.id
        defer {
            lyricsDownloading = false
            lyricsDownloadAlbumID = nil
        }

        // 按唯一音频文件分组（CUE 分轨共享同一 url）
        let files = Dictionary(grouping: album.tracks) { $0.url.standardizedFileURL }
        var downloaded = 0
        var skipped = 0
        var failed: [String] = []

        for (url, tracks) in files {
            let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
            if FileManager.default.fileExists(atPath: lrcURL.path) {
                skipped += 1
                continue
            }

            let isCUEWhole = tracks.count > 1
            let lrcText: String?
            if isCUEWhole {
                lrcText = await Self.searchWholeAlbum(albumName: album.name,
                                                      artistName: album.artist,
                                                      tracks: tracks)
            } else if let t = tracks.first {
                lrcText = await Self.searchTrack(albumName: t.album, artistName: t.artist,
                                                 trackName: t.title, duration: t.duration)
            } else {
                lrcText = nil
            }

            guard let text = lrcText, !text.isEmpty else {
                failed.append(url.lastPathComponent)
                continue
            }
            do {
                try text.write(to: lrcURL, atomically: true, encoding: .utf8)
                downloaded += 1
            } catch {
                failed.append(url.lastPathComponent)
            }
        }

        // 刷新正在播放的歌词（若属于该专辑；CUE 分轨按 [start, end) 过滤）
        if let cur = currentTrack,
           files.keys.contains(cur.url.standardizedFileURL),
           let fresh = LyricsParser.loadLyrics(for: cur.url) {
            let filtered = fresh.filter {
                $0.time >= cur.startOffset - 0.01 && $0.time < cur.startOffset + cur.duration
            }
            currentTrack = AudioTrack(id: cur.id, url: cur.url, title: cur.title,
                                      artist: cur.artist, album: cur.album,
                                      duration: cur.duration,
                                      artworkData: cur.artworkData, artworkPath: cur.artworkPath,
                                      bitrate: cur.bitrate, sampleRate: cur.sampleRate,
                                      bitDepth: cur.bitDepth, startOffset: cur.startOffset,
                                      lyrics: filtered.isEmpty ? fresh : filtered,
                                      dynamicCoverURL: cur.dynamicCoverURL,
                                      trackNumber: cur.trackNumber)
        }

        var msg = "《\(album.name)》添加歌词：成功 \(downloaded) 首"
        if skipped > 0 { msg += "，已有 \(skipped) 首" }
        if !failed.isEmpty { msg += "，失败 \(failed.count) 首" }
        statusMessage = msg
    }

    /// 清洗专辑名用于搜索：去 [xxx]/(xxx)/（xxx）括号版本标注与常见版本词
    private static nonisolated func cleanAlbumName(_ name: String) -> String {
        var s = name
        s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"（[^）]*）"#, with: "", options: .regularExpression)
        let words = ["台湾首版", "香港首版", "首版", "限量版", "典藏版", "豪华版", "台版", "港版",
                     "Deluxe", "Remastered", "Expanded", "Special Edition", "Bonus Track"]
        for w in words {
            s = s.replacingOccurrences(of: w, with: "", options: .caseInsensitive)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 单曲查询：专辑+艺术家+曲名精确匹配，无结果时用关键词兜底搜索
    private static nonisolated func searchTrack(albumName: String, artistName: String,
                                                trackName: String, duration: Double) async -> String? {
        let cleanAlbum = Self.cleanAlbumName(albumName)
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: trackName),
            URLQueryItem(name: "album_name", value: cleanAlbum),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        if !artistName.isEmpty, artistName != "未知艺术家" {
            comps.queryItems?.append(URLQueryItem(name: "artist_name", value: artistName))
        }
        if let hits = await Self.fetchHits(url: comps.url!), !hits.isEmpty,
           let lrc = Self.bestHit(hits, duration: duration) {
            return lrc
        }
        // 兜底：关键词搜索（专辑名匹配不上时仍能找到）
        var q = trackName
        if !artistName.isEmpty, artistName != "未知艺术家" {
            q = "\(artistName) \(trackName)"
        }
        var comps2 = URLComponents(string: "https://lrclib.net/api/search")!
        comps2.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let hits2 = await Self.fetchHits(url: comps2.url!) else { return nil }
        return Self.bestHit(hits2, duration: duration)
    }

    /// CUE 整轨查询：q 搜索清洗后的专辑名，把每首分轨歌词按 startOffset 平移拼接成整轨 .lrc
    private static nonisolated func searchWholeAlbum(albumName: String, artistName: String,
                                                     tracks: [AudioTrack]) async -> String? {
        let cleanAlbum = Self.cleanAlbumName(albumName)
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: cleanAlbum)]
        guard let hits = await Self.fetchHits(url: comps.url!), !hits.isEmpty else { return nil }

        let wholeDuration = tracks.map { $0.startOffset + $0.duration }.max() ?? 0
        // 1. 直接命中整轨：仅当存在时长与整轨接近（±30s 内）的同步歌词才视为整轨
        let wholeCandidates = hits.filter { $0.syncedLyrics != nil && !$0.instrumental }
        if let whole = wholeCandidates.min(by: {
            abs(($0.duration ?? 0) - wholeDuration) < abs(($1.duration ?? 0) - wholeDuration)
        }), let d = whole.duration, abs(d - wholeDuration) <= 30 {
            return whole.syncedLyrics
        }

        // 2. 逐曲拼接：每首分轨匹配歌词，时间戳 + startOffset 平移
        var out: [(time: Double, text: String)] = []
        for track in tracks.sorted(by: { $0.startOffset < $1.startOffset }) {
            guard let hit = Self.bestMatch(for: track, in: hits),
                  let synced = hit.syncedLyrics else { continue }
            for line in synced.components(separatedBy: .newlines) {
                guard let m = Self.lrcLineTime(line) else { continue }
                out.append((time: m.time + track.startOffset, text: m.text))
            }
        }
        guard !out.isEmpty else { return nil }
        out.sort { $0.time < $1.time }
        return out.map { String(format: "[%02d:%05.2f]", Int($0.time / 60), $0.time.truncatingRemainder(dividingBy: 60)) + $0.text }
            .joined(separator: "\n")
    }

    /// 分轨标题与 lrclib 命中归一化匹配（忽略大小写/空格/括号/序号/全半角逗号，繁→简）
    private static nonisolated func bestMatch(for track: AudioTrack, in hits: [LRCLibHit]) -> LRCLibHit? {
        let norm: (String) -> String = { s in
            var t = s.lowercased()
            t = t.replacingOccurrences(of: #"^\s*\d+[\.\、\-\s]+"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"[\(\)\[\]（）【】\-_,，.·、'\"“”]+"#, with: "", options: .regularExpression)
            return t.filter { !$0.isWhitespace }
        }
        let target = norm(track.title)
        let candidates = hits.filter { $0.syncedLyrics != nil && !$0.instrumental }
        // 1. 精确（归一化后相等）
        if let hit = candidates.first(where: { norm($0.trackName) == target }) {
            return hit
        }
        // 2. 包含匹配，取时长最接近的
        let contains = candidates.filter {
            let n = norm($0.trackName)
            return n.contains(target) || target.contains(n)
        }
        if let hit = contains.min(by: {
            abs(($0.duration ?? 0) - track.duration) < abs(($1.duration ?? 0) - track.duration)
        }) {
            return hit
        }
        // 3. 时长兜底：标题对不上（如繁简差异）时按时长（±15s）选，
        //    且必须与目标标题有共同汉字（防同专辑近似时长歌曲错配）
        let targetChars = Set(target)
        return candidates
            .filter {
                abs(($0.duration ?? 0) - track.duration) < 15 &&
                !Set(norm($0.trackName)).intersection(targetChars).isEmpty
            }
            .min { abs(($0.duration ?? 0) - track.duration) < abs(($1.duration ?? 0) - track.duration) }
    }

    /// 解析 LRC 行 "[mm:ss.xx]文本"，返回时间（秒）与文本
    private static nonisolated func lrcLineTime(_ line: String) -> (time: Double, text: String)? {
        guard let m = line.range(of: #"\[(\d+):(\d+(?:\.\d+)?)\](.*)"#, options: .regularExpression) else { return nil }
        let full = String(line[m])
        guard let colon = full.firstIndex(of: ":") else { return nil }
        let mm = full[full.index(full.startIndex, offsetBy: 1)..<colon]
        guard let close = full.firstIndex(of: "]") else { return nil }
        let ss = full[full.index(after: colon)..<close]
        guard let mInt = Int(mm), let sDouble = Double(ss) else { return nil }
        return (time: Double(mInt) * 60 + sDouble, text: String(full[full.index(after: close)...]))
    }

    /// 从命中中选同步歌词 + 时长最接近的
    private static nonisolated func bestHit(_ hits: [LRCLibHit], duration: Double) -> String? {
        hits.filter { $0.syncedLyrics != nil && !$0.instrumental }
            .min { a, b in
                abs((a.duration ?? 0) - duration) < abs((b.duration ?? 0) - duration)
            }?.syncedLyrics
    }

    private struct LRCLibHit: Decodable {
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: Double?
        let instrumental: Bool
        let syncedLyrics: String?
    }

    private static nonisolated func fetchHits(url: URL) async -> [LRCLibHit]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("ShengChao/1.1 (LiquidGlassPlayer)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode([LRCLibHit].self, from: data)
        } catch {
            return nil
        }
    }

    func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - 收藏

    func favoriteKey(for track: AudioTrack) -> String {
        "\(track.url.standardizedFileURL.path)|\(track.startOffset)"
    }

    func isFavorite(_ track: AudioTrack) -> Bool {
        favoriteKeys.contains(favoriteKey(for: track))
    }

    func toggleFavorite(_ track: AudioTrack) {
        let key = favoriteKey(for: track)
        if favoriteKeys.contains(key) {
            favoriteKeys.remove(key)
        } else {
            favoriteKeys.insert(key)
        }
        UserDefaults.standard.set(Array(favoriteKeys), forKey: "favoriteTracks")
    }

    var favoriteTracks: [AudioTrack] {
        tracks.filter { favoriteKeys.contains(favoriteKey(for: $0)) }
    }

    // MARK: - 播放列表

    func createPlaylist(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists.append(Playlist(name: trimmed, trackKeys: []))
        savePlaylists()
    }

    func deletePlaylist(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        if selectedPlaylist?.id == playlist.id {
            selectedPlaylist = nil
        }
        savePlaylists()
    }

    func addToPlaylist(_ track: AudioTrack, _ playlist: Playlist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let key = favoriteKey(for: track)
        if !playlists[idx].trackKeys.contains(key) {
            playlists[idx].trackKeys.append(key)
            savePlaylists()
        }
    }

    func removeFromPlaylist(_ track: AudioTrack, _ playlist: Playlist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let key = favoriteKey(for: track)
        playlists[idx].trackKeys.removeAll { $0 == key }
        savePlaylists()
    }

    func isInPlaylist(_ track: AudioTrack, _ playlist: Playlist) -> Bool {
        playlist.trackKeys.contains(favoriteKey(for: track))
    }

    func tracks(in playlist: Playlist) -> [AudioTrack] {
        let keys = Set(playlist.trackKeys)
        return tracks.filter { keys.contains(favoriteKey(for: $0)) }
    }

    private func savePlaylists() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: "playlists")
        }
    }
}
