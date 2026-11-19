import SwiftUI

// Commit on mouse-up. During a drag the action retains the reading the user
// started from, even if the popover polls a changed color profile.
private final class PercentSlider: NSSlider {
    var trackingMouse = false
    override func mouseDown(with event: NSEvent) {
        trackingMouse = true
        defer { trackingMouse = false }
        super.mouseDown(with: event)
    }
}

struct DisplaySlider: NSViewRepresentable {
    let row: PanelDisplay
    let reading: SliderReading
    let commit: (Int, SliderReading) -> Void

    final class Coordinator: NSObject {
        var changed: ((Int) -> Void)?
        @objc func apply(_ sender: NSSlider) {
            changed?(Int(sender.doubleValue.rounded()))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSlider {
        let slider = PercentSlider()
        slider.minValue = 10
        slider.maxValue = 100
        slider.isContinuous = false
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.apply(_:))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        guard (slider as? PercentSlider)?.trackingMouse != true else { return }
        slider.doubleValue = Double(reading.percent)
        slider.setAccessibilityLabel(row.name + " 밝기")
        slider.setAccessibilityIdentifier("brightness." + row.id)
        context.coordinator.changed = { commit($0, reading) }
    }
}
