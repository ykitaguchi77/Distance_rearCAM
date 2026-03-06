//
//  AnalysisView.swift
//  DIstance_rearCAM
//
//  Created by Claude on 2026/03/06.
//

import SwiftUI

struct AnalysisView: View {
    let capturedFrame: CapturedFrame
    let onDismiss: () -> Void

    @State private var segManager = SegmentationManager()
    @State private var analysisStarted = false

    private var headerTitle: String {
        analysisStarted ? "セグメンテーション解析" : "撮影プレビュー"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text(headerTitle)
                .font(.headline)
                .padding()

            Divider()

            // Content
            if !analysisStarted {
                // プレビュー画面
                ScrollView {
                    VStack(spacing: 12) {
                        // 全体画像プレビュー
                        Image(uiImage: capturedFrame.fullImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 12)

                        // ROIサムネイル（横スクロール）
                        if !capturedFrame.eyeROIs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("検出ROI (\(capturedFrame.eyeROIs.count)件)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 12)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(capturedFrame.eyeROIs) { roi in
                                            VStack(spacing: 2) {
                                                Image(uiImage: UIImage(cgImage: roi.croppedImage))
                                                    .resizable()
                                                    .aspectRatio(1, contentMode: .fit)
                                                    .frame(width: 100, height: 100)
                                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                                Text(roi.label == "Right_eye" ? "右眼" : roi.label == "Left_eye" ? "左眼" : roi.label)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                }
                            }
                        } else {
                            Text("眼瞼ROIが検出されていません")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding()
                        }
                    }
                    .padding(.vertical, 8)
                }

                Divider()

                // 解析開始ボタン
                Button {
                    analysisStarted = true
                    segManager.analyze(frame: capturedFrame)
                } label: {
                    Label("解析を開始", systemImage: "wand.and.stars")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(capturedFrame.eyeROIs.isEmpty ? Color.gray : Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(capturedFrame.eyeROIs.isEmpty)
                .padding(.horizontal)
                .padding(.vertical, 4)

                // 戻るボタン
                Button {
                    onDismiss()
                } label: {
                    Label("撮り直す", systemImage: "arrow.uturn.backward")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

            } else if segManager.isProcessing {
                ZStack {
                    // 撮影画像を背景に表示（クリア表示）
                    Image(uiImage: capturedFrame.fullImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)

                    // 半透明オーバーレイ（ブラーなし）
                    Color.black.opacity(0.3)

                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("推論中...")
                            .foregroundColor(.white)
                    }
                }

                Divider()

                // 戻るボタン（解析中 → キャンセルして戻る）
                Button {
                    segManager.cancel()
                    onDismiss()
                } label: {
                    Label("動画に戻る", systemImage: "video.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

            } else if let error = segManager.errorMessage {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()

                Divider()

                Button {
                    onDismiss()
                } label: {
                    Label("動画に戻る", systemImage: "video.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

            } else if segManager.results.isEmpty {
                Spacer()
                Text("解析結果なし")
                    .foregroundColor(.secondary)
                Spacer()

                Divider()

                Button {
                    onDismiss()
                } label: {
                    Label("動画に戻る", systemImage: "video.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

            } else {
                ResultsGridView(results: segManager.results)

                Divider()

                Button {
                    onDismiss()
                } label: {
                    Label("動画に戻る", systemImage: "video.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Results Grid (2x2: 上段=元写真, 下段=inferenceオーバーレイ)

private struct ResultsGridView: View {
    let results: [SegmentationResult]

    private var rightEye: SegmentationResult? {
        results.first { $0.eyeLabel == "Right_eye" }
    }
    private var leftEye: SegmentationResult? {
        results.first { $0.eyeLabel == "Left_eye" }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                // ラベル行
                HStack(spacing: 8) {
                    eyeLabel(rightEye, name: "右眼")
                    eyeLabel(leftEye, name: "左眼")
                }
                .padding(.horizontal, 12)

                // 上段: 元写真
                HStack(spacing: 8) {
                    eyeImage(rightEye?.roiImage)
                    eyeImage(leftEye?.roiImage)
                }
                .padding(.horizontal, 12)

                // 下段: inferenceオーバーレイ
                HStack(spacing: 8) {
                    eyeImage(rightEye?.overlayImage)
                    eyeImage(leftEye?.overlayImage)
                }
                .padding(.horizontal, 12)

                // 凡例 + ピクセル数
                VStack(spacing: 4) {
                    HStack(spacing: 16) {
                        LegendItem(color: .red, label: "Eyelid")
                        LegendItem(color: .green, label: "Iris")
                        LegendItem(color: .blue, label: "Pupil")
                    }
                    .font(.caption2)

                    if let r = rightEye {
                        pixelCountRow("右眼", counts: r.pixelCounts)
                    }
                    if let l = leftEye {
                        pixelCountRow("左眼", counts: l.pixelCounts)
                    }
                }
                .padding(8)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func eyeLabel(_ result: SegmentationResult?, name: String) -> some View {
        HStack {
            Text(name)
                .font(.caption.bold())
            Spacer()
            if let d = result?.distance {
                Text(String(format: "%.2fm", d))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func eyeImage(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.systemGray5))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Text("--")
                        .foregroundColor(.secondary)
                }
        }
    }

    private func pixelCountRow(_ label: String, counts: [Int]) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.bold())
                .frame(width: 30, alignment: .leading)
            Text("Eyelid:\(counts[0])")
            Text("Iris:\(counts[1])")
            Text("Pupil:\(counts[2])")
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundColor(.secondary)
    }
}

// MARK: - Legend Item

private struct LegendItem: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
        }
    }
}
