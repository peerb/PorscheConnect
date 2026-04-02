import Foundation

// MARK: - Token Storage

/// Protocol for persisting OAuth2 tokens between sessions.
///
/// Implement this to store tokens in Keychain, CoreData, or any other backend.
/// A default ``FileTokenStore`` is provided for file-based storage.
public protocol PorscheTokenStore {
    /// Load a previously saved token, or `nil` if none exists.
    func load() -> PorscheToken?
    /// Persist the token for future sessions.
    func save(_ token: PorscheToken)
    /// Remove the stored token (e.g., on sign-out).
    func delete()
}

/// Default token store that writes JSON to a file with `chmod 600`.
public class FileTokenStore: PorscheTokenStore {
    private let path: String

    /// Create a file-based token store.
    /// - Parameter path: Absolute path to the JSON file (directories are created automatically).
    public init(path: String) {
        self.path = path
    }

    public func load() -> PorscheToken? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let token = try? JSONDecoder().decode(PorscheToken.self, from: data) else { return nil }
        return token
    }

    public func save(_ token: PorscheToken) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(token) {
            try? data.write(to: URL(fileURLWithPath: path))
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    public func delete() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

// MARK: - OAuth2 Token

/// Represents an OAuth2 token with access token, refresh token, and expiry.
public struct PorscheToken: Codable {
    /// The bearer token used to authenticate API requests.
    public var accessToken: String?
    /// Token used to obtain a new access token without re-authenticating.
    public var refreshToken: String?
    /// Lifetime of the access token in seconds (from the auth server response).
    public var expiresIn: Int?
    /// Absolute Unix timestamp when the access token expires.
    public var expiresAt: TimeInterval?

    /// Whether the token has expired (includes a 60-second leeway).
    public var isExpired: Bool {
        guard let expiresAt else { return true }
        return (expiresAt - Porsche.tokenLeeway) < Date().timeIntervalSince1970
    }

    /// Whether a full login flow is needed (no token at all).
    public var needsFullLogin: Bool {
        accessToken == nil || expiresAt == nil
    }

    /// Recalculate `expiresAt` from `expiresIn` relative to now.
    public mutating func updateExpiry() {
        if let expiresIn {
            expiresAt = Date().timeIntervalSince1970 + Double(expiresIn)
        }
    }

    /// Merge fields from another token (e.g., a refresh response that only contains a new access token).
    public mutating func update(from other: PorscheToken) {
        if let at = other.accessToken { accessToken = at }
        if let rt = other.refreshToken { refreshToken = rt }
        if let ei = other.expiresIn { expiresIn = ei }
        updateExpiry()
    }

    public init(accessToken: String? = nil, refreshToken: String? = nil,
                expiresIn: Int? = nil, expiresAt: TimeInterval? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
    }
}

// MARK: - Captcha

/// A captcha challenge returned by the Porsche auth server.
public struct PorscheCaptcha {
    /// The captcha image as a base64 data URI (e.g., `data:image/svg+xml;base64,...`).
    public let image: String
    /// The auth state parameter needed to resume login after solving.
    public let state: String

    public init(image: String, state: String) {
        self.image = image
        self.state = state
    }
}

// MARK: - Errors

/// Errors that can occur when communicating with the Porsche Connect API.
public enum PorscheConnectError: LocalizedError {
    /// Email or password is incorrect.
    case wrongCredentials
    /// The auth server requires a captcha to proceed. Display the image to the user.
    case captchaRequired(PorscheCaptcha)
    /// A step in the OAuth2 flow failed.
    case authFailed(String)
    /// The API returned an HTTP error.
    case httpError(Int, String)
    /// Could not extract an authorization code from the redirect.
    case noAuthCode
    /// The refresh token was rejected (expired or revoked).
    case tokenRefreshFailed
    /// The API returned an empty response where data was expected.
    case noData
    /// A remote command (lock, climate, etc.) failed.
    case remoteCommandFailed(String)
    /// A remote command did not complete within the timeout period.
    case remoteCommandTimeout(Int)

    public var errorDescription: String? {
        switch self {
        case .wrongCredentials:             return "Wrong email or password"
        case .captchaRequired:              return "Captcha required"
        case .authFailed(let msg):          return "Auth failed: \(msg)"
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .noAuthCode:                   return "Could not obtain authorization code"
        case .tokenRefreshFailed:           return "Token refresh failed"
        case .noData:                       return "No data returned"
        case .remoteCommandFailed(let msg): return "Remote command failed: \(msg)"
        case .remoteCommandTimeout(let s):  return "Remote command timed out after \(s)s"
        }
    }
}

// MARK: - Vehicle List

/// A vehicle from the Porsche Connect account.
public struct PCVehicleListItem: Decodable {
    /// Vehicle Identification Number.
    public let vin: String
    /// Factory model name (e.g., "Taycan Sport Turismo").
    public let modelName: String
    /// Model type details (year, engine type).
    public let modelType: PCModelType
    /// User-assigned name, if any.
    public let customName: String?

    /// The custom name if set, otherwise the factory model name.
    public var displayName: String { customName ?? modelName }
    /// Model year as a string (e.g., "2026"), or empty if unavailable.
    public var year: String { modelType.year ?? "" }
    /// Whether the vehicle has a high-voltage battery (BEV or PHEV).
    public var isElectric: Bool { modelType.engine == "BEV" || modelType.engine == "PHEV" }

    public init(vin: String, modelName: String, modelType: PCModelType, customName: String? = nil) {
        self.vin = vin; self.modelName = modelName; self.modelType = modelType; self.customName = customName
    }
}

/// Vehicle model type metadata.
public struct PCModelType: Decodable {
    /// Model year (e.g., "2026").
    public let year: String?
    /// Drivetrain type: `"BEV"`, `"PHEV"`, or `"COMBUSTION"`.
    public let engine: String?

    public init(year: String? = nil, engine: String? = nil) {
        self.year = year; self.engine = engine
    }
}

// MARK: - Pictures

/// A vehicle picture with its view angle and URL.
public struct PCPicture: Decodable {
    /// View angle (e.g., `"sideView"`, `"frontView"`, `"rearView"`, `"topView"`).
    public let view: String
    /// Image URL. Append query parameters to control size (e.g., `width=640&height=360`).
    public let url: String
}

// MARK: - Vehicle Status

/// Response from the vehicle status endpoint (stored or current overview).
public struct PCVehicleStatus: Decodable {
    /// Vehicle Identification Number.
    public let vin: String?
    /// Factory model name.
    public let modelName: String?
    /// Model type details.
    public let modelType: PCModelType?
    /// List of measurements (battery, range, mileage, lock state, etc.).
    public let measurements: [PCMeasurement]?
}

/// A single measurement from the vehicle status response.
public struct PCMeasurement: Decodable {
    /// Measurement key (e.g., `"BATTERY_LEVEL"`, `"MILEAGE"`, `"LOCK_STATE_VEHICLE"`).
    public let key: String
    /// Whether this measurement is enabled for this vehicle.
    public let status: PCMeasurementStatus
    /// The measurement value, or `nil` if the measurement has no data.
    public let value: PCMeasurementValue?
}

/// Whether a measurement is enabled.
public struct PCMeasurementStatus: Decodable {
    public let isEnabled: Bool
}

/// A heterogeneous measurement value container.
///
/// Vehicle measurements have varying structures. Use the typed accessors to extract values:
/// ```swift
/// let percent = measurement.value?.int(forKey: "percent")
/// let isLocked = measurement.value?.bool(forKey: "isLocked")
/// let location = measurement.value?.string(forKey: "location")
/// ```
public struct PCMeasurementValue: Decodable {
    private let raw: [String: AnyCodable]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        raw = (try? container.decode([String: AnyCodable].self)) ?? [:]
    }

    /// Extract an integer value for the given key.
    public func int(forKey key: String) -> Int? { raw[key]?.intValue }
    /// Extract a double value for the given key.
    public func double(forKey key: String) -> Double? { raw[key]?.doubleValue }
    /// Extract a string value for the given key.
    public func string(forKey key: String) -> String? { raw[key]?.stringValue }
    /// Extract a boolean value for the given key.
    public func bool(forKey key: String) -> Bool? { raw[key]?.boolValue }
}

// MARK: - AnyCodable (internal)

struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let o = try? container.decode([String: AnyCodable].self) { value = o.mapValues(\.value) }
        else { value = NSNull() }
    }

    var intValue: Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }
    var doubleValue: Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
    var stringValue: String? { value as? String }
    var boolValue: Bool? { value as? Bool }
}
