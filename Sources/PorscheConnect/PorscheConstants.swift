import Foundation

/// Constants for the Porsche Connect API.
///
/// The `clientID` and `xClientID` are Porsche's public app identifiers
/// extracted from the official My Porsche app. They are not secrets.
enum Porsche {
    static let authServer       = "identity.porsche.com"
    static let authorizeURL     = "https://identity.porsche.com/authorize"
    static let tokenURL         = "https://identity.porsche.com/oauth/token"
    static let apiBaseURL       = "https://api.ppa.porsche.com/app"
    static let redirectURI      = "my-porsche-app://auth0/callback"
    static let audience         = "https://api.porsche.com"
    static let clientID         = "XhygisuebbrqQ80byOuU5VncxLIm8E6H"
    static let xClientID        = "41843fb4-691d-4970-85c7-2673e8ecef40"
    static let userAgent        = "PorscheConnect/1.0"

    /// HTTP request timeout in seconds.
    static let timeout: TimeInterval = 90

    /// Seconds before actual expiry to consider a token expired, preventing edge-case failures.
    static let tokenLeeway: TimeInterval = 60

    /// Delay after password submission — Porsche's auth server needs time to propagate the session.
    static let authPropagationDelay: UInt64 = 2_500_000_000 // nanoseconds (2.5s)

    /// Maximum seconds to poll for a remote command result before timing out.
    static let commandPollingTimeout: TimeInterval = 240

    /// Seconds between remote command status polls.
    static let commandPollingInterval: TimeInterval = 1

    /// OAuth2 scopes requested during authentication.
    static let scopes = [
        "openid", "profile", "email", "offline_access",
        "mbb", "ssodb", "badge", "vin", "dealers", "cars",
        "charging", "manageCharging", "plugAndCharge",
        "climatisation", "manageClimatisation",
        "pid:user_profile.porscheid:read",
        "pid:user_profile.name:read",
        "pid:user_profile.vehicles:read",
        "pid:user_profile.dealers:read",
        "pid:user_profile.emails:read",
        "pid:user_profile.phones:read",
        "pid:user_profile.addresses:read",
        "pid:user_profile.birthdate:read",
        "pid:user_profile.locale:read",
        "pid:user_profile.legal:read",
    ].joined(separator: " ")

    /// Vehicle measurement keys requested from the status endpoint.
    static let measurements = [
        "BATTERY_CHARGING_STATE", "BATTERY_LEVEL",
        "CHARGING_SUMMARY", "CHARGING_RATE",
        "E_RANGE", "FUEL_LEVEL",
        "GPS_LOCATION",
        "LOCK_STATE_VEHICLE",
        "MILEAGE",
        "OPEN_STATE_CHARGE_FLAP_LEFT", "OPEN_STATE_CHARGE_FLAP_RIGHT",
        "OPEN_STATE_DOOR_FRONT_LEFT", "OPEN_STATE_DOOR_FRONT_RIGHT",
        "OPEN_STATE_DOOR_REAR_LEFT", "OPEN_STATE_DOOR_REAR_RIGHT",
        "OPEN_STATE_LID_FRONT", "OPEN_STATE_LID_REAR",
        "CLIMATIZER_STATE",
        "TIRE_PRESSURE",
        "RANGE",
    ]
}
