import AppKit

/// スクリーンショットの保存先フォルダ(既定はデスクトップ。
/// スクリーンショットApp側で変更していればその設定を読む)を監視し、
/// 新しい画像ファイルが追加されたら通知する。
@MainActor
final class ScreenshotWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var knownFiles: Set<String> = []
    private let onNewScreenshot: (URL) -> Void

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]

    init(onNewScreenshot: @escaping (URL) -> Void) {
        self.onNewScreenshot = onNewScreenshot
    }

    func start() {
        let dir = Self.screenshotDirectory()
        knownFiles = Self.listImageFiles(in: dir)

        directoryFD = open(dir.path, O_EVTONLY)
        guard directoryFD >= 0 else { return }

        let newSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: directoryFD, eventMask: .write, queue: .main)
        newSource.setEventHandler { [weak self] in
            self?.checkForNewFiles(in: dir)
        }
        let fd = directoryFD
        newSource.setCancelHandler {
            close(fd)
        }
        newSource.resume()
        source = newSource
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func checkForNewFiles(in dir: URL) {
        let current = Self.listImageFiles(in: dir)
        let newNames = current.subtracting(knownFiles)
        knownFiles = current
        guard !newNames.isEmpty else { return }

        let newest = newNames
            .map { dir.appendingPathComponent($0) }
            .max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }

        guard let newest else { return }
        // 書き込みが完了しきっていないタイミングで読むと失敗するため少し待つ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.onNewScreenshot(newest)
        }
    }

    private static func screenshotDirectory() -> URL {
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let expanded = (custom as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    private static func listImageFiles(in dir: URL) -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        // スクリーンショットは書き込み中、"."で始まる一時的な隠しファイル名で
        // 現れてから最終的なファイル名にリネームされることがあるため対象から除く
        return Set(names.filter {
            !$0.hasPrefix(".") && imageExtensions.contains(($0 as NSString).pathExtension.lowercased())
        })
    }
}

private extension URL {
    var modificationDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

/// Cmd+Ctrl+Shift+4などファイル保存を伴わないスクリーンショットは、
/// フォルダ監視では検知できないためクリップボードの変化を監視して拾う。
/// macOSにはクリップボードの内容が「スクリーンショット由来」かを判別する
/// 公開APIがないため、この監視は新しい画像がコピーされた時点で全て拾う
/// (通常の画像コピー操作にも反応するため、既定ではオフの追加機能として扱う)。
@MainActor
final class ClipboardImageWatcher {
    private var timer: Timer?
    private var lastChangeCount: Int
    private let onNewImage: (NSImage) -> Void

    init(onNewImage: @escaping (NSImage) -> Void) {
        self.onNewImage = onNewImage
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let image = NSImage(pasteboard: pasteboard) else { return }
        onNewImage(image)
    }
}
