import SwiftUI

/// Sliders for manual camera controls: ISO, Shutter Speed, Focus, White Balance.
struct ManualControlsOverlay: View {
    @ObservedObject var settings: CaptureSettings

    var body: some View {
        VStack(spacing: 10) {
            // ISO
            ControlRow(
                label: "ISO",
                isAuto: $settings.isAutoExposure,
                valueDisplay: "\(Int(settings.iso))"
            ) {
                LogarithmicSlider(
                    value: $settings.iso,
                    range: 25...3072,
                    label: "ISO"
                )
            }

            // Shutter Speed
            ControlRow(
                label: "SS",
                isAuto: $settings.isAutoExposure,
                valueDisplay: settings.shutterSpeedDisplay
            ) {
                LogarithmicSlider(
                    value: Binding(
                        get: { Float(settings.shutterSpeed) },
                        set: { settings.shutterSpeed = Double($0) }
                    ),
                    range: 0.00001...1.0,
                    label: "Shutter"
                )
            }

            // Focus
            ControlRow(
                label: "Focus",
                isAuto: $settings.isAutoFocus,
                valueDisplay: String(format: "%.2f", settings.focusPosition)
            ) {
                Slider(value: $settings.focusPosition, in: 0...1)
                    .tint(.white)
            }

            // White Balance Temperature
            ControlRow(
                label: "WB",
                isAuto: $settings.isAutoWhiteBalance,
                valueDisplay: "\(Int(settings.wbTemperature))K"
            ) {
                Slider(value: $settings.wbTemperature, in: 2000...10000)
                    .tint(
                        LinearGradient(
                            colors: [.orange, .white, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }

            // White Balance Tint
            if !settings.isAutoWhiteBalance {
                HStack {
                    Text("Tint")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 45, alignment: .leading)

                    Slider(value: $settings.wbTint, in: -150...150)
                        .tint(
                            LinearGradient(
                                colors: [.green, .white, .pink],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text(String(format: "%+.0f", settings.wbTint))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial.opacity(0.8))
        .cornerRadius(12)
    }
}

// MARK: - Control Row

/// A single row of a manual control with auto toggle, label, slider, and value display.
struct ControlRow<SliderContent: View>: View {
    let label: String
    @Binding var isAuto: Bool
    let valueDisplay: String
    @ViewBuilder let slider: () -> SliderContent

    var body: some View {
        HStack(spacing: 8) {
            // Auto/Manual toggle
            Button(action: { isAuto.toggle() }) {
                Text(isAuto ? "A" : "M")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(isAuto ? .yellow : .white)
                    .frame(width: 20, height: 20)
                    .background(Circle().stroke(isAuto ? Color.yellow : Color.white, lineWidth: 1))
            }

            // Label
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 40, alignment: .leading)

            // Slider (disabled when auto)
            slider()
                .disabled(isAuto)
                .opacity(isAuto ? 0.4 : 1.0)

            // Value
            Text(valueDisplay)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 55, alignment: .trailing)
        }
    }
}

// MARK: - Logarithmic Slider

/// A slider that maps a linear position to a logarithmic value.
/// Essential for ISO and shutter speed where the perceptual range is logarithmic.
struct LogarithmicSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let label: String

    private var logMin: Float { log2(range.lowerBound) }
    private var logMax: Float { log2(range.upperBound) }

    var body: some View {
        Slider(
            value: Binding(
                get: { log2(max(value, range.lowerBound)) },
                set: { value = pow(2.0, $0) }
            ),
            in: logMin...logMax
        )
        .tint(.white)
    }
}
