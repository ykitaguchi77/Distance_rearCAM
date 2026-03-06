//
//  CameraView.swift
//  DIstance_rearCAM
//
//  Created by Claude on 2026/03/05.
//

import ARKit
import SwiftUI

// MARK: - ARSCNView Wrapper

struct ARViewContainer: UIViewRepresentable {
    let sessionManager: ARSessionManager

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView()
        scnView.automaticallyUpdatesLighting = true
        sessionManager.startSession(for: scnView)
        return scnView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) {
        uiView.session.pause()
    }
}

// MARK: - Camera Screen

struct CameraView: View {
    @State private var sessionManager = ARSessionManager()
    @State private var showAnalysis = false
    @State private var selectedZoom: CGFloat = 1.0

    private let zoomLevels: [CGFloat] = [1, 2, 3]

    var body: some View {
        ZStack {
            // AR camera feed + face overlay（デジタルズームで一緒にスケール）
            ARViewContainer(sessionManager: sessionManager)
                .scaleEffect(sessionManager.currentZoomFactor)
                .ignoresSafeArea()

            FaceOverlayView(faces: sessionManager.faces)
                .scaleEffect(sessionManager.currentZoomFactor)
                .ignoresSafeArea()

            // --- UI Overlay (3-column layout) ---

            // Center top: distance + detection count
            VStack {
                VStack(spacing: 4) {
                    if let distance = sessionManager.primaryDistance {
                        Text(String(format: "%.2f m", distance))
                            .font(.system(size: 56, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .shadow(color: .black, radius: 4, x: 0, y: 2)
                    }

                    if !sessionManager.faces.isEmpty {
                        Text("眼瞼検出: \(sessionManager.faces.count)箇所")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }

                    if !sessionManager.modelLoaded {
                        Text("モデル未読込")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.top, 60)

                Spacer()
            }

            // Left side: flash button (center) + zoom buttons (bottom)
            HStack {
                VStack {
                    Spacer()

                    // Flash toggle
                    Button {
                        sessionManager.flashEnabled.toggle()
                    } label: {
                        Image(systemName: sessionManager.flashEnabled
                              ? "bolt.fill" : "bolt.slash.fill")
                            .font(.system(size: 24))
                            .foregroundColor(sessionManager.flashEnabled
                                             ? .yellow : .white.opacity(0.7))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    Spacer()

                    // Zoom buttons
                    VStack(spacing: 8) {
                        ForEach(zoomLevels, id: \.self) { zoom in
                            Button {
                                selectedZoom = zoom
                                sessionManager.setZoom(factor: zoom)
                            } label: {
                                Text("×\(Int(zoom))")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(selectedZoom == zoom ? .yellow : .white)
                                    .frame(width: 40, height: 40)
                                    .background(selectedZoom == zoom
                                                 ? Color.white.opacity(0.3)
                                                 : Color.clear)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
                .padding(.leading, 16)

                Spacer()
            }

            // Right bottom: capture button
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        sessionManager.captureFrameForAnalysis()
                    } label: {
                        Image(systemName: "camera.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.white, .white.opacity(0.3))
                            .shadow(radius: 4)
                    }
                    .padding(.trailing, 24)
                    .padding(.bottom, 40)
                }
            }
        }
        .onDisappear {
            sessionManager.pauseSession()
        }
        .navigationBarBackButtonHidden(false)
        .toolbarBackground(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showAnalysis) {
            if let frame = sessionManager.capturedFrame {
                AnalysisView(capturedFrame: frame) {
                    showAnalysis = false
                }
            }
        }
        .onChange(of: sessionManager.captureCount) { _, _ in
            if sessionManager.capturedFrame != nil {
                showAnalysis = true
            }
        }
        .onChange(of: showAnalysis) { _, isShowing in
            if isShowing {
                sessionManager.pauseSession()
            } else {
                sessionManager.resumeSession()
            }
        }
    }
}
