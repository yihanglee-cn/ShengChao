import SwiftUI
import AppKit

// MARK: - 界面缩放（大屏 / 电视远距离观看）

/// 界面缩放档位。
///
/// 声潮原有界面按「标准」档设计：所有字号、间距、封面尺寸都在此处按倍率等比放大。
/// 每个档位同时驱动两类缩放：
/// - 字体：`ui.fs(16, .semibold)`
/// - 尺寸与间距：`ui.s(14)`
///
/// 「标准」档倍率为 1.0，且取整步长能保证所有原始数值不变，
/// 因此升级后默认外观与旧版**完全一致**。
enum UIScaleOption: String, CaseIterable, Identifiable {
    case standard
    case large
    case xlarge
    case television

    /// UserDefaults 键（与 @AppStorage 共用）
    static let storageKey = "uiScale"

    var id: String { rawValue }

    /// 当前档位（用于无法读取环境的场合，如 NSViewRepresentable、全局几何常量）
    static var current: UIScaleOption {
        UIScaleOption(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .standard
    }

    var title: String {
        switch self {
        case .standard: return "标准"
        case .large: return "大"
        case .xlarge: return "特大"
        case .television: return "电视"
        }
    }

    /// 设置面板里的一句话说明
    var caption: String {
        switch self {
        case .standard: return "默认大小，适合显示器近距离使用"
        case .large: return "放大 15%，适合稍远的观看距离"
        case .xlarge: return "放大 30%，适合 2 米左右"
        case .television: return "放大 50%，适合接电视 / 投影远距离观看"
        }
    }

    /// 相对「标准」档的缩放倍率
    var factor: CGFloat {
        switch self {
        case .standard: return 1.0
        case .large: return 1.15
        case .xlarge: return 1.3
        case .television: return 1.5
        }
    }

    /// 字号按倍率缩放，并吸附到 0.5pt（避免大量非整数磅值导致字距毛糙）
    func scaledSize(_ base: CGFloat) -> CGFloat {
        snap(base * factor, step: 0.5)
    }

    /// 尺寸 / 间距 / 圆角：按倍率缩放，吸附到 1pt
    func s(_ base: CGFloat) -> CGFloat {
        snap(base * factor, step: 1)
    }

    /// 主界面左侧（侧边栏）宽度。
    ///
    /// 界面整体等比放大时，若侧边栏也按同一倍率变宽，放大档位下左侧区域会显得
    /// 过宽、占比过大（用户反馈）。这里让侧边栏随档位只按整体倍率的一半步长放大
    /// 并设上限封顶，使大档位下左侧区域相对收窄、占窗口比例变小，
    /// 同时保证内部文字（放大后）仍能完整放下。
    var sidebarWidth: CGFloat {
        let base: CGFloat = 210
        // 折减缩放：整体每放大 10%，侧边栏仅放大 5%
        let gentle = 1 + (factor - 1) * 0.5
        // 上限封顶，避免电视等更远档位下侧边栏无限变宽
        return min(snap(base * gentle, step: 1), 260)
    }

    private func snap(_ value: CGFloat, step: CGFloat) -> CGFloat {
        (value / step).rounded() * step
    }
}

// MARK: - 界面字体（从系统已安装字体里挑一个）

/// 界面字体选择：只存字体族名，空字符串表示跟随系统。
///
/// 只换字面（typeface），不动字号——字号仍由界面缩放档位与各自的布局决定。
/// 所选字体缺字时（例如纯英文字体遇到中文）由系统自动回退，不会出现豆腐块。
enum AppFont {
    /// UserDefaults 键（与 @AppStorage 共用）
    static let storageKey = "appFontFamily"

    /// 跟随系统字体
    static let systemDefault = ""

    /// 设置面板里「跟随系统」那一项的标题
    static let systemDefaultTitle = "跟随系统"

    /// 当前选择（用于无法读取环境的场合）
    static var currentFamily: String {
        UserDefaults.standard.string(forKey: storageKey) ?? systemDefault
    }

    /// 系统已安装的字体族（按本地化顺序排好，只算一次）
    static let families: [String] = NSFontManager.shared.availableFontFamilies
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    /// 解析缓存：族名 + 字重 -> PostScript 名（空串代表解析失败，同样缓存避免反复失败）
    private static var faceCache: [String: String] = [:]

    /// 取某族在指定字重下最接近的字面。
    /// 族不存在、或该族一个可用字面都没有时返回 nil，调用方回退系统字体。
    static func faceName(family: String, weight: Font.Weight) -> String? {
        guard !family.isEmpty else { return nil }
        let key = "\(family)|\(weightTag(weight))"
        if let cached = faceCache[key] { return cached.isEmpty ? nil : cached }
        let resolved = resolveFace(family: family, weight: weight) ?? ""
        faceCache[key] = resolved
        return resolved.isEmpty ? nil : resolved
    }

    /// 某族的常规字面（设置面板里用它实时预览字体长相）
    static func previewName(family: String) -> String? {
        faceName(family: family, weight: .regular)
    }

