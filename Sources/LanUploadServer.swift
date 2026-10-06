import Foundation
import Network
import Darwin

// MARK: - 局域网上传（手机浏览器 → 当前曲库目录）

/// 上传过程中的事件。由连接线程投递回主线程更新界面。
enum LanUploadEvent {
    case log(String)
    case error(String)
    case transferStarted(name: String, total: Int64)
    case transferProgress(name: String, sent: Int64, total: Int64)
    case fileSaved(String)
    case requestFinished
}

/// 上传日志（弹窗里展示最近若干条）
struct LanUploadLogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
    let isError: Bool
}

/// 正在接收的文件
struct LanUploadTransfer: Identifiable {
    let id = UUID()
    let name: String
    var sent: Int64
    let total: Int64
    var fraction: Double { total > 0 ? min(1, Double(sent) / Double(total)) : 0 }
}

// MARK: - 服务

@MainActor
final class LanUploadServer: ObservableObject {
    static let shared = LanUploadServer()

    /// 局域网候选地址（en0 优先）
    struct LanAddress: Identifiable, Hashable {
        var id: String { ip }
        let name: String
        let ip: String
    }

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var token = ""
    @Published private(set) var addresses: [LanAddress] = []
    @Published var selectedAddress: String?
    @Published private(set) var logs: [LanUploadLogEntry] = []
    @Published private(set) var transfer: LanUploadTransfer?
    @Published private(set) var savedFiles: [String] = []
    @Published private(set) var uploadDirectory = ""
    @Published var errorMessage: String?

    /// 一批上传结束后回调（用于触发曲库增量扫描）
    var onFilesUploaded: (() -> Void)?

    private var listener: NWListener?
    private var liveConnections: [LanUploadConnection] = []
    private let queue = DispatchQueue(label: "com.dan.shengchao.lan-upload", qos: .userInitiated)
    private var rescanTask: Task<Void, Never>?

    private static let preferredPort: UInt16 = 8080
    private static let portProbeCount: UInt16 = 20

    // MARK: 生命周期

    /// 展示给手机访问的地址（带随机 token）
    var pageURL: String? {
        guard isRunning, let host = selectedAddress ?? addresses.first?.ip else { return nil }
        return "http://\(host):\(port)/\(token)"
    }

