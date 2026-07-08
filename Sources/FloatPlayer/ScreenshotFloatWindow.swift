import AppKit
import UniformTypeIdentifiers

/// スクリーンショット画像だけを表示する、UIなしのフローティングウィンドウ。
/// ドラッグで移動でき、右クリックで閉じる/保存/コピーができる。
@MainActor
final class ScreenshotFloatWindow: NSObject {
    private var panel: NSPanel!
    private var image: NSImage!
    var onClose: (() -> Void)?

    init(image: NSImage) {
        super.init()
        setup(image: image)
    }

    private func setup(image: NSImage) {
        self.image = image

        let maxDimension: CGFloat = 420
        let largestSide = max(image.size.width, image.size.height)
        let scale = largestSide > maxDimension ? maxDimension / largestSide : 1
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let menu = NSMenu()
        menu.addItem(withTitle: "閉じる", action: #selector(closeSelf), keyEquivalent: "").target = self
        menu.addItem(withTitle: "名前を付けて保存…", action: #selector(saveAs), keyEquivalent: "").target = self
        menu.addItem(withTitle: "コピー", action: #selector(copyImage), keyEquivalent: "").target = self
        imageView.menu = menu

        let newPanel = NSPanel(
            contentRect: NSRect(origin: Self.nextSpawnPoint(), size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // UIが何もなく画像だけなので、背景をそのままドラッグして動かせる
        newPanel.isMovableByWindowBackground = true
        newPanel.isReleasedWhenClosed = false
        newPanel.contentView = imageView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: newPanel
        )

        newPanel.makeKeyAndOrderFront(nil)
        panel = newPanel
    }

    // 複数回連続でスクリーンショットを撮っても重ならないよう、少しずつ位置をずらす
    private static var lastSpawnIndex = 0
    private static func nextSpawnPoint() -> NSPoint {
        defer { lastSpawnIndex += 1 }
        let offset = CGFloat((lastSpawnIndex % 6) * 32)
        return NSPoint(x: 220 + offset, y: 420 - offset)
    }

    @objc private func windowWillClose() {
        onClose?()
    }

    @objc private func closeSelf() {
        panel.close()
    }

    @objc private func saveAs() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "スクリーンショット.png"
        guard savePanel.runModal() == .OK, let url = savePanel.url,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
