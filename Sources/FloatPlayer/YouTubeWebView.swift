import Combine
import SwiftUI
import WebKit

struct YouTubeWebView: NSViewRepresentable {
    @ObservedObject var viewModel: MediaViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // ミュートなしの自動再生を許可(自分専用アプリのため)
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = .clear
        context.coordinator.attach(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadVideoIfNeeded(videoID: viewModel.currentVideoID)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.pauseAllMediaPlayback(completionHandler: nil)
    }

    @MainActor
    final class Coordinator {
        private weak var viewModel: MediaViewModel?
        private weak var webView: WKWebView?
        private var loadedVideoID: String?
        private var cancellables = Set<AnyCancellable>()

        init(viewModel: MediaViewModel) {
            self.viewModel = viewModel
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            guard let viewModel, cancellables.isEmpty else { return }

            // 他モードに切り替えたら一時停止、YouTubeに戻したら続きから再開する
            viewModel.$mode
                .dropFirst()
                .sink { [weak self] mode in
                    guard let self, self.loadedVideoID != nil else { return }
                    self.run(mode == .youtube ? "fpPlay();" : "fpPause();")
                }
                .store(in: &cancellables)

            // チャプター選択時は再読み込みせず、JSでシークだけ行う
            viewModel.seekSubject
                .sink { [weak self] seconds in
                    self?.run("fpSeek(\(seconds));")
                }
                .store(in: &cancellables)
        }

        func loadVideoIfNeeded(videoID: String?) {
            guard let videoID, videoID != loadedVideoID, let webView else { return }
            loadedVideoID = videoID

            let html = """
            <!doctype html>
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden;}
            #player{position:absolute;top:0;left:0;width:100%;height:100%;}</style>
            </head>
            <body>
            <div id="player"></div>
            <script>
              var tag = document.createElement('script');
              tag.src = "https://www.youtube.com/iframe_api";
              document.body.appendChild(tag);

              var player;
              function onYouTubeIframeAPIReady() {
                player = new YT.Player('player', {
                  videoId: '\(videoID)',
                  playerVars: { autoplay: 1, playsinline: 1, loop: 1, playlist: '\(videoID)' }
                });
              }
              function fpPause() { if (player && player.pauseVideo) player.pauseVideo(); }
              function fpPlay() { if (player && player.playVideo) player.playVideo(); }
              function fpSeek(sec) { if (player && player.seekTo) { player.seekTo(sec, true); player.playVideo(); } }
            </script>
            </body></html>
            """
            // baseURLをyoutube.com自身にすると自己埋め込みとして扱われ検証に失敗するため、
            // 実際のサイトが埋め込む状況に近い、無関係な自前ドメイン風のオリジンにする
            webView.loadHTMLString(html, baseURL: URL(string: "https://floatplayer.local"))
        }

        private func run(_ js: String) {
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
