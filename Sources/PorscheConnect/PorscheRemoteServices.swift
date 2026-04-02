import CryptoKit
import Foundation

// MARK: - Command Status

/// The execution state of a remote command.
public enum RemoteCommandState: String {
    /// Command completed successfully.
    case performed = "PERFORMED"
    /// Command failed.
    case error     = "ERROR"
    /// Command was accepted and is being executed (will be polled).
    case accepted  = "ACCEPTED"
    /// Status is not yet known.
    case unknown   = "UNKNOWN"

    /// Parse a state string from the API (case-insensitive).
    public init(raw: String?) {
        self = RemoteCommandState(rawValue: raw?.uppercased() ?? "") ?? .unknown
    }
}

/// The result of a remote command execution.
public struct RemoteCommandStatus {
    /// Final state of the command.
    public let state: RemoteCommandState
    /// Server-assigned status ID (used for polling).
    public let statusId: String?
    /// Raw response from the API.
    public let details: [String: Any]
}

// MARK: - Remote Services

/// Send remote commands to a Porsche vehicle (lock, charge, climate, etc.).
///
/// Commands are sent via POST and polled until completion (up to 4 minutes).
///
/// ```swift
/// let remote = api.remoteServices(vin: "WP0...")
/// try await remote.lockVehicle()
/// try await remote.flashIndicators()
/// try await remote.climatizeOn()
/// ```
public class PorscheRemoteServices {
    private let auth: PorscheAuth
    private let vin: String

    /// Create a remote services handle for a specific vehicle.
    /// - Parameters:
    ///   - auth: The auth handler (provides access tokens).
    ///   - vin: Vehicle Identification Number.
    public init(auth: PorscheAuth, vin: String) {
        self.auth = auth
        self.vin = vin
    }

    // MARK: - Flash & Honk

    /// Flash the vehicle's indicators briefly.
    public func flashIndicators() async throws -> RemoteCommandStatus {
        try await sendCommand(key: "HONK_FLASH", payload: ["mode": "FLASH", "spin": NSNull()])
    }

    /// Honk the horn and flash indicators.
    public func honkAndFlash() async throws -> RemoteCommandStatus {
        try await sendCommand(key: "HONK_FLASH", payload: ["mode": "HONK_AND_FLASH", "spin": NSNull()])
    }

    // MARK: - Climate

    /// Start remote climate control.
    /// - Parameters:
    ///   - targetTemperature: Temperature in Kelvin (default 293.15 = 20°C).
    ///   - frontLeft: Enable front-left climate zone.
    ///   - frontRight: Enable front-right climate zone.
    ///   - rearLeft: Enable rear-left climate zone.
    ///   - rearRight: Enable rear-right climate zone.
    public func climatizeOn(
        targetTemperature: Double = 293.15,
        frontLeft: Bool = false,
        frontRight: Bool = false,
        rearLeft: Bool = false,
        rearRight: Bool = false
    ) async throws -> RemoteCommandStatus {
        try await sendCommand(key: "REMOTE_CLIMATIZER_START", payload: [
            "targetTemperature": targetTemperature,
            "climateZonesEnabled": [
                "frontLeft": frontLeft, "frontRight": frontRight,
                "rearLeft": rearLeft, "rearRight": rearRight,
            ],
        ])
    }

    /// Stop remote climate control.
    public func climatizeOff() async throws -> RemoteCommandStatus {
        try await sendCommand(key: "REMOTE_CLIMATIZER_STOP", payload: [:])
    }

    // MARK: - Charging

    /// Start direct charging.
    public func directChargeOn() async throws -> RemoteCommandStatus {
        try await sendCommand(key: "DIRECT_CHARGING_START", payload: ["spin": NSNull()])
    }

    /// Stop direct charging.
    public func directChargeOff() async throws -> RemoteCommandStatus {
        try await sendCommand(key: "DIRECT_CHARGING_STOP", payload: ["spin": NSNull()])
    }

