import AppKit
import Combine
import SwiftUI

/// メインパネル用のNSPanelサブクラス。
/// Escキーは既定でNSPanelの「キャンセル」動作(実質クローズ)にひもづいており、
/// 全画面表示の解除と一緒にパネル自体が閉じて消えてしまっていた。
/// cancelOperationを乗っ取ることで、Escの意味を完全にこちらで制御する
final class FloatPlayerPanel: NSPanel {
    var onCancelOperation: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancelOperation?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var panel: FloatPlayerPanel!
    private var statusItem: NSStatusItem!
    private var clickThroughMenuItem: NSMenuItem!
    private var uiHiddenMenuItem: NSMenuItem!
    private var chaptersMenuItem: NSMenuItem!
    private var screenshotWatcherMenuItem: NSMenuItem!
    private var clipboardWatcherMenuItem: NSMenuItem!
    private let viewModel = MediaViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var screenshotWatcher: ScreenshotWatcher?
    private var clipboardWatcher: ClipboardImageWatcher?
    private var floatingScreenshots: [ScreenshotFloatWindow] = []

    // パネル上の右クリックメニュー(ステータスバーのメニューとは別インスタンス)。
    // 開くたびにmenuWillOpenでチェック状態・スライダーの値を最新化する
    private var panelContextMenu: NSMenu!
    private var panelClickThroughItem: NSMenuItem!
    private var panelUIHiddenItem: NSMenuItem!
    private var panelScreenshotItem: NSMenuItem!
    private var panelClipboardItem: NSMenuItem!
    private var panelMediaOpacitySlider: SliderMenuItemView!
    private var panelUIOpacitySlider: SliderMenuItemView!
    // addLocalMonitorForEventsの戻り値(モニターの実体)。保持しないとARCで即座に
    // 解放され、モニターが機能しなくなる
    private var rightClickMonitor: Any?
    // 全画面表示に入る前のパネルのframe。Escで抜けた時に元の位置・サイズへ戻すために保持する
    private var frameBeforeFullscreen: NSRect?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOSの自動終了/サドンターミネーション機構がこのアプリを
        // アイドルな裏方アプリと誤認して勝手にterminate:するのを防ぐ
        ProcessInfo.processInfo.disableAutomaticTermination("FloatPlayerは常駐して浮遊表示を続ける必要があるため")
        ProcessInfo.processInfo.disableSuddenTermination()

