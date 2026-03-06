//
//  ContentView.swift
//  DIstance_rearCAM
//
//  Created by Yoshiyuki Kitaguchi on 2026/03/04.
//

import SwiftUI

struct ContentView: View {
    @State private var showLiDARAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()

                Image(systemName: "camera.metering.spot")
                    .font(.system(size: 72))
                    .foregroundStyle(.blue)

                Text("Distance rearCAM")
                    .font(.largeTitle.bold())

                Text("LiDARで眼瞼までの距離を測定")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                NavigationLink {
                    CameraView()
                } label: {
                    Label("Start", systemImage: "arrow.right.circle.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!ARSessionManager.isLiDARAvailable)
                .padding(.horizontal, 40)

                Spacer()
                    .frame(height: 60)
            }
            .onAppear {
                if !ARSessionManager.isLiDARAvailable {
                    showLiDARAlert = true
                }
            }
            .alert("LiDAR非対応", isPresented: $showLiDARAlert) {
                Button("OK") {}
            } message: {
                Text("このデバイスはLiDARセンサーに対応していません。LiDAR搭載のiPad ProまたはiPhone Proが必要です。")
            }
        }
    }
}

#Preview {
    ContentView()
}
