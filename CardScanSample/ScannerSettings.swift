import CardScanKit
import SwiftUI

/// Interactive examples of the public configuration; no settings or card data are persisted.
struct ScannerSettings: View {
  @Binding var configuration: CardScannerConfiguration
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section("Presets") {
          HStack {
            Button("Balanced") { configuration = .balanced }
            Button("Fast") { configuration = .fast }
            Button("Strict") { configuration = .strict }
          }.buttonStyle(.bordered)
        }
        Section("Controls") {
          Toggle("Torch", isOn: $configuration.controls.torchVisible)
          Toggle("Tap to focus", isOn: $configuration.controls.tapToFocusEnabled)
          Toggle("Zoom controls", isOn: $configuration.controls.zoomVisible)
          Toggle("Retry", isOn: $configuration.controls.retryVisible)
        }
        Section("Recognition") {
          Toggle(
            "Require expiry",
            isOn: Binding(
              get: { configuration.validation.expiryRequirement == .required },
              set: { configuration.validation.expiryRequirement = $0 ? .required : .optional }))
          Toggle(
            "Confirm before returning",
            isOn: Binding(
              get: { configuration.completionMode == .userConfirmation },
              set: { configuration.completionMode = $0 ? .userConfirmation : .automatic }))
          Toggle(
            "Mask preview",
            isOn: Binding(
              get: { configuration.appearance.numberDisplay == .masked },
              set: { configuration.appearance.numberDisplay = $0 ? .masked : .full }))
          Toggle("Merge partial numbers", isOn: $configuration.partial.enabled)
          Text("Expiry wait: \(Int(configuration.timing.expiryWaitTimeout))s")
          Slider(value: $configuration.timing.expiryWaitTimeout, in: 2...30, step: 1)
        }
      }.navigationTitle("Scanner settings")
        .toolbar { Button("Done") { dismiss() } }
    }
  }
}