        NSApp.mainMenu = buildMainMenu()
        setupPanel()
        setupStatusItem()
        bindViewModel()
    }

    // 部分スクリーンショットなどで新しい画像がスクリーンショット保存先フォルダに
    // 現れたら、UIなしの画像だけのフローティングウィンドウとして表示する
    // (クリップボードのみのスクショもこの同じ経路を通る)
    private func showFloatingScreenshot(image: NSImage) {
        let floatWindow = ScreenshotFloatWindow(image: image)
        floatWindow.onClose = { [weak self, weak floatWindow] in
            guard let floatWindow else { return }
            self?.floatingScreenshots.removeAll { $0 === floatWindow }
        }
        floatingScreenshots.append(floatWindow)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // このアプリはメニューバー常駐のユーティリティなので、
        // パネルが(一瞬でも)閉じた扱いになってもアプリ全体は終了させない。
        // 終了はメニューバーの「終了」からのみ行う。
        false
    }

    // メニューバーを持たないアクセサリアプリのままだと、Cmd+C/V/X/Aなどの
    // 標準編集ショートカットがテキストフィールドまで正しくルーティングされない。
    // 表示はされない最小限のEditメニューを用意し、キー等価物の解決先を与える。
    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "FloatPlayerを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "元に戻す", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべて選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // Cmd+Vはテキスト入力欄用なので、写真の貼り付けは別のショートカットにする
        let pastePhotoItem = NSMenuItem(title: "スクリーンショットを貼り付け", action: #selector(pastePhoto), keyEquivalent: "v")
        pastePhotoItem.keyEquivalentModifierMask = [.command, .shift]
        pastePhotoItem.target = self
        editMenu.addItem(pastePhotoItem)

        return mainMenu
    }

    private func setupPanel() {
        // これまでメニューバーのステータスアイコンからしか変更できなかった設定を、
        // パネル上の右クリック(トラックパッドは2本指クリック)からも変更できるようにする。
        // メニュー自体はinstallPanelRightClickOverride内でウィンドウ全体のrightMouseDownを
        // 横取りして表示する(ボタンやWebViewの上でも同じメニューが開くようにするため)
        let contextMenu = buildPanelContextMenu()
        let hosting = NSHostingView(rootView: ContentView(viewModel: viewModel))
        // NSHostingViewは既定でSwiftUI側の理想サイズ(fittingSize)に合わせて
        // ウィンドウ自体をリサイズしてしまう。ウィンドウサイズは自分たちで管理したいので無効化する
        hosting.sizingOptions = []
        // 透明ウィンドウは上下の角が不揃いに見えることがあるため、
        // コンテンツ自体を四隅そろえて丸くクリップする
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true

        let newPanel = FloatPlayerPanel(
            contentRect: NSRect(x: 200, y: 200, width: 420, height: 280),
            // .closable/.miniaturizableを付けないと赤(閉じる)・黄(しまう)の
            // トラフィックライトボタンが表示だけされて無効化(グレーアウト)されてしまう
            styleMask: [.titled, .resizable, .closable, .miniaturizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Escキーを押すとNSPanel標準の「キャンセル(=閉じる)」動作が働き、
        // SwiftUI側の.onExitCommandによる全画面解除と同時にパネル自体が
        // 閉じて消えてしまっていた。cancelOperationを乗っ取り、全画面表示中なら
        // それを解除するだけにして、標準のキャンセル(クローズ)は発生させない
        newPanel.onCancelOperation = { [weak self] in
            guard let self else { return }
            if self.viewModel.isFullscreen {
                self.viewModel.isFullscreen = false
            }
        }
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovableByWindowBackground = false // DragHandleでドラッグを制御する
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.minSize = NSSize(width: 260, height: 180)
        newPanel.contentView = hosting
        newPanel.isReleasedWhenClosed = false
        // NSPanelは既定でhidesOnDeactivate=trueのため、他アプリにフォーカスが移ると
        // パネルごと隠れてしまう。常時フロートさせたいのでfalseにする
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = false
        // .regularポリシーだと既定でウィンドウの状態復元が働き、
        // 手動でリサイズした過去のフレームを次回起動時に引きずることがあるため無効化する
        newPanel.isRestorable = false

        // 緑の信号機ボタンを独自の全画面表示のトグルに割り当てる。
        // クラッシュの根本原因はEscの二重処理(FloatPlayerPanel.cancelOperationで解消済み)
        // だったため、ボタン自体の割り当ては安全に行える
        if let zoomButton = newPanel.standardWindowButton(.zoomButton) {
            zoomButton.target = self
            zoomButton.action = #selector(toggleFullscreen)
        }

        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = newPanel

        observeAppActivation()
        installPanelRightClickOverride(menu: contextMenu)
    }

    // ボタンやYouTubeのWebViewなど、実際のUI部品の上で右クリックしても
    // (その部品自身がクリックを処理してしまい)設定メニューが出なかったため、
    // ウィンドウ内のrightMouseDownをここで横取りし、パネル上のどこでも
    // 同じ設定メニューが開くようにする。ブラウザがUI上のどこを右クリックしても
    // 何かしらのメニューが出るのと同じ体験にするための対応
    private func installPanelRightClickOverride(menu: NSMenu) {
        // 戻り値(モニターの実体)をプロパティに保持しておかないと、ARCによって
        // この関数を抜けた直後に解放され、モニターが実質的に機能しなくなる
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.panel, let contentView = self.panel.contentView else {
                return event
            }
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
            return nil // 元のビュー(WebViewやテキストフィールド)に渡さず、ここで処理を終える
        }
    }

    // 自分がアクティブな間だけ最前面(.floating)に浮かせ、
    // 他のアプリを使っている間はその後ろに回るようにする(.normal)。
    // FloatPlayer自体をクリックすればまた最前面に戻る。
    private func observeAppActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func handleAppActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        panel.level = app.processIdentifier == ProcessInfo.processInfo.processIdentifier ? .floating : .normal
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "FloatPlayer")

        let menu = NSMenu()

        let showItem = NSMenuItem(title: "パネルを表示", action: #selector(showPanel), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let clickThroughItem = NSMenuItem(title: "クリックスルー", action: #selector(toggleClickThrough), keyEquivalent: "")
        clickThroughItem.target = self
        menu.addItem(clickThroughItem)
        clickThroughMenuItem = clickThroughItem

        let uiHiddenItem = NSMenuItem(title: "UIを隠す", action: #selector(toggleUIHidden), keyEquivalent: "")
        uiHiddenItem.target = self
        menu.addItem(uiHiddenItem)
        uiHiddenMenuItem = uiHiddenItem

        let chaptersItem = NSMenuItem(title: "チャプター", action: nil, keyEquivalent: "")
        chaptersItem.isEnabled = false
        menu.addItem(chaptersItem)
        chaptersMenuItem = chaptersItem

        menu.addItem(.separator())

        // Cmd+Vはテキスト入力欄用に使っているため、写真の貼り付けは別のショートカットにする
        let pastePhotoItem = NSMenuItem(title: "スクリーンショットを貼り付け", action: #selector(pastePhoto), keyEquivalent: "v")
        pastePhotoItem.keyEquivalentModifierMask = [.command, .shift]
        pastePhotoItem.target = self
        menu.addItem(pastePhotoItem)

        let screenshotToggleItem = NSMenuItem(
            title: "スクショを自動でフローティング表示",
            action: #selector(toggleScreenshotWatcher),
            keyEquivalent: ""
        )
        screenshotToggleItem.target = self
        menu.addItem(screenshotToggleItem)
        screenshotWatcherMenuItem = screenshotToggleItem

        let screenshotHelpItem = NSMenuItem(
            title: "→ Cmd+Shift+4等で撮ると自動で画像が浮きます",
            action: nil,
            keyEquivalent: ""
        )
        screenshotHelpItem.isEnabled = false
        menu.addItem(screenshotHelpItem)

        let clipboardToggleItem = NSMenuItem(
            title: "クリップボードの画像も自動でフローティング表示",
            action: #selector(toggleClipboardWatcher),
            keyEquivalent: ""
        )
        clipboardToggleItem.target = self
        menu.addItem(clipboardToggleItem)
        clipboardWatcherMenuItem = clipboardToggleItem

        let clipboardHelpItem = NSMenuItem(
            title: "→ Cmd+Ctrl+Shift+4等(保存せずコピー)にも反応します",
            action: nil,
            keyEquivalent: ""
        )
        clipboardHelpItem.isEnabled = false
        menu.addItem(clipboardHelpItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    // ステータスバーのメニューと同じ設定項目に加えて、透明度スライダーを埋め込む。
    // SwiftUIの.contextMenu内のSliderはNSMenuItemへの変換で機能しなかったため、
    // NSMenuItem.viewに直接NSSliderを持たせるAppKitネイティブの方式にしている
    // (ScreenshotFloatWindowの右クリックメニューと同じ手法)
    private func buildPanelContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let clickThroughItem = NSMenuItem(title: "クリックスルー", action: #selector(toggleClickThrough), keyEquivalent: "")
        clickThroughItem.target = self
        menu.addItem(clickThroughItem)
        panelClickThroughItem = clickThroughItem

        let uiHiddenItem = NSMenuItem(title: "UIを隠す", action: #selector(toggleUIHidden), keyEquivalent: "")
        uiHiddenItem.target = self
        menu.addItem(uiHiddenItem)
        panelUIHiddenItem = uiHiddenItem

        let fullscreenItem = NSMenuItem(title: "全画面表示(Escで終了)", action: #selector(enterFullscreen), keyEquivalent: "")
        fullscreenItem.target = self
        menu.addItem(fullscreenItem)

        menu.addItem(.separator())

        let mediaOpacityItem = NSMenuItem()
        let mediaSlider = SliderMenuItemView(title: "映像の透明度", value: viewModel.mediaOpacity, range: 0.15...1.0) { [weak self] value in
            self?.viewModel.mediaOpacity = value
        }
        mediaOpacityItem.view = mediaSlider
        menu.addItem(mediaOpacityItem)
        panelMediaOpacitySlider = mediaSlider

        let uiOpacityItem = NSMenuItem()
        let uiSlider = SliderMenuItemView(title: "UIの透明度", value: viewModel.uiOpacity, range: 0.15...1.0) { [weak self] value in
            self?.viewModel.uiOpacity = value
        }
        uiOpacityItem.view = uiSlider
        menu.addItem(uiOpacityItem)
        panelUIOpacitySlider = uiSlider

        menu.addItem(.separator())

        let pastePhotoItem = NSMenuItem(title: "スクリーンショットを貼り付け", action: #selector(pastePhoto), keyEquivalent: "")
        pastePhotoItem.target = self
        menu.addItem(pastePhotoItem)

        let screenshotItem = NSMenuItem(title: "スクショを自動でフローティング表示", action: #selector(toggleScreenshotWatcher), keyEquivalent: "")
        screenshotItem.target = self
        menu.addItem(screenshotItem)
        panelScreenshotItem = screenshotItem

        let clipboardItem = NSMenuItem(title: "クリップボードの画像も自動でフローティング表示", action: #selector(toggleClipboardWatcher), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)
        panelClipboardItem = clipboardItem

        panelContextMenu = menu
        return menu
    }

    // 開かれる直前に、チェック状態とスライダーの値を現在のviewModelの内容へ最新化する。
    // ステータスバー側や別経路(パネル下部のUI)での変更もここで反映される
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === panelContextMenu else { return }
        panelClickThroughItem.state = viewModel.isClickThrough ? .on : .off
        panelUIHiddenItem.state = viewModel.isUIHidden ? .on : .off
        panelUIHiddenItem.title = viewModel.isUIHidden ? "UIを表示" : "UIを隠す"
        panelScreenshotItem.state = viewModel.isScreenshotWatcherEnabled ? .on : .off
        panelClipboardItem.state = viewModel.isClipboardWatcherEnabled ? .on : .off
        panelMediaOpacitySlider.setValue(viewModel.mediaOpacity)
        panelUIOpacitySlider.setValue(viewModel.uiOpacity)
    }

    private func bindViewModel() {
        // windowOpacityは上下バーの背景(ContentView側)だけに使う。
        // 映像/写真自体まで薄くしたくないので、パネル全体のalphaValueは常に1.0のまま。

        viewModel.$isClickThrough
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.panel.ignoresMouseEvents = enabled
                self?.clickThroughMenuItem.state = enabled ? .on : .off
            }
            .store(in: &cancellables)

        viewModel.$isUIHidden
            .receive(on: RunLoop.main)
            .sink { [weak self] hidden in
                self?.uiHiddenMenuItem.state = hidden ? .on : .off
                self?.uiHiddenMenuItem.title = hidden ? "UIを表示" : "UIを隠す"
            }
            .store(in: &cancellables)

        viewModel.$isFullscreen
            .receive(on: RunLoop.main)
            .sink { [weak self] fullscreen in
                self?.updateFullscreen(fullscreen)
            }
            .store(in: &cancellables)

        viewModel.$isScreenshotWatcherEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.updateScreenshotWatcher(enabled: enabled)
            }
            .store(in: &cancellables)

        viewModel.$isClipboardWatcherEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.updateClipboardWatcher(enabled: enabled)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(viewModel.$chapters, viewModel.$isLoadingChapters)
            .receive(on: RunLoop.main)
            .sink { [weak self] chapters, isLoading in
                self?.rebuildChaptersMenu(chapters, isLoading: isLoading)
            }
            .store(in: &cancellables)
    }

    private func rebuildChaptersMenu(_ chapters: [Chapter], isLoading: Bool) {
        guard let chaptersMenuItem else { return }

        if isLoading {
            chaptersMenuItem.submenu = nil
            chaptersMenuItem.isEnabled = false
            chaptersMenuItem.title = "チャプターを読み込み中…"
            return
        }
        chaptersMenuItem.title = "チャプター"

        if chapters.isEmpty {
            chaptersMenuItem.submenu = nil
            chaptersMenuItem.isEnabled = false
            return
        }
        let submenu = NSMenu()
        for (index, chapter) in chapters.enumerated() {
            let item = NSMenuItem(title: "\(chapter.timeLabel)  \(chapter.title)", action: #selector(jumpToChapter(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            submenu.addItem(item)
        }
        chaptersMenuItem.submenu = submenu
        chaptersMenuItem.isEnabled = true
    }

    // 本来のYouTubeなどと同じく、UIを消して画面いっぱいに表示する。
    // macOS標準のフルスクリーン(Spaces切り替えを伴う)は使わず、パネル自体を
    // 画面のフレームまでリサイズするだけの簡易な方式にしている
    private func updateFullscreen(_ fullscreen: Bool) {
        guard let panel else { return }
        if fullscreen {
            guard frameBeforeFullscreen == nil else { return }
            frameBeforeFullscreen = panel.frame
            let screenFrame = panel.screen?.frame ?? NSScreen.main?.frame ?? panel.frame
            panel.setFrame(screenFrame, display: true, animate: true)
        } else {
            guard let previousFrame = frameBeforeFullscreen else { return }
            frameBeforeFullscreen = nil
            panel.setFrame(previousFrame, display: true, animate: true)
        }
    }

    @objc private func showPanel() {
        panel.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func pastePhoto() {
        viewModel.pastePhotoFromClipboard()
    }

    // 実際のウォッチャーの起動/停止とメニューのチェック状態反映は、
    // viewModel.isScreenshotWatcherEnabled購読(bindViewModel)からここに集約している。
    // これにより、ステータスバーのメニューだけでなく、パネルの右クリックメニューからの
    // 変更でも同じ経路で反映される
    private func updateScreenshotWatcher(enabled: Bool) {
        screenshotWatcherMenuItem?.state = enabled ? .on : .off
        guard enabled else {
            screenshotWatcher?.stop()
            screenshotWatcher = nil
            return
        }
        guard screenshotWatcher == nil else { return }
        let watcher = ScreenshotWatcher { [weak self] url in
            guard let image = NSImage(contentsOf: url) else { return }
            self?.showFloatingScreenshot(image: image)
        }
        watcher.start()
        screenshotWatcher = watcher
    }

    // 既定ではオフ。どんな画像コピーにも反応してしまうため、
    // 「保存せずコピーだけのスクショ」も浮かせたい人向けの追加機能として提供する
    private func updateClipboardWatcher(enabled: Bool) {
        clipboardWatcherMenuItem?.state = enabled ? .on : .off
        guard enabled else {
            clipboardWatcher?.stop()
            clipboardWatcher = nil
            return
        }
        guard clipboardWatcher == nil else { return }
        let watcher = ClipboardImageWatcher { [weak self] image in
            self?.showFloatingScreenshot(image: image)
        }
        watcher.start()
        clipboardWatcher = watcher
    }

    @objc private func toggleScreenshotWatcher() {
        viewModel.isScreenshotWatcherEnabled.toggle()
    }

    @objc private func toggleClipboardWatcher() {
        viewModel.isClipboardWatcherEnabled.toggle()
    }

    // クリックスルー中はパネル自身のトグルUIも押せなくなるため、
    // メニューバーからだけは常に解除できるようにしている
    @objc private func toggleClickThrough() {
        viewModel.isClickThrough.toggle()
    }

    @objc private func toggleUIHidden() {
        viewModel.isUIHidden.toggle()
    }

    @objc private func enterFullscreen() {
        viewModel.isFullscreen = true
    }

    // 緑の信号機ボタンは常時クリックできてしまうため、enterFullscreenのように
    // 「入るだけ」だと2回目のクリックで戻せなくなる。ボタン用にはトグル版を使う
    @objc private func toggleFullscreen() {
        viewModel.isFullscreen.toggle()
    }

    @objc private func jumpToChapter(_ sender: NSMenuItem) {
        guard viewModel.chapters.indices.contains(sender.tag) else { return }
        viewModel.seek(toChapter: viewModel.chapters[sender.tag])
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

/// 右クリックメニューにラベル付きの透明度スライダーを埋め込むためのビュー。
/// NSMenuはSwiftUIのContextMenu経由だとSliderのような操作可能なコントロールを
/// 描画できないため、NSMenuItem.viewに直接NSSliderを持たせるAppKitネイティブの
/// 方式にしている(ScreenshotFloatWindowのOpacityMenuItemViewと同じ考え方)。
private final class SliderMenuItemView: NSView {
    private let slider: NSSlider
    private var onChange: ((Double) -> Void)?

    init(title: String, value: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) {
        slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 42))

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 24, width: 192, height: 14)
        addSubview(label)

        slider.frame = NSRect(x: 14, y: 4, width: 192, height: 20)
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        addSubview(slider)

        self.onChange = onChange
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // メニューが開かれるたびに、現在のviewModelの値へ合わせ直す
    func setValue(_ value: Double) {
        slider.doubleValue = value
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        onChange?(sender.doubleValue)
    }
}
