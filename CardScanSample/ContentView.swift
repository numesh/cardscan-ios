import CardScanKit
import SwiftUI

private enum FormStyle {
  static let field = Color(red: 0.96, green: 0.96, blue: 0.97)
  static let hint = Color(red: 0.75, green: 0.77, blue: 0.79)
  static let label = Color(red: 0.33, green: 0.33, blue: 0.33)
}

struct ContentView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = AddCardModel()

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "arrow.left")
            .font(.system(size: 22, weight: .medium))
            .frame(width: 48, height: 48)
        }
        .accessibilityLabel("Back")
        Text("Add card").font(.system(size: 20, weight: .semibold))
        Spacer()
        Button("Settings") { model.send(.showSettings(true)) }.padding(.trailing, 12)
      }
      .foregroundStyle(.black)
      .padding(.leading, 8)
      .frame(height: 52)

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if let note = model.state.scanNote {
            successBanner(note)
              .padding(.bottom, 22)
          }

          fieldLabel("Card number", required: true)
          HStack(spacing: 10) {
            Image(systemName: "creditcard")
              .font(.system(size: 19, weight: .regular))
              .foregroundStyle(FormStyle.hint)
            TextField(
              "Enter card number",
              text: binding(
                \.cardNumber, AddCardEvent.cardNumberChanged)
            )
            .keyboardType(.numberPad)
            .textContentType(.creditCardNumber)
            .font(.system(size: 16))
            .privacySensitive()
            .accessibilityLabel("Card number")
            Button {
              model.send(.scanRequested)
            } label: {
              Image(systemName: "camera")
                .font(.system(size: 24, weight: .regular))
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Scan card with camera")
          }
          .foregroundStyle(.black)
          .padding(.leading, 14)
          .padding(.trailing, 6)
          .frame(height: 52)
          .background(
            model.state.scanNote == nil ? .white : FormStyle.field,
            in: RoundedRectangle(cornerRadius: 6)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(
                model.state.scanNote == nil ? Color.black : Color.gray.opacity(0.42), lineWidth: 1)
          )
          .padding(.top, 4)

          HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
              fieldLabel("Expiry date", required: true)
              HStack(spacing: 3) {
                TextField("MM", text: binding(\.month, AddCardEvent.monthChanged))
                  .frame(width: model.state.month.isEmpty ? 30 : 23)
                  .accessibilityLabel("Expiry month")
                Text("/")
                TextField("YY", text: binding(\.year, AddCardEvent.yearChanged))
                  .frame(width: 30)
                  .accessibilityLabel("Expiry year")
              }
              .font(.system(size: 16))
              .keyboardType(.numberPad)
              .padding(.horizontal, 14)
              .frame(maxWidth: .infinity, alignment: .leading)
              .frame(height: 52)
              .background(FormStyle.field, in: RoundedRectangle(cornerRadius: 6))
              .privacySensitive()
            }
            VStack(alignment: .leading, spacing: 4) {
              fieldLabel("CVV", required: true)
              SecureField(
                model.state.scanNote == nil ? "123" : "CVV",
                text: binding(\.cvv, AddCardEvent.cvvChanged)
              )
              .keyboardType(.numberPad)
              .textContentType(.creditCardSecurityCode)
              .font(.system(size: 16))
              .padding(.horizontal, 14)
              .frame(height: 52)
              .background(FormStyle.field, in: RoundedRectangle(cornerRadius: 6))
              .accessibilityLabel("CVV")
              .privacySensitive()
            }
          }
          .foregroundStyle(.black)
          .padding(.top, 22)

          fieldLabel("Nickname", required: false)
            .padding(.top, 18)
          TextField(
            "Enter a nickname for your card (Optional)",
            text: binding(\.nickname, AddCardEvent.nicknameChanged)
          )
          .font(.system(size: 16))
          .padding(.horizontal, 14)
          .frame(height: 52)
          .background(FormStyle.field, in: RoundedRectangle(cornerRadius: 6))
          .padding(.top, 4)

          if model.state.scanNote != nil {
            Text(
              model.state.month.isEmpty || model.state.year.isEmpty
                ? "Enter expiry date and CVV to continue." : "Enter CVV to continue."
            )
            .font(.system(size: 13))
            .foregroundStyle(Color(red: 0.44, green: 0.50, blue: 0.60))
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, model.state.scanNote == nil ? 24 : 8)
      }
      .scrollDismissesKeyboard(.interactively)

      Text("Add card")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(Color(red: 0.37, green: 0.40, blue: 0.44))
        .frame(maxWidth: .infinity)
        .frame(height: 60)
        .background(Color(red: 1, green: 0.91, blue: 0.59), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityLabel("Add card unavailable in demo")
    }
    .background(Color.white)
    .preferredColorScheme(.light)
    .overlay { if scenePhase != .active { Color.white.ignoresSafeArea() } }
    .sheet(
      isPresented: Binding(
        get: { model.state.settingsPresented }, set: { model.send(.showSettings($0)) })
    ) {
      ScannerSettings(
        configuration: Binding(
          get: { model.state.configuration }, set: { model.send(.configure($0)) }))
    }
    .fullScreenCover(
      isPresented: Binding(
        get: { model.state.scannerPresented },
        set: { if !$0 { model.send(.scanDismissed) } }
      )
    ) {
      CardScannerView(
        configuration: model.state.configuration, onComplete: { model.send(.scanCompleted($0)) },
        onCancel: { model.send(.scanDismissed) })
    }
  }

  private func binding(
    _ keyPath: KeyPath<AddCardState, String>,
    _ event: @escaping (String) -> AddCardEvent
  ) -> Binding<String> {
    Binding(get: { model.state[keyPath: keyPath] }, set: { model.send(event($0)) })
  }

  private func fieldLabel(_ title: String, required: Bool) -> some View {
    HStack(spacing: 3) {
      Text(title).foregroundStyle(FormStyle.label)
      if required { Text("*").foregroundStyle(.red) }
    }
    .font(.system(size: 14))
  }

  private func successBanner(_ note: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: model.state.scanWarning ? "exclamationmark" : "checkmark")
        .font(.system(size: 19, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(model.state.scanWarning ? Color.red : Color(red: 0.03, green: 0.66, blue: 0.23), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(note).font(.system(size: 15, weight: .semibold))
        Text("Check your details before continuing.")
          .font(.system(size: 13))
          .foregroundStyle(FormStyle.label)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .frame(height: 66)
    .background(
      model.state.scanWarning ? Color.red.opacity(0.12) : Color(red: 0.89, green: 0.97, blue: 0.91),
      in: RoundedRectangle(cornerRadius: 6))
  }
}

#Preview {
  ContentView()
}
