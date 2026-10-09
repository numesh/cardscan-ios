#if os(iOS)
  import SwiftUI
  import Observation

  /// Main actor adapter owns the active-time clock and one-shot outcomes; policy lives in ScanEngine.
  @MainActor @Observable final class ScannerModel {
    let configuration: CardScannerConfiguration
    private(set) var state = ScannerState()
    private(set) var previewSize: CGSize = .zero
    private let engine: ScanEngine?
    private let onOutcome: (ScanOutcome) -> Void
    private let onProgress: (ScannerProgress) -> Void
    private var active = false
    private var generation = 0
    private var delivered = false
    private var elapsed: TimeInterval = 0
    private var timer: Task<Void, Never>?
    private var lastProgress: ScannerMessage?
    @ObservationIgnored lazy var camera = CameraService(
      configuration: configuration,
      onFrame: { [weak self] lines, size in self?.receive(lines, imageSize: size) },
      onStatus: { [weak self] key, warning in
        guard let self, self.active, !self.delivered else { return }
        if key == .cameraUnavailable {
          self.engine?.terminate(.failed(.cameraUnavailable))
        } else {
          self.engine?.status(key, warning: warning, now: self.elapsed)
        }
        self.refresh()
      }, onTorch: { [weak self] enabled in self?.state.torchEnabled = enabled },
      onAvailability: { [weak self] available in self?.state.torchAvailable = available })
    init(
      configuration: CardScannerConfiguration, validator: ((CardScanResult) -> Bool)?,
      onOutcome: @escaping (ScanOutcome) -> Void, onProgress: @escaping (ScannerProgress) -> Void
    ) {
      let validatedEngine = try? ScanEngine(config: configuration, validator: validator)
      self.engine = validatedEngine
      // SwiftUI can render before start() delivers invalidConfiguration. Keep that first
      // layout safe even when the supplied geometry or typography contains invalid values.
      self.configuration = validatedEngine?.config ?? .balanced
      self.onOutcome = onOutcome
      self.onProgress = onProgress
    }
    func start() async {
      guard !active, !delivered else { return }
      guard engine != nil else {
        delivered = true
        onOutcome(.failed(.invalidConfiguration))
        return
      }
      active = true
      generation += 1
      let currentGeneration = generation
      await camera.start()
      guard generation == currentGeneration else { return }
      guard active, !delivered else {
        camera.stop()
        return
      }
      guard state.message != .permissionDenied else { return }
      timer?.cancel()
      timer = Task { [weak self] in
        var previous = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
          guard let self, self.active, !self.delivered else { return }
          let now = ProcessInfo.processInfo.systemUptime
          self.elapsed += now - previous
          previous = now
          self.engine?.tick(now: self.elapsed)
          self.refresh()
        }
      }
    }
    func pause() {
      generation += 1
      active = false
      timer?.cancel()
      camera.stop()
    }
    func stop() {
      pause()
      engine?.reset()
      state = ScannerState()
    }
    func send(_ action: ScannerAction) {
      guard !delivered else { return }
      switch action {
      case .close: engine?.terminate(.cancelled(.user))
      case .manualEntry: engine?.terminate(.manualEntryRequested)
      case .retry:
        elapsed = 0
        engine?.reset()
      case .confirm: engine?.confirm(now: elapsed)
      case .toggleTorch: camera.toggleTorch()
      case .zoomIn: camera.zoom(by: 0.5)
      case .zoomOut: camera.zoom(by: -0.5)
      }
      refresh()
    }
    func focus(at point: CGPoint) {
      guard configuration.controls.tapToFocusEnabled else { return }
      state.focusPoint = point
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(configuration.timing.focusMarkerDuration))
        if state.focusPoint == point { state.focusPoint = nil }
      }
    }
    func updatePreviewSize(_ size: CGSize) { previewSize = size }
    func guide(in size: CGSize) -> CGRect {
      let a = configuration.appearance
      let width = max(
        0, min(size.width * a.guideWidthFraction, size.height * 0.40 * a.guideAspectRatio))
      let height = width / a.guideAspectRatio
      return CGRect(
        x: (size.width - width) / 2,
        y: min(size.height * a.guideVerticalPosition, max(0, size.height - height)), width: width,
        height: height)
    }
    private func receive(_ lines: [OCRLine], imageSize: CGSize) {
      guard active, !delivered, previewSize.width > 0, imageSize.width > 0 else { return }
      let rect = guide(in: previewSize).insetBy(
        dx: -configuration.appearance.analysisPadding, dy: -configuration.appearance.analysisPadding
      )
      let scale = max(previewSize.width / imageSize.width, previewSize.height / imageSize.height)
      let x = (previewSize.width - imageSize.width * scale) / 2
      let y = (previewSize.height - imageSize.height * scale) / 2
      let filtered = lines.filter {
        rect.contains(
          CGPoint(
            x: x + $0.boundingBox.midX * imageSize.width * scale,
            y: y + (1 - $0.boundingBox.midY) * imageSize.height * scale))
      }
      engine?.frame(filtered, now: elapsed)
      refresh()
    }
    private func refresh() {
      guard let engine, !delivered else { return }
      let torch = state.torchEnabled
      let available = state.torchAvailable
      let focus = state.focusPoint
      state = engine.state
      state.torchEnabled = torch
      state.torchAvailable = available
      state.focusPoint = focus
      if lastProgress != state.message {
        lastProgress = state.message
        onProgress(ScannerProgress(message: state.message, warning: state.warningVisible))
        if configuration.controls.hapticsEnabled
          && (state.warningVisible || state.message == .success)
        {
          UINotificationFeedbackGenerator().notificationOccurred(
            state.warningVisible ? .warning : .success)
        }
        if configuration.appearance.announceStatus && UIAccessibility.isVoiceOverRunning {
          UIAccessibility.post(
            notification: .announcement, argument: configuration.text(state.message))
        }
      }
      if let outcome = engine.outcome {
        delivered = true
        pause()
        onOutcome(outcome)
      }
    }
  }
#endif
