import Foundation
import AVFoundation

// MARK: - 歌词行

struct LyricsLine: Identifiable, Codable {
    let id = UUID()
    let time: Double
    let text: String
    enum CodingKeys: CodingKey { case time, text }
}

// MARK: - LRC 解析

enum LyricsParser {
    /// 从音频文件 URL 找同名 .lrc 并解析；没有则返回 nil
    static func loadLyrics(for audioURL: URL) -> [LyricsLine]? {
        let base = audioURL.deletingPathExtension()
        for ext in ["lrc", "LRC"] {
            let url = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) {
                return loadLyrics(from: url)
            }
        }
        return nil
    }

    static func loadLyrics(from url: URL) -> [LyricsLine]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var content: String?
        // 先 UTF-8，失败再 GB18030（中文老 LRC 常见）
        if let s = String(data: data, encoding: .utf8) {
            content = s
        } else {
            let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            if let s = String(data: data, encoding: gb) {
                content = s
            }
        }
        guard let content else { return nil }
        let lines = parse(content)
        return lines.isEmpty ? nil : lines
    }

    /// 解析 LRC 文本：`[mm:ss.xx]歌词`
    static func parse(_ content: String) -> [LyricsLine] {
        var result: [LyricsLine] = []
        let pattern = #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }

            // 歌词文本 = 去掉所有时间戳后剩余部分
            var text = line
            for m in matches.reversed() {
                text = (text as NSString).replacingCharacters(in: m.range, with: "")
            }
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            // 每个时间戳生成一行（重复段）
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac: Double = 0
                if m.numberOfRanges > 3 {
                    let s = ns.substring(with: m.range(at: 3))
                    if !s.isEmpty, let v = Double(s) {
                        frac = v / pow(10, Double(s.count))
                    }
                }
                result.append(LyricsLine(time: min * 60 + sec + frac, text: text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    // MARK: - 内嵌歌词读取（ID3 USLT / iTunes ©lyr / FLAC LYRICS）

    /// 从音频文件内嵌标签读取歌词；外部同名 .lrc 缺失时由调用方兜底使用
    static func loadEmbeddedLyrics(url: URL, duration: Double) async -> [LyricsLine]? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        var text: String?
        for item in items {
            let keyStr = ((item.key as? String) ?? "").lowercased()
            let idStr = (item.identifier?.rawValue ?? "").lowercased()
            let isLyricKey = ["uslt", "©lyr", "lyr", "lyrics", "unsyncedlyrics",
                              "unsynchronizedlyric", "lyric"]
                .contains { keyStr.contains($0) || idStr.contains($0) }
            guard isLyricKey else { continue }
            if let v = try? await item.load(.stringValue), !v.isEmpty {
                text = v
                break
            }
        }
        return parseEmbedded(text, duration: duration)
    }

    /// 解析内嵌歌词文本：带 LRC 时间戳走正常解析；纯文本则按每行长度加权分配时间
    /// （长句唱得久、短句短），让歌词面板能随播放进度逐行滚动
    static func parseEmbedded(_ text: String?, duration: Double) -> [LyricsLine]? {
        guard let text, !text.isEmpty else { return nil }
        let timed = parse(text)
        if !timed.isEmpty {
            return timed
        }
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !rawLines.isEmpty else { return nil }
        // 权重 = 每行字符数（短句保底 6，避免瞬间跳过）
        let weights = rawLines.map { max(Double($0.count), 6) }
        let total = weights.reduce(0, +)
        var t: Double = 0
        var result: [LyricsLine] = []
        for (i, line) in rawLines.enumerated() {
            result.append(LyricsLine(time: t, text: line))
            t += duration * weights[i] / total
        }
        return result
    }
}
