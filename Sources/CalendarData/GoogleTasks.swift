import CalendarCore
import CryptoKit
import Foundation
import Security

public struct GoogleTaskDeadline: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        public let connectionID: String
        let listID: String
        let taskID: String
    }

    public let id: ID
    public let title: String
    public let list: String
    public let day: Date
    public let isCompleted: Bool
    public let completedAt: Date?

    /// The API's timestamp encodes a Gregorian date, independent of the local time zone.
    public static func dueDay(_ timestamp: String, in zone: TimeZone) -> Date? {
        let pieces = timestamp.prefix(10).split(separator: "-")
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let expected = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: expected),
              calendar.dateComponents([.year, .month, .day], from: date) == expected else { return nil }
        return calendar.startOfDay(for: date)
    }
}

public struct GoogleTasksClient: Sendable {
    public struct Authorization: Sendable {
        public let url: URL
        let state: String
        let verifier: String
    }

    public struct Token: Decodable, Sendable {
        let access_token: String
        public let refresh_token: String?
        let expires_in: TimeInterval

        public var lifetime: TimeInterval { expires_in }
    }

    public enum Failure: LocalizedError, Equatable, Sendable {
        case signIn, sessionExpired, request, secureStorage

        public var errorDescription: String? {
            switch self {
            case .signIn: "Google Tasks sign-in couldn’t finish."
            case .sessionExpired: "Reconnect Google Tasks to renew access."
            case .request: "Google Tasks couldn’t refresh. Try again when connected."
            case .secureStorage: "The Google Tasks connection couldn’t be accessed in Keychain."
            }
        }
    }

    private struct TaskList: Decodable {
        let id: String
        let title: String
    }

    private struct RemoteTask: Decodable {
        let id: String
        let title: String
        let due: String?
        let status: String?
        let completed: String?
    }

    private struct Page<Item: Decodable>: Decodable {
        let items: [Item]?
        let nextPageToken: String?
    }

    private static let scope = "https://www.googleapis.com/auth/tasks.readonly"
    private let clientID: String
    private let connectionID: String?
    private let session: URLSession
    public let callbackScheme: String

    public init?(clientID: String?, connectionID: String? = nil,
                 session: URLSession = URLSession(configuration: .ephemeral)) {
        guard let clientID, clientID.hasSuffix(".apps.googleusercontent.com"),
              !clientID.contains(where: \.isWhitespace) else { return nil }
        self.clientID = clientID
        self.connectionID = connectionID
        self.session = session
        callbackScheme = clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    private var redirect: String { "\(callbackScheme):/oauth2redirect" }

    public func authorize() throws -> Authorization {
        let verifier = try Self.randomToken()
        let state = try Self.randomToken()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
        ]
        guard let url = components.url else { throw Failure.signIn }
        return Authorization(url: url, state: state, verifier: verifier)
    }

    public func exchange(_ callback: URL, authorization: Authorization) async throws -> Token {
        let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let values = components?.queryItems ?? []
        guard components?.scheme?.lowercased() == callbackScheme.lowercased(),
              components?.path == "/oauth2redirect",
              values.first(where: { $0.name == "state" })?.value == authorization.state,
              let code = values.first(where: { $0.name == "code" })?.value else { throw Failure.signIn }
        return try await token(fields: [
            "grant_type": "authorization_code", "code": code, "code_verifier": authorization.verifier, "redirect_uri": redirect,
        ])
    }

    public func refresh(using refreshToken: String) async throws -> Token {
        try await token(fields: ["grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    public func deadlines(token: Token, in window: DateInterval, timeZone: TimeZone) async throws -> [GoogleTaskDeadline] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let filter = [
            URLQueryItem(name: "dueMin", value: formatter.string(from: window.start) + "T00:00:00Z"),
            URLQueryItem(name: "dueMax", value: formatter.string(from: window.end) + "T00:00:00Z"),
            URLQueryItem(name: "showCompleted", value: "true"),
            URLQueryItem(name: "showHidden", value: "true"),
            URLQueryItem(name: "showAssigned", value: "true"),
            URLQueryItem(name: "maxResults", value: "100"),
        ]
        let lists: [TaskList] = try await pages(path: "/users/@me/lists", query: [.init(name: "maxResults", value: "100")], token: token)
        let completionFormatter = ISO8601DateFormatter()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions.insert(.withFractionalSeconds)
        var deadlines: [GoogleTaskDeadline] = []
        for list in lists {
            let escaped = list.id.addingPercentEncoding(withAllowedCharacters: Self.formCharacters) ?? ""
            let tasks: [RemoteTask] = try await pages(path: "/lists/\(escaped)/tasks", query: filter, token: token)
            for task in tasks {
                guard let due = task.due, let day = GoogleTaskDeadline.dueDay(due, in: timeZone),
                      window.start <= day, day < window.end else { continue }
                deadlines.append(GoogleTaskDeadline(
                    id: .init(connectionID: connectionID ?? GoogleTaskConnection.primary.id,
                              listID: list.id, taskID: task.id),
                    title: task.title, list: list.title, day: day,
                    isCompleted: task.status == "completed" || task.completed != nil,
                    completedAt: task.completed.flatMap { fractionalFormatter.date(from: $0) ?? completionFormatter.date(from: $0) }
                ))
            }
        }
        return deadlines.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    public func storedRefreshToken() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveRefreshToken(_ refreshToken: String) throws {
        let query = keychainQuery
        let value = [kSecValueData as String: Data(refreshToken.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.secureStorage }
    }

    public func removeRefreshToken() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.secureStorage }
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.example.stillday.google-tasks",
         kSecAttrAccount as String: connectionID.map { "\(clientID):\($0)" } ?? clientID,
         kSecUseDataProtectionKeychain as String: true]
    }

    private static let formCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private func token(fields: [String: String]) async throws -> Token {
        let fields = fields.merging(["client_id": clientID]) { first, _ in first }
        let body = fields.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: Self.formCharacters) ?? "")
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 400, fields["grant_type"] == "refresh_token" {
            struct TokenError: Decodable { let error: String }
            if (try? JSONDecoder().decode(TokenError.self, from: data).error) == "invalid_grant" { throw Failure.sessionExpired }
        }
        guard status == 200 else { throw Failure.request }
        return try JSONDecoder().decode(Token.self, from: data)
    }

    private func pages<Item: Decodable>(path: String, query: [URLQueryItem], token: Token) async throws -> [Item] {
        var result: [Item] = []
        var cursor: String?
        var usedCursors: Set<String> = []
        repeat {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://tasks.googleapis.com")!
            url.percentEncodedPath = "/tasks/v1" + path
            url.queryItems = query + (cursor.map { [.init(name: "pageToken", value: $0)] } ?? [])
            guard let endpoint = url.url else { throw Failure.request }
            var request = URLRequest(url: endpoint, timeoutInterval: 25)
            request.setValue("Bearer \(token.access_token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 401 { throw Failure.sessionExpired }
            guard status == 200 else { throw Failure.request }
            let page = try JSONDecoder().decode(Page<Item>.self, from: data)
            result.append(contentsOf: page.items ?? [])
            cursor = page.nextPageToken
            if let cursor, !usedCursors.insert(cursor).inserted { throw Failure.request }
        } while cursor != nil
        return result
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.signIn }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
