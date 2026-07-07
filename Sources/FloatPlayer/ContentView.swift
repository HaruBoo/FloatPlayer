import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: MediaViewModel

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if !viewModel.isUIHidden {
                    topBar
                        .background(barBackground)
                        .background(DragHandle())

                    Divider().opacity(0.3)
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

                if !viewModel.isUIHidden {
                    Divider().opacity(0.3)

                    bottomBar
                        .background(barBackground)
                }
            }

            if viewModel.isUIHidden {
                // UIを隠している間もウィンドウを動かせるように、上端に細い帯だけ残す
                Color.clear
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
                    .background(DragHandle())
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }

    // 上下バーの背景。映像/写真自体は薄くせず、バーの背景だけスライダーで透明度を変える
    private var barBackground: some View {
        Rectangle()
            .fill(.regularMaterial)
            .opacity(viewModel.windowOpacity)
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

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help("終了")
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
            } else {
                hint(text: "「写真を選択」でスクリーンショットや写真を選ぶか、\nここにファイルをドラッグ&ドロップ、\nまたはコピーした画像を「貼り付け」してください")
            }
        }
        .overlay(alignment: .bottom) {
            HStack {
                Button("写真を選択") { viewModel.pickPhoto() }
                Button("貼り付け") { viewModel.pastePhotoFromClipboard() }
            }
            .padding(8)
        }
    }

    private var videoSection: some View {
        Group {
            if viewModel.videoURL != nil {
                VideoPlayer(player: viewModel.player)
            } else {
                hint(text: "「動画を選択」で保存済みの動画ファイルを選ぶか、\nここにファイルをドラッグ&ドロップしてください")
            }
        }
        .overlay(alignment: .bottom) {
            Button("動画を選択") { viewModel.pickVideo() }
                .padding(8)
        }
    }

    private func hint(text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.secondary)
            Slider(value: $viewModel.windowOpacity, in: 0.15...1.0)
            Toggle("クリックスルー", isOn: $viewModel.isClickThrough)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(8)
    }
}
