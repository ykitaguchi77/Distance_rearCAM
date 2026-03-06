//
//  SegmentationManager.swift
//  DIstance_rearCAM
//
//  Created by Claude on 2026/03/06.
//

import CoreML
import UIKit

// MARK: - Segmentation Result

struct SegmentationResult: Identifiable {
    let id = UUID()
    let eyeLabel: String        // "Right_eye" / "Left_eye"
    let roiImage: UIImage       // 元のROI切り出し画像
    let overlayImage: UIImage   // マスクオーバーレイ合成画像
    let pixelCounts: [Int]      // [eyelid, iris, pupil] のピクセル数
    let distance: Float?
}

// MARK: - Segmentation Manager

@Observable
class SegmentationManager {
    var results: [SegmentationResult] = []
    var isProcessing = false
    var errorMessage: String?

    private var mlModel: MLModel?
    private let processingQueue = DispatchQueue(label: "com.app.segmentation", qos: .userInitiated)
    private var cancelled = false

    // ImageNet normalization constants
    private static let inputSize = 512
    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let std: [Float] = [0.229, 0.224, 0.225]
    private static let threshold: Float = 0.5

    // MARK: - Model Loading (lazy)

    private func loadModelIfNeeded() throws {
        guard mlModel == nil else { return }
        guard let url = Bundle.main.url(forResource: "EyelidSegFormer", withExtension: "mlmodelc") else {
            throw NSError(
                domain: "SegmentationManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "EyelidSegFormer.mlmodelc not found in bundle"]
            )
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine  // ARKit Metal競合回避
        mlModel = try MLModel(contentsOf: url, configuration: config)
        print("[SegFormer] Model loaded successfully")
    }

    // MARK: - Public API

    func analyze(frame: CapturedFrame) {
        isProcessing = true
        results = []
        errorMessage = nil
        cancelled = false

        processingQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.loadModelIfNeeded()
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "モデル読込失敗: \(error.localizedDescription)"
                    self.isProcessing = false
                }
                return
            }

            // 右眼・左眼を逐次処理（メモリ節約、キャンセルチェック付き）
            var newResults: [SegmentationResult] = []
            for roi in frame.eyeROIs {
                if self.cancelled { break }
                if let result = self.processROI(roi) {
                    newResults.append(result)
                }
            }

