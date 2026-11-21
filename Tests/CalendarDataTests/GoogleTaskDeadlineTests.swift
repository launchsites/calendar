@testable import CalendarData
import Foundation
import Testing

struct GoogleTaskDeadlineTests {
    @Test func scheduledDatesStayOnTheSameCalendarDayInAnyZone() throws {
        for id in ["America/Los_Angeles", "Europe/Lisbon", "Pacific/Auckland"] {
            let zone = try #require(TimeZone(identifier: id))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let due = try #require(GoogleTaskDeadline.dueDay("2026-11-10T00:00:00.000Z", in: zone))
            #expect(calendar.dateComponents([.year, .month, .day], from: due) == DateComponents(year: 2026, month: 11, day: 10))
            #expect(GoogleTaskDeadline.dueDay("2026-02-30T00:00:00Z", in: zone) == nil)
        }
    }

    @Test func authorizationRequiresStateAndUsesReadOnlyScope() async throws {
        let client = try #require(GoogleTasksClient(clientID: "example.apps.googleusercontent.com"))
        let request = try client.authorize()
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.host == "accounts.google.com")
        #expect(components.queryItems?.first(where: { $0.name == "scope" })?.value == "https://www.googleapis.com/auth/tasks.readonly")
        #expect(components.queryItems?.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        let callback = try #require(URL(string: "\(client.callbackScheme):/oauth2redirect?state=wrong&code=example"))
        await #expect(throws: GoogleTasksClient.Failure.signIn) {
            try await client.exchange(callback, authorization: request)
        }
    }

    @Test func completedTaskRetainsItsScheduledDateAndConnection() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TaskFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try #require(GoogleTasksClient(clientID: "example.apps.googleusercontent.com",
                                                    connectionID: "fixture", session: session))
        let scheduled = try #require(GoogleTaskDeadline.dueDay("2026-11-10T00:00:00Z", in: .gmt))
        let window = DateInterval(start: scheduled, duration: 86_400)
        let token = GoogleTasksClient.Token(access_token: "fixture", refresh_token: nil, expires_in: 3600)
        let items = try await client.deadlines(token: token, in: window, timeZone: .gmt)
        let completed = try #require(items.first { $0.title == "Completed fixture" })
        #expect(completed.id.connectionID == "fixture")
        #expect(completed.day == scheduled)
        #expect(completed.isCompleted)
        #expect(completed.completedAt == scheduled.addingTimeInterval(15 * 3600 + 0.125))
        #expect(items.first { $0.title == "Open fixture" }?.isCompleted == false)
    }
}

private final class TaskFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let payload: String
        let status: Int
        if url.path.hasSuffix("/users/@me/lists") {
            payload = #"{"items":[{"id":"list","title":"Fixtures"}]}"#
            status = 200
        } else {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            status = query.contains(.init(name: "showCompleted", value: "true"))
                && query.contains(.init(name: "showHidden", value: "true")) ? 200 : 400
            payload = """
                {"items":[
                  {"id":"a","title":"Completed fixture","due":"2026-11-10T00:00:00Z",
                   "status":"completed","completed":"2026-11-10T15:00:00.125Z"},
                  {"id":"b","title":"Open fixture","due":"2026-11-10T00:00:00Z","status":"needsAction"}
                ]}
                """
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
