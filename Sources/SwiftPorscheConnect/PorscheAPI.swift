import Foundation

/// High-level client for the Porsche Connect vehicle API.
///
/// Uses ``PorscheAuth`` for token management and makes authenticated requests.
///
/// ```swift
/// let api = PorscheConnectAPI(email: "...", password: "...", tokenStore: FileTokenStore(path: "..."))
/// let data = try await api.fetchVehicleData()
/// print(data.batteryLevel)  // 87
/// ```
///
/// All methods are `async` and require Swift concurrency (Swift 5.5+).
/// This class is **not thread-safe** — avoid concurrent calls from multiple tasks.
public class PorscheConnectAPI {
    /// The auth handler. Access this to call ``PorscheAuth/loginWithCaptcha(code:state:)``
    /// after receiving a ``PorscheConnectError/captchaRequired(_:)`` error.
    public let auth: PorscheAuth

    /// Create a Porsche Connect API client.
    /// - Parameters:
    ///   - email: Porsche ID email address.
    ///   - password: Porsche ID password.
    ///   - tokenStore: Optional store for persisting tokens between sessions.
    public init(email: String, password: String, tokenStore: PorscheTokenStore? = nil) {
        self.auth = PorscheAuth(email: email, password: password, tokenStore: tokenStore)
    }

    // MARK: - Vehicles

    /// Fetch all vehicles associated with the Porsche ID account.
    public func getVehicles() async throws -> [PCVehicleListItem] {
        return try await get("/connect/v1/vehicles")
    }

    /// Fetch picture URLs for a vehicle (side, front, rear, top views).
    /// - Parameter vin: Vehicle Identification Number.
    public func getPictures(vin: String) async throws -> [PCPicture] {
        return try await get("/connect/v1/vehicles/\(vin)/pictures")
    }

    // MARK: - Vehicle Status

    /// Fetch the cached vehicle status. Does **not** wake the car.
    /// - Parameter vin: Vehicle Identification Number.
    public func getStoredOverview(vin: String) async throws -> PCVehicleStatus {
        let mf = Porsche.measurements.map { "mf=\($0)" }.joined(separator: "&")
        return try await get("/connect/v1/vehicles/\(vin)?\(mf)")
    }

    /// Fetch live vehicle status. **Wakes the car** to get real-time data.
    /// - Parameter vin: Vehicle Identification Number.
    public func getCurrentOverview(vin: String) async throws -> PCVehicleStatus {
        let mf = Porsche.measurements.map { "mf=\($0)" }.joined(separator: "&")
        let wakeup = "&wakeUpJob=\(UUID().uuidString)"
        return try await get("/connect/v1/vehicles/\(vin)?\(mf)\(wakeup)")
    }

    /// Fetch trip statistics for a vehicle.
    /// - Parameter vin: Vehicle Identification Number.
    public func getTripStatistics(vin: String) async throws -> PCVehicleStatus {
        let trips = [
            "TRIP_STATISTICS_CYCLIC", "TRIP_STATISTICS_LONG_TERM",
            "TRIP_STATISTICS_LONG_TERM_HISTORY", "TRIP_STATISTICS_SHORT_TERM_HISTORY",
            "TRIP_STATISTICS_CYCLIC_HISTORY", "TRIP_STATISTICS_SHORT_TERM",
        ]
        let mf = trips.map { "mf=\($0)" }.joined(separator: "&")
        return try await get("/connect/v1/vehicles/\(vin)?\(mf)")
    }

    /// Fetch vehicle capabilities (available measurements and commands).
    /// - Parameter vin: Vehicle Identification Number.
    public func getCapabilities(vin: String) async throws -> PCVehicleStatus {
        let mf = Porsche.measurements.map { "mf=\($0)" }.joined(separator: "&")
        let commands = [
            "HONK_FLASH", "LOCK", "UNLOCK", "REMOTE_CLIMATIZER_START",
            "REMOTE_CLIMATIZER_STOP", "DIRECT_CHARGING_START", "DIRECT_CHARGING_STOP",
            "CHARGING_SETTINGS_EDIT", "CHARGING_PROFILES_EDIT",
        ]
        let cf = commands.map { "cf=\($0)" }.joined(separator: "&")
        return try await get("/connect/v1/vehicles/\(vin)?\(mf)&\(cf)")
    }

