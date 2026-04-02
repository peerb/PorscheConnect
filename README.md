# PorscheConnect

[![CI](https://github.com/peerb/PorscheConnect/actions/workflows/ci.yml/badge.svg)](https://github.com/peerb/PorscheConnect/actions/workflows/ci.yml)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20|%20iOS%20|%20watchOS%20|%20tvOS-blue.svg)](https://github.com/peerb/PorscheConnect)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A Swift package for the Porsche Connect API. Reimplementation of [pyporscheconnectapi](https://github.com/cjne/pyporscheconnectapi) in native Swift.

Works on macOS 13+, iOS 16+, watchOS 9+, and tvOS 16+. No external dependencies beyond Foundation and CryptoKit.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/peerb/PorscheConnect.git", from: "1.0.0"),
]
```

## Quick Start

```swift
import PorscheConnect

let tokenStore = FileTokenStore(path: "\(NSHomeDirectory())/.porsche/tokens.json")
let api = PorscheConnectAPI(email: "you@example.com", password: "***", tokenStore: tokenStore)

let data = try await api.fetchVehicleData()
print(data.selectedVehicle.modelName)  // "Taycan Sport Turismo"
print(data.batteryLevel)               // 87
print(data.rangeKm)                    // 312
print(data.isLocked)                   // true
```

## Requirements

- Swift 5.9+
- async/await (Swift concurrency)
- Apple platforms (uses Foundation networking and CryptoKit)

## API

### Vehicle Data

```swift
// List all vehicles
let vehicles = try await api.getVehicles()

// Vehicle pictures (side, front, rear, top)
let pictures = try await api.getPictures(vin: "WP0...")

// Cached vehicle status (doesn't wake the car)
let status = try await api.getStoredOverview(vin: "WP0...")

// Live vehicle status (wakes the car)
let live = try await api.getCurrentOverview(vin: "WP0...")

// Trip statistics
let trips = try await api.getTripStatistics(vin: "WP0...")

// All data in one call (vehicles + pictures + status)
let data = try await api.fetchVehicleData(selectedVin: "WP0...")
```

### Remote Commands

```swift
let remote = api.remoteServices(vin: "WP0...")

try await remote.lockVehicle()
try await remote.unlockVehicle(pin: "1234")  // SHA512 challenge-response
try await remote.flashIndicators()
try await remote.honkAndFlash()
try await remote.climatizeOn(targetTemperature: 293.15)  // 20°C in Kelvin
try await remote.climatizeOff()
try await remote.directChargeOn()
try await remote.directChargeOff()
try await remote.setTargetSOC(80)  // 25–100%
```

Remote commands are sent via POST and automatically polled until completion (up to 4 minutes).

### Captcha Handling

The Porsche auth flow may require a captcha. The library throws `PorscheConnectError.captchaRequired` with the captcha image. Display it to the user, then resume:

```swift
do {
    try await api.auth.ensureValidToken()
} catch let error as PorscheConnectError {
    if case .captchaRequired(let captcha) = error {
        let code = showCaptchaUI(captcha.image)  // your UI
        try await api.auth.loginWithCaptcha(code: code, state: captcha.state)
    }
}
```

### Token Storage

Tokens are persisted via the `PorscheTokenStore` protocol:

```swift
public protocol PorscheTokenStore {
    func load() -> PorscheToken?
    func save(_ token: PorscheToken)
    func delete()
}
```

A `FileTokenStore` is included for file-based storage (JSON, `chmod 600`). Implement the protocol for Keychain, CoreData, or any other backend.

## Measurement Keys

The vehicle status response contains measurements keyed by name:

| Key | Value Fields | Description |
|-----|-------------|-------------|
| `BATTERY_LEVEL` | `percent` (Int) | High-voltage battery percentage |
| `E_RANGE` | `kilometers` (Int) | Electric range |
| `MILEAGE` | `kilometers` (Int) | Odometer reading |
| `LOCK_STATE_VEHICLE` | `isLocked` (Bool) | Lock status |
| `GPS_LOCATION` | `location` (String), `direction` (Int) | Lat,lon as string |
| `TIRE_PRESSURE` | Per-tire `currentBar`, `differenceBar` | Tire pressures |
| `CLIMATIZER_STATE` | `isOn` (Bool) | Climate control status |
| `CHARGING_SUMMARY` | `mode`, `minSoC` | Charging info |
| `CHARGING_RATE` | `chargingRate`, `chargingPower` | Current charge rate |

Access values via the typed accessors:
```swift
let percent = measurement.value?.int(forKey: "percent")
let isLocked = measurement.value?.bool(forKey: "isLocked")
let location = measurement.value?.string(forKey: "location")
```

## Thread Safety

This library is **not thread-safe**. Avoid calling API methods concurrently from multiple tasks. If you need concurrent access, serialize calls through an actor or serial queue.

## Credits

Swift reimplementation based on the protocol and API knowledge from [pyporscheconnectapi](https://github.com/cjne/pyporscheconnectapi) by Johan Isacsson, licensed under MIT.

## License

MIT — see [LICENSE](LICENSE).
