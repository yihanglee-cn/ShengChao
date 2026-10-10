import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - 局域网上传弹窗

/// 顶栏「上传」按钮打开的弹窗：开启局域网服务、展示手机访问链接与二维码、
/// 实时显示上传进度与结果。
struct LanUploadPanel: View {
    @Environment(\.uiScale) private var ui
    @Environment(\.theme) private var theme
    @ObservedObject private var server = LanUploadServer.shared
    @Binding var show: Bool
    @State private var hoveringClose = false
    @State private var copied = false

    var body: some View {
        ZStack {
            // 点击空白处关闭
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            card
        }
        .onDisappear { releaseFirstResponder() }
    }

    // MARK: 卡片

    private var card: some View {
        VStack(alignment: .leading, spacing: ui.s(14)) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: ui.s(14)) {
                    if server.isRunning {
                        runningContent
                    } else {
                        stoppedContent
                    }
                }
                .padding(.trailing, ui.s(2))
            }
            .frame(maxHeight: ui.s(400))
        }
        .padding(ui.s(20))
        .frame(width: ui.s(380))
        // 跟设置面板一致：不透明底 + 描边 + 投影，随昼夜主题切换
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.panelBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(theme.isDay ? 0.16 : 0.45), radius: 26, y: 10)
        .padding(.top, ui.s(60))
    }

    private var header: some View {
        HStack(spacing: ui.s(8)) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(ui.fs(FB.headline, .semibold))
                .foregroundStyle(theme.primaryText)
            Text("局域网上传")
                .font(ui.fs(FB.headline, .semibold))
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 8)
            Circle()
                .fill(server.isRunning ? Color.green : Color.gray)
                .frame(width: ui.s(8), height: ui.s(8))
            Text(server.isRunning ? "运行中" : "未开启")
                .font(ui.fs(FB.caption))
                .foregroundStyle(theme.secondaryText)
            closeButton
        }
    }

    // MARK: 未开启

    private var stoppedContent: some View {
        VStack(alignment: .leading, spacing: ui.s(12)) {
            Text("开启后，手机连同一个 Wi-Fi，用浏览器打开链接即可上传歌曲到当前曲库目录。")
                .font(ui.fs(FB.subheadline))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let directory = currentDirectoryHint {
                infoRow(title: "目标目录", value: directory)
            }

            if let error = server.errorMessage {
                Text(error)
                    .font(ui.fs(FB.caption))
                    .foregroundStyle(theme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            primaryButton(title: "开启上传服务", systemImage: "wifi") {
                server.start()
            }
        }
    }

    // MARK: 运行中

    private var runningContent: some View {
        VStack(alignment: .leading, spacing: ui.s(14)) {
            if let url = server.pageURL {
                VStack(alignment: .leading, spacing: ui.s(8)) {
                    HStack(spacing: ui.s(6)) {
                        Text("手机浏览器打开")
                            .font(ui.fs(FB.caption))
                            .foregroundStyle(theme.secondaryText)
                        Spacer(minLength: 8)
                        Button {
                            copy(url)
                        } label: {
                            HStack(spacing: ui.s(4)) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "已复制" : "复制")
                            }
                            .font(ui.fs(FB.caption))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.secondaryText)
                    }

                    // 不用 .textSelection(.enabled)：可选中文本会变成 NSTextView 抢占
                    // 窗口 first responder，而全局键盘监视器「有文本框聚焦就放行」，
                    // 会导致空格/方向键/切歌全部失效且关掉弹窗也不恢复。复制用右侧按钮。
                    Text(url)
                        .font(.system(size: ui.s(14), weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Spacer()
                        qrView(url)
                        Spacer()
                    }
                    .padding(.top, ui.s(4))
                }
            }

            if server.addresses.count > 1 {
                // 不用原生 Picker：它跟随「系统」外观取色，系统浅色时会在深色弹窗上画成黑字。
                VStack(alignment: .leading, spacing: ui.s(6)) {
                    Text("网卡")
                        .font(ui.fs(FB.caption))
                        .foregroundStyle(theme.secondaryText)
                    ForEach(server.addresses) { address in
                        addressRow(address)
                    }
                    Text("手机连的 Wi-Fi 对应哪块网卡，就选哪一个")
                        .font(ui.fs(FB.caption2))
                        .foregroundStyle(theme.tertiaryText)
                }
            }

            infoRow(title: "目标目录", value: server.uploadDirectory)

            if let transfer = server.transfer {
                VStack(alignment: .leading, spacing: ui.s(5)) {
                    Text(transfer.name)
                        .font(ui.fs(FB.caption))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.linear)
                        .tint(Color(red: 0.35, green: 0.62, blue: 1.0))
                    Text("\(byteText(transfer.sent)) / \(byteText(transfer.total))")
                        .font(ui.fs(FB.caption2))
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(ui.s(10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.fieldFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !server.savedFiles.isEmpty {
                VStack(alignment: .leading, spacing: ui.s(5)) {
                    Text("已接收 \(server.savedFiles.count) 个文件")
                        .font(ui.fs(FB.caption))
                        .foregroundStyle(theme.secondaryText)
                    ForEach(server.savedFiles.prefix(5), id: \.self) { name in
                        Text(name)
                            .font(ui.fs(FB.caption2))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let last = server.logs.first {
                Text(last.text)
                    .font(ui.fs(FB.caption2))
                    .foregroundStyle(last.isError ? theme.errorText : theme.tertiaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: ui.s(10)) {
                primaryButton(title: "停止服务", systemImage: "stop.circle") {
                    server.stop()
                }
                ghostButton(title: "打开目录", systemImage: "folder") {
                    guard !server.uploadDirectory.isEmpty else { return }
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: server.uploadDirectory)
                }
            }

            Text("手机需与电脑在同一 Wi-Fi；若连不上，请确认路由器未开启「AP 隔离」，或换选另一块网卡。")
                .font(ui.fs(FB.caption2))
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 组件

    private func infoRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: ui.s(3)) {
            Text(title)
                .font(ui.fs(FB.caption))
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(ui.fs(FB.caption2))
                .foregroundStyle(theme.primaryText)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 网卡选择行的边框色：浅色底用深色描边、深色底用浅色描边
    private func borderColor(selected: Bool) -> Color {
        theme.isDay
            ? Color.black.opacity(selected ? 0.30 : 0.10)
            : Color.white.opacity(selected ? 0.32 : 0.10)
    }

    /// 网卡选择行：全部用主题色自绘，不碰系统控件配色
    private func addressRow(_ address: LanUploadServer.LanAddress) -> some View {
        let selected = (server.selectedAddress ?? server.addresses.first?.ip) == address.ip
        return HStack(spacing: ui.s(8)) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(ui.fs(FB.caption))
                .foregroundStyle(selected ? Color(red: 0.35, green: 0.62, blue: 1.0) : theme.tertiaryText)
            Text("\(address.name) · \(address.ip)")
                .font(ui.fs(FB.caption, selected ? .semibold : .regular))
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ui.s(10))
        .padding(.vertical, ui.s(6))
        .background(theme.fieldFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor(selected: selected), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { server.selectedAddress = address.ip }
    }

    private func primaryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: ui.s(6)) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(ui.fs(FB.subheadline, .medium))
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, ui.s(14))
            .padding(.vertical, ui.s(8))
        }
        .buttonStyle(.plain)
        .background(theme.fieldFill, in: Capsule())
        .overlay { Capsule().stroke(theme.hairline, lineWidth: 1) }
    }

    private func ghostButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: ui.s(6)) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(ui.fs(FB.subheadline, .medium))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, ui.s(14))
            .padding(.vertical, ui.s(8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func qrView(_ text: String) -> some View {
        if let image = Self.qrImage(for: text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: ui.s(150), height: ui.s(150))
                .padding(ui.s(8))
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Circle()
                .fill(Color(red: 1.0, green: 0.373, blue: 0.341))
                .frame(width: ui.s(12), height: ui.s(12))
                .overlay(
                    Image(systemName: "xmark")
                        .font(ui.fs(6.5, .bold))
                        .foregroundStyle(Color(red: 0.42, green: 0.05, blue: 0.05))
                )
                .opacity(hoveringClose ? 1 : 0)
        }
        .buttonStyle(.plain)
        .frame(width: ui.s(28), height: ui.s(28))
        .background(HoverDetector { hoveringClose = $0 })
        .animation(.easeInOut(duration: 0.15), value: hoveringClose)
        .help("关闭")
    }

    // MARK: 工具

    /// 未开启服务时也能提示将要写入的目录
    private var currentDirectoryHint: String? {
        AudioLibrary.shared.primaryLibraryRoot?.path
    }

    private func dismiss() {
        releaseFirstResponder()
        withAnimation(.easeInOut(duration: 0.15)) { show = false }
    }

    /// 弹窗内控件抢到的 first responder 必须交还窗口。
    /// 全局键盘监视器（ContentView）遇到 NSTextView/NSTextField 聚焦会放行所有按键，
    /// 若弹窗关掉后 responder 没还回去，空格/方向键/切歌/L/Z 会一直失效。
    private func releaseFirstResponder() {
        guard let window = NSApp.keyWindow, let responder = window.firstResponder else { return }
        if responder is NSTextView || responder is NSTextField {
            window.makeFirstResponder(nil)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func byteText(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// 生成二维码（供手机扫码直接打开上传页）
    static func qrImage(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // 小尺寸二维码直接整数倍放大，保证扫描清晰且边缘锐利
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