    func start() {
        guard !isRunning else { return }
        errorMessage = nil

        // 落盘目标 = 当前曲库扫描目录的第一个根目录
        guard let directory = AudioLibrary.shared.primaryLibraryRoot else {
            errorMessage = "还没有扫描任何音乐文件夹，请先点「扫描音乐」选择曲库目录"
            return
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            errorMessage = "曲库目录不可写：\(directory.path)"
            return
        }

        addresses = Self.lanAddresses()
        if selectedAddress == nil || !addresses.contains(where: { $0.ip == selectedAddress }) {
            selectedAddress = addresses.first?.ip
        }
        guard selectedAddress != nil else {
            errorMessage = "没有找到可用的局域网地址，请确认已连接 Wi-Fi 或网线"
            return
        }

        let newToken = Self.makeToken()
        guard let chosenPort = Self.firstFreePort(startingAt: Self.preferredPort) else {
            errorMessage = "端口 \(Self.preferredPort)–\(Self.preferredPort + Self.portProbeCount - 1) 都被占用，请关闭占用程序后重试"
            return
        }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: chosenPort)!)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.isRunning else { connection.cancel(); return }
                    self.accept(connection, token: newToken, destination: directory)
                }
            }

            self.token = newToken
            self.port = chosenPort
            self.uploadDirectory = directory.path
            self.listener = listener
            self.savedFiles = []
            self.logs = []
            listener.start(queue: queue)
            isRunning = true
            appendLog("服务已开启 · \(directory.lastPathComponent)")
            appendLog("等待手机访问 \(pageURL ?? "")")
        } catch {
            errorMessage = "监听端口失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        rescanTask?.cancel()
        rescanTask = nil
        listener?.cancel()
        listener = nil
        for connection in liveConnections { connection.cancel() }
        liveConnections.removeAll()
        isRunning = false
        transfer = nil
        appendLog("服务已停止")
    }

    func clearLogs() {
        logs.removeAll()
        savedFiles.removeAll()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .failed(let error):
            appendLog("监听失败：\(error.localizedDescription)", isError: true)
            errorMessage = "监听失败：\(error.localizedDescription)"
            stop()
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection, token: String, destination: URL) {
        let handler = LanUploadConnection(connection: connection,
                                          queue: queue,
                                          token: token,
                                          destination: destination,
                                          pageDirectory: uploadDirectory) { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
        handler.onClose = { [weak self, weak handler] in
            Task { @MainActor in
                guard let self, let handler else { return }
                self.liveConnections.removeAll { $0 === handler }
            }
        }
        liveConnections.append(handler)
        handler.start()
    }

    // MARK: 事件回主线程

    private func apply(_ event: LanUploadEvent) {
        switch event {
        case .log(let text):
            appendLog(text)
        case .error(let text):
            appendLog(text, isError: true)
        case .transferStarted(let name, let total):
            transfer = LanUploadTransfer(name: name, sent: 0, total: total)
        case .transferProgress(let name, let sent, let total):
            transfer = LanUploadTransfer(name: name, sent: sent, total: total)
        case .fileSaved(let name):
            transfer = nil
            savedFiles.insert(name, at: 0)
            if savedFiles.count > 30 { savedFiles.removeLast(savedFiles.count - 30) }
            appendLog("已保存 \(name)")
        case .requestFinished:
            transfer = nil
            scheduleRescan()
        }
    }

    /// 连续上传多个文件时合并为一次扫描；曲库正在扫描时顺延
    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            if AudioLibrary.shared.isScanning {
                self.scheduleRescan()
                return
            }
            self.appendLog("正在把新歌加入曲库…")
            self.onFilesUploaded?()
        }
    }

    private func appendLog(_ text: String, isError: Bool = false) {
        logs.insert(LanUploadLogEntry(time: Date(), text: text, isError: isError), at: 0)
        if logs.count > 60 { logs.removeLast(logs.count - 60) }
    }

    // MARK: 工具

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 探测可用端口：直接把 BSD socket bind 上去试一次
    private static func firstFreePort(startingAt base: UInt16) -> UInt16? {
        for offset in 0..<portProbeCount {
            let candidate = base + offset
            if isPortFree(candidate) { return candidate }
        }
        return nil
    }

    private static func isPortFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// 枚举局域网 IPv4：排除回环、虚拟网卡与自分配地址，en0 排最前
    static func lanAddresses() -> [LanAddress] {
        let virtualPrefixes = ["utun", "bridge", "awdl", "llw", "lo", "gif", "stf", "anpi", "ap", "vmenet", "vmnet"]
        var result: [LanAddress] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = current.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            guard !virtualPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }  // 自分配地址，连不上
            result.append(LanAddress(name: name, ip: ip))
        }

        result.sort { rank($0.name) < rank($1.name) }
        return result
    }

    private static func rank(_ interface: String) -> Int {
        if interface == "en0" { return 0 }
        if interface.hasPrefix("en") { return 1 }
        return 2
    }
}

// MARK: - 单条连接（HTTP/1.1 + multipart 流式解析）

