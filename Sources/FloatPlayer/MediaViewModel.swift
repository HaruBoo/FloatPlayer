import AppKit
import AVFoundation
import Combine
import Foundation

struct Chapter: Identifiable {
    let id = UUID()
    let seconds: Int
    let title: String

    var timeLabel: String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum PlaybackMode: String, CaseIterable, Identifiable {
    case youtube
    case photo
    case video

    var id: String { rawValue }

    var label: String {
        switch self {
        case .youtube: return "YouTube"
        case .photo: return "写真"
        case .video: return "動画"
        }
    }
}

@MainActor
final class MediaViewModel: ObservableObject {
    @Published var mode: PlaybackMode = .youtube

    // YouTube
    @Published var youtubeInput: String = ""
    @Published var currentVideoID: String?
    /// チャプター選択時にJS経由でシークさせるための通知(再読み込みはしない)
    let seekSubject = PassthroughSubject<Int, Never>()

    // 写真 / スクリーンショット
    @Published var photoImage: NSImage?

    // 動画
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    @Published var videoURL: URL?

    // ウィンドウの見た目
    @Published var mediaOpacity: Double = 1.0 // YouTube/写真/動画の透明度
    @Published var uiOpacity: Double = 1.0 // 上下バーなどUIの透明度
    @Published var isClickThrough: Bool = false
    @Published var isUIHidden: Bool = false

    // チャプター(YouTube Data API v3を使用)
    @Published var apiKey: String = UserDefaults.standard.string(forKey: "youtubeAPIKey") ?? "" {
        didSet { UserDefaults.standard.set(apiKey, forKey: "youtubeAPIKey") }
    }
    @Published var chapters: [Chapter] = []
    @Published var isLoadingChapters: Bool = false

    func loadYouTube() {
        guard let id = Self.extractYouTubeID(from: youtubeInput) else { return }
        chapters = []
        currentVideoID = id
        mode = .youtube
        isUIHidden = true // 再生開始したらUIを隠し、映像だけにする
        fetchChapters(videoID: id)
    }

    /// チャプター選択時はURLを作り直して再読み込みするのではなく、
    /// 再生中のプレイヤーにJSでシーク指示を送るだけにする(位置が飛ばず、再読み込みもしない)
    func seek(toChapter chapter: Chapter) {
        seekSubject.send(chapter.seconds)
    }

    /// YouTube Data API v3で動画の概要欄を取得し、タイムスタンプ行をチャプターとして抽出する
    private func fetchChapters(videoID: String) {
        guard !apiKey.isEmpty else { return }
        isLoadingChapters = true
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "id", value: videoID),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components.url else {
            isLoadingChapters = false
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let parsed = data.map { Self.parseChapters(fromAPIResponse: $0) } ?? []
            Task { @MainActor in
                self?.chapters = parsed
                self?.isLoadingChapters = false
            }
        }.resume()
    }

    private struct VideosResponse: Decodable {
        struct Item: Decodable {
            struct Snippet: Decodable { let description: String }
            let snippet: Snippet
        }
        let items: [Item]
    }

    nonisolated static func parseChapters(fromAPIResponse data: Data) -> [Chapter] {
        guard let response = try? JSONDecoder().decode(VideosResponse.self, from: data),
              let description = response.items.first?.snippet.description else { return [] }
        return parseChapters(fromDescription: description)
    }

    nonisolated static func parseChapters(fromDescription description: String) -> [Chapter] {
        guard let regex = try? NSRegularExpression(pattern: #"^\(?(\d{1,2}(?::\d{2}){1,2})\)?\s*[-:–—]?\s*(.+)$"#) else { return [] }

        var results: [Chapter] = []
        for rawLine in description.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let timeRange = Range(match.range(at: 1), in: line),
                  let titleRange = Range(match.range(at: 2), in: line),
                  let seconds = secondsFromTimestamp(String(line[timeRange])) else { continue }
            let title = String(line[titleRange]).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            results.append(Chapter(seconds: seconds, title: title))
        }
        // 誤検出(本文中の時刻表記など)を避けるため、最低2件そろって初めてチャプターとみなす
        return results.count >= 2 ? results : []
    }

    private nonisolated static func secondsFromTimestamp(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    func pickPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            photoImage = NSImage(contentsOf: url)
            mode = .photo
        }
    }

    /// 部分スクリーンショット(Cmd+Shift+Ctrl+4など)をファイル保存なしでそのまま貼り付ける
    func pastePhotoFromClipboard() {
        guard let image = NSImage(pasteboard: .general) else { return }
        photoImage = image
        mode = .photo
    }

    func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            loadVideo(url: url)
            mode = .video
        }
    }

    func loadVideo(url: URL) {
        videoURL = url
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
    }

    /// ドラッグ&ドロップされたファイルを画像/動画どちらか判定して読み込む
    func handleDropped(url: URL) {
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
        if videoExtensions.contains(url.pathExtension.lowercased()) {
            loadVideo(url: url)
            mode = .video
        } else {
            photoImage = NSImage(contentsOf: url)
            mode = .photo
        }
    }

    static func extractYouTubeID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.count == 11, trimmed.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            return trimmed
        }

        guard let url = URL(string: trimmed),
              let host = url.host else { return nil }

        if host.contains("youtu.be") {
            return url.pathComponents.last(where: { $0 != "/" })
        }

        if host.contains("youtube.com") {
            if url.path.contains("/embed/") {
                return url.pathComponents.last(where: { $0 != "/" })
            }
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            return comps?.queryItems?.first(where: { $0.name == "v" })?.value
        }

        return nil
    }
}
