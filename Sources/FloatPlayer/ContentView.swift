import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: MediaViewModel

    // UIを隠している時と全画面表示中は、どちらもバー類を消す
    private var barsHidden: Bool { viewModel.isUIHidden || viewModel.isFullscreen }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if !barsHidden {
                    topBar
                        .background(DragHandle())
                        .opacity(viewModel.uiOpacity)

                    Divider().opacity(0.3 * viewModel.uiOpacity)
                }

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        guard let provider = providers.first else { return false }
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                            guard let data = item as? Data,
                                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                            DispatchQueue.main.async {
                                viewModel.handleDropped(url: url)
                            }
                        }
                        return true
                    }

                if !barsHidden {
                    Divider().opacity(0.3 * viewModel.uiOpacity)

                    bottomBar
                        .opacity(viewModel.uiOpacity)
                }
            }
            // バーごとに背景を分けず、1枚のマテリアルにして段差をなくす
            .background(.regularMaterial.opacity(viewModel.uiOpacity))

            if viewModel.isUIHidden && !viewModel.isFullscreen {
                // UIを隠している間もウィンドウを動かせるように、上端に細い帯だけ残す。
                // 全画面表示中はウィンドウ自体を動かす必要が無いので出さない
                Color.clear
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
                    .background(DragHandle())
            }
        }
        // Escキーでの全画面解除はAppDelegate側(FloatPlayerPanel.cancelOperation)で処理している。
        // ここでも.onExitCommandを使うとNSPanel標準のキャンセル(クローズ)動作と二重に発火し、
        // パネルが閉じて消えてしまっていた
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $viewModel.mode) {
                ForEach(PlaybackMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Spacer(minLength: 20)

            Button {
                viewModel.isFullscreen = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("全画面表示(Escキーで終了)")
        }
        .padding(8)
    }

    // 3セクションは常にマウントしたまま表示だけ切り替える。
    // switchで作り直すと、モード切替のたびにWKWebView/AVPlayerが破棄・再生成され、
    // YouTubeの再生位置が失われたり、裏で再生が止まらなくなったりするため。
    private var content: some View {
        ZStack {
            youtubeSection
                .opacity(viewModel.mode == .youtube ? 1 : 0)
                .allowsHitTesting(viewModel.mode == .youtube)
            photoSection
                .opacity(viewModel.mode == .photo ? 1 : 0)
                .allowsHitTesting(viewModel.mode == .photo)
            videoSection
                .opacity(viewModel.mode == .video ? 1 : 0)
                .allowsHitTesting(viewModel.mode == .video)
        }
    }

    private var youtubeSection: some View {
        VStack(spacing: 8) {
            if !viewModel.isUIHidden {
                HStack {
                    TextField("YouTubeのURLまたは動画ID", text: $viewModel.youtubeInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { viewModel.loadYouTube() }
                    Button("再生") { viewModel.loadYouTube() }
                }
                .padding(.horizontal, 8)

                HStack {
                    TextField("YouTube Data APIキー(チャプター取得用・任意)", text: $viewModel.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }
                .padding(.horizontal, 8)
            }

            if viewModel.currentVideoID != nil {
                YouTubeWebView(viewModel: viewModel)
                    .opacity(viewModel.mediaOpacity)
            } else {
                hint(text: "YouTubeのURLか動画IDを入力して「再生」を押してください")
            }
        }
    }

    private var photoSection: some View {
        Group {
            if let image = viewModel.photoImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(viewModel.mediaOpacity)
                    .overlay(alignment: .bottom) {
                        HStack {
                            Button("写真を選択") { viewModel.pickPhoto() }
                            Button("貼り付け") { viewModel.pastePhotoFromClipboard() }
                        }
                        .padding(8)
                    }
            } else {
                // 説明文とボタンが重ならないよう縦に並べ、中央に配置する
                VStack(spacing: 16) {
                    hint(text: "「写真を選択」でスクリーンショットや写真を選ぶか、\nここにファイルをドラッグ&ドロップ、\nまたはコピーした画像を「貼り付け」してください")
                    HStack {
                        Button("写真を選択") { viewModel.pickPhoto() }
                        Button("貼り付け") { viewModel.pastePhotoFromClipboard() }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var videoSection: some View {
        Group {
            if viewModel.videoURL != nil {
                VideoPlayer(player: viewModel.player)
                    .opacity(viewModel.mediaOpacity)
                    .overlay(alignment: .bottom) {
                        Button("動画を選択") { viewModel.pickVideo() }
                            .padding(8)
                    }
            } else {
                VStack(spacing: 16) {
                    hint(text: "「動画を選択」で保存済みの動画ファイルを選ぶか、\nここにファイルをドラッグ&ドロップしてください")
                    Button("動画を選択") { viewModel.pickVideo() }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // 選択中のモードに合わせてラベルを切り替える(YouTubeは商標ロゴを避け汎用の再生アイコンにする)
    @ViewBuilder
    private var mediaOpacityLabel: some View {
        switch viewModel.mode {
        case .youtube:
            Image(systemName: "play.rectangle.fill")
        case .photo:
            Text("写真")
        case .video:
            Text("動画")
        }
    }

    private func hint(text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .font(.callout)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                mediaOpacityLabel
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)
                    .help("YouTube/写真/動画の透明度")
                Slider(value: $viewModel.mediaOpacity, in: 0.15...1.0)
            }
            HStack(spacing: 8) {
                Text("UI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)
                    .help("UI(ボタン・スライダーなど)の透明度")
                Slider(value: $viewModel.uiOpacity, in: 0.15...1.0)
                Toggle("クリックスルー", isOn: $viewModel.isClickThrough)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
        .padding(8)
    }
}
