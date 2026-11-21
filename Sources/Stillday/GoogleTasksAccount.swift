import AuthenticationServices
import CalendarCore
import CalendarData
import Foundation
import SwiftUI

@MainActor @Observable
final class GoogleTasksAccount {
    let id: String
    let client: GoogleTasksClient?
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var error: String?
    private(set) var revision = 0
    private(set) var lastRefreshed: Date?
    private var refreshRequest: UUID?
    var isRefreshing: Bool { refreshRequest != nil }
    private var window: DateInterval?
    private var loadedZone: TimeZone?
    private var loadedRevision: Int?
    private var deadlines: [GoogleTaskDeadline] = []
    @ObservationIgnored private var refreshToken: String?
    @ObservationIgnored private var access: (token: GoogleTasksClient.Token, expiresAt: Date)?

    init(id: String, bundle: Bundle = .main) {
        self.id = id
        client = GoogleTasksClient(clientID: bundle.object(forInfoDictionaryKey: "StilldayGoogleTasksClientID") as? String,
                                   connectionID: id == GoogleTaskConnection.primary.id ? nil : id)
        refreshToken = client?.storedRefreshToken()
        isConnected = refreshToken != nil
    }

    func deadlines(in window: DateInterval, timeZone: TimeZone) -> [GoogleTaskDeadline] {
        guard isConnected, loadedZone == timeZone else { return [] }
        return deadlines.filter { window.start <= $0.day && $0.day < window.end }
    }

    func connect(using browser: WebAuthenticationSession) async {
        guard let client, !isConnecting else { return }
        isConnecting = true
        error = nil
        defer { isConnecting = false }

        do {
            let authorization = try client.authorize()
            let callback: URL
            if #available(iOS 17.4, macOS 14.4, *) {
                callback = try await browser.authenticate(using: authorization.url, callback: .customScheme(client.callbackScheme),
                                                          additionalHeaderFields: [:])
            } else {
                callback = try await browser.authenticate(using: authorization.url, callbackURLScheme: client.callbackScheme)
            }
            let token = try await client.exchange(callback, authorization: authorization)
            guard let refresh = token.refresh_token else { throw GoogleTasksClient.Failure.signIn }
            try client.saveRefreshToken(refresh)
            refreshToken = refresh
            remember(token)
            deadlines = []
            window = nil
            lastRefreshed = nil
            isConnected = true
            invalidate()
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return
        } catch let failure as GoogleTasksClient.Failure {
            error = failure.localizedDescription
        } catch {
            self.error = GoogleTasksClient.Failure.signIn.localizedDescription
        }
    }

    @discardableResult func disconnect() -> Bool {
        do {
            try client?.removeRefreshToken()
            refreshToken = nil
            access = nil
            deadlines = []
            window = nil
            lastRefreshed = nil
            error = nil
            isConnected = false
            invalidate()
            return true
        } catch {
            self.error = GoogleTasksClient.Failure.secureStorage.localizedDescription
            return false
        }
    }

    func invalidate() { revision += 1 }

    func load(in range: DateInterval, required: DateInterval, timeZone: TimeZone, force: Bool = false) async {
        guard let client, let refresh = refreshToken else { return }
        let loadingRevision = revision
        if !force, loadedRevision == loadingRevision, loadedZone == timeZone, let window,
           window.start <= required.start, required.end <= window.end { return }
        let request = UUID()
        refreshRequest = request
        defer { if refreshRequest == request { refreshRequest = nil } }
        do {
            let token: GoogleTasksClient.Token
            if let access, access.expiresAt > .now {
                token = access.token
            } else {
                token = try await client.refresh(using: refresh)
                try Task.checkCancellation()
                guard refresh == refreshToken, refreshRequest == request else { return }
                remember(token)
            }
            let items = try await client.deadlines(token: token, in: range, timeZone: timeZone)
            try Task.checkCancellation()
            guard refresh == refreshToken, revision == loadingRevision, refreshRequest == request else { return }
            deadlines = items
            window = range
            loadedZone = timeZone
            loadedRevision = loadingRevision
            lastRefreshed = .now
            error = nil
        } catch {
            guard !Task.isCancelled, refresh == refreshToken, revision == loadingRevision,
                  refreshRequest == request else { return }
            if (error as? GoogleTasksClient.Failure) == .sessionExpired { access = nil }
            self.error = (error as? GoogleTasksClient.Failure ?? .request).localizedDescription
        }
    }

    private func remember(_ token: GoogleTasksClient.Token) {
        access = (token, Date().addingTimeInterval(max(0, token.lifetime - 60)))
    }
}
