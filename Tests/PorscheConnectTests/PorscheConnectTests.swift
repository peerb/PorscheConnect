import XCTest
@testable import PorscheConnect

// MARK: - Captcha Extraction

final class CaptchaExtractionTests: XCTestCase {

    let auth = PorscheAuth(email: "test@test.com", password: "pass")

    func testACULContext() {
        let context: [String: Any] = [
            "screen": ["captcha": ["provider": "auth0", "image": "data:image/svg+xml;base64,TESTCAPTCHA"]],
            "client": ["id": "test"],
        ]
        let base64 = try! JSONSerialization.data(withJSONObject: context).base64EncodedString()
        let html = #"<script>atob("\#(base64)")</script>"#
        XCTAssertEqual(auth.extractCaptchaImage(from: html), "data:image/svg+xml;base64,TESTCAPTCHA")
    }

    func testImgTag() {
        let html = #"<div><img alt="captcha" src="https://example.com/captcha.png" /></div>"#
        XCTAssertEqual(auth.extractCaptchaImage(from: html), "https://example.com/captcha.png")
    }

    func testSVGDataURI() {
        let html = #"<div style="background:url(data:image/svg+xml;base64,PHN2Zz4= )"></div>"#
        XCTAssertEqual(auth.extractCaptchaImage(from: html), "data:image/svg+xml;base64,PHN2Zz4=")
    }

    func testNoCaptchaReturnsNil() {
        XCTAssertNil(auth.extractCaptchaImage(from: "<html><body>Normal page</body></html>"))
    }

    func testACULPriority() {
        let context: [String: Any] = ["screen": ["captcha": ["image": "acul-image"]]]
        let base64 = try! JSONSerialization.data(withJSONObject: context).base64EncodedString()
        let html = #"<script>atob("\#(base64)")</script><img alt="captcha" src="img-tag-image" />"#
        XCTAssertEqual(auth.extractCaptchaImage(from: html), "acul-image")
    }

    func testRealAuth0Structure() {
        let context: [String: Any] = [
            "client": ["id": "XhygisuebbrqQ80byOuU5VncxLIm8E6H"],
            "screen": ["captcha": ["provider": "auth0", "image": "data:image/svg+xml;base64,PHN2Zz4="]],
        ]
        let base64 = try! JSONSerialization.data(withJSONObject: context).base64EncodedString()
        let html = #"<script>window.universal_login_context=JSON.parse(new TextDecoder('utf-8').decode(Uint8Array.from(atob("\#(base64)"))))</script>"#
        XCTAssert(auth.extractCaptchaImage(from: html)?.hasPrefix("data:image/svg+xml;base64,") == true)
    }
}

// MARK: - Query Parameters

final class QueryParamTests: XCTestCase {

    let auth = PorscheAuth(email: "test@test.com", password: "pass")

    func testExtractsCode() {
        let url = "my-porsche-app://auth0/callback?code=ABC123&state=xyz"
        XCTAssertEqual(auth.extractQueryParam("code", from: url), "ABC123")
        XCTAssertEqual(auth.extractQueryParam("state", from: url), "xyz")
    }

    func testMissingParam() {
        XCTAssertNil(auth.extractQueryParam("code", from: "https://example.com?foo=bar"))
    }

    func testURLEncodedValues() {
        XCTAssertEqual(auth.extractQueryParam("msg", from: "https://example.com?msg=hello%20world"), "hello world")
    }

    func testEmptyValue() {
        XCTAssertEqual(auth.extractQueryParam("key", from: "https://example.com?key="), "")
    }
}

// MARK: - Token

final class TokenTests: XCTestCase {

    func testNotExpiredWhenFuture() {
        let token = PorscheToken(accessToken: "valid", expiresAt: Date().timeIntervalSince1970 + 3600)
        XCTAssertFalse(token.isExpired)
        XCTAssertFalse(token.needsFullLogin)
    }

    func testExpiredWhenPast() {
        let token = PorscheToken(accessToken: "old", expiresAt: Date().timeIntervalSince1970 - 100)
        XCTAssertTrue(token.isExpired)
    }

    func testExpiredWithinLeeway() {
        let token = PorscheToken(accessToken: "almost", expiresAt: Date().timeIntervalSince1970 + 30)
        XCTAssertTrue(token.isExpired)
    }

    func testExpiredWithNoExpiresAt() {
        XCTAssertTrue(PorscheToken().isExpired)
    }

