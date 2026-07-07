import AppKit

let app = NSApplication.shared
// main.swiftのトップレベルはmain actor分離されていないため、明示的に橋渡しする
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
// Dockに固定できるよう通常アプリとして振る舞う(メニューバーのアイコンは別途残る)
app.setActivationPolicy(.regular)
app.run()
