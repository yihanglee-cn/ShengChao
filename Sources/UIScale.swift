import SwiftUI

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

    /// 字体：按倍率缩放，并吸附到 0.5pt（避免大量非整数磅值导致字距毛糙）
    func fs(_ base: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: snap(base * factor, step: 0.5), weight: weight, design: design)
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
    /// 计算属性（而非 let）：兜底读取最新档位，避免常量被首次访问后永久缓存
    static var defaultValue: UIScaleOption { UIScaleOption.current }
}

extension EnvironmentValues {
    /// 当前界面缩放档位。视图读取它即可在档位切换时自动重新布局。
    var uiScale: UIScaleOption {
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
