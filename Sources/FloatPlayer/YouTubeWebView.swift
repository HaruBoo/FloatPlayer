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
        // YouTube本体のホーム画面は動画サムネイルのクリックをページ全体の再読み込みなしに
        // JS内(SPA)で処理してしまうため、WKNavigationDelegateでは検知できないことがある。
        // そこでクリックそのものをキャプチャフェーズで捕まえ、YouTube側の処理より先に
        // 動画リンクかどうかを判定して横取りする
        config.userContentController.add(context.coordinator, name: "fpVideoLink")
        let interceptScript = WKUserScript(
            source: Coordinator.videoLinkInterceptJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(interceptScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = .clear
        // 動画内のYouTubeロゴなど、新規タブ/ウィンドウを開こうとする挙動を横取りするために必要
        webView.uiDelegate = context.coordinator
        // ホーム画面で動画サムネイルをクリックした際の遷移を横取りし、埋め込みプレイヤーに切り替えるために必要
        webView.navigationDelegate = context.coordinator
        // 既定のWKWebViewのUser-AgentはGoogleのログイン画面から「安全でないブラウザ」と
        // 判定され弾かれることがあるため、通常のSafariに近い文字列にしてログインが通りやすくする
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        context.coordinator.attach(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadVideoIfNeeded(videoID: viewModel.currentVideoID)
    }

    // WKWebViewは実際に読み込んだページの内容(YouTubeホームのような大きな実サイトなど)に応じて
    // 大きなfittingSize/intrinsicContentSizeを報告することがあり、それが.frame()指定を素通りして
    // 親のSwiftUIレイアウト・ひいてはウィンドウ自体を巨大化させてしまう。ここで「親から提案された
    // サイズをそのまま使う」と明示的に返すことで、WKWebView自身の内容サイズを完全に無視させる
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.bounds.width, height: proposal.height ?? nsView.bounds.height)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "fpState")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "fpVideoLink")
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
        // 動画埋め込み(IFrame Player API)ではなく、YouTube本体のホーム画面を表示中かどうか。
        // trueの間はfpPlay/fpPauseなどの自作JS関数が存在しないため呼び出しをスキップする
        private var isShowingHome = false

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
                    guard let self, self.loadedVideoID != nil, !self.isShowingHome else { return }
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

            // アプリを開いた直後、まだ動画が選択されていなければ
            // (ログイン状態を保った)YouTubeホーム画面を最初から表示しておく。
            // makeNSView実行中の同期呼び出しだと、SwiftUI側のframe制約がまだ
            // 確定しておらずウィンドウが一瞬巨大化することがあるため、
            // レイアウトが確定した次の実行サイクルまで読み込みを遅らせる
            if viewModel.currentVideoID == nil {
                DispatchQueue.main.async { [weak self] in
                    self?.loadYouTubeHome()
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "fpState":
                guard let state = message.body as? Int else { return }
                isActuallyPlaying = (state == 1) // YT.PlayerState.PLAYING
            case "fpVideoLink":
                // ホーム画面上で動画リンクがクリックされた(JS側でpreventDefault済み)。
                // ネイティブの視聴ページへは遷移させず、既存のクリーンな埋め込み再生に流し込む
                guard let href = message.body as? String,
                      let videoID = MediaViewModel.extractYouTubeID(from: href) else { return }
                viewModel?.loadYouTube(videoID: videoID)
            default:
                break
            }
        }

        // ホーム画面のクリックをキャプチャフェーズで捕まえ、動画(/watchや/shorts)へのリンクなら
        // 既定の遷移を止めて動画URLをSwift側に伝える。document読み込み開始時に注入することで、
        // YouTube自身のクリックハンドラより先に登録され、確実に横取りできる
        fileprivate static let videoLinkInterceptJS = """
        document.addEventListener('click', function(e) {
          var el = e.target;
          while (el && el.tagName !== 'A') { el = el.parentElement; }
          if (!el || !el.href) return;
          if (el.href.indexOf('/watch') !== -1 || el.href.indexOf('/shorts/') !== -1) {
            e.preventDefault();
            e.stopPropagation();
            window.webkit.messageHandlers.fpVideoLink.postMessage(el.href);
          }
        }, true);
        """

        func loadVideoIfNeeded(videoID: String?) {
            // ホーム表示中に、直前に見ていたのと同じ動画IDが選ばれた場合でも
            // (videoID自体は変わっていなくても)ホームから埋め込み再生へ戻す必要がある
            guard let videoID, videoID != loadedVideoID || isShowingHome, let webView else { return }
            loadedVideoID = videoID
            isShowingHome = false

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

        // 動画内のYouTubeロゴなどをクリックした際に本来は新規タブで開こうとする遷移を、
        // 同じWebView内でYouTubeのホーム画面に置き換えて表示する
        fileprivate func loadYouTubeHome() {
            guard let webView, let homeURL = URL(string: "https://www.youtube.com/") else { return }
            isShowingHome = true
            webView.load(URLRequest(url: homeURL))
        }
    }
}

extension YouTubeWebView.Coordinator: WKUIDelegate {
    // window.open(target="_blank"など)で新規タブ/ウィンドウを開こうとする挙動を横取りする。
    // 新しいWKWebViewを作らずnilを返すことで、代わりに同じWebViewをホームへ遷移させる
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        loadYouTubeHome()
        return nil
    }
}

extension YouTubeWebView.Coordinator: WKNavigationDelegate {
    // ホーム画面で動画サムネイルをクリックすると、本来はYouTube本来の(広告や関連動画付きの)
    // 視聴ページへそのまま遷移してしまう。ここでその遷移を横取りし、動画IDだけを取り出して
    // 既存の埋め込みプレイヤー経路(loadYouTube(videoID:))に流し込むことで、URLをコピペし
    // 直す手間や、ネイティブ再生と埋め込み再生が同時に始まる二重再生を避ける
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // サブフレーム(動画自体を表示するembed用iframeなど)への読み込みは対象外。
        // メインフレームがwatch/shortsページへ向かおうとした時だけ横取りする
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           let videoID = MediaViewModel.extractYouTubeID(from: url.absoluteString) {
            decisionHandler(.cancel)
            viewModel?.loadYouTube(videoID: videoID)
            return
        }
        decisionHandler(.allow)
    }
}
