import AppKit

// FloatPlayerのアプリアイコンを描画するスクリプト。
// デザイン: 白背景の角丸スクエアに、水色の「F」がゆらゆら浮いているイメージ。
// Fの字自体をサインカーブで波状に歪ませて「浮遊感・揺らぎ」を表現する。

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))

image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// macOSアイコンの標準グリッド: 1024キャンバスの中央に824x824の角丸スクエア
let squareSize: CGFloat = 824
let origin = (canvas - squareSize) / 2
let squareRect = CGRect(x: origin, y: origin, width: squareSize, height: squareSize)
let bgPath = CGPath(roundedRect: squareRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

// 背景: 白(ほんのわずかに青みを入れて冷たい白にする)
ctx.addPath(bgPath)
ctx.setFillColor(CGColor(red: 0.99, green: 0.995, blue: 1.0, alpha: 1.0))
ctx.fillPath()

// これ以降の描画が角丸からはみ出さないようにクリップ
ctx.addPath(bgPath)
ctx.clip()

// --- 「F」を一旦オフスクリーン画像に描き、横方向のサイン波で歪ませる ---

let font = NSFont.systemFont(ofSize: 600, weight: .bold)
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(calibratedRed: 0.49, green: 0.80, blue: 0.92, alpha: 1.0)
]
let text = NSAttributedString(string: "F", attributes: attributes)
let textSize = text.size()

let waveAmplitude: CGFloat = 16 // 波の振れ幅
let wavePeriod: CGFloat = 300   // 波1周期の高さ

// 歪ませる余白込みでFを描いた元画像
let fSourceSize = NSSize(width: textSize.width + waveAmplitude * 2, height: textSize.height)
let fSource = NSImage(size: fSourceSize)
fSource.lockFocus()
text.draw(at: NSPoint(x: waveAmplitude, y: 0))
// 描いた文字の形をマスクにして(.sourceIn)、上→下のグラデーションで塗り直す。
// 上は明るいスカイブルー、下はやや深いアクアで、軽さを保ちながら立体感を出す
if let cg = NSGraphicsContext.current?.cgContext {
    cg.setBlendMode(.sourceIn)
    let colors = [
        CGColor(red: 0.33, green: 0.68, blue: 0.89, alpha: 1.0), // 上(深い)
        CGColor(red: 0.62, green: 0.88, blue: 0.97, alpha: 1.0)  // 下(明るい)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        cg.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: fSourceSize.height), // 画像座標は左下原点なので上端はheight
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }
    cg.setBlendMode(.normal)
}
fSource.unlockFocus()

// 元画像を細い横帯に分割し、各帯をsin(y)分だけ左右にずらして描き直す
let sliceHeight: CGFloat = 2
let fWavy = NSImage(size: fSourceSize)
fWavy.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
var y: CGFloat = 0
while y < fSourceSize.height {
    let offset = sin(y / wavePeriod * 2 * .pi) * waveAmplitude
    let srcRect = NSRect(x: 0, y: y, width: fSourceSize.width, height: sliceHeight)
    let destRect = NSRect(x: offset, y: y, width: fSourceSize.width, height: sliceHeight)
    fSource.draw(in: destRect, from: srcRect, operation: .sourceOver, fraction: 1.0)
    y += sliceHeight
}
fWavy.unlockFocus()

// --- 波状のFを本体キャンバスに配置 ---

// Fの真下のやわらかい楕円の影(浮遊感の要)
let shadowRect = CGRect(x: canvas / 2 - 180, y: origin + 130, width: 360, height: 62)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 46, color: CGColor(red: 0.45, green: 0.75, blue: 0.88, alpha: 0.50))
ctx.setFillColor(CGColor(red: 0.55, green: 0.83, blue: 0.93, alpha: 0.32))
ctx.fillEllipse(in: shadowRect)
ctx.restoreGState()

ctx.saveGState()
// Fそのものにもごく薄い影を落として立体感を出す
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30,
              color: CGColor(red: 0.30, green: 0.62, blue: 0.78, alpha: 0.30))
let fCenter = CGPoint(x: canvas / 2, y: canvas / 2 + 60)
// 中心を軸に約-8度回転させて、ゆらっと傾いた浮遊感を出す
ctx.translateBy(x: fCenter.x, y: fCenter.y)
ctx.rotate(by: -8 * .pi / 180)
ctx.translateBy(x: -fCenter.x, y: -fCenter.y)
fWavy.draw(at: NSPoint(x: fCenter.x - fSourceSize.width / 2, y: fCenter.y - fSourceSize.height / 2),
           from: .zero, operation: .sourceOver, fraction: 1.0)
ctx.restoreGState()

// 小さな泡を2つ(Fの右上あたり)
func drawBubble(center: CGPoint, radius: CGFloat, alpha: CGFloat) {
    ctx.setStrokeColor(CGColor(red: 0.55, green: 0.83, blue: 0.93, alpha: alpha))
    ctx.setLineWidth(14)
    ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2))
}
drawBubble(center: CGPoint(x: origin + squareSize - 185, y: origin + squareSize - 200), radius: 34, alpha: 0.60)
drawBubble(center: CGPoint(x: origin + squareSize - 120, y: origin + squareSize - 295), radius: 20, alpha: 0.38)

image.unlockFocus()

// PNGとして書き出す
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("failed to encode png")
}
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: outputPath))
print("written: \(outputPath)")
