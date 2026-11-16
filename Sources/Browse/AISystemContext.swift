import Foundation
import CoreLocation
import AI

// @lat: [[lat.md/architecture/ai#System and location tools]]
@MainActor enum AISystemContext {
    static func systemInfo(now: Date = Date(), timeZone: TimeZone = .current,
                           bundle: Bundle = .main, osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString) -> JSONValue {
        let rounded = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970 / 60) * 60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: rounded)
        formatter.dateFormat = "HH:mm"
        return .object([
            "os_version": .string(osVersion),
            "bend_version": .string(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"),
            "bend_build": .string(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"),
            "date": .string(date), "time": .string(formatter.string(from: rounded)),
            "timezone": .string(timeZone.identifier),
            "utc_offset_minutes": .integer(Int64(timeZone.secondsFromGMT(for: rounded) / 60)),
            "time_precision": .string("Rounded up to the next minute; date and offset refer to that same instant.")
        ])
    }

    static func location() async throws -> JSONValue {
        let request = AILocationRequest()
        return try await request.fetch()
    }
}

/// Created only after inline approval. One request, no background tracking.
/// Core Location delivers delegate callbacks on the main run loop where its manager is created.
@MainActor final class AILocationRequest: NSObject, @preconcurrency CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<JSONValue, Error>?
    private var timeout: Task<Void, Never>?
    private var requestedAuthorization = false
    private var requestedLocation = false

    func fetch() async throws -> JSONValue {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let manager = CLLocationManager()
                self.manager = manager
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                manager.delegate = self
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    self?.finish(.failure(AIError.configuration("Location request timed out. Try again if needed.")))
                }
                authorize(manager)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func authorize(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            if !requestedAuthorization {
                requestedAuthorization = true
                manager.requestWhenInUseAuthorization()
            }
        case .authorizedAlways, .authorizedWhenInUse:
            if !requestedLocation { requestedLocation = true; manager.requestLocation() }
        case .denied, .restricted:
            finish(.failure(AIError.configuration("Location access is denied or unavailable in macOS Location Services.")))
        @unknown default:
            finish(.failure(AIError.configuration("Location authorization is unavailable.")))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { authorize(manager) }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(location.coordinate),
              abs(location.timestamp.timeIntervalSinceNow) < 120 else {
            finish(.failure(AIError.configuration("A recent location could not be determined.")))
            return
        }
        finish(.success(.object([
            "latitude": .number(location.coordinate.latitude),
            "longitude": .number(location.coordinate.longitude),
            "accuracy_meters": .number(location.horizontalAccuracy)
        ])))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(AIError.configuration("Current location could not be determined. Check macOS Location Services and try again.")))
    }
    private func finish(_ result: Result<JSONValue, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        manager?.stopUpdatingLocation(); manager?.delegate = nil; manager = nil
        continuation.resume(with: result)
    }
}
