import CoreLocation
import MapKit
import SwiftUI

struct MacSetLocationPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themes = MacThemeStore.shared

    let onSave: (String?, Double?, Double?) -> Void

    @State private var name: String
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var cameraPosition: MapCameraPosition

    init(
        name: String?,
        latitude: Double?,
        longitude: Double?,
        onSave: @escaping (String?, Double?, Double?) -> Void
    ) {
        self.onSave = onSave
        _name = State(initialValue: name ?? "")

        if let latitude, let longitude {
            let coordinate = CLLocationCoordinate2D(
                latitude: latitude,
                longitude: longitude)
            _coordinate = State(initialValue: coordinate)
            _cameraPosition = State(initialValue: .camera(Self.camera(for: coordinate)))
        } else {
            _coordinate = State(initialValue: nil)
            _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.55, longitude: -122.28),
                span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35))))
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set Location")
                        .font(.title2.weight(.semibold))
                    Text("Click the satellite map to place or move the pin.")
                        .font(.callout)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
            }

            TextField("Venue, beach, city…", text: $name)
                .textFieldStyle(.roundedBorder)

            MapReader { proxy in
                Map(
                    position: $cameraPosition,
                    interactionModes: [.pan, .zoom, .rotate, .pitch]
                ) {
                    if let coordinate {
                        Marker(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Set location"
                                : name,
                            coordinate: coordinate)
                            .tint(Theme.accent)
                    }
                }
                .mapStyle(.imagery(elevation: .realistic))
                .mapControls {
                    MapCompass()
                    MapPitchToggle()
                    MapScaleView()
                }
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            guard let dropped = proxy.convert(
                                value.location,
                                from: .local) else { return }
                            coordinate = dropped
                            cameraPosition = .camera(Self.camera(for: dropped))
                            reverseGeocode(dropped)
                        })
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))
            }

            HStack {
                if let coordinate {
                    Text(String(
                        format: "%.5f, %.5f",
                        coordinate.latitude,
                        coordinate.longitude))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                } else {
                    Text("No pin placed")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }

                Spacer()

                Button("Remove", role: .destructive) {
                    onSave(nil, nil, nil)
                    dismiss()
                }

                Button("Save Pin") {
                    guard let coordinate else { return }
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(
                        trimmed.isEmpty ? "Pinned location" : trimmed,
                        coordinate.latitude,
                        coordinate.longitude)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinate == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 580)
        .background(Theme.background)
    }

    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) {
        Task {
            let geocoder = CLGeocoder()
            guard let placemark = try? await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            ).first else { return }
            let suggested = [placemark.name, placemark.locality]
                .compactMap { $0 }
                .reduce(into: [String]()) { result, part in
                    if !result.contains(part) {
                        result.append(part)
                    }
                }
                .joined(separator: ", ")
            if !suggested.isEmpty {
                name = suggested
            }
        }
    }

    private static func camera(for coordinate: CLLocationCoordinate2D) -> MapCamera {
        MapCamera(
            centerCoordinate: coordinate,
            distance: 1_500,
            heading: 18,
            pitch: 62)
    }
}

struct MacSetLocationPreview: View {
    @ObservedObject private var themes = MacThemeStore.shared
    let name: String
    let latitude: Double
    let longitude: Double

    @State private var cameraPosition: MapCameraPosition
    @State private var isInteractive = false

    init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        _cameraPosition = State(initialValue: .camera(MapCamera(
            centerCoordinate: coordinate,
            distance: 900,
            heading: 28,
            pitch: 68)))
    }

    var body: some View {
        Map(
            position: $cameraPosition,
            interactionModes: isInteractive ? [.pan, .zoom, .rotate, .pitch] : []
        ) {
            Marker(
                name,
                coordinate: CLLocationCoordinate2D(
                    latitude: latitude,
                    longitude: longitude))
                .tint(Theme.accent)
        }
        .mapStyle(.imagery(elevation: .realistic))
        .mapControls {
            if isInteractive {
                MapCompass()
                MapScaleView()
            }
        }
        .onHover { hovering in
            if !hovering {
                isInteractive = false
            }
        }
        .onExitCommand {
            isInteractive = false
        }
        .overlay {
            if !isInteractive {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isInteractive = true
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            Text(isInteractive ? "Map active · move pointer away to scroll" : "Click to explore map")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(10)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            Label(name, systemImage: "mappin.circle.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.black.opacity(0.7), in: Capsule())
                .foregroundStyle(.white)
                .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))
    }
}
