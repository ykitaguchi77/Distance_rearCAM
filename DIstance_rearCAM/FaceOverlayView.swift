//
//  FaceOverlayView.swift
//  DIstance_rearCAM
//
//  Created by Claude on 2026/03/05.
//

import SwiftUI

struct FaceOverlayView: View {
    let faces: [FaceData]

    var body: some View {
        Canvas { context, size in
            for face in faces {
                let rect = face.displayRect

                let color: Color
                switch face.label {
                case "Right_eye": color = .cyan
                case "Left_eye": color = .yellow
                default: color = .green
                }

                // Bounding box
                context.stroke(Path(rect), with: .color(color), lineWidth: 2)

                // Distance label above the box
                if let distance = face.distance {
                    let prefix: String
                    switch face.label {
                    case "Right_eye": prefix = "R "
                    case "Left_eye": prefix = "L "
                    default: prefix = ""
                    }
                    let text = Text(prefix + String(format: "%.2f m", distance))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(color)
                    context.draw(
                        text,
                        at: CGPoint(x: rect.midX, y: rect.minY - 14),
                        anchor: .bottom
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
