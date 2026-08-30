import AppKit
import SwiftUI

// 只调整系统滚动条滑块样式（深色），保留系统原生的自动显示/隐藏
struct ScrollbarStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        if let scrollView = view.enclosingScrollView {
            scrollView.verticalScroller?.knobStyle = .dark
            scrollView.horizontalScroller?.knobStyle = .dark
        } else {
            DispatchQueue.main.async { [weak view] in
                if let sv = view?.enclosingScrollView {
                    sv.verticalScroller?.knobStyle = .dark
                    sv.horizontalScroller?.knobStyle = .dark
                }
            }
        }
    }
}