    func testNeedsFullLoginWithoutAccessToken() {
        let token = PorscheToken(expiresAt: Date().timeIntervalSince1970 + 3600)
        XCTAssertTrue(token.needsFullLogin)
    }

    func testUpdateExpiry() {
        var token = PorscheToken(expiresIn: 3600)
        let before = Date().timeIntervalSince1970
        token.updateExpiry()
        XCTAssertGreaterThanOrEqual(token.expiresAt!, before + 3600)
    }

    func testUpdateMergesFields() {
        var token = PorscheToken(accessToken: "old", refreshToken: "refresh1")
        let update = PorscheToken(accessToken: "new", expiresIn: 7200)
        token.update(from: update)
        XCTAssertEqual(token.accessToken, "new")
        XCTAssertEqual(token.refreshToken, "refresh1")
        XCTAssertNotNil(token.expiresAt)
    }

    func testJSONRoundTrip() {
        let original = PorscheToken(accessToken: "at123", refreshToken: "rt456", expiresIn: 3600, expiresAt: 1700000000)
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(PorscheToken.self, from: data)
        XCTAssertEqual(decoded.accessToken, "at123")
        XCTAssertEqual(decoded.refreshToken, "rt456")
        XCTAssertEqual(decoded.expiresAt, 1700000000)
    }
}

// MARK: - FileTokenStore

final class FileTokenStoreTests: XCTestCase {

    var storePath: String!

    override func setUp() {
        storePath = NSTemporaryDirectory() + "porscheconnect_test_\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: storePath)
    }

    func testSaveAndLoad() {
        let store = FileTokenStore(path: storePath)
        let token = PorscheToken(accessToken: "at", refreshToken: "rt", expiresAt: 1700000000)
        store.save(token)
        let loaded = store.load()
        XCTAssertEqual(loaded?.accessToken, "at")
        XCTAssertEqual(loaded?.refreshToken, "rt")
        XCTAssertEqual(loaded?.expiresAt, 1700000000)
    }

    func testLoadReturnsNilWhenNoFile() {
        let store = FileTokenStore(path: storePath)
        XCTAssertNil(store.load())
    }

    func testDelete() {
        let store = FileTokenStore(path: storePath)
        store.save(PorscheToken(accessToken: "temp"))
        store.delete()
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: storePath))
    }

    func testOverwrite() {
        let store = FileTokenStore(path: storePath)
        store.save(PorscheToken(accessToken: "first"))
        store.save(PorscheToken(accessToken: "second"))
        XCTAssertEqual(store.load()?.accessToken, "second")
    }

    func testFilePermissions() {
        let store = FileTokenStore(path: storePath)
        store.save(PorscheToken(accessToken: "secret"))
        let attrs = try? FileManager.default.attributesOfItem(atPath: storePath)
        let perms = attrs?[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "Token file should be owner-only readable")
    }

    func testCreatesParentDirectories() {
        let nested = NSTemporaryDirectory() + "porscheconnect_test_\(UUID().uuidString)/nested/tokens.json"
        let store = FileTokenStore(path: nested)
        store.save(PorscheToken(accessToken: "deep"))
        XCTAssertEqual(store.load()?.accessToken, "deep")
        try? FileManager.default.removeItem(atPath: (nested as NSString).deletingLastPathComponent)
    }
}

// MARK: - PIN Hash

final class PinHashTests: XCTestCase {

    let rs = PorscheRemoteServices(auth: PorscheAuth(email: "t@t.com", password: "p"), vin: "WP0TEST")

    func testDeterministic() {
        let hash1 = rs.computePinHash(pin: "1234", challenge: "AABB")
        let hash2 = rs.computePinHash(pin: "1234", challenge: "AABB")
        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 128)
        XCTAssertEqual(hash1, hash1.uppercased())
    }

    func testDifferentPIN() {
        XCTAssertNotEqual(
            rs.computePinHash(pin: "1234", challenge: "AABB"),
            rs.computePinHash(pin: "5678", challenge: "AABB")
        )
    }

    func testDifferentChallenge() {
        XCTAssertNotEqual(
            rs.computePinHash(pin: "1234", challenge: "AABB"),
            rs.computePinHash(pin: "1234", challenge: "CCDD")
        )
    }
}

// MARK: - Vehicle Selection

final class VehicleSelectionTests: XCTestCase {