    /// 在族内按字重距离挑最近的字面。
    ///
    /// 不用 NSFontManager 那套 0~15 的整数权重（含义随系统版本漂移），
    /// 而是逐个字面读 `NSFontDescriptor` 的 weight 轴（-1 ~ 1）比对，
    /// 这样「没有真粗体」的族（如 PingFang SC）也能稳定落到 Semibold。
    private static func resolveFace(family: String, weight: Font.Weight) -> String? {
        let target = nsWeight(weight)
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family) else {
            return nil
        }
        var best: (name: String, distance: CGFloat)?
        for member in members {
            guard let psName = member.first as? String,
                  let font = NSFont(name: psName, size: 12) else { continue }
            let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            let faceWeight = (traits?[.weight] as? CGFloat) ?? 0
            let distance = abs(faceWeight - target)
            if best == nil || distance < best!.distance {
                best = (psName, distance)
            }
        }
        return best?.name
    }

    /// SwiftUI 字重 -> NSFontDescriptor 的 weight 轴取值
    private static func nsWeight(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight: return -0.8
        case .thin: return -0.6
        case .light: return -0.4
        case .regular: return 0
        case .medium: return 0.23
        case .semibold: return 0.3
        case .bold: return 0.4
        case .heavy: return 0.56
        case .black: return 0.62
        default: return 0
        }
    }

    private static func weightTag(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight: return "ultraLight"
        case .thin: return "thin"
        case .light: return "light"
        case .regular: return "regular"
        case .medium: return "medium"
        case .semibold: return "semibold"
        case .bold: return "bold"
        case .heavy: return "heavy"
        case .black: return "black"
        default: return "regular"
        }
    }
}

// MARK: - 界面度量 + 字体（环境值）

/// 环境里统一下发的界面度量：缩放档位 + 界面字体。
///
/// 调用方写法不变（`ui.fs(16, .semibold)` / `ui.s(14)`），
/// 字体族在这里统一生效，因此改一个地方就能换掉整个 App 的字面。
struct UIScale: Equatable {
    var option: UIScaleOption = .standard
    /// 空字符串 = 跟随系统字体
    var fontFamily: String = AppFont.systemDefault

    var factor: CGFloat { option.factor }

    /// 尺寸 / 间距 / 圆角：按倍率缩放
    func s(_ base: CGFloat) -> CGFloat { option.s(base) }

    /// 主界面左侧宽度
    var sidebarWidth: CGFloat { option.sidebarWidth }

    /// 界面文字：字号按档位缩放，字面按用户选择
    func fs(_ base: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        font(size: option.scaledSize(base), weight: weight, design: design)
    }

    /// 播放页文字（歌名 / 歌词 / 封面控件）：字号由调用方自己算，
    /// 这里只换字面、不再乘倍率，避免与全屏布局自带的缩放叠加。
    func rawFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        font(size: size, weight: weight, design: design)
    }

    private func font(size: CGFloat, weight: Font.Weight, design: Font.Design) -> Font {
        if let psName = AppFont.faceName(family: fontFamily, weight: weight) {
            // 自选字体时忽略 design（.rounded / .monospaced 是系统字体的变体，对自定义字体无意义）
            return .custom(psName, size: size)
        }
        return .system(size: size, weight: weight, design: design)
    }
}

/// SwiftUI 语义字体的 macOS 基准磅值。
///
/// 实测（`NSFont.preferredFont(forTextStyle:)` 与 SwiftUI 语义字体渲染宽度完全一致）：
/// body = 13、caption = 10、subheadline = 11、title2 = 17、largeTitle = 26 …
///
/// 之所以把语义字体也换成基准磅值，有两个原因：
/// 1. macOS 上 `.dynamicTypeSize` 对语义字体**完全无效**（实测三种档位渲染宽度一模一样），
///    指望系统动态字体放大在这条路上走不通；
/// 2. 统一成显式磅值后，全部文字都受界面缩放档位控制，比例关系可预期。
enum FB {
    static let largeTitle: CGFloat = 26
    static let title: CGFloat = 22
    static let title2: CGFloat = 17
    static let title3: CGFloat = 15
    /// headline 在 macOS 上即 13pt semibold
    static let headline: CGFloat = 13
    static let body: CGFloat = 13
    static let callout: CGFloat = 12
    static let subheadline: CGFloat = 11
    static let footnote: CGFloat = 10
    static let caption: CGFloat = 10
    static let caption2: CGFloat = 10
}

private struct UIScaleKey: EnvironmentKey {
    /// 计算属性（而非 let）：兜底读取最新档位与字体，避免常量被首次访问后永久缓存
    static var defaultValue: UIScale {
        UIScale(option: UIScaleOption.current, fontFamily: AppFont.currentFamily)
    }
}

