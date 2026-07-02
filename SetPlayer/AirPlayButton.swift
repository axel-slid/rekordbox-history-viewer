import AVKit
import SwiftUI

/// System AirPlay route picker — send playback to a Mac, HomePod, or any
/// AirPlay speaker. (Playback runs on the phone; AirPlay carries the audio.)
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.accent)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
