#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreLocation

/// One-shot coarse-location capture with reverse-geocode caching.
/// Opt-in, privacy-first: reduced accuracy, on-device geocoding, never blocks.
actor LocationCaptureService {

    /// Captured place info — lat/lon rounded to 2 decimal places (~1 km precision).
    struct Place: Sendable, Equatable {
        let latitude: Double
        let longitude: Double
        let placeName: String?

        /// Two-decimal rounding key — used for cache deduplication.
        var cacheKey: String {
            String(format: "%.2f,%.2f", latitude, longitude)
        }
    }

    /// The CoreLocation clients are built lazily on first `capture()` rather than
    /// in `init`, so merely *owning* a LocationCaptureService (PlayerModel holds one
    /// eagerly) touches no CoreLocation framework state. This is good privacy hygiene
    /// and — critically — keeps `PlayerModel()` construction free of process-global
    /// system singletons, which is what the unit-test suite exercises. (Constructing
    /// CLLocationManager during PlayerModel init double-freed on the iOS 26.2 CI
    /// simulator; see task_66ce9a55.)
    private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        manager.distanceFilter = kCLDistanceFilterNone
        return manager
    }()
    private lazy var geocoder = CLGeocoder()
    private var cache: [String: Place] = [:]

    /// Captures the current coarse location, reverse-geocoded to "Neighborhood, City".
    /// Fires once and returns nil on timeout, denial, or error.
    /// Never blocks the caller for more than ~10 seconds.
    func capture(description: String? = nil, timeout: TimeInterval = 10) async -> Place? {
        // Check authorization first
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return nil
        }

        return await withTaskTimeout(timeout) { [weak self] in
            guard let self else { return nil }

            let coord: CLLocationCoordinate2D
            do {
                coord = try await self.requestLocation()
            } catch {
                return nil
            }

            let lat = round(coord.latitude * 100) / 100
            let lon = round(coord.longitude * 100) / 100
            let key = String(format: "%.2f,%.2f", lat, lon)

            // Return cached place if we've been here before
            if let cached = await self.cached(key) {
                return cached
            }

            // Reverse-geocode
            let location = CLLocation(latitude: lat, longitude: lon)
            let name: String?
            do {
                let placemarks = try await self.geocoder.reverseGeocodeLocation(location)
                name = placemarks.first.flatMap { pm in
                    [pm.subLocality, pm.locality].compactMap { $0 }.joined(separator: ", ")
                }
            } catch {
                name = nil
            }

            let place = Place(latitude: lat, longitude: lon, placeName: name)
            await self.store(key, place)
            return place
        }
    }

    /// Clears the in-memory geocode cache.
    func flushCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private func requestLocation() async throws -> CLLocationCoordinate2D {
        // CLLocationUpdate.liveUpdates() emits one value then continues;
        // we take the first value.
        for try await update in CLLocationUpdate.liveUpdates() {
            guard let coord = update.location?.coordinate else { continue }
            return coord
        }
        throw CancellationError()
    }

    private func cached(_ key: String) -> Place? {
        cache[key]
    }

    private func store(_ key: String, _ place: Place) {
        cache[key] = place
    }
}

/// Runs an async operation with a timeout, returning nil if it exceeds the limit.
private func withTaskTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T?
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = await group.next()
        group.cancelAll()
        return result ?? nil
    }
}

#endif
