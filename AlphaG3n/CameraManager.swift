//
//  CameraManager.swift
//  AlphaG3n
//
//  Created by Peter Zhao on 5/23/26.
//

@preconcurrency import AVFoundation
import Combine
import CoreImage
import UIKit

/// Owns the capture session and feeds the SwiftUI preview, per-frame pixels,
/// and captured photos.
///
/// The two hook methods — `didReceiveFrame(_:)` and `didCapturePhoto(_:)` — are
/// intentionally empty. Fill them in to do something with the pixels.
///
/// AVFoundation drives this class from its own background queues rather than the
/// main actor, so it is `nonisolated`. Access to the session is confined to
/// `sessionQueue` (hence `@unchecked Sendable`), and the UI-facing `@Published`
/// values are explicitly `@MainActor` so SwiftUI only ever reads them on main.
nonisolated final class CameraManager:
    NSObject,
    ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCapturePhotoCaptureDelegate,
    @unchecked Sendable {

    /// The session the SwiftUI preview layer renders.
    let session = AVCaptureSession()

    /// Cameras this device actually has (e.g. wide, ultra-wide, front).
    @MainActor @Published private(set) var availableCameras: [AVCaptureDevice] = []

    /// The camera currently feeding the session.
    @MainActor @Published private(set) var selectedCamera: AVCaptureDevice?

    /// What the UI should show: live camera, an in-flight OCR job, the
    /// finished overlay, or an error from the last attempt.
    @MainActor @Published private(set) var captureState: CaptureState = .idle

    enum CaptureState: @unchecked Sendable {
        case idle
        case processing
        case result(UIImage)
        case failed(String)
    }

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    /// Serial queue for all session configuration and start/stop work, so the
    /// main thread never blocks on `startRunning()`.
    private let sessionQueue = DispatchQueue(label: "camera.session")

    /// Dedicated queue on which live frames are delivered.
    private let videoQueue = DispatchQueue(label: "camera.video")


    /// Talks to the PaddleOCR job API. The API key is read from the app
    /// bundle's Info.plist (populated from `secrets.xcconfig` at build time) —
    /// see `Secrets.swift`.
    private let paddleClient = PaddleOCRClient.makeDefault()

    /// Reused to turn camera pixel buffers into JPEG data.
    private let ciContext = CIContext()

    // MARK: - Empty hooks for you to fill in

    /// Called on every live frame.
    /// Runs on `videoQueue` (a background thread) — dispatch to main before
    /// touching any UI.
    private func didReceiveFrame(_ pixelBuffer: CVPixelBuffer) {
        
    }

    /// Called once each time the shutter button finishes taking a photo.
    /// Runs on a background thread — dispatch to main before touching any UI.
    private func didCapturePhoto(_ pixelBuffer: CVPixelBuffer) {
        guard let imageData = jpegData(from: pixelBuffer) else {
            Task { @MainActor in
                self.captureState = .failed("Failed to encode the captured photo.")
            }
            return
        }
        Task { @MainActor in self.captureState = .processing }
        Task { await runOCR(on: imageData) }
    }

    /// Reset back to live camera. Call from the UI when the user dismisses
    /// the result or error overlay.
    @MainActor
    func resetCaptureState() {
        captureState = .idle
    }

    // MARK: - Lifecycle

    /// Requests camera access, configures the session once, and starts it.
    func start() {
        requestAccess { [weak self] granted in
            guard let self, granted else { return }
            self.sessionQueue.async {
                self.configureSessionIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - Camera selection

    /// Switches the live feed to one of the `availableCameras`.
    func selectCamera(_ camera: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            // Drop the current camera input.
            for input in self.session.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput,
                   deviceInput.device.hasMediaType(.video) {
                    self.session.removeInput(deviceInput)
                }
            }

            // Attach the chosen camera.
            guard let newInput = try? AVCaptureDeviceInput(device: camera),
                  self.session.canAddInput(newInput) else { return }
            self.session.addInput(newInput)

            Task { @MainActor in self.selectedCamera = camera }
        }
    }

    // MARK: - Photo capture

    /// Takes a still photo; the result is delivered to `didCapturePhoto(_:)`.
    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Request BGRA pixels so the result is guaranteed to carry a CVPixelBuffer.
            let settings = AVCapturePhotoSettings(format: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Session configuration

    private func configureSessionIfNeeded() {
        // Inputs are only added during configuration, so an empty list means
        // we haven't set the session up yet.
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        let cameras = discoverCameras()
        Task { @MainActor in self.availableCameras = cameras }

        // Start on the back camera, falling back to whatever is first.
        let defaultCamera = cameras.first { $0.position == .back } ?? cameras.first
        if let defaultCamera,
           let input = try? AVCaptureDeviceInput(device: defaultCamera),
           session.canAddInput(input) {
            session.addInput(input)
            Task { @MainActor in self.selectedCamera = defaultCamera }
        }

        // Per-frame output. BGRA keeps frames consistent with captured photos.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // Still-photo output.
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()
    }

    /// Finds every built-in camera on the device, front and back.
    private func discoverCameras() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    private func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
        default:
            completion(false)
        }
    }

    // MARK: - PaddleOCR upload

    /// Uploads the captured photo to PaddleOCR, builds a `VirtualDocument`
    /// from the first returned page, renders the color-coded overlay, and
    /// publishes it via `captureState` for the UI.
    private func runOCR(on imageData: Data) async {
        guard PaddleOCRClient.isAPIKeyConfigured else {
            await publishFailure("Set the PaddleOCR API key in secrets.xcconfig before capturing.")
            return
        }

        let tempDirectory = FileManager.default.temporaryDirectory
        let imageURL = tempDirectory.appendingPathComponent("capture-\(UUID().uuidString).jpg")
        let outputDirectory = tempDirectory.appendingPathComponent("paddleocr-\(UUID().uuidString)")

        do {
            try imageData.write(to: imageURL)
            let pages = try await paddleClient.process(
                fileURL: imageURL,
                optionalPayload: OptionalPayload(useDocOrientationClassify: true),
                outputDirectory: outputDirectory
            )

            guard let page = pages.first else {
                await publishFailure("PaddleOCR returned no pages.")
                return
            }
            guard let pruned = page.prunedResult else {
                await publishFailure("PaddleOCR response was missing layout data.")
                return
            }

            // Prefer the deskewed/oriented preprocessed image (its coordinate
            // space matches the bboxes). Fall back to the original capture.
            let sourceImage: UIImage = {
                if let url = page.preprocessedImageURL,
                   let data = try? Data(contentsOf: url),
                   let img = UIImage(data: data) {
                    return img
                }
                return UIImage(data: imageData) ?? UIImage()
            }()

            let document = VirtualDocument.make(from: pruned, image: sourceImage)
            let overlay = document.render()
            await MainActor.run { self.captureState = .result(overlay) }
        } catch {
            await publishFailure("PaddleOCR error: \(error)")
        }
    }

    @MainActor
    private func publishFailure(_ message: String) {
        captureState = .failed(message)
    }

    /// Encodes a camera pixel buffer as JPEG data for upload.
    private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
    }

    // MARK: - AVCapture delegate callbacks

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        didReceiveFrame(pixelBuffer)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let pixelBuffer = photo.pixelBuffer else { return }
        didCapturePhoto(pixelBuffer)
    }
}
