import AppKit
import SwiftUI

// 只调整系统滚动条滑块样式，保留系统原生的自动显示/隐藏。
// 浅色底要配深色滑块、深色底要配浅色滑块，否则滑块跟底色同色会看不见。
struct ScrollbarStyler: NSViewRepresentable {
    var isDay: Bool = true

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        let knob: NSScroller.KnobStyle = isDay ? .dark : .light
        if let scrollView = view.enclosingScrollView {
            scrollView.verticalScroller?.knobStyle = knob
            scrollView.horizontalScroller?.knobStyle = knob
        } else {
            DispatchQueue.main.async { [weak view] in
                if let sv = view?.enclosingScrollView {
                    sv.verticalScroller?.knobStyle = knob
                    sv.horizontalScroller?.knobStyle = knob
                }
            }
        }
    }
}
