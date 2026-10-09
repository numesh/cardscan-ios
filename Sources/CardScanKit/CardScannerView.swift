#if os(iOS)
  import SwiftUI

  /// Optional replacements receive state/actions. Return AnyView to use host assets or typography.
  public struct ScannerSlots {
    public var header: ((ScannerState, @escaping (ScannerAction) -> Void) -> AnyView)?
    public var controls: ((ScannerState, @escaping (ScannerAction) -> Void) -> AnyView)?
    public var status: ((ScannerState) -> AnyView)?
    public var detectedValues: ((ScannerState) -> AnyView)?
    public init() {}
  }

  /// Host owns presentation and dismisses after the terminal callback. Configuration is a session snapshot.
  public struct CardScannerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric private var fontScale: CGFloat = 1
    @State private var model: ScannerModel
    private let slots: ScannerSlots
    private var c: CardScannerConfiguration { model.configuration }
    private var a: ScannerAppearance { c.appearance }

    public init(
      configuration: CardScannerConfiguration = CardScannerConfiguration(),
      slots: ScannerSlots = ScannerSlots(),
      additionalValidator: ((CardScanResult) -> Bool)? = nil,
      onProgress: @escaping (ScannerProgress) -> Void = { _ in },
      onOutcome: @escaping (ScanOutcome) -> Void
    ) {
      self.slots = slots
      _model = State(
        initialValue: ScannerModel(
          configuration: configuration, validator: additionalValidator, onOutcome: onOutcome,
          onProgress: onProgress))
    }
    /// Source-compatible v1 entry point. Non-completion outcomes map to onCancel.
    public init(
      configuration: CardScannerConfiguration = CardScannerConfiguration(),
      onComplete: @escaping (CardScanResult) -> Void, onCancel: @escaping () -> Void
    ) {
      self.init(
        configuration: configuration,
        onOutcome: { outcome in
          if case .completed(let result) = outcome { onComplete(result) } else { onCancel() }
        })
    }
    public var body: some View {
      GeometryReader { geometry in
        let guide = model.guide(in: geometry.size)
        ZStack(alignment: .topLeading) {
          CameraPreview(camera: model.camera, onFocus: model.focus(at:))
            .frame(width: geometry.size.width, height: geometry.size.height)
          Canvas { context, size in
            var shade = Path(CGRect(origin: .zero, size: size))
            shade.addRect(guide)
            context.fill(
              shade, with: .color(color(a.backgroundColor).opacity(a.shadeOpacity)),
              style: FillStyle(eoFill: true))
            if a.guideVisible {
              if a.guideStyle == .outline {
                context.stroke(
                  Path(roundedRect: guide, cornerRadius: a.cornerRadius),
                  with: .color(color(a.guideColor)), lineWidth: a.guideStroke)
              } else {
                let length = min(28, guide.width / 4, guide.height / 4)
                var path = Path()
                for (point, dx, dy) in [
                  (CGPoint(x: guide.minX, y: guide.minY), 1.0, 1.0),
                  (CGPoint(x: guide.maxX, y: guide.minY), -1.0, 1.0),
                  (CGPoint(x: guide.minX, y: guide.maxY), 1.0, -1.0),
                  (CGPoint(x: guide.maxX, y: guide.maxY), -1.0, -1.0),
                ] {
                  path.move(to: CGPoint(x: point.x + length * dx, y: point.y))
                  path.addLine(to: point)
                  path.addLine(to: CGPoint(x: point.x, y: point.y + length * dy))
                }
                context.stroke(path, with: .color(color(a.guideColor)), lineWidth: a.guideStroke)
              }
            }
          }.allowsHitTesting(false)
          VStack(spacing: a.spacing) {
            if let header = slots.header {
              header(model.state, model.send)
            } else {
              HStack {
                if c.controls.closeVisible { button(.close, icon: a.closeIcon, action: .close) }
                Text(c.text(.title)).font(scaledFont(a.titleSize)).foregroundStyle(
                  color(a.textColor))
                Spacer()
              }
              Text(c.text(.instructions)).font(scaledFont(a.bodySize)).foregroundStyle(
                color(a.textColor)
              ).multilineTextAlignment(.center)
            }
            if c.controls.placement == .top { controls }
            Spacer(minLength: 0)
          }.padding(a.spacing)
          VStack(alignment: .center, spacing: 6) {
            if let values = slots.detectedValues {
              values(model.state)
            } else {
              if let number = model.state.numberPreview { chip(number, invalid: false) }
              if a.expiryPreviewVisible, let expiry = model.state.expiryPreview {
                chip(
                  c.text(.expiryPrefix) + " " + expiry, invalid: model.state.expiryPreviewInvalid)
              }
            }
          }.padding(.horizontal, a.spacing).frame(width: geometry.size.width).offset(
            y: max(guide.minY, guide.maxY - 104))
          VStack {
            if let status = slots.status {
              status(model.state)
            } else {
              Text(c.text(model.state.message)).font(scaledFont(a.bodySize)).foregroundStyle(
                color(a.textColor)
              )
              .multilineTextAlignment(.center).padding(8)
              .frame(maxWidth: .infinity)
              .background(
                color(
                  model.state.warningVisible
                    ? a.warningColor
                    : model.state.message == .success ? a.successColor : a.backgroundColor),
                in: RoundedRectangle(cornerRadius: a.cornerRadius))
            }
          }.padding(.horizontal, a.spacing).frame(width: geometry.size.width).offset(
            y: guide.maxY + 8)
          VStack(spacing: 8) {
            Spacer()
            if c.controls.placement == .bottom { controls }
            if model.state.readyToConfirm { button(.confirm, action: .confirm) }
            if c.controls.manualEntryVisible {
              button(.manual, icon: a.manualIcon, action: .manualEntry, showLabel: true)
            }
            if a.privacyVisible {
              Label(c.text(.privacy), systemImage: a.privacyIcon).font(.caption).foregroundStyle(
                color(a.textColor))
            }
          }.padding(a.spacing).frame(width: geometry.size.width, height: geometry.size.height)
          if c.controls.focusMarkerVisible, let point = model.state.focusPoint {
            Circle().stroke(color(a.focusColor), lineWidth: 2).frame(width: 48, height: 48)
              .position(point).allowsHitTesting(false)
          }
        }
        .background(color(a.backgroundColor))
        .onAppear { model.updatePreviewSize(geometry.size) }
        .onChange(of: geometry.size) { _, size in model.updatePreviewSize(size) }
      }
      .background(color(a.backgroundColor).ignoresSafeArea())
      .task { await model.start() }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await model.start() } } else { model.pause() }
      }
      .onDisappear { model.stop() }
      .overlay { if scenePhase != .active { Color.black.ignoresSafeArea() } }
    }
    @ViewBuilder private var controls: some View {
      if let custom = slots.controls {
        custom(model.state, model.send)
      } else {
        HStack(spacing: a.spacing) {
          if c.controls.torchVisible
            && (!c.controls.hideTorchWhenUnavailable || model.state.torchAvailable)
          {
            button(
              model.state.torchEnabled ? .torchOff : .torchOn,
              icon: model.state.torchEnabled ? a.torchOnIcon : a.torchOffIcon, action: .toggleTorch,
              large: true)
          }
          if c.controls.retryVisible { button(.retry, action: .retry) }
          if c.controls.zoomVisible {
            button(.zoomOut, icon: "minus", action: .zoomOut)
            button(.zoomIn, icon: "plus", action: .zoomIn)
          }
        }
      }
    }
    private func button(
      _ key: ScannerMessage, icon: String? = nil, action: ScannerAction, showLabel: Bool = false,
      large: Bool = false
    ) -> some View {
      Button {
        model.send(action)
      } label: {
        HStack {
          if let icon { Image(systemName: icon).font(.system(size: a.iconSize)) }
          if icon == nil || showLabel { Text(c.text(key)).font(scaledFont(a.buttonTextSize)) }
        }.foregroundStyle(color(a.textColor)).padding(8)
          .frame(minWidth: large ? a.buttonSize : 44, minHeight: large ? a.buttonSize : 44)
          .background(color(a.buttonColor), in: RoundedRectangle(cornerRadius: a.cornerRadius))
      }.accessibilityLabel(c.text(key))
    }
    private func chip(_ value: String, invalid: Bool) -> some View {
      Text(value).font(scaledFont(a.previewSize)).foregroundStyle(color(a.textColor)).padding(6)
        .background(
          color(invalid ? a.warningColor : a.previewColor),
          in: RoundedRectangle(cornerRadius: a.cornerRadius)
        ).privacySensitive()
    }
    private func scaledFont(_ size: CGFloat) -> Font {
      .system(size: size * fontScale)
    }
    private func color(_ argb: UInt32) -> Color {
      Color(
        .sRGB, red: Double((argb >> 16) & 255) / 255, green: Double((argb >> 8) & 255) / 255,
        blue: Double(argb & 255) / 255, opacity: Double((argb >> 24) & 255) / 255)
    }
  }
#endif
