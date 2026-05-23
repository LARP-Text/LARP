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
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            VStack {
                cameraPicker
                Spacer()
                shutterButton
            }
            .padding()
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
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
    }
}

#Preview {
    ContentView()
}