extension EnvironmentValues {
    /// 当前界面缩放档位与界面字体。视图读取它即可在切换时自动重新布局。
    var uiScale: UIScale {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

// MARK: - 主窗口探测（切换档位时按比例调整窗口尺寸）

/// 上报 SwiftUI 视图所在的宿主窗口，避免靠窗口标题猜测。
struct HostWindowProbe: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

// MARK: - 设置里的「界面缩放」行（主设置面板与旧版设置窗口共用）

struct UIScalePickerRow: View {
    @Environment(\.uiScale) private var ui
    @Environment(\.theme) private var theme
    @AppStorage(UIScaleOption.storageKey) private var raw = UIScaleOption.standard.rawValue

    private var option: UIScaleOption { UIScaleOption(rawValue: raw) ?? .standard }

    var body: some View {
        VStack(alignment: .leading, spacing: ui.s(8)) {
            VStack(alignment: .leading, spacing: ui.s(2)) {
                Text("界面缩放")
                    .foregroundStyle(theme.primaryText)
                Text(option.caption)
                    .font(ui.fs(FB.caption))
                    .foregroundStyle(theme.secondaryText)
            }
            Picker("", selection: $raw) {
                ForEach(UIScaleOption.allCases) { item in
                    Text(item.title).tag(item.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("放大整个界面的字号与控件，适合接电视远距离观看")
        }
    }
}

// MARK: - 设置里的「界面字体」行（下拉 + 搜索 + 实时预览）

/// 字体选择器：下拉列表里每个字体名都用它自己的字面渲染（字体册那种预览），
/// 顶部带搜索框（系统可能装着两三百个族），第一项是「跟随系统」。
struct FontPickerRow: View {
    @Environment(\.uiScale) private var ui
    @Environment(\.theme) private var theme
    @AppStorage(AppFont.storageKey) private var family = AppFont.systemDefault
    @State private var expanded = false
    @State private var query = ""

    private var filtered: [String] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return AppFont.families }
        return AppFont.families.filter { $0.localizedCaseInsensitiveContains(keyword) }
    }

    /// 字体名用它自己的字面渲染，选之前就能看出长什么样
    private func previewFont(_ name: String, size: CGFloat) -> Font {
        guard let psName = AppFont.previewName(family: name) else { return .system(size: size) }
        return .custom(psName, size: size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ui.s(8)) {
            VStack(alignment: .leading, spacing: ui.s(2)) {
                Text("界面字体")
                    .foregroundStyle(theme.primaryText)
                Text(family.isEmpty ? "当前跟随系统字体" : "当前：\(family)")
                    .font(ui.fs(FB.caption))
                    .foregroundStyle(theme.secondaryText)
            }

            // 收起状态：一行当前字体（用它自己的字面渲染）
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: ui.s(8)) {
                    Text(family.isEmpty ? AppFont.systemDefaultTitle : family)
                        .font(family.isEmpty ? ui.fs(FB.body) : previewFont(family, size: ui.s(13)))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(ui.fs(9, .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(.horizontal, ui.s(10))
                // 固定高度：下拉浮层靠它定位，避免依赖文字高度
                .frame(height: ui.s(30))
                .background(RoundedRectangle(cornerRadius: ui.s(8), style: .continuous)
                    .fill(theme.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: ui.s(8), style: .continuous)
                    .stroke(theme.hairline, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                dropdown
            }
        }
        .help("换掉整个界面的字面（字号仍由「界面缩放」控制）；所选字体缺字时系统会自动回退")
    }

    private var dropdown: some View {
        VStack(spacing: ui.s(6)) {
            TextField("搜索字体", text: $query)
                .textFieldStyle(.plain)
                .font(ui.fs(FB.caption))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, ui.s(9))
                .frame(height: ui.s(24))
                .background(RoundedRectangle(cornerRadius: ui.s(7), style: .continuous)
                    .fill(theme.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: ui.s(7), style: .continuous)
                    .stroke(theme.hairline, lineWidth: 1))

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    fontRow(title: AppFont.systemDefaultTitle,
                            value: AppFont.systemDefault,
                            previewName: nil)
                    ForEach(filtered, id: \.self) { name in
                        fontRow(title: name, value: name, previewName: name)
                    }
                }
                .padding(.vertical, ui.s(4))
            }
            .frame(height: ui.s(180))
            .background(RoundedRectangle(cornerRadius: ui.s(8), style: .continuous)
                .fill(theme.fieldFill))
            .overlay(RoundedRectangle(cornerRadius: ui.s(8), style: .continuous)
                .stroke(theme.hairline, lineWidth: 1))
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func fontRow(title: String, value: String, previewName: String?) -> some View {
        Button {
            family = value
            withAnimation(.easeInOut(duration: 0.15)) { expanded = false }
        } label: {
            HStack(spacing: ui.s(6)) {
                Text(title)
                    .font(previewName.map { previewFont($0, size: ui.s(13)) } ?? ui.fs(13))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if family == value {
                    Image(systemName: "checkmark")
                        .font(ui.fs(9, .bold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, ui.s(9))
            .padding(.vertical, ui.s(5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(family == value ? theme.selectionFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