    func testBEVIsElectric() {
        let v = PCVehicleListItem(vin: "WP0", modelName: "Taycan", modelType: PCModelType(year: "2024", engine: "BEV"))
        XCTAssertTrue(v.isElectric)
    }

    func testPHEVIsElectric() {
        let v = PCVehicleListItem(vin: "WP0", modelName: "Cayenne", modelType: PCModelType(year: "2024", engine: "PHEV"))
        XCTAssertTrue(v.isElectric)
    }

    func testCombustionNotElectric() {
        let v = PCVehicleListItem(vin: "WP0", modelName: "911", modelType: PCModelType(year: "1988", engine: "COMBUSTION"))
        XCTAssertFalse(v.isElectric)
    }

    func testCustomName() {
        let v = PCVehicleListItem(vin: "WP0", modelName: "Taycan", modelType: PCModelType(), customName: "My Car")
        XCTAssertEqual(v.displayName, "My Car")
    }

    func testModelNameFallback() {
        let v = PCVehicleListItem(vin: "WP0", modelName: "Taycan", modelType: PCModelType())
        XCTAssertEqual(v.displayName, "Taycan")
    }
}

// MARK: - Measurement Decoding

final class MeasurementDecodingTests: XCTestCase {

    func testBatteryLevel() {
        let m = decode(#"{"key":"BATTERY_LEVEL","status":{"isEnabled":true},"value":{"percent":87}}"#)
        XCTAssertEqual(m.value?.int(forKey: "percent"), 87)
    }

    func testLockState() {
        let m = decode(#"{"key":"LOCK_STATE_VEHICLE","status":{"isEnabled":true},"value":{"isLocked":true}}"#)
        XCTAssertEqual(m.value?.bool(forKey: "isLocked"), true)
    }

    func testMileageDouble() {
        let m = decode(#"{"key":"MILEAGE","status":{"isEnabled":true},"value":{"kilometers":12345.6}}"#)
        XCTAssertEqual(m.value?.double(forKey: "kilometers"), 12345.6)
        XCTAssertEqual(m.value?.int(forKey: "kilometers"), 12345)
    }

    func testStringValue() {
        let m = decode(#"{"key":"GPS_LOCATION","status":{"isEnabled":true},"value":{"location":"48.1,11.4"}}"#)
        XCTAssertEqual(m.value?.string(forKey: "location"), "48.1,11.4")
    }

    func testMissingValue() {
        let m = decode(#"{"key":"SOME_KEY","status":{"isEnabled":true}}"#)
        XCTAssertNil(m.value)
    }

    func testDisabled() {
        let m = decode(#"{"key":"FUEL","status":{"isEnabled":false},"value":{"percent":0}}"#)
        XCTAssertFalse(m.status.isEnabled)
    }

    func testMissingKey() {
        let m = decode(#"{"key":"T","status":{"isEnabled":true},"value":{"foo":"bar"}}"#)
        XCTAssertNil(m.value?.int(forKey: "missing"))
        XCTAssertNil(m.value?.bool(forKey: "missing"))
    }

    func testNestedObject() {
        let m = decode(#"{"key":"TIRE","status":{"isEnabled":true},"value":{"front":{"bar":2.4}}}"#)
        XCTAssertNotNil(m.value)
    }

    func testEmptyValue() {
        let m = decode(#"{"key":"E","status":{"isEnabled":true},"value":{}}"#)
        XCTAssertNil(m.value?.int(forKey: "anything"))
    }

    private func decode(_ json: String) -> PCMeasurement {
        try! JSONDecoder().decode(PCMeasurement.self, from: json.data(using: .utf8)!)
    }
}

// MARK: - Vehicle List Decoding

final class VehicleListDecodingTests: XCTestCase {

    func testFullList() {
        let json = """
        [
            {"vin":"WP0A","modelName":"911","modelType":{"year":"1988","engine":"COMBUSTION"}},
            {"vin":"WP0B","modelName":"Taycan","modelType":{"year":"2026","engine":"BEV"},"customName":"My Taycan"}
        ]
        """.data(using: .utf8)!
        let vehicles = try! JSONDecoder().decode([PCVehicleListItem].self, from: json)
        XCTAssertEqual(vehicles.count, 2)
        XCTAssertFalse(vehicles[0].isElectric)
        XCTAssertTrue(vehicles[1].isElectric)
        XCTAssertEqual(vehicles[1].displayName, "My Taycan")
    }

    func testMissingOptionalFields() {
        let json = #"[{"vin":"WP0","modelName":"Test","modelType":{}}]"#.data(using: .utf8)!
        let vehicles = try! JSONDecoder().decode([PCVehicleListItem].self, from: json)
        XCTAssertEqual(vehicles[0].year, "")
        XCTAssertFalse(vehicles[0].isElectric)
    }
}

// MARK: - ExtractKm

final class ExtractKmTests: XCTestCase {

    let api = PorscheConnectAPI(email: "t@t.com", password: "p")

    func testKilometersKey() {
        let m = decodeMeasurement(#"{"key":"E_RANGE","status":{"isEnabled":true},"value":{"kilometers":183}}"#)
        XCTAssertEqual(api.extractKm(from: ["E_RANGE": m.value!], keys: ["E_RANGE"]), 183)
    }

    func testValueKeyFallback() {
        let m = decodeMeasurement(#"{"key":"RANGE","status":{"isEnabled":true},"value":{"value":250}}"#)
        XCTAssertEqual(api.extractKm(from: ["RANGE": m.value!], keys: ["RANGE"]), 250)
    }

    func testMultipleKeysOrder() {
        let m = decodeMeasurement(#"{"key":"MILEAGE","status":{"isEnabled":true},"value":{"kilometers":5000}}"#)
        XCTAssertEqual(api.extractKm(from: ["MILEAGE": m.value!], keys: ["E_RANGE", "MILEAGE"]), 5000)
    }

    func testNoMatch() {
        XCTAssertNil(api.extractKm(from: [:], keys: ["E_RANGE"]))
    }

    func testDoubleTruncation() {
        let m = decodeMeasurement(#"{"key":"M","status":{"isEnabled":true},"value":{"kilometers":2371.7}}"#)
        XCTAssertEqual(api.extractKm(from: ["M": m.value!], keys: ["M"]), 2371)
    }

    private func decodeMeasurement(_ json: String) -> PCMeasurement {
        try! JSONDecoder().decode(PCMeasurement.self, from: json.data(using: .utf8)!)
    }
}

// MARK: - Remote Command State

final class RemoteCommandStateTests: XCTestCase {

    func testKnownStates() {
        XCTAssertEqual(RemoteCommandState(raw: "PERFORMED"), .performed)
        XCTAssertEqual(RemoteCommandState(raw: "ERROR"), .error)
        XCTAssertEqual(RemoteCommandState(raw: "ACCEPTED"), .accepted)
    }

    func testUnknown() {
        XCTAssertEqual(RemoteCommandState(raw: "SOMETHING"), .unknown)
        XCTAssertEqual(RemoteCommandState(raw: nil), .unknown)
        XCTAssertEqual(RemoteCommandState(raw: ""), .unknown)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(RemoteCommandState(raw: "performed"), .performed)
        XCTAssertEqual(RemoteCommandState(raw: "Accepted"), .accepted)
    }
}

// MARK: - Errors

final class ErrorTests: XCTestCase {

    func testDescriptions() {
        XCTAssertEqual(PorscheConnectError.wrongCredentials.localizedDescription, "Wrong email or password")
        XCTAssertEqual(PorscheConnectError.noAuthCode.localizedDescription, "Could not obtain authorization code")
        XCTAssertEqual(PorscheConnectError.httpError(404, "Not found").localizedDescription, "HTTP 404: Not found")
        XCTAssertEqual(PorscheConnectError.remoteCommandTimeout(240).localizedDescription, "Remote command timed out after 240s")
    }
}

// MARK: - Constants

final class ConstantsTests: XCTestCase {

    func testURLsAreHTTPS() {
        XCTAssert(Porsche.authorizeURL.hasPrefix("https://"))
        XCTAssert(Porsche.tokenURL.hasPrefix("https://"))
        XCTAssert(Porsche.apiBaseURL.hasPrefix("https://"))
    }

    func testScopesContainRequired() {
        XCTAssert(Porsche.scopes.contains("openid"))
        XCTAssert(Porsche.scopes.contains("offline_access"))
        XCTAssert(Porsche.scopes.contains("charging"))
    }

    func testMeasurementsNotEmpty() {
        XCTAssertFalse(Porsche.measurements.isEmpty)
        XCTAssert(Porsche.measurements.contains("BATTERY_LEVEL"))
        XCTAssert(Porsche.measurements.contains("LOCK_STATE_VEHICLE"))
    }
}