    // MARK: - Remote Services

    /// Create a remote services handle for sending commands to a vehicle.
    /// - Parameter vin: Vehicle Identification Number.
    /// - Returns: A ``PorscheRemoteServices`` instance bound to this vehicle.
    public func remoteServices(vin: String) -> PorscheRemoteServices {
        PorscheRemoteServices(auth: auth, vin: vin)
    }

    // MARK: - Convenience

    /// Aggregated vehicle data for display.
    public struct VehicleData {
        /// All vehicles in the account.
        public let vehicles: [PCVehicleListItem]
        /// The selected vehicle (by VIN, or first EV, or first vehicle).
        public let selectedVehicle: PCVehicleListItem
        /// Battery level as a percentage (0–100), or `nil` for non-EV vehicles.
        public let batteryLevel: Int?
        /// Electric range in kilometers, or `nil` if unavailable.
        public let rangeKm: Int?
        /// Odometer reading in kilometers, or `nil` if unavailable.
        public let mileageKm: Int?
        /// Whether the vehicle is locked, or `nil` if unavailable.
        public let isLocked: Bool?
        /// Picture URLs keyed by view angle (`"sideView"`, `"frontView"`, etc.).
        public let pictures: [String: String]
        /// Raw measurements keyed by measurement name (e.g., `"BATTERY_LEVEL"`).
        public let measurements: [String: PCMeasurementValue]
    }

    /// Fetch all display data for a vehicle in one call.
    ///
    /// Vehicle selection priority: explicit `selectedVin` → first electric vehicle → first vehicle.
    ///
    /// - Parameter selectedVin: Optional VIN to select a specific vehicle.
    public func fetchVehicleData(selectedVin: String? = nil) async throws -> VehicleData {
        let vehicles = try await getVehicles()
        guard !vehicles.isEmpty else {
            throw PorscheConnectError.noData
        }

        let selected: PCVehicleListItem
        if let vin = selectedVin, let match = vehicles.first(where: { $0.vin == vin }) {
            selected = match
        } else if let ev = vehicles.first(where: { $0.isElectric }) {
            selected = ev
        } else {
            selected = vehicles[0]
        }

        var pictureMap: [String: String] = [:]
        if let pics = try? await getPictures(vin: selected.vin) {
            for p in pics { pictureMap[p.view] = p.url }
        }

        var measurements: [String: PCMeasurementValue] = [:]
        if let status = try? await getStoredOverview(vin: selected.vin),
           let mList = status.measurements {
            for m in mList where m.status.isEnabled && m.value != nil {
                measurements[m.key] = m.value!
            }
        }

        return VehicleData(
            vehicles: vehicles, selectedVehicle: selected,
            batteryLevel: measurements["BATTERY_LEVEL"]?.int(forKey: "percent"),
            rangeKm: extractKm(from: measurements, keys: ["E_RANGE", "RANGE"]),
            mileageKm: extractKm(from: measurements, keys: ["MILEAGE"]),
            isLocked: measurements["LOCK_STATE_VEHICLE"]?.bool(forKey: "isLocked"),
            pictures: pictureMap, measurements: measurements
        )
    }

    // MARK: - Internal Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let accessToken = try await auth.ensureValidToken()

        var request = URLRequest(url: URL(string: "\(Porsche.apiBaseURL)\(path)")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Porsche.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Porsche.xClientID, forHTTPHeaderField: "X-Client-ID")
        request.timeoutInterval = Porsche.timeout

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PorscheConnectError.httpError(status, String(body.prefix(500)))
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Extract a kilometer value from measurements, trying multiple keys and nested field names.
    func extractKm(from measurements: [String: PCMeasurementValue], keys: [String]) -> Int? {
        for key in keys {
            if let v = measurements[key] {
                if let km = v.int(forKey: "kilometers") ?? v.int(forKey: "value") ?? v.int(forKey: "distance") {
                    return km
                }
                if let d = v.double(forKey: "kilometers") ?? v.double(forKey: "value") ?? v.double(forKey: "distance") {
                    return Int(d)
                }
            }
        }
        return nil
    }
}
