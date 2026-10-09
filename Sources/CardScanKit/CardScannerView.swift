#if os(iOS)
import SwiftUI

/// Reusable library screen. The host decides how to present and dismiss it.
public struct CardScannerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ScannerModel
    private let onCancel: () -> Void

    public init(onComplete: @escaping (CardScanResult) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: ScannerModel(onComplete: onComplete))
        self.onCancel = onCancel
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let guide = model.guide(in: size)
            ZStack(alignment: .topLeading) {
                Color.black
                CameraPreview(camera: model.camera, onFocus: model.focus(at:))
                    .frame(width: size.width, height: size.height)
                CameraShade(guide: guide, size: size)
                    .allowsHitTesting(false)
                GuideCorners(guide: guide)
                    .allowsHitTesting(false)

                HStack(spacing: 8) {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Close scanner")
                    Text("Scan card").font(.system(size: 20, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.leading, 8)
                .frame(height: 52)

                Text("Position your card number and expiry date\ninside the frame.")
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(width: size.width - 32)
                    .position(x: size.width / 2, y: 90)

                if let number = model.state.numberPreview {
                    Text(number)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.white)
                        .frame(width: size.width - 80, height: 44)
                        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .privacySensitive()
                        .position(x: size.width / 2, y: guide.maxY - 80)
                        .accessibilityLabel("Card number detected")
                }
                if let expiry = model.state.expiryPreview {
                    Text("EXP \(expiry)")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 120, height: 40)
                        .background(model.state.expiryPreviewInvalid ? Color.red : Color.black.opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .privacySensitive()
                        .position(x: 100, y: guide.maxY - 30)
                }

                Text(model.state.status)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(width: size.width - 48)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(model.state.warningVisible ? Color(red: 0.68, green: 0.14, blue: 0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .position(x: size.width / 2, y: guide.maxY + 38)
                    .accessibilityAddTraits(model.state.warningVisible ? .updatesFrequently : [])

                if let point = model.state.focusPoint {
                    Circle()
                        .stroke(Color(red: 1, green: 0.78, blue: 0.24), lineWidth: 2)
                        .frame(width: 48, height: 48)
                        .overlay(Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.24)))
                        .position(point)
                        .allowsHitTesting(false)
                }

                Button { model.toggleTorch() } label: {
                    Image(systemName: model.state.torchEnabled ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 28, weight: .light))
                        .frame(width: 72, height: 72)
                        .background(.white.opacity(model.state.torchEnabled ? 0.27 : 0.13), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 2))
                }
                .accessibilityLabel(model.state.torchEnabled ? "Turn torch off" : "Turn torch on")
                .foregroundStyle(.white)
                .position(x: size.width / 2, y: size.height - 164)

                Button(action: onCancel) {
                    Text("Enter details manually")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white, lineWidth: 2))
                }
                .padding(.horizontal, 16)
                .position(x: size.width / 2, y: size.height - 90)

                HStack(spacing: 7) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 17))
                    Text("Your card image is not saved.")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Color(red: 0.86, green: 0.89, blue: 0.93))
                .position(x: size.width / 2, y: size.height - 27)
            }
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .onAppear {
                model.updatePreviewSize(size)
                Task { await model.start() }
            }
            .onChange(of: size) { _, newSize in model.updatePreviewSize(newSize) }
            .onDisappear { model.stop() }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay { if scenePhase != .active { Color.black.ignoresSafeArea() } }
    }
}

private struct CameraShade: View {
    let guide: CGRect
    let size: CGSize

    var body: some View {
        Canvas { context, _ in
            let shade = Color.black.opacity(0.67)
            func fill(_ rect: CGRect, _ color: Color) {
                guard rect.width > 0, rect.height > 0 else { return }
                context.fill(Path(rect), with: .color(color))
            }
            fill(CGRect(x: 0, y: 0, width: size.width, height: guide.minY), shade)
            fill(CGRect(x: 0, y: guide.maxY, width: size.width, height: size.height - guide.maxY), shade)
            fill(CGRect(x: 0, y: guide.minY, width: guide.minX, height: guide.height), shade)
            fill(CGRect(x: guide.maxX, y: guide.minY, width: size.width - guide.maxX, height: guide.height), shade)
            fill(CGRect(x: 0, y: 0, width: size.width, height: guide.minY - 28), .black)
            fill(CGRect(x: 0, y: guide.maxY + 60, width: size.width,
                        height: size.height - guide.maxY - 60), .black)
        }
    }
}

private struct GuideCorners: View {
    let guide: CGRect

    var body: some View {
        Canvas { context, _ in
            let length: CGFloat = 28
            var path = Path()
            path.move(to: CGPoint(x: guide.minX + length, y: guide.minY))
            path.addLine(to: CGPoint(x: guide.minX, y: guide.minY))
            path.addLine(to: CGPoint(x: guide.minX, y: guide.minY + length))
            path.move(to: CGPoint(x: guide.maxX - length, y: guide.minY))
            path.addLine(to: CGPoint(x: guide.maxX, y: guide.minY))
            path.addLine(to: CGPoint(x: guide.maxX, y: guide.minY + length))
            path.move(to: CGPoint(x: guide.minX + length, y: guide.maxY))
            path.addLine(to: CGPoint(x: guide.minX, y: guide.maxY))
            path.addLine(to: CGPoint(x: guide.minX, y: guide.maxY - length))
            path.move(to: CGPoint(x: guide.maxX - length, y: guide.maxY))
            path.addLine(to: CGPoint(x: guide.maxX, y: guide.maxY))
            path.addLine(to: CGPoint(x: guide.maxX, y: guide.maxY - length))
            context.stroke(path, with: .color(Color(red: 1, green: 0.84, blue: 0.13)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }
}
#endif
