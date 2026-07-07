import AppKit
import SwiftUI

/// タイトルバーを隠しているため、コンテンツ上のどこからでも
/// ウィンドウをドラッグ移動できるようにするための透明な帯
struct DragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