            DispatchQueue.main.async {
                if !self.cancelled {
                    self.results = newResults
                }
                self.isProcessing = false
            }
        }
    }

    func cancel() {
        cancelled = true
    }

    // MARK: - ROI Processing Pipeline

    private func processROI(_ roi: EyeROI) -> SegmentationResult? {
        guard let mlModel else { return nil }

        // 1. Preprocess: CGImage → 512x512 → ImageNet正規化 → MLMultiArray
        guard let inputArray = preprocess(image: roi.croppedImage) else {
            print("[SegFormer] Preprocessing failed for \(roi.label)")
            return nil
        }

        // 2. Predict
        let inputFeatures: MLDictionaryFeatureProvider
        do {
            inputFeatures = try MLDictionaryFeatureProvider(
                dictionary: ["input": MLFeatureValue(multiArray: inputArray)]
            )
        } catch {
            print("[SegFormer] Feature provider creation failed: \(error)")
            return nil
        }

        guard let prediction = try? mlModel.prediction(from: inputFeatures),
              let output = prediction.featureValue(for: "probabilities")?.multiArrayValue
        else {
            print("[SegFormer] Prediction failed for \(roi.label)")
            return nil
        }

        // 3. Post-process: threshold → overlay → composite
        let roiUIImage = UIImage(cgImage: roi.croppedImage)
        let (overlayImage, pixelCounts) = generateOverlay(
            from: output, originalImage: roi.croppedImage
        )

        return SegmentationResult(
            eyeLabel: roi.label,
            roiImage: roiUIImage,
            overlayImage: overlayImage ?? roiUIImage,
            pixelCounts: pixelCounts,
            distance: roi.distance
        )
    }

    // MARK: - Preprocessing (ImageNet Normalization)

    private func preprocess(image: CGImage) -> MLMultiArray? {
        let size = Self.inputSize
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = 4 * size

        // 512x512 にリサイズして RGBX バイト列を取得
        let rawData = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * size)
        defer { rawData.deallocate() }

        guard let context = CGContext(
            data: rawData,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        // MLMultiArray [1, 3, 512, 512] (CHW format)
        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
            dataType: .float32
        ) else { return nil }

        let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let channelSize = size * size

        for y in 0..<size {
            for x in 0..<size {
                let pixelOffset = y * bytesPerRow + x * 4
                let r = Float(rawData[pixelOffset]) / 255.0
                let g = Float(rawData[pixelOffset + 1]) / 255.0
                let b = Float(rawData[pixelOffset + 2]) / 255.0

                let arrayIdx = y * size + x
                ptr[arrayIdx] = (r - Self.mean[0]) / Self.std[0]
                ptr[channelSize + arrayIdx] = (g - Self.mean[1]) / Self.std[1]
                ptr[2 * channelSize + arrayIdx] = (b - Self.mean[2]) / Self.std[2]
            }
        }

        return array
    }

    // MARK: - Overlay Generation

    private func generateOverlay(
        from output: MLMultiArray, originalImage: CGImage
    ) -> (UIImage?, [Int]) {
        let size = Self.inputSize
        let channelSize = size * size
        let threshold = Self.threshold

        var pixelCounts = [0, 0, 0]  // eyelid, iris, pupil
        var pixelData = [UInt8](repeating: 0, count: channelSize * 4)

        // Float32 dataPointer による高速アクセス
        guard output.dataType == .float32 else {
            print("[SegFormer] Unexpected output data type: \(output.dataType.rawValue)")
            // Fallback: NSNumber subscript (遅いが安全)
            return generateOverlayFallback(from: output, originalImage: originalImage)
        }

        let ptr = output.dataPointer.assumingMemoryBound(to: Float32.self)

        for i in 0..<channelSize {
            let eyelid = ptr[i]                        // Channel 0
            let iris = ptr[channelSize + i]             // Channel 1
            let pupil = ptr[2 * channelSize + i]        // Channel 2

            let pi = i * 4
            var hasClass = false

            if eyelid > threshold {
                pixelData[pi] = 128       // R (premultiplied: 255 * 0.5)
                pixelCounts[0] += 1
                hasClass = true
            }
            if iris > threshold {
                pixelData[pi + 1] = 128   // G
                pixelCounts[1] += 1
                hasClass = true
            }
            if pupil > threshold {
                pixelData[pi + 2] = 128   // B
                pixelCounts[2] += 1
                hasClass = true
            }
            if hasClass {
                pixelData[pi + 3] = 128   // A (50% opacity)
            }
        }

        return compositeOverlay(pixelData: pixelData, originalImage: originalImage, pixelCounts: pixelCounts)
    }

    private func generateOverlayFallback(
        from output: MLMultiArray, originalImage: CGImage
    ) -> (UIImage?, [Int]) {
        let size = Self.inputSize
        let channelSize = size * size
        let threshold = Self.threshold

        var pixelCounts = [0, 0, 0]
        var pixelData = [UInt8](repeating: 0, count: channelSize * 4)

        for i in 0..<channelSize {
            let row = i / size
            let col = i % size
            let eyelid = output[[0, 0, row as NSNumber, col as NSNumber]].floatValue
            let iris = output[[0, 1, row as NSNumber, col as NSNumber]].floatValue
            let pupil = output[[0, 2, row as NSNumber, col as NSNumber]].floatValue

            let pi = i * 4
            var hasClass = false

            if eyelid > threshold { pixelData[pi] = 128; pixelCounts[0] += 1; hasClass = true }
            if iris > threshold { pixelData[pi + 1] = 128; pixelCounts[1] += 1; hasClass = true }
            if pupil > threshold { pixelData[pi + 2] = 128; pixelCounts[2] += 1; hasClass = true }
            if hasClass { pixelData[pi + 3] = 128 }
        }

        return compositeOverlay(pixelData: pixelData, originalImage: originalImage, pixelCounts: pixelCounts)
    }

    private func compositeOverlay(
        pixelData: [UInt8], originalImage: CGImage, pixelCounts: [Int]
    ) -> (UIImage?, [Int]) {
        let size = Self.inputSize
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // オーバーレイ CGImage 生成
        let data = Data(pixelData)
        guard let provider = CGDataProvider(data: data as CFData),
              let overlayImage = CGImage(
                  width: size, height: size,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: size * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil, shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return (nil, pixelCounts) }

        // 元ROI画像 + オーバーレイ合成
        let roiWidth = CGFloat(originalImage.width)
        let roiHeight = CGFloat(originalImage.height)
        let compositeSize = CGSize(width: roiWidth, height: roiHeight)

        let renderer = UIGraphicsImageRenderer(size: compositeSize)
        let composited = renderer.image { _ in
            UIImage(cgImage: originalImage).draw(in: CGRect(origin: .zero, size: compositeSize))
            UIImage(cgImage: overlayImage).draw(in: CGRect(origin: .zero, size: compositeSize))
        }

        return (composited, pixelCounts)
    }
}
