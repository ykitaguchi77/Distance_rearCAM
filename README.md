# Distance rearCAM

LiDAR搭載iPhoneの背面カメラを使い、眼瞼までの距離をリアルタイム測定し、眼瞼セグメンテーション解析を行うiOSアプリ。

## 機能

- **リアルタイム距離測定**: ARKit + LiDAR深度マップで眼瞼までの距離を計測
- **眼瞼検出 (YOLO)**: カスタムYOLOモデル (EyelidDetector) で右眼・左眼をリアルタイム検出、バウンディングボックス表示
- **セグメンテーション解析 (SegFormer)**: 撮影した静止画に対してSegFormer B3モデルで眼瞼(Eyelid)・虹彩(Iris)・瞳孔(Pupil)のピクセルレベルセグメンテーション
- **デジタルズーム**: x1 / x2 / x3 切替（SwiftUI scaleEffect + 中央クロップ）
- **フラッシュ制御**: 撮影時のみ一瞬トーチ点灯
- **プレビューフロー**: 撮影 → プレビュー確認 → 解析開始（キャンセル可能）

## 動作要件

- iOS 16.0+
- LiDAR搭載デバイス（iPhone Pro / iPad Pro）
- Xcode 15.0+

## セットアップ

### 1. リポジトリをクローン

```bash
git clone https://github.com/ykitaguchi77/Distance_rearCAM.git
```

### 2. CoreMLモデルを配置

以下の2つのモデルファイルを `DIstance_rearCAM/models/` に配置してください（サイズが大きいためgit管理外）:

| モデル | ファイル名 | 用途 |
|--------|-----------|------|
| EyelidDetector | `EyelidDetector.mlpackage` | YOLO眼瞼検出（リアルタイム） |
| EyelidSegFormer | `EyelidSegFormer.mlpackage` | SegFormer B3セグメンテーション（静止画解析） |

SegFormerモデルの変換スクリプト: `convert_segformer.py`

### 3. ビルド & 実行

Xcodeでプロジェクトを開き、実機（LiDAR搭載デバイス）で実行してください。シミュレータではARKit/LiDARは動作しません。

## アプリ構成

```
DIstance_rearCAM/
├── DIstance_rearCAMApp.swift   # エントリーポイント
├── ContentView.swift            # ホーム画面（LiDARチェック）
├── CameraView.swift             # 撮影画面（AR表示 + UI操作）
├── ARSessionManager.swift       # ARKit管理、YOLO検出、距離計測、キャプチャ
├── FaceOverlayView.swift        # バウンディングボックス描画
├── AnalysisView.swift           # プレビュー + 解析結果表示（2x2グリッド）
├── SegmentationManager.swift    # SegFormer推論エンジン
└── models/                      # CoreMLモデル（git管理外）
```

## 解析結果の見方

解析結果は2x2グリッドで表示されます:

|  | 右眼 | 左眼 |
|--|------|------|
| **元画像** | ROI切り出し | ROI切り出し |
| **セグメンテーション** | オーバーレイ合成 | オーバーレイ合成 |

- 赤: Eyelid（眼瞼）
- 緑: Iris（虹彩）
- 青: Pupil（瞳孔）

## License

See [LICENSE](LICENSE) file.
