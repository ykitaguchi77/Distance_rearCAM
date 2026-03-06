//
//  ARSessionManager.swift
//  DIstance_rearCAM
//
//  Created by Claude on 2026/03/05.
//

import ARKit
import AVFoundation
import CoreML
import Vision

struct FaceData: Identifiable, Sendable {
    let id: UUID
    let displayRect: CGRect
    let distance: Float?
    let label: String?
    let confidence: Float?
}

// MARK: - Captured Frame for Analysis

struct EyeROI: Identifiable {
    let id: UUID
    let label: String          // "Right_eye" / "Left_eye"
    let croppedImage: CGImage  // 正方形ROI
    let distance: Float?
}

struct CapturedFrame {
    let fullImage: UIImage
    let eyeROIs: [EyeROI]
}

// MARK: - Detection Result (internal)

private struct DetectionResult {
    let boundingBox: CGRect
    let label: String?
    let confidence: Float?
}

// MARK: - Tracked Face (visual smoothing for bbox, raw distance)

private struct TrackedFace {
    let id: UUID
    var smoothedRect: CGRect   // EMA smoothed for display
    var distance: Float?       // raw value, no averaging
    var missCount: Int
    var label: String?
    var confidence: Float?
}

@Observable
class ARSessionManager: NSObject, ARSessionDelegate {
    var faces: [FaceData] = []
    var primaryDistance: Float?
    var screenshotTaken = false
    var modelLoaded = false
    var capturedFrame: CapturedFrame?
    var flashEnabled = false
    var currentZoomFactor: CGFloat = 1.0
    var captureCount = 0
    weak var sceneView: ARSCNView?

    private let arSession = ARSession()
    private let processingQueue = DispatchQueue(label: "com.app.faceDetection", qos: .userInitiated)
    private var isProcessing = false

    // YOLO CoreML model
    private var visionModel: VNCoreMLModel?

    // UI tracking (MainActor)
    private var trackedFaces: [TrackedFace] = []
    private let maxMissCount = 2
    private let matchThreshold: CGFloat = 50
    private let smoothingAlpha: CGFloat = 0.4

    // Frame skip (processingQueue only)
    private var processedFrameCount = 0
    private let detectionInterval = 1

    static var isLiDARAvailable: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    override init() {
        super.init()
        loadYOLOModel()
    }

    // MARK: - Model Loading

    private func loadYOLOModel() {
        guard let modelURL = Bundle.main.url(forResource: "EyelidDetector", withExtension: "mlmodelc") else {
            print("[EyelidDetector] mlmodelc not found in bundle")
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            visionModel = try VNCoreMLModel(for: mlModel)
            modelLoaded = true
            print("[EyelidDetector] Model loaded successfully")
        } catch {
            print("[EyelidDetector] Failed to load model: \(error)")
        }
    }

    func startSession(for view: ARSCNView) {
        sceneView = view
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics.insert(.sceneDepth)
        arSession.delegate = self
        view.session = arSession
        arSession.run(config)
    }

    func pauseSession() {
        arSession.pause()
    }

