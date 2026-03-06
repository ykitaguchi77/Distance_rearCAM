# ARKit + SwiftUI でのデジタルズーム実装

## ARSCNView のズームで避けるべきこと

1. **`AVCaptureDevice.videoZoomFactor`**: ARKitがカメラセッションを専有するため反映されない
2. **`ARSCNView.transform = CGAffineTransform(...)`**: SwiftUIの`UIViewRepresentable`がレイアウト更新時に上書きするため効かない
3. **`supportedVideoFormats`でレンズ切替**: デバイスによって利用可能なフォーマットが限られ、期待通りに動かない場合がある

## 正しいアプローチ: SwiftUI `.scaleEffect()`

```swift
ARViewContainer(sessionManager: sessionManager)
    .scaleEffect(zoomFactor)
    .ignoresSafeArea()

FaceOverlayView(faces: sessionManager.faces)
    .scaleEffect(zoomFactor)
    .ignoresSafeArea()
```

- カメラfeedとオーバーレイに同じ`.scaleEffect()`を適用 → 座標系が自動一致
- UIボタン等は別レイヤーに配置してズームから除外

## キャプチャ時の注意

- `sceneView.snapshot()` は `.scaleEffect()` に関係なく**フルフレーム**を返す
- ROI切り出しは**フルフレーム**から行う（face座標がフルフレーム基準のため）
- 表示用の`fullImage`のみにズームクロップ（中央切り出し）を適用する
- フルフレームとクロップ後の画像を混同するとROI位置がズレる
