# ARKit + Vision bbox座標のビューマッピング

## 問題

Vision (VNCoreMLRequest) が返すbounding boxは正規化座標(0-1)だが、ARSCNViewはカメラ画像を**アスペクトフィル**で表示する（はみ出し部分をクロップ）。単純に `bbox.x * viewWidth` とすると、カメラとビューのアスペクト比が異なる場合にbboxがズレる。

## 典型例: portrait mode

- カメラ画像（回転後）: 1440×1920 = **3:4**
- iPhoneビュー: ~393×852 = **≈1:2.17**
- ARSCNViewは高さ基準でフィル → 横がクロップされる
- Vision bboxのX座標をそのままビュー幅に掛けると、位置・サイズ共にズレる

## 正しいマッピング方法

```swift
// カメラ画像の生ピクセルサイズ（landscape）
let rawW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
let rawH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

// 回転後の表示サイズ
let displayImageW: CGFloat
let displayImageH: CGFloat
switch interfaceOrientation {
case .portrait, .portraitUpsideDown:
    displayImageW = rawH  // 回転で幅と高さが入れ替わる
    displayImageH = rawW
default:
    displayImageW = rawW
    displayImageH = rawH
}

// アスペクトフィルのスケールとオフセット
let scale = max(viewSize.width / displayImageW, viewSize.height / displayImageH)
let mappedW = displayImageW * scale
let mappedH = displayImageH * scale
let offsetX = (mappedW - viewSize.width) / 2
let offsetY = (mappedH - viewSize.height) / 2

// Vision bbox → ビュー座標（portrait例）
displayRect = CGRect(
    x: bbox.minX * mappedW - offsetX,
    y: (1 - bbox.maxY) * mappedH - offsetY,
    width: bbox.width * mappedW,
    height: bbox.height * mappedH
)
```

## ポイント

- `CVPixelBufferGetWidth/Height` でカメラの実ピクセルサイズを取得する（デバイスにより異なる）
- portrait時は回転後のサイズ（W/H入替）を使う
- `max()` でアスペクトフィルのスケールを計算（`min()`だとアスペクトフィットになる）
- オフセットはクロップされる側のみ非ゼロになる（portrait→X方向、landscape→Y方向が典型）
