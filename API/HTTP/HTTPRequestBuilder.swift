import Foundation

/// The single, credential-safe URL and request construction boundary shared by
/// ordinary HTTP and streaming transports.
enum HTTPRequestBuilder {
    static func makeURL(endpoint: ServiceEndpoint, request: HTTPRequest) throws -> URL {
        let base = endpoint.baseURL
        guard let scheme = base.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = base.host, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil else {
            throw HTTPTransportError.invalidRequest("base URL must be an HTTP(S) URL without user info")
        }
        if scheme == "http" && !isLoopbackHost(host) {
            throw HTTPTransportError.invalidRequest("plaintext HTTP requires a loopback endpoint")
        }
        let path = request.relativePath
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("?"),
              !path.contains("#"), !path.contains("\\") else {
            throw HTTPTransportError.invalidRequest("relative path is not endpoint-safe")
        }
        guard let decoded = path.removingPercentEncoding else {
            throw HTTPTransportError.invalidRequest("relative path contains malformed escaping")
        }
        guard !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else {
            throw HTTPTransportError.invalidRequest("relative path contains traversal")
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let basePath = components?.percentEncodedPath ?? ""
        components?.percentEncodedPath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? path : (basePath.hasSuffix("/") ? basePath + String(path.dropFirst()) : basePath + path)
        components?.queryItems = request.queryItems.map { URLQueryItem(name: $0.name, value: $0.value) }
        guard let url = components?.url, url.host != nil else {
            throw HTTPTransportError.invalidRequest("could not construct request URL")
        }
        return url
    }

    static func makeRequest(connection: ServiceConnection, request: HTTPRequest, timeout: TimeInterval,
                            contentType: String? = nil, accept: String? = nil) async throws -> (URLRequest, URL) {
        let url = try makeURL(endpoint: connection.endpoint, request: request)
        var result = URLRequest(url: url)
        result.httpMethod = request.method.rawValue
        result.timeoutInterval = timeout
        result.httpBody = request.body
        if request.body != nil { result.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type") }
        if let accept { result.setValue(accept, forHTTPHeaderField: "Accept") }
        do {
            if let credential = try await connection.credentialCapability.credential(for: connection.connectionID) {
                let bytes = Data("\(credential.username):\(credential.password)".utf8).base64EncodedString()
                result.setValue("Basic \(bytes)", forHTTPHeaderField: "Authorization")
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw HTTPTransportError.credentialUnavailable }
        try Task.checkCancellation()
        return (result, url)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "localhost" || normalized == "::1" { return true }
        let octets = normalized.split(separator: ".")
        return octets.count == 4 && octets.first == "127" && octets.dropFirst().allSatisfy {
            guard let value = Int($0) else { return false }; return (0...255).contains(value)
        }
    }
}
