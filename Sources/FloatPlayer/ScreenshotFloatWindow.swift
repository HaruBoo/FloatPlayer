import AppKit
import UniformTypeIdentifiers

/// 画像を描画しつつ、ドラッグ移動とスクロールでの透明度調整を自前で処理するビュー。
/// NSImageViewをそのまま使うと、画像のドラッグ書き出し用の既定の挙動が
/// mouseDownを奪ってしまい、ウィンドウの背景ドラッグ移動が効かなくなるため、
/// レイヤーに画像を描画するだけの軽量なビューとして自作している。
///
/// リサイズは自前実装せず、メインパネルと同じ.titled+.resizable(タイトルバーは
/// 透明・非表示にして見た目上はボーダーレスにする)によるAppKit標準の
/// edge-dragリサイズに任せている。以前.borderlessのままカーソル形状や
/// 自前の端判定でリサイズを実装しようとしたが、カーソル表示が環境によって
/// 反映されず、標準のリサイズ機構にも乗れなかったため、この方式に統一した。
private final class DraggableImageView: NSView {
    var onScrollOpacity: ((CGFloat) -> Void)?

    init(image: NSImage, frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // 縦横比を保たず自由に伸び縮みできるようにしたいので、
        // アスペクト比を保つ.resizeAspectではなく引き伸ばす.resizeにする
        layer?.contentsGravity = .resize
        layer?.contents = image
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // 見えているUIを増やさずに透明度を変えられるよう、スクロールで調整する
        onScrollOpacity?(event.scrollingDeltaY)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

/// 右クリック(トラックパッドの2本指クリック)で開くメニューに、
/// 透明度スライダーを埋め込んで表示するための小さなビュー。
private final class OpacityMenuItemView: NSView {
    init(initialValue: Double, onChange: @escaping (Double) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 28))

        let slider = NSSlider(value: initialValue, minValue: 0.15, maxValue: 1.0, target: nil, action: nil)
        slider.frame = NSRect(x: 14, y: 4, width: 172, height: 20)
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        addSubview(slider)
        self.onChange = onChange
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var onChange: ((Double) -> Void)?

    @objc private func sliderChanged(_ sender: NSSlider) {
        onChange?(sender.doubleValue)
    }
}

/// スクリーンショット画像だけを表示する、UIなしのフローティングウィンドウ。
/// 中央をドラッグして移動、端(標準のedge-dragリサイズ)で拡大縮小、
/// 右クリックのメニューに埋め込まれたスライダーまたはスクロールで透明度調整ができる。
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

        let imageView = DraggableImageView(image: image, frame: NSRect(origin: .zero, size: size))

        let newPanel = NSPanel(
            contentRect: NSRect(origin: Self.nextSpawnPoint(), size: size),
            // メインパネルと同じ組み合わせ。.titled+.resizableで標準のedge-drag
            // リサイズ(カーソル形状も含めて)を有効にしつつ、タイトルバー自体は
            // 透明・非表示・トラフィックライト非表示にして見た目はボーダーレスにする
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.standardWindowButton(.closeButton)?.isHidden = true
        newPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newPanel.standardWindowButton(.zoomButton)?.isHidden = true
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false
        newPanel.minSize = NSSize(width: 80, height: 80)
        newPanel.contentView = imageView

        let menu = NSMenu()
        let opacityItem = NSMenuItem()
        opacityItem.view = OpacityMenuItemView(initialValue: newPanel.alphaValue) { [weak newPanel] value in
            newPanel?.alphaValue = value
        }
        menu.addItem(opacityItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "閉じる", action: #selector(closeSelf), keyEquivalent: "").target = self
        menu.addItem(withTitle: "名前を付けて保存…", action: #selector(saveAs), keyEquivalent: "").target = self
        menu.addItem(withTitle: "コピー", action: #selector(copyImage), keyEquivalent: "").target = self
        imageView.menu = menu

        imageView.onScrollOpacity = { [weak newPanel] delta in
            guard let newPanel else { return }
            let next = newPanel.alphaValue + delta * 0.02
            newPanel.alphaValue = min(1.0, max(0.15, next))
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: newPanel
        )

        // メインパネルと同じく、自分(FloatPlayer)がアクティブな間だけ最前面に浮かせ、
        // ブラウザなど他アプリを使っている間はその後ろに回るようにする
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        newPanel.makeKeyAndOrderFront(nil)
        panel = newPanel
    }

    @objc private func handleAppActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        panel.level = app.processIdentifier == ProcessInfo.processInfo.processIdentifier ? .floating : .normal
    }

    // 複数回連続でスクリーンショットを撮っても重ならないよう、少しずつ位置をずらす
    private static var lastSpawnIndex = 0
    private static func nextSpawnPoint() -> NSPoint {
        defer { lastSpawnIndex += 1 }
        let offset = CGFloat((lastSpawnIndex % 6) * 32)
        return NSPoint(x: 220 + offset, y: 420 - offset)
    }

    @objc private func windowWillClose() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