final class LanUploadConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token: String
    private let destination: URL
    private let pageDirectory: String
    private let event: (LanUploadEvent) -> Void
    var onClose: (() -> Void)?

    private var buffer = Data()
    private var head: HTTPHead?
    private var parser: MultipartParser?
    private var receivedBytes: Int64 = 0
    private var bodyTotal: Int64 = 0
    private var closed = false
    private var finished = false

    /// 单个请求体上限（手机上传单曲，8GB 足够）
    private static let maxRequestBytes: Int64 = 8 * 1024 * 1024 * 1024
    private static let maxHeadBytes = 64 * 1024
    private static let receiveChunk = 512 * 1024

    init(connection: NWConnection,
         queue: DispatchQueue,
         token: String,
         destination: URL,
         pageDirectory: String,
         event: @escaping (LanUploadEvent) -> Void) {
        self.connection = connection
        self.queue = queue
        self.token = token
        self.destination = destination
        self.pageDirectory = pageDirectory
        self.event = event
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        connection.cancel()
        close()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunk) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receivedBytes += Int64(data.count)
                if self.receivedBytes > Self.maxRequestBytes {
                    self.respondJSON(413, "Payload Too Large", ["error": "文件超过 8GB 上限"])
                    return
                }
                self.buffer.append(data)
                self.consume()
            }
            if self.closed || self.finished { return }
            if let error {
                self.event(.error("连接中断：\(error.localizedDescription)"))
                self.close()
                return
            }
            if isComplete {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func consume() {
        if head == nil {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.maxHeadBytes {
                    respondJSON(431, "Request Header Fields Too Large", ["error": "请求头过大"])
                }
                return
            }
            let headData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let parsed = HTTPHead(data: headData) else {
                respondJSON(400, "Bad Request", ["error": "请求格式错误"])
                return
            }
            head = parsed
            guard prepare(parsed) else { return }
        }

        guard let parser else { return }
        let chunk = buffer
        buffer.removeAll(keepingCapacity: false)
        do {
            try parser.feed(chunk)
        } catch {
            parser.abort()
            respondJSON(500, "Internal Server Error", ["error": "写入失败：\(error.localizedDescription)"])
            return
        }
        if parser.isFinished {
            finished = true
            let names = parser.savedFileNames
            event(.requestFinished)
            respondJSON(200, "OK", ["ok": true, "saved": names])
        }
    }

    /// 返回 false 表示请求已在头部阶段处理完毕
    private func prepare(_ head: HTTPHead) -> Bool {
        let path = head.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? head.path

        guard path == "/\(token)" || path == "/\(token)/" else {
            if path == "/\(token)/upload" {
                return prepareUpload(head)
            }
            respondJSON(404, "Not Found", ["error": "无效地址，请使用 App 里显示的链接"])
            return false
        }

        guard head.method == "GET" else {
            respondJSON(405, "Method Not Allowed", ["error": "只支持 GET"])
            return false
        }
        respond(200, "OK", contentType: "text/html; charset=utf-8",
                body: Data(Self.pageHTML(directory: pageDirectory).utf8))
        return false
    }

    private func prepareUpload(_ head: HTTPHead) -> Bool {
        guard head.method == "POST" else {
            respondJSON(405, "Method Not Allowed", ["error": "只支持 POST"])
            return false
        }
        guard let contentType = head.headers["content-type"],
              contentType.lowercased().contains("multipart/form-data"),
              let boundary = Self.boundary(from: contentType), !boundary.isEmpty else {
            respondJSON(400, "Bad Request", ["error": "需要 multipart/form-data"])
            return false
        }

        bodyTotal = Int64(head.headers["content-length"] ?? "") ?? 0
        if bodyTotal > 0, !Self.hasFreeSpace(at: destination, needed: bodyTotal) {
            respondJSON(507, "Insufficient Storage", ["error": "电脑磁盘可用空间不足"])
            return false
        }

        // 大文件客户端可能先发 Expect: 100-continue
        if let expect = head.headers["expect"], expect.lowercased().contains("100-continue") {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
        }

        parser = MultipartParser(boundary: boundary, destination: destination) { [weak self] item in
            guard let self else { return }
            switch item {
            case .fileStarted(let name):
                self.event(.transferStarted(name: name, total: self.bodyTotal))
            case .progress(let name, let written):
                self.event(.transferProgress(name: name, sent: written, total: self.bodyTotal))
            case .saved(let url):
                self.event(.fileSaved(url.lastPathComponent))
            }
        }
        return true
    }

    private static func boundary(from contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=") else { return nil }
        var value = String(contentType[range.upperBound...])
        if value.hasPrefix("\"") {
            value.removeFirst()
            if let end = value.firstIndex(of: "\"") { value = String(value[..<end]) }
        } else if let end = value.firstIndex(of: ";") {
            value = String(value[..<end])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func hasFreeSpace(at directory: URL, needed: Int64) -> Bool {
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return true }
        return available > needed
    }

    // MARK: 响应

    private func respondJSON(_ status: Int, _ reason: String, _ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        respond(status, reason, contentType: "application/json; charset=utf-8", body: data)
    }

    private func respond(_ status: Int, _ reason: String, contentType: String, body: Data) {
        guard !closed else { return }
        closed = true
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func close() {
        parser?.abort()
        parser = nil
        guard !closed else {
            if !finished { connection.cancel() }
            onClose?()
            return
        }
        closed = true
        connection.cancel()
        onClose?()
    }
}

// MARK: - 请求头

struct HTTPHead {
    let method: String
    let path: String
    let headers: [String: String]

    init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        path = String(parts[1])

        var parsed: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { parsed[key] = value }
        }
        headers = parsed
    }
}

