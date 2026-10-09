#if os(iOS)
  import AVFoundation
  import ImageIO
  import SwiftUI
  import UIKit
  import Vision

  /// Owns AVFoundation and Vision. The model receives OCR text only; no image is stored.
  final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let configuration: CardScannerConfiguration
    private let onAvailability: @MainActor (Bool) -> Void
    private let sessionQueue = DispatchQueue(label: "com.andronuke.cardscan.session")
    private let analysisQueue = DispatchQueue(label: "com.andronuke.cardscan.analysis")
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var lastAnalysis: TimeInterval = 0
    // Generation checks discard late permission/recognition completions across pause or dismissal.
    private let stateLock = NSLock()
    private var generation = 0
    private var acceptingFrames = false
    private var rotation: CGFloat = 90
    private func beginCapture() -> Int {
      stateLock.withLock {
        generation += 1
        acceptingFrames = true
        return generation
      }
    }
    private func currentGeneration() -> Int? {
      stateLock.withLock { acceptingFrames ? generation : nil }
    }
    private func invalidateCapture() {
      stateLock.withLock {
        generation += 1
        acceptingFrames = false
      }
    }
    private let onFrame: @MainActor ([OCRLine], CGSize) -> Void
    private let onStatus: @MainActor (ScannerMessage, Bool) -> Void
    private let onTorch: @MainActor (Bool) -> Void

    init(
      configuration: CardScannerConfiguration,
      onFrame: @escaping @MainActor ([OCRLine], CGSize) -> Void,
      onStatus: @escaping @MainActor (ScannerMessage, Bool) -> Void,
      onTorch: @escaping @MainActor (Bool) -> Void,
      onAvailability: @escaping @MainActor (Bool) -> Void
    ) {
      self.configuration = configuration
      self.onAvailability = onAvailability
      self.onFrame = onFrame
      self.onStatus = onStatus
      self.onTorch = onTorch
    }

    func start() async {
      let token = beginCapture()
      let authorized: Bool
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized: authorized = true
      case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
      default: authorized = false
      }
      guard currentGeneration() == token else { return }
      guard authorized else {
        await onStatus(.permissionDenied, true)
        return
      }
      let ready = await withCheckedContinuation { continuation in
        sessionQueue.async {
          guard self.currentGeneration() == token else {
            continuation.resume(returning: false)
            return
          }
          do {
            if !self.configured { try self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
            continuation.resume(returning: true)
          } catch {
            continuation.resume(returning: false)
          }
        }
      }
      guard currentGeneration() == token else { return }
      if ready && configuration.controls.initialTorchEnabled { toggleTorch() }
      await onStatus(ready ? .ready : .cameraUnavailable, !ready)
    }

    func stop() {
      invalidateCapture()
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
          Task { @MainActor in self.onStatus(.cameraStarting, false) }
          return
        }
        guard device.hasTorch else {
          Task { @MainActor in self.onStatus(.torchUnavailable, false) }
          return
        }
        do {
          try device.lockForConfiguration()
          let enabled = device.torchMode != .on
          device.torchMode = enabled ? .on : .off
          device.unlockForConfiguration()
          Task { @MainActor in self.onTorch(enabled) }
        } catch {
          Task { @MainActor in self.onStatus(.torchUnavailable, false) }
        }
      }
    }

    func focus(at layerPoint: CGPoint, in previewLayer: AVCaptureVideoPreviewLayer) {
      guard configuration.controls.tapToFocusEnabled else { return }
      let point = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
      sessionQueue.async {
        guard let device = self.device else { return }
        do {
          try device.lockForConfiguration()
          if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
            device.focusPointOfInterest = point
            device.focusMode = .autoFocus
          }
          if device.isExposurePointOfInterestSupported
            && device.isExposureModeSupported(.continuousAutoExposure)
          {
            device.exposurePointOfInterest = point
            device.exposureMode = .continuousAutoExposure
          }
          device.unlockForConfiguration()
        } catch {
          Task { @MainActor in self.onStatus(.focusFailed, false) }
        }
      }
    }

    func zoom(by delta: CGFloat) {
      sessionQueue.async {
        guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        device.videoZoomFactor = min(
          device.maxAvailableVideoZoomFactor,
          max(device.minAvailableVideoZoomFactor, device.videoZoomFactor + delta))
      }
    }

    func rotate(to angle: CGFloat) {
      sessionQueue.async {
        self.rotation = angle
        if let connection = self.output.connection(with: .video),
          connection.isVideoRotationAngleSupported(angle)
        {
          connection.videoRotationAngle = angle
        }
      }
    }

    private func configure() throws {
      session.beginConfiguration()
      defer { session.commitConfiguration() }
      let preset: AVCaptureSession.Preset =
        configuration.recognition.resolution == .hd720
        ? .hd1280x720 : configuration.recognition.resolution == .hd1080 ? .hd1920x1080 : .high
      if session.canSetSessionPreset(preset) { session.sessionPreset = preset }
      guard
        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
      else { throw CameraError.unavailable }
      let input = try AVCaptureDeviceInput(device: camera)
      guard session.canAddInput(input), session.canAddOutput(output) else {
        throw CameraError.unavailable
      }
      session.addInput(input)
      output.alwaysDiscardsLateVideoFrames = true
      session.addOutput(output)
      if let connection = output.connection(with: .video),
        connection.isVideoRotationAngleSupported(rotation)
      {
        connection.videoRotationAngle = rotation
      }
      output.setSampleBufferDelegate(self, queue: analysisQueue)
      device = camera
      configured = true
      try camera.lockForConfiguration()
      camera.videoZoomFactor = min(
        camera.maxAvailableVideoZoomFactor,
        max(camera.minAvailableVideoZoomFactor, configuration.controls.initialZoom))
      camera.unlockForConfiguration()
      Task { @MainActor in self.onAvailability(camera.hasTorch) }
    }

    func captureOutput(
      _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
      from connection: AVCaptureConnection
    ) {
      guard let token = currentGeneration() else { return }
      let time = CACurrentMediaTime()
      guard time - lastAnalysis >= configuration.timing.analysisInterval,
        let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
      else { return }
      lastAnalysis = time
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = configuration.recognition.level == .accurate ? .accurate : .fast
      request.minimumTextHeight = configuration.recognition.minimumTextHeight
      request.usesLanguageCorrection = false  // Card digits should not become words.
      request.recognitionLanguages = configuration.recognition.languages
      do {
        // Video output rotates buffers with the preview, so Vision uses upright coordinates.
        try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
          guard let candidate = observation.topCandidates(1).first,
            candidate.confidence >= configuration.recognition.minimumConfidence
          else { return nil }
          let text = candidate.string
          let box = observation.boundingBox
          return OCRLine(text: text, top: 1 - box.maxY, left: box.minX, boundingBox: box)
        }
        let portraitSize = CGSize(
          width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        Task { @MainActor in
          guard self.currentGeneration() == token else { return }
          self.onFrame(lines, portraitSize)
        }
      } catch {
        Task { @MainActor in
          guard self.currentGeneration() == token else { return }
          self.onStatus(.analysisFailed, false)
        }
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

    override func layoutSubviews() {
      super.layoutSubviews()
      let angle: CGFloat
      switch window?.windowScene?.interfaceOrientation {
      case .landscapeLeft: angle = 0
      case .landscapeRight: angle = 180
      case .portraitUpsideDown: angle = 270
      default: angle = 90
      }
      if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
        connection.videoRotationAngle = angle
      }
      camera?.rotate(to: angle)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
      let point = recognizer.location(in: self)
      camera?.focus(at: point, in: previewLayer)
      onFocus?(point)
    }
  }
#endif
