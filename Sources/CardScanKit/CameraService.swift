#if os(iOS)
import AVFoundation
import ImageIO
import SwiftUI
import UIKit
import Vision

/// Owns AVFoundation and Vision. The model receives OCR text only; no image is stored.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.andronuke.cardscan.session")
    private let analysisQueue = DispatchQueue(label: "com.andronuke.cardscan.analysis")
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var lastAnalysis: TimeInterval = 0
    private let onFrame: @MainActor ([OCRLine], CGSize) -> Void
    private let onStatus: @MainActor (String, Bool) -> Void
    private let onTorch: @MainActor (Bool) -> Void

    init(onFrame: @escaping @MainActor ([OCRLine], CGSize) -> Void,
         onStatus: @escaping @MainActor (String, Bool) -> Void,
         onTorch: @escaping @MainActor (Bool) -> Void) {
        self.onFrame = onFrame
        self.onStatus = onStatus
        self.onTorch = onTorch
    }

    func start() async {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard authorized else {
            await onStatus("Camera permission denied. Enter details manually or enable it in Settings.", true)
            return
        }
        let ready = await withCheckedContinuation { continuation in
            sessionQueue.async {
                do {
                    if !self.configured { try self.configure() }
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
        await onStatus(ready ? "Hold steady and avoid reflections." :
            "Camera unavailable. Enter details manually.", !ready)
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            if let device = self.device, device.hasTorch, device.torchMode == .on {
                if (try? device.lockForConfiguration()) != nil {
                    device.torchMode = .off
                    device.unlockForConfiguration()
                }
            }
            Task { @MainActor in self.onTorch(false) }
        }
    }

    func toggleTorch() {
        sessionQueue.async {
            guard let device = self.device, self.session.isRunning else {
                Task { @MainActor in self.onStatus("Camera is starting. Try the flash again in a moment.", false) }
                return
            }
            guard device.hasTorch else {
                Task { @MainActor in self.onStatus("Flash is unavailable on this camera.", false) }
                return
            }
            do {
                try device.lockForConfiguration()
                let enabled = device.torchMode != .on
                device.torchMode = enabled ? .on : .off
                device.unlockForConfiguration()
                Task { @MainActor in self.onTorch(enabled) }
            } catch {
                Task { @MainActor in self.onStatus("Flash is unavailable on this camera.", false) }
            }
        }
    }

    func focus(at layerPoint: CGPoint, in previewLayer: AVCaptureVideoPreviewLayer) {
        let point = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        sessionQueue.async {
            guard let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in self.onStatus("Could not focus. Hold the card steady.", false) }
            }
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw CameraError.unavailable }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CameraError.unavailable }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: analysisQueue)
        device = camera
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let time = CACurrentMediaTime()
        guard time - lastAnalysis >= 0.25, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = time
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // Card digits should not become words.
        request.recognitionLanguages = ["en-US"]
        do {
            // Back-camera buffers are landscape; .right gives portrait Vision coordinates.
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right).perform([request])
            let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let box = observation.boundingBox
                return OCRLine(text: text, top: 1 - box.maxY, left: box.minX, boundingBox: box)
            }
            let portraitSize = CGSize(width: CVPixelBufferGetHeight(buffer), height: CVPixelBufferGetWidth(buffer))
            Task { @MainActor in self.onFrame(lines, portraitSize) }
        } catch {
            Task { @MainActor in self.onStatus("Text could not be analyzed. Try more light or enter manually.", false) }
        }
    }

    private enum CameraError: Error { case unavailable }
}

/// UIKit's preview layer gives the correct aspect-fill camera image and tap coordinates.
struct CameraPreview: UIViewRepresentable {
    let camera: CameraService
    let onFocus: (CGPoint) -> Void

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.camera = camera
        view.onFocus = onFocus
        return view
    }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        view.onFocus = onFocus
    }
}

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    weak var camera: CameraService?
    var onFocus: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(recognizer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        camera?.focus(at: point, in: previewLayer)
        onFocus?(point)
    }
}
#endif