    /// Set the target state of charge (SOC) for the high-voltage battery.
    /// - Parameter soc: Target percentage, clamped to 25–100%.
    public func setTargetSOC(_ soc: Int) async throws -> RemoteCommandStatus {
        let clamped = min(max(soc, 25), 100)
        return try await sendCommand(key: "CHARGING_SETTINGS_EDIT", payload: [
            "targetSoc": clamped, "spin": NSNull(),
        ])
    }

    // MARK: - Lock & Unlock

    /// Lock the vehicle.
    public func lockVehicle() async throws -> RemoteCommandStatus {
        try await sendCommand(key: "LOCK", payload: ["spin": NSNull()])
    }

    /// Unlock the vehicle using a SHA512 challenge-response.
    ///
    /// The PIN is never sent in plain text — it's hashed with a server-provided challenge.
    /// - Parameter pin: The user's 4-digit Porsche security PIN.
    public func unlockVehicle(pin: String) async throws -> RemoteCommandStatus {
        // Step 1: Request a challenge from the server
        let challengePayload: [String: Any] = ["key": "SPIN_CHALLENGE", "payload": ["spin": NSNull()]]
        let challengeResponse = try await postCommand(json: challengePayload)

        guard let data = challengeResponse["data"] as? [String: Any],
              let challenge = data["challenge"] as? String else {
            throw PorscheConnectError.authFailed("No challenge returned for unlock")
        }

        // Step 2: Compute SHA512(pin_hex + challenge_hex) and send
        let pinHash = computePinHash(pin: pin, challenge: challenge)
        return try await sendCommand(key: "UNLOCK", payload: [
            "spin": ["challenge": challenge, "hash": pinHash],
        ])
    }

    // MARK: - Command Infrastructure

    private func sendCommand(key: String, payload: [String: Any]) async throws -> RemoteCommandStatus {
        let json: [String: Any] = ["key": key, "payload": payload]
        let response = try await postCommand(json: json)

        guard let statusDict = response["status"] as? [String: Any] else {
            throw PorscheConnectError.noData
        }

        let statusId = statusDict["id"] as? String
        let resultCode = statusDict["result"] as? String
        let state = RemoteCommandState(raw: resultCode)

        if state == .accepted, let statusId {
            return try await pollUntilDone(statusId: statusId)
        }

        return RemoteCommandStatus(state: state, statusId: statusId, details: response)
    }

    private func postCommand(json: [String: Any]) async throws -> [String: Any] {
        let accessToken = try await auth.ensureValidToken()
        let url = URL(string: "\(Porsche.apiBaseURL)/connect/v1/vehicles/\(vin)/commands")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Porsche.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Porsche.xClientID, forHTTPHeaderField: "X-Client-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Porsche.timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: json)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PorscheConnectError.httpError(status, String(body.prefix(500)))
        }

        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func pollUntilDone(statusId: String) async throws -> RemoteCommandStatus {
        let deadline = Date().addingTimeInterval(Porsche.commandPollingTimeout)

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(Porsche.commandPollingInterval * 1_000_000_000))

            let accessToken = try await auth.ensureValidToken()
            let url = URL(string: "\(Porsche.apiBaseURL)/connect/v1/vehicles/\(vin)/commands/\(statusId)")!

            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(Porsche.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Porsche.xClientID, forHTTPHeaderField: "X-Client-ID")
            request.timeoutInterval = Porsche.timeout

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

            let result = (json["status"] as? [String: Any])?["result"] as? String
            let state = RemoteCommandState(raw: result)

            switch state {
            case .error:
                throw PorscheConnectError.remoteCommandFailed("\(json)")
            case .performed:
                return RemoteCommandStatus(state: .performed, statusId: statusId, details: json)
            case .accepted, .unknown:
                continue
            }
        }

        throw PorscheConnectError.remoteCommandTimeout(Int(Porsche.commandPollingTimeout))
    }

    // MARK: - PIN Hash

    /// Compute SHA512 hash of PIN + challenge for the unlock challenge-response.
    func computePinHash(pin: String, challenge: String) -> String {
        let combined = Data(hexToBytes(pin) + hexToBytes(challenge))
        let digest = SHA512.hash(data: combined)
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let nextIdx = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[idx..<nextIdx], radix: 16) {
                bytes.append(byte)
            }
            idx = nextIdx
        }
        return bytes
    }
}