// MARK: - multipart 流式解析（边收边写盘，不整段驻留内存）

final class MultipartParser {
    enum ParserError: LocalizedError {
        case malformed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let text): return text
            case .writeFailed(let text): return text
            }
        }
    }

    enum Item {
        case fileStarted(String)
        case progress(String, Int64)
        case saved(URL)
    }

    private enum State { case preamble, boundaryTail, headers, body, finished }

    private let firstBoundary: Data
    private let nextBoundary: Data
    private let crlf = Data("\r\n".utf8)
    private let dashDash = Data("--".utf8)
    private let headerTerminator = Data("\r\n\r\n".utf8)
    private let destination: URL
    private let onItem: (Item) -> Void

    private var buffer = Data()
    private var state: State = .preamble
    private var currentName: String?
    private var currentTarget: URL?
    private var currentTemp: URL?
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var lastReported: Int64 = 0
    private var savedURLs: [URL] = []

    /// 进度上报节流（每 512KB 一次，避免刷爆主线程）
    private static let progressStep: Int64 = 512 * 1024
    private static let maxHeaderBytes = 64 * 1024

    init(boundary: String, destination: URL, onItem: @escaping (Item) -> Void) {
        self.firstBoundary = Data("--\(boundary)".utf8)
        self.nextBoundary = Data("\r\n--\(boundary)".utf8)
        self.destination = destination
        self.onItem = onItem
    }

    var isFinished: Bool { state == .finished }

    var savedFileNames: [String] { savedURLs.map { $0.lastPathComponent } }

    func feed(_ data: Data) throws {
        guard state != .finished else { return }
        if !data.isEmpty { buffer.append(data) }
        try pump()
    }

    /// 连接中断/出错时清理未完成的临时文件
    func abort() {
        try? handle?.close()
        handle = nil
        if let temp = currentTemp { try? FileManager.default.removeItem(at: temp) }
        currentTemp = nil
        currentTarget = nil
        currentName = nil
    }

    // MARK: 状态机

    private func pump() throws {
        while true {
            switch state {
            case .finished:
                return

            case .preamble:
                guard let range = buffer.range(of: firstBoundary) else {
                    // 保留可能被截断的边界前缀，其余丢弃
                    let keep = max(0, firstBoundary.count - 1)
                    if buffer.count > keep { buffer.removeFirst(buffer.count - keep) }
                    return
                }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                state = .boundaryTail

            case .boundaryTail:
                guard buffer.count >= 2 else { return }
                let two = buffer.prefix(2)
                if two == dashDash {
                    buffer.removeFirst(2)
                    state = .finished
                    try finishFile()
                    return
                }
                guard two == crlf else { throw ParserError.malformed("分片边界格式错误") }
                buffer.removeFirst(2)
                state = .headers

            case .headers:
                guard let range = buffer.range(of: headerTerminator) else {
                    if buffer.count > Self.maxHeaderBytes { throw ParserError.malformed("分片头过大") }
                    return
                }
                let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                if let name = MultipartParser.fileName(in: headerData), !name.isEmpty {
                    try beginFile(named: name)
                } else {
                    currentName = nil  // 普通表单字段，丢弃内容
                }
                state = .body

            case .body:
                if let range = buffer.range(of: nextBoundary) {
                    let chunk = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                    try append(chunk)
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    try finishFile()
                    state = .boundaryTail
                } else {
                    // 边界可能被截断在缓冲区尾部，保留 len+2 字节再刷盘
                    let keep = nextBoundary.count + 2
                    guard buffer.count > keep else { return }
                    let end = buffer.index(buffer.startIndex, offsetBy: buffer.count - keep)
                    let chunk = buffer.subdata(in: buffer.startIndex..<end)
                    try append(chunk)
                    buffer.removeSubrange(buffer.startIndex..<end)
                    return
                }
            }
        }
    }

    // MARK: 落盘

    private func beginFile(named raw: String) throws {
        let name = MultipartParser.sanitize(raw)
        let target = destination.appendingPathComponent(name)
        let temp = destination.appendingPathComponent(".shengchao-upload-\(UUID().uuidString).part")

        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let fileHandle = FileHandle(forWritingAtPath: temp.path) else {
            throw ParserError.writeFailed("无法在曲库目录创建文件")
        }

        currentName = name
        currentTarget = target
        currentTemp = temp
        handle = fileHandle
        written = 0
        lastReported = 0
        onItem(.fileStarted(name))
    }

    private func append(_ chunk: Data) throws {
        guard let handle, !chunk.isEmpty else { return }
        do {
            try handle.write(contentsOf: chunk)
        } catch {
            throw ParserError.writeFailed(error.localizedDescription)
        }
        written += Int64(chunk.count)
        if written - lastReported >= Self.progressStep {
            lastReported = written
            onItem(.progress(currentName ?? "", written))
        }
    }

    private func finishFile() throws {
        guard let temp = currentTemp, let target = currentTarget else {
            handle = nil
            return
        }
        try? handle?.close()
        handle = nil

        // rename 原子覆盖同名文件（YH 要求：已有文件直接覆盖）
        if rename(temp.path, target.path) != 0 {
            let message = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temp)
            currentTemp = nil
            currentTarget = nil
            currentName = nil
            throw ParserError.writeFailed(message)
        }

        onItem(.progress(currentName ?? target.lastPathComponent, written))
        savedURLs.append(target)
        onItem(.saved(target))

        currentTemp = nil
        currentTarget = nil
        currentName = nil
        written = 0
        lastReported = 0
    }

    // MARK: 头部与文件名

    private static func fileName(in headerData: Data) -> String? {
        let text = String(data: headerData, encoding: .utf8)
            ?? String(data: headerData, encoding: .isoLatin1)
        guard let text else { return nil }

        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "content-disposition" else { continue }
            let value = line[line.index(after: colon)...]

            // filename* 优先（RFC 5987），回退 filename
            if let encoded = attribute(in: value, name: "filename*") {
                return decodeRFC5987(encoded)
            }
            if let plain = attribute(in: value, name: "filename") {
                return plain.removingPercentEncoding ?? plain
            }
        }
        return nil
    }

    private static func attribute(in header: Substring, name: String) -> String? {
        guard let range = header.range(of: name + "=") else { return nil }
        let rest = header[range.upperBound...]
        if rest.hasPrefix("\"") {
            let inner = rest.dropFirst()
            guard let end = inner.firstIndex(of: "\"") else { return String(inner) }
            return String(inner[..<end])
        }
        let end = rest.firstIndex(of: ";") ?? rest.endIndex
        return rest[..<end].trimmingCharacters(in: .whitespaces)
    }

    private static func decodeRFC5987(_ value: String) -> String {
        var text = value
        if let separator = text.range(of: "''") {
            text = String(text[separator.upperBound...])
        }
        return text.removingPercentEncoding ?? text
    }

    /// 去路径、去控制字符、截断长度；同名文件由 rename 覆盖
    static func sanitize(_ raw: String) -> String {
        var name = raw
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: slash)...])
        }
        name = name.replacingOccurrences(of: ":", with: "-")
        name = name.components(separatedBy: CharacterSet.controlCharacters).joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }

        if name.isEmpty {
            name = "未命名-\(Int(Date().timeIntervalSince1970)).mp3"
        }
        if name.count > 180 {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            name = String(base.prefix(150)) + (ext.isEmpty ? "" : "." + ext)
        }
        return name
    }
}

