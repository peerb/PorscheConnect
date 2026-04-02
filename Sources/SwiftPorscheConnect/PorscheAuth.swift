import Foundation

/// Handles Porsche Connect OAuth2 authentication using Auth0's Identifier First flow.
///
/// The authentication flow:
/// 1. `GET /authorize` → 302 with auth code (if session exists) or state (needs login)
/// 2. `POST /u/login/identifier` → submit email (+ captcha code if retrying)
/// 3. `POST /u/login/password` → submit password, receive resume URL
/// 4. `GET /authorize/resume` → 302 with authorization code
/// 5. `POST /oauth/token` → exchange code for access + refresh tokens
///
/// Token refresh: `POST /oauth/token` with `grant_type=refresh_token`
///
/// This class is **not thread-safe**. Callers should ensure that only one
/// call to ``ensureValidToken()`` or ``loginWithCaptcha(code:state:)`` is
/// in flight at a time.
public class PorscheAuth {
    private let email: String
    private let password: String
    private let session: URLSession
    private var token: PorscheToken
    private let tokenStore: PorscheTokenStore?

    /// Create an auth handler.
    /// - Parameters:
    ///   - email: Porsche ID email address.
    ///   - password: Porsche ID password.
    ///   - tokenStore: Optional store for persisting tokens between sessions.
    public init(email: String, password: String, tokenStore: PorscheTokenStore? = nil) {
        self.email = email
        self.password = password
        self.token = tokenStore?.load() ?? PorscheToken()
        self.tokenStore = tokenStore

        // URLSession that does NOT follow redirects — we need to read Location headers manually
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.timeoutIntervalForRequest = Porsche.timeout
        self.session = URLSession(configuration: config, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Public API

    /// Returns a valid access token, refreshing or logging in as needed.
    ///
    /// - Throws: ``PorscheConnectError/captchaRequired(_:)`` if a captcha must be solved.
    ///   Display the captcha image to the user, then call ``loginWithCaptcha(code:state:)``.
    /// - Returns: A valid bearer token string.
    @discardableResult
    public func ensureValidToken() async throws -> String {
        if !token.needsFullLogin && !token.isExpired {
            return token.accessToken!
        }

        // Try refresh first
        if let refreshToken = token.refreshToken, !token.needsFullLogin {
            if let refreshed = try? await refreshAccessToken(refreshToken) {
                token.update(from: refreshed)
                tokenStore?.save(token)
                return token.accessToken!
            }
        }

        // Full login
        let code = try await fetchAuthorizationCode(captchaCode: nil, state: nil)
        let tokenData = try await exchangeCodeForToken(code)
        token.update(from: tokenData)
        tokenStore?.save(token)
        return token.accessToken!
    }

    /// Resume authentication after solving a captcha.
    ///
    /// - Parameters:
    ///   - code: The captcha solution entered by the user.
    ///   - state: The `state` value from the ``PorscheCaptcha``.
    /// - Returns: A valid bearer token string.
    @discardableResult
    public func loginWithCaptcha(code: String, state: String) async throws -> String {
        let authCode = try await fetchAuthorizationCode(captchaCode: code, state: state)
        let tokenData = try await exchangeCodeForToken(authCode)
        token.update(from: tokenData)
        tokenStore?.save(token)
        return token.accessToken!
    }

    /// Returns the current token (e.g., for manual persistence).
    public func getToken() -> PorscheToken { token }

    // MARK: - Authorization Code Flow

    private func fetchAuthorizationCode(captchaCode: String?, state: String?) async throws -> String {
        if let captchaCode, let state {
            let resumePath = try await loginWithIdentifier(state: state, captchaCode: captchaCode)
            return try await getAuthCodeFromResume(resumePath: resumePath)
        }

        let params = [
            "response_type": "code",
            "client_id": Porsche.clientID,
            "redirect_uri": Porsche.redirectURI,
            "audience": Porsche.audience,
            "scope": Porsche.scopes,
            "state": "porscheconnect",
        ]
        let url = buildURL(Porsche.authorizeURL, params: params)
        let (_, response) = try await session.data(for: authRequest(url: url))

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 302,
              let location = httpResponse.value(forHTTPHeaderField: "Location") else {
            throw PorscheConnectError.authFailed("Expected 302 from /authorize")
        }

        // Existing session — code is in the redirect
        if let code = extractQueryParam("code", from: location) {
            return code
        }

        // No session — need to login
        guard let authState = extractQueryParam("state", from: location) else {
            throw PorscheConnectError.authFailed("No state in /authorize redirect")
        }

        let resumePath = try await loginWithIdentifier(state: authState, captchaCode: nil)
        return try await getAuthCodeFromResume(resumePath: resumePath)
    }

    private func getAuthCodeFromResume(resumePath: String) async throws -> String {
        let resumeURL = URL(string: "https://\(Porsche.authServer)\(resumePath)")!
        let (_, resumeResponse) = try await session.data(for: authRequest(url: resumeURL))

        guard let httpResumeResponse = resumeResponse as? HTTPURLResponse,
              httpResumeResponse.statusCode == 302,
              let resumeLocation = httpResumeResponse.value(forHTTPHeaderField: "Location"),
              let code = extractQueryParam("code", from: resumeLocation) else {
            throw PorscheConnectError.noAuthCode
        }
        return code
    }

    // MARK: - Identifier First Login

    private func loginWithIdentifier(state: String, captchaCode: String?) async throws -> String {
        // Step 1: Submit email (and captcha if retrying)
        var body: [String: Any] = [
            "state": state,
            "username": email,
            "js-available": true,
            "webauthn-available": false,
            "is-brave": false,
            "webauthn-platform-available": false,
            "action": "default",
        ]
        if let captchaCode {
            body["captcha"] = captchaCode
        }

        let identifierURL = URL(string: "https://\(Porsche.authServer)/u/login/identifier?state=\(state)")!
        let (identifierData, identifierResponse) = try await session.data(
            for: authFormRequest(url: identifierURL, body: body)
        )

        let identifierStatus = (identifierResponse as? HTTPURLResponse)?.statusCode ?? 0

        if identifierStatus == 401 {
            throw PorscheConnectError.wrongCredentials
        }

        if identifierStatus == 400 {
            let html = String(data: identifierData, encoding: .utf8) ?? ""
            if let captchaImage = extractCaptchaImage(from: html) {
                throw PorscheConnectError.captchaRequired(PorscheCaptcha(image: captchaImage, state: state))
            }
            throw PorscheConnectError.authFailed("400 from identifier endpoint but no captcha found")
        }

        // Step 2: Submit password
        let passwordBody: [String: Any] = [
            "state": state,
            "username": email,
            "password": password,
            "action": "default",
        ]

        let passwordURL = URL(string: "https://\(Porsche.authServer)/u/login/password?state=\(state)")!
        let (_, passwordResponse) = try await session.data(
            for: authFormRequest(url: passwordURL, body: passwordBody)
        )

        let passwordStatus = (passwordResponse as? HTTPURLResponse)?.statusCode ?? 0

        if passwordStatus == 400 {
            throw PorscheConnectError.wrongCredentials
        }

        guard let passwordLocation = (passwordResponse as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Location") else {
            throw PorscheConnectError.authFailed("No redirect after password submission")
        }

        try await Task.sleep(nanoseconds: Porsche.authPropagationDelay)

        return passwordLocation
    }

    // MARK: - Token Exchange & Refresh

    private func exchangeCodeForToken(_ code: String) async throws -> PorscheToken {
        let body = [
            "client_id": Porsche.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Porsche.redirectURI,
        ]

        var request = URLRequest(url: URL(string: Porsche.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Porsche.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Porsche.xClientID, forHTTPHeaderField: "X-Client-ID")
        request.httpBody = urlEncode(body).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw PorscheConnectError.authFailed("Token exchange failed with HTTP \(status)")
        }

        return try JSONDecoder().decode(PorscheToken.self, from: data)
    }

    private func refreshAccessToken(_ refreshToken: String) async throws -> PorscheToken {
        let body = [
            "client_id": Porsche.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]

        var request = URLRequest(url: URL(string: Porsche.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Porsche.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Porsche.xClientID, forHTTPHeaderField: "X-Client-ID")
        request.httpBody = urlEncode(body).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 403 {
            throw PorscheConnectError.tokenRefreshFailed
        }
        guard (200...299).contains(status) else {
            throw PorscheConnectError.authFailed("Token refresh failed with HTTP \(status)")
        }

        return try JSONDecoder().decode(PorscheToken.self, from: data)
    }

    // MARK: - Captcha Extraction

    /// Extract a captcha image from Auth0's HTML response.
    /// Tries three strategies: ACUL base64 context, `<img>` tag, SVG data URI.
    func extractCaptchaImage(from html: String) -> String? {
        // Method 1: Auth0 ACUL context — atob("base64...") → JSON → screen.captcha.image
        if let match = html.range(of: #"atob\("([A-Za-z0-9+/=]+)""#, options: .regularExpression) {
            let base64Start = html.index(match.lowerBound, offsetBy: 6)
            let base64End = html.index(match.upperBound, offsetBy: -1)
            let base64Str = String(html[base64Start..<base64End])
            if let decoded = Data(base64Encoded: base64Str),
               let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
               let screen = json["screen"] as? [String: Any],
               let captcha = screen["captcha"] as? [String: Any],
               let image = captcha["image"] as? String {
                return image
            }
        }

        // Method 2: <img alt="captcha" src="...">
        if let match = html.range(of: #"<img[^>]*alt="captcha"[^>]*src="([^"]*)"#, options: .regularExpression) {
            let srcStart = html.range(of: #"src=""#, options: .literal, range: match)!.upperBound
            let srcEnd = html[srcStart...].firstIndex(of: "\"") ?? srcStart
            return String(html[srcStart..<srcEnd])
        }

        // Method 3: data:image/svg... URI
        if let match = html.range(of: #"(data:image/svg[^ ]+)"#, options: .regularExpression) {
            return String(html[match])
        }

        return nil
    }

    /// Extract a query parameter from a URL string.
    func extractQueryParam(_ name: String, from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString) else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    // MARK: - HTTP Helpers

    private func authRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Porsche.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Porsche.xClientID, forHTTPHeaderField: "X-Client-ID")
        return request
    }

    private func authFormRequest(url: URL, body: [String: Any]) -> URLRequest {
        var request = authRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlEncode(body).data(using: .utf8)
        return request
    }

    private func buildURL(_ base: String, params: [String: String]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private func urlEncode(_ params: [String: Any]) -> String {
        params.map { key, value in
            let v = "\(value)"
            let escaped = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(key)=\(escaped)"
        }.joined(separator: "&")
    }
}

// MARK: - Redirect Blocker

/// URLSession delegate that prevents automatic redirect following.
/// The OAuth2 flow requires reading `Location` headers from 302 responses.
private class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
