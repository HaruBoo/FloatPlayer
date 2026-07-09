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
        // YouTube Player本体の再生状態(再生中/一時停止など)をJS側から受け取るためのブリッジ。
        // これが無いと「離れる前に自分で一時停止していたか」をSwift側から知る術がなく、
        // モード復帰時に常に再生を再開してしまっていた
        config.userContentController.add(context.coordinator, name: "fpState")
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "fpState")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        private weak var viewModel: MediaViewModel?
        private weak var webView: WKWebView?
        private var loadedVideoID: String?
        private var cancellables = Set<AnyCancellable>()
        // YT.PlayerStateの実際の値をJS側のonStateChangeから受け取って追跡する。
        // 1 = YT.PlayerState.PLAYING
        private var isActuallyPlaying = false
        // 他モードへ離れる直前に実際に再生中だったかどうか。
        // これがtrueの時だけ、YouTubeモードに戻った時に再生を再開する
        private var wasPlayingBeforeLeaving = false

        init(viewModel: MediaViewModel) {
            self.viewModel = viewModel
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            guard let viewModel, cancellables.isEmpty else { return }

            // 他モードに切り替えたら一時停止し、YouTubeに戻したら「離れる前に実際に
            // 再生中だった場合だけ」再開する。ユーザー自身が一時停止していた場合まで
            // 勝手に再生を再開してしまわないようにするための分岐
            viewModel.$mode
                .dropFirst()
                .sink { [weak self] mode in
                    guard let self, self.loadedVideoID != nil else { return }
                    if mode == .youtube {
                        if self.wasPlayingBeforeLeaving {
                            self.run("fpPlay();")
                        }
                    } else {
                        self.wasPlayingBeforeLeaving = self.isActuallyPlaying
                        self.run("fpPause();")
                    }
                }
                .store(in: &cancellables)

            // チャプター選択時は再読み込みせず、JSでシークだけ行う
            viewModel.seekSubject
                .sink { [weak self] seconds in
                    self?.run("fpSeek(\(seconds));")
                }
                .store(in: &cancellables)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "fpState", let state = message.body as? Int else { return }
            isActuallyPlaying = (state == 1) // YT.PlayerState.PLAYING
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
                  playerVars: { autoplay: 1, playsinline: 1, loop: 1, playlist: '\(videoID)' },
                  events: {
                    onStateChange: function(e) {
                      window.webkit.messageHandlers.fpState.postMessage(e.data);
                    }
                  }
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
