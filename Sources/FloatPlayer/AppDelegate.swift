import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var clickThroughMenuItem: NSMenuItem!
    private var uiHiddenMenuItem: NSMenuItem!
    private var chaptersMenuItem: NSMenuItem!
    private let viewModel = MediaViewModel()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOSの自動終了/サドンターミネーション機構がこのアプリを
        // アイドルな裏方アプリと誤認して勝手にterminate:するのを防ぐ
        ProcessInfo.processInfo.disableAutomaticTermination("FloatPlayerは常駐して浮遊表示を続ける必要があるため")
        ProcessInfo.processInfo.disableSuddenTermination()

        NSApp.mainMenu = Self.buildMainMenu()
        setupPanel()
        setupStatusItem()
        bindViewModel()
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
    private static func buildMainMenu() -> NSMenu {
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

        return mainMenu
    }

    private func setupPanel() {
        let hosting = NSHostingView(rootView: ContentView(viewModel: viewModel))
        // 透明ウィンドウは上下の角が不揃いに見えることがあるため、
        // コンテンツ自体を四隅そろえて丸くクリップする
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true

        let newPanel = NSPanel(
            contentRect: NSRect(x: 200, y: 200, width: 420, height: 340),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovableByWindowBackground = false // DragHandleでドラッグを制御する
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.minSize = NSSize(width: 260, height: 200)
        newPanel.contentView = hosting
        newPanel.isReleasedWhenClosed = false
        // NSPanelは既定でhidesOnDeactivate=trueのため、他アプリにフォーカスが移ると
        // パネルごと隠れてしまう。常時フロートさせたいのでfalseにする
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = false

        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = newPanel
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

        let quitItem = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func bindViewModel() {
        viewModel.$windowOpacity
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.panel.alphaValue = value
            }
            .store(in: &cancellables)

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

    @objc private func showPanel() {
        panel.makeKeyAndOrderFront(nil)
    }

    // クリックスルー中はパネル自身のトグルUIも押せなくなるため、
    // メニューバーからだけは常に解除できるようにしている
    @objc private func toggleClickThrough() {
        viewModel.isClickThrough.toggle()
    }

    @objc private func toggleUIHidden() {
        viewModel.isUIHidden.toggle()
    }

    @objc private func jumpToChapter(_ sender: NSMenuItem) {
        guard viewModel.chapters.indices.contains(sender.tag) else { return }
        viewModel.seek(toChapter: viewModel.chapters[sender.tag])
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