    func resumeSession() {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics.insert(.sceneDepth)
        arSession.run(config)
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !isProcessing, visionModel != nil else { return }
        isProcessing = true

        let pixelBuffer = frame.capturedImage
        let depthMap = frame.sceneDepth?.depthMap
        let interfaceOrientation = Self.currentInterfaceOrientation()
        let visionOri = Self.visionOrientation(for: interfaceOrientation)
        let viewSize = sceneView?.bounds.size ?? CGSize(width: 1, height: 1)

        // カメラ画像サイズ（landscape）
        let rawW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let rawH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        processingQueue.async { [weak self] in
            guard let self else { return }

            self.processedFrameCount += 1
            guard self.processedFrameCount % self.detectionInterval == 0 else {
                DispatchQueue.main.async { self.isProcessing = false }
                return
            }

            var currentDetections = self.runDetection(
                pixelBuffer: pixelBuffer, orientation: visionOri)

            currentDetections.sort {
                $0.boundingBox.width * $0.boundingBox.height
                    > $1.boundingBox.width * $1.boundingBox.height
            }

            // カメラ画像の表示サイズ計算（アスペクトフィル）
            let displayImageW: CGFloat
            let displayImageH: CGFloat
            switch interfaceOrientation {
            case .portrait, .portraitUpsideDown:
                displayImageW = rawH  // 回転後
                displayImageH = rawW
            default:
                displayImageW = rawW
                displayImageH = rawH
            }

            let scale = max(viewSize.width / displayImageW, viewSize.height / displayImageH)
            let mappedW = displayImageW * scale
            let mappedH = displayImageH * scale
            let offsetX = (mappedW - viewSize.width) / 2
            let offsetY = (mappedH - viewSize.height) / 2

            var detections: [(displayRect: CGRect, distance: Float?, label: String?, confidence: Float?)] = []
            for det in currentDetections {
                let bbox = det.boundingBox
                let displayRect: CGRect
                switch interfaceOrientation {
                case .portrait:
                    displayRect = CGRect(
                        x: bbox.minX * mappedW - offsetX,
                        y: (1 - bbox.maxY) * mappedH - offsetY,
                        width: bbox.width * mappedW,
                        height: bbox.height * mappedH
                    )
                default:
                    displayRect = CGRect(
                        x: (1 - bbox.maxX) * mappedW - offsetX,
                        y: bbox.minY * mappedH - offsetY,
                        width: bbox.width * mappedW,
                        height: bbox.height * mappedH
                    )
                }

                let distance = depthMap.flatMap {
                    Self.readDepth(from: $0, visionBBox: bbox, orientation: visionOri)
                }
                detections.append((displayRect: displayRect, distance: distance,
                                   label: det.label, confidence: det.confidence))
            }

            DispatchQueue.main.async { [weak self] in
                self?.updateTracking(with: detections)
                self?.isProcessing = false
            }
        }
    }

    // MARK: - Detection & Tracking (processingQueue)

    private func runDetection(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> [DetectionResult] {
        guard let visionModel else { return [] }

        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        try? handler.perform([request])

        let results = (request.results as? [VNRecognizedObjectObservation]) ?? []
        return results.map { obs in
            let topLabel = obs.labels.first
            return DetectionResult(
                boundingBox: obs.boundingBox,
                label: topLabel?.identifier,
                confidence: topLabel.map { Float($0.confidence) }
            )
        }
    }

    // MARK: - Orientation

    private static func currentInterfaceOrientation() -> UIInterfaceOrientation {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return .portrait
        }
        return scene.effectiveGeometry.interfaceOrientation
    }