// MARK: - 手机端网页

extension LanUploadConnection {
    static func pageHTML(directory: String) -> String {
        let escaped = directory
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="dark">
        <title>声潮 · 上传音乐</title>
        <style>
        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        body {
          margin: 0; padding: 22px 16px 44px; min-height: 100vh; color: #fff;
          font: 15px/1.5 -apple-system, "PingFang SC", "Helvetica Neue", sans-serif;
          background: radial-gradient(circle at 20% 0%, #1d2740 0%, #0b0e17 55%, #05070c 100%);
        }
        h1 { font-size: 22px; margin: 0 0 6px; letter-spacing: 2px; }
        .sub { color: rgba(255,255,255,.55); font-size: 12px; margin: 0 0 24px; word-break: break-all; }
        .pick {
          display: block; text-align: center; padding: 17px; border-radius: 18px;
          font-weight: 600; font-size: 16px; color: #fff;
          background: linear-gradient(180deg, rgba(90,150,255,.95), rgba(20,90,240,.95));
          box-shadow: 0 6px 22px rgba(30,90,220,.35);
        }
        .pick:active { transform: scale(.98); }
        input[type=file] { display: none; }
        .row { margin-top: 14px; padding: 12px 14px; border-radius: 14px; background: rgba(255,255,255,.07); }
        .name { font-size: 13px; word-break: break-all; margin-bottom: 8px; }
        .bar { height: 6px; border-radius: 3px; background: rgba(255,255,255,.14); overflow: hidden; }
        .bar i { display: block; height: 100%; width: 0; border-radius: 3px;
                 background: linear-gradient(90deg, #4f9dff, #7ee0ff); transition: width .15s; }
        .st { margin-top: 6px; font-size: 11px; color: rgba(255,255,255,.55); }
        .st.ok { color: #6ee7a0; }
        .st.bad { color: #ff8a8a; }
        .tip { margin-top: 28px; font-size: 12px; color: rgba(255,255,255,.45); line-height: 1.8; }
        </style>
        </head>
        <body>
        <h1>声潮</h1>
        <p class="sub">局域网上传 · 目标目录<br>\(escaped)</p>
        <label class="pick" for="f">选择音乐文件</label>
        <input id="f" type="file" multiple accept=".flac,.m4a,.alac,.wav,.aiff,.aif,.caf,.mp3,.aac,.cue,audio/*">
        <div id="list"></div>
        <p class="tip">手机需与电脑连接同一个 Wi-Fi，可一次选择多首。<br>上传完成后会自动加入曲库；同名文件将被覆盖。</p>
        <script>
        var input = document.getElementById('f');
        var list = document.getElementById('list');
        input.addEventListener('change', function () {
          var files = Array.prototype.slice.call(input.files);
          input.value = '';
          var chain = Promise.resolve();
          files.forEach(function (file) {
            chain = chain.then(function () { return send(file); });
          });
        });
        function fmt(n) {
          if (n < 1024) return n + ' B';
          if (n < 1048576) return (n / 1024).toFixed(0) + ' KB';
          if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
          return (n / 1073741824).toFixed(2) + ' GB';
        }
        function send(file) {
          return new Promise(function (resolve) {
            var row = document.createElement('div');
            row.className = 'row';
            var name = document.createElement('div');
            name.className = 'name';
            name.textContent = file.name;
            var bar = document.createElement('div');
            bar.className = 'bar';
            var fill = document.createElement('i');
            bar.appendChild(fill);
            var st = document.createElement('div');
            st.className = 'st';
            st.textContent = '等待上传…';
            row.appendChild(name); row.appendChild(bar); row.appendChild(st);
            list.appendChild(row);

            var xhr = new XMLHttpRequest();
            xhr.open('POST', 'upload');
            xhr.upload.onprogress = function (e) {
              if (!e.lengthComputable) return;
              fill.style.width = (e.loaded / e.total * 100).toFixed(1) + '%';
              st.textContent = fmt(e.loaded) + ' / ' + fmt(e.total);
            };
            xhr.onload = function () {
              if (xhr.status === 200) {
                fill.style.width = '100%';
                st.className = 'st ok';
                st.textContent = '已上传';
              } else {
                st.className = 'st bad';
                st.textContent = '失败：' + (xhr.responseText || xhr.status);
              }
              resolve();
            };
            xhr.onerror = function () {
              st.className = 'st bad';
              st.textContent = '网络错误，请确认手机仍与电脑在同一 Wi-Fi';
              resolve();
            };
            var form = new FormData();
            form.append('files', file, file.name);
            xhr.send(form);
          });
        }
        </script>
        </body>
        </html>
        """
    }
}
