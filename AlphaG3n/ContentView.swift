//
//  ContentView.swift
//  AlphaG3n
//
//  Created by Peter Zhao on 5/23/26.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraManager()

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session, detections: camera.liveDetections)
                .ignoresSafeArea()

            VStack {
                //cameraPicker
                Spacer()
                shutterButton
            }
            .padding()

            overlay
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    @ViewBuilder
    private var overlay: some View {
        switch camera.captureState {
        case .idle:
            EmptyView()
        case .processing:
            processingOverlay
        case .result(let image):
            ResultOverlay(image: image) { camera.resetCaptureState() }
        case .failed(let message):
            FailureOverlay(message: message) { camera.resetCaptureState() }
        }
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.4)
                Text("Reading document…")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
        }
        .transition(.opacity)
    }

    /// Lets you pick among the cameras the device actually has.
    /// Only shown when there's more than one to choose from.
    @ViewBuilder
    private var cameraPicker: some View {
        if camera.availableCameras.count > 1 {
            Picker("Camera", selection: cameraSelection) {
                ForEach(camera.availableCameras, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device as AVCaptureDevice?)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var cameraSelection: Binding<AVCaptureDevice?> {
        Binding(
            get: { camera.selectedCamera },
            set: { device in if let device { camera.selectCamera(device) } }
        )
    }

    private var shutterButton: some View {
        Button(action: camera.capturePhoto) {
            Circle()
                .fill(.white)
                .frame(width: 70, height: 70)
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.6), lineWidth: 4)
                        .padding(4)
                )
        }
        .disabled(!camera.captureState.isIdle)
        .opacity(camera.captureState.isIdle ? 1 : 0.4)
    }
}

// MARK: - Result / failure overlays

private struct ResultOverlay: View {
    let image: UIImage
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .ignoresSafeArea(edges: .bottom)

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                }
                .padding()
                Spacer()
            }
        }
        .transition(.opacity)
    }
}

private struct FailureOverlay: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .transition(.opacity)
    }
}

private extension CameraManager.CaptureState {
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

#Preview {
    ContentView()
}
