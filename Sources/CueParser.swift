import Foundation

// MARK: - CUE 分轨解析

struct CueTrackInfo {
    let title: String
    let performer: String
    let startTime: Double
}

struct CueSheetInfo {
    let albumTitle: String
    let albumArtist: String
    let audioFileName: String
    let tracks: [CueTrackInfo]
}

enum CueParser {
    static func parse(fileURL: URL) -> CueSheetInfo? {
        guard let data = try? Data(contentsOf: fileURL),
              let content = decode(data) else { return nil }

        var albumTitle = ""
        var albumArtist = ""
        var audioFileName = ""
        var fileCount = 0
        var tracks: [CueTrackInfo] = []

        var currentTitle = ""
        var currentPerformer = ""
        var currentStart: Double = -1
        var pendingTrack = false

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("FILE ") {
                fileCount += 1
                audioFileName = extractQuoted(line)
            } else if line.hasPrefix("TRACK ") {
                if pendingTrack && currentStart >= 0 {
                    tracks.append(CueTrackInfo(title: currentTitle,
                                               performer: currentPerformer,
                                               startTime: currentStart))
                }
                currentTitle = ""
                currentPerformer = ""
                currentStart = -1
                pendingTrack = true
            } else if line.hasPrefix("TITLE ") {
                let v = extractQuoted(line)
                if pendingTrack { currentTitle = v } else { albumTitle = v }
            } else if line.hasPrefix("PERFORMER ") {
                let v = extractQuoted(line)
                if pendingTrack { currentPerformer = v } else { albumArtist = v }
            } else if line.hasPrefix("INDEX 01 ") {
                currentStart = parseIndexTime(line)
            }
        }
        if pendingTrack && currentStart >= 0 {
            tracks.append(CueTrackInfo(title: currentTitle,
                                       performer: currentPerformer,
                                       startTime: currentStart))
        }

        guard fileCount == 1, !audioFileName.isEmpty, !tracks.isEmpty else { return nil }
        return CueSheetInfo(albumTitle: albumTitle, albumArtist: albumArtist,
                            audioFileName: audioFileName, tracks: tracks)
    }

    // CUE 文件常见 GBK / Big5 / UTF-8 编码
    private static func decode(_ data: Data) -> String? {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)))
        // utf16 放最后：它对 GBK 字节会"误成功"产生乱码
        let candidates: [String.Encoding] = [.utf8, gb18030, big5, .utf16]
        for enc in candidates {
            guard let s = String(data: data, encoding: enc) else { continue }
            let clean = s.replacingOccurrences(of: "\u{FEFF}", with: "")
            if clean.contains("FILE") || clean.contains("TRACK") || clean.contains("INDEX") {
                return clean
            }
        }
        return nil
    }

    private static func extractQuoted(_ line: String) -> String {
        guard let start = line.firstIndex(of: "\""),
              let end = line.lastIndex(of: "\""),
              start < end else { return "" }
        return String(line[line.index(after: start)..<end])
    }

    private static func parseIndexTime(_ line: String) -> Double {
        guard let timeStr = line.split(separator: " ").last else { return -1 }
        let comps = timeStr.split(separator: ":")
        guard comps.count == 3,
              let m = Double(comps[0]),
              let s = Double(comps[1]),
              let f = Double(comps[2]) else { return -1 }
        return m * 60 + s + f / 75.0
    }
}