    private static func visionOrientation(
        for interfaceOrientation: UIInterfaceOrientation
    ) -> CGImagePropertyOrientation {
        switch interfaceOrientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
        }
    }

    // MARK: - Face Tracking (MainActor)

    private func updateTracking(
        with detections: [(displayRect: CGRect, distance: Float?, label: String?, confidence: Float?)]
    ) {
        var usedTrackIDs = Set<UUID>()
        var updatedFaces: [TrackedFace] = []

        for detection in detections {
            let bestMatch = trackedFaces
                .filter { !usedTrackIDs.contains($0.id) }
                .min {
                    Self.centerDistance($0.smoothedRect, detection.displayRect)
                        < Self.centerDistance($1.smoothedRect, detection.displayRect)
                }

            if let match = bestMatch,
                Self.centerDistance(match.smoothedRect, detection.displayRect) < matchThreshold
            {
                // Reuse existing ID, smooth bbox position, raw distance
                let face = TrackedFace(
                    id: match.id,
                    smoothedRect: Self.smoothRect(
                        match.smoothedRect, towards: detection.displayRect, alpha: smoothingAlpha),
                    distance: detection.distance,
                    missCount: 0,
                    label: detection.label,
                    confidence: detection.confidence
                )
                usedTrackIDs.insert(face.id)
                updatedFaces.append(face)
            } else {
                let newFace = TrackedFace(
                    id: UUID(),
                    smoothedRect: detection.displayRect,
                    distance: detection.distance,
                    missCount: 0,
                    label: detection.label,
                    confidence: detection.confidence
                )
                updatedFaces.append(newFace)
            }
        }

        for face in trackedFaces where !usedTrackIDs.contains(face.id) {
            var f = face
            f.missCount += 1
            if f.missCount <= maxMissCount {
                updatedFaces.append(f)
            }
        }

        trackedFaces = updatedFaces

        let sorted = trackedFaces.sorted {
            $0.smoothedRect.width * $0.smoothedRect.height
                > $1.smoothedRect.width * $1.smoothedRect.height
        }

        faces = sorted.map {
            FaceData(
                id: $0.id,
                displayRect: $0.smoothedRect,
                distance: $0.distance,
                label: $0.label,
                confidence: $0.confidence
            )
        }
        primaryDistance = sorted.first?.distance
    }

    private static func centerDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return sqrt(dx * dx + dy * dy)
    }

    private static func smoothRect(_ old: CGRect, towards new: CGRect, alpha: CGFloat) -> CGRect {
        CGRect(
            x: old.minX + alpha * (new.minX - old.minX),
            y: old.minY + alpha * (new.minY - old.minY),
            width: old.width + alpha * (new.width - old.width),
            height: old.height + alpha * (new.height - old.height)
        )
    }

    // MARK: - Depth Reading

    private nonisolated static func readDepth(
        from depthMap: CVPixelBuffer,
        visionBBox bbox: CGRect,
        orientation: CGImagePropertyOrientation
    ) -> Float? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let vx = bbox.midX
        let vy = bbox.midY

        let col: Int
        let row: Int
        switch orientation {
        case .right:
            col = Int((1 - vy) * CGFloat(width))
            row = Int((1 - vx) * CGFloat(height))
        case .left:
            col = Int(vy * CGFloat(width))
            row = Int(vx * CGFloat(height))
        case .up:
            col = Int(vx * CGFloat(width))
            row = Int((1 - vy) * CGFloat(height))
        case .down:
            col = Int((1 - vx) * CGFloat(width))
            row = Int(vy * CGFloat(height))
        default:
            col = Int(vx * CGFloat(width))
            row = Int((1 - vy) * CGFloat(height))
        }

        guard col >= 0, col < width, row >= 0, row < height,
            let base = CVPixelBufferGetBaseAddress(depthMap)
        else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let offset = row * bytesPerRow + col * MemoryLayout<Float32>.size
        let depth = base.advanced(by: offset).assumingMemoryBound(to: Float32.self).pointee

        guard depth > 0, depth.isFinite, depth < 5 else { return nil }
        return depth
    }

    // MARK: - Screenshot

    func captureScreenshot() {
        guard let sceneView else { return }
        let snapshot = sceneView.snapshot()

        let imageSize = snapshot.size
        let viewBounds = sceneView.bounds
        let scaleX = imageSize.width / viewBounds.width
        let scaleY = imageSize.height / viewBounds.height

        let renderer = UIGraphicsImageRenderer(size: imageSize)
        let composited = renderer.image { ctx in
            snapshot.draw(at: .zero)

            for face in faces {
                let imageRect = CGRect(
                    x: face.displayRect.origin.x * scaleX,
                    y: face.displayRect.origin.y * scaleY,
                    width: face.displayRect.size.width * scaleX,
                    height: face.displayRect.size.height * scaleY
                )

                let boxColor: UIColor
                switch face.label {
                case "Right_eye": boxColor = .cyan
                case "Left_eye": boxColor = .yellow
                default: boxColor = .green
                }

                ctx.cgContext.setStrokeColor(boxColor.cgColor)
                ctx.cgContext.setLineWidth(3)
                ctx.cgContext.stroke(imageRect)

                if let distance = face.distance {
                    let prefix: String
                    switch face.label {
                    case "Right_eye": prefix = "R "
                    case "Left_eye": prefix = "L "
                    default: prefix = ""
                    }
                    let text = prefix + String(format: "%.2f m", distance)
                    let fontSize: CGFloat = 20 * min(scaleX, scaleY)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
                        .foregroundColor: boxColor,
                        .strokeColor: UIColor.black,
                        .strokeWidth: -3,
                    ]
                    let textSize = (text as NSString).size(withAttributes: attrs)
                    let textPoint = CGPoint(
                        x: imageRect.midX - textSize.width / 2,
                        y: imageRect.minY - textSize.height - 4
                    )
                    (text as NSString).draw(at: textPoint, withAttributes: attrs)
                }
            }

            if let distance = primaryDistance {
                let text = String(format: "%.2f m", distance)
                let fontSize: CGFloat = 48 * min(scaleX, scaleY)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: UIColor.white,
                    .strokeColor: UIColor.black,
                    .strokeWidth: -4,
                ]
                let textSize = (text as NSString).size(withAttributes: attrs)
                let textPoint = CGPoint(
                    x: (imageSize.width - textSize.width) / 2,
                    y: imageSize.height - textSize.height - 80 * scaleY
                )
                (text as NSString).draw(at: textPoint, withAttributes: attrs)
            }
        }

        UIImageWriteToSavedPhotosAlbum(composited, nil, nil, nil)
        screenshotTaken = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.screenshotTaken = false
        }
    }

    // MARK: - Torch Control

    private func setTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    // MARK: - Zoom Control (デジタルズーム)
    // ズーム表示はSwiftUIの.scaleEffect()で行う。ここではfactorの管理のみ。

    func setZoom(factor: CGFloat) {
        currentZoomFactor = min(max(factor, 1.0), 3.0)
    }

    /// デジタルズーム分を中央クロップする
    private func applyZoomCrop(to image: UIImage) -> UIImage {
        guard currentZoomFactor > 1.01, let cgImage = image.cgImage else { return image }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let cropW = w / currentZoomFactor
        let cropH = h / currentZoomFactor
        let cropRect = CGRect(
            x: (w - cropW) / 2,
            y: (h - cropH) / 2,
            width: cropW,
            height: cropH
        )
        guard let cropped = cgImage.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Frame Capture for Segmentation Analysis

    func captureFrameForAnalysis() {
        guard let sceneView else { return }

        if flashEnabled { setTorch(on: true) }

        // LED安定待ち後にスナップショット
        DispatchQueue.main.asyncAfter(deadline: .now() + (flashEnabled ? 0.2 : 0)) { [weak self] in
            guard let self else { return }
            let snapshot = sceneView.snapshot()
            if self.flashEnabled { self.setTorch(on: false) }

            // ROI切り出しはフルフレームから行う（座標がフルフレーム基準のため）
            guard let fullCGImage = snapshot.cgImage else { return }

            let fullW = CGFloat(fullCGImage.width)
            let fullH = CGFloat(fullCGImage.height)
            let viewBounds = sceneView.bounds
            let pixelScaleX = fullW / viewBounds.width
            let pixelScaleY = fullH / viewBounds.height

            var eyeROIs: [EyeROI] = []

            for face in self.faces {
                guard face.label == "Right_eye" || face.label == "Left_eye" else { continue }

                let imageRect = CGRect(
                    x: face.displayRect.origin.x * pixelScaleX,
                    y: face.displayRect.origin.y * pixelScaleY,
                    width: face.displayRect.size.width * pixelScaleX,
                    height: face.displayRect.size.height * pixelScaleY
                )

                let paddedWidth = imageRect.width * 1.5
                let squareSize = max(paddedWidth, imageRect.height * 1.5)
                let centerX = imageRect.midX
                let centerY = imageRect.midY

                var cropRect = CGRect(
                    x: centerX - squareSize / 2,
                    y: centerY - squareSize / 2,
                    width: squareSize,
                    height: squareSize
                )

                cropRect = cropRect.intersection(
                    CGRect(x: 0, y: 0, width: fullW, height: fullH)
                )

                guard !cropRect.isEmpty,
                      let croppedImage = fullCGImage.cropping(to: cropRect)
                else { continue }

                eyeROIs.append(EyeROI(
                    id: face.id,
                    label: face.label ?? "Unknown",
                    croppedImage: croppedImage,
                    distance: face.distance
                ))
            }

            // 表示用のfullImageのみズームクロップ適用
            let displayImage = self.applyZoomCrop(to: snapshot)

            self.capturedFrame = CapturedFrame(
                fullImage: displayImage,
                eyeROIs: eyeROIs
            )
            self.captureCount += 1
        }
    }
}
