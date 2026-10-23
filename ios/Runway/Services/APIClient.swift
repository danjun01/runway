import Foundation

enum APIError: LocalizedError {
    case server(String)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .server(let message): message
        case .unreachable: "Can't reach the Runway server. Check that the backend is running and the server URL in Settings is right."
        }
    }
}

/// Talks to the Runway backend, which holds the Plaid and Claude API keys.
struct APIClient {
    static let serverURLDefaultsKey = "serverURL"

    /// Settings override first, then the build setting baked into Info.plist.
    static var baseURL: URL {
        let override = UserDefaults.standard.string(forKey: serverURLDefaultsKey) ?? ""
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: "RunwayAPIBaseURL") as? String ?? ""
        let raw = !override.isEmpty ? override : (!fromPlist.isEmpty ? fromPlist : "http://localhost:8787")
        return URL(string: raw) ?? URL(string: "http://localhost:8787")!
    }

    /// A random id per install. It scopes data on the server; it is not real auth.
    static var userId: String {
        let key = "runwayUserId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: Self.baseURL.appending(path: path))
        req.httpMethod = method
        req.setValue(Self.userId, forHTTPHeaderField: "X-Runway-User")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.timeoutInterval = 60
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.unreachable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.server(message ?? "The server returned an error.")
        }
        return data
    }

    func linkToken() async throws -> String {
        let data = try await send(request("api/link-token", method: "POST", body: Data("{}".utf8)))
        return try JSONDecoder().decode([String: String].self, from: data)["linkToken"] ?? ""
    }

    func exchange(publicToken: String, institutionName: String) async throws {
        let body = try JSONEncoder().encode(["publicToken": publicToken, "institutionName": institutionName])
        _ = try await send(request("api/exchange", method: "POST", body: body))
    }

    func snapshot() async throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: try await send(request("api/snapshot")))
    }

    func unlink(itemId: String) async throws {
        _ = try await send(request("api/items/\(itemId)", method: "DELETE"))
    }

    private struct ChatBody: Encodable {
        struct Message: Encodable { var role: String; var content: String }
        var messages: [Message]
        var context: ChatContext
    }

    private struct ChatEvent: Decodable {
        var type: String
        var text: String?
        var message: String?
    }

    /// Streams Claude's reply as text chunks.
    func chat(messages: [ChatMessage], context: ChatContext) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try JSONEncoder().encode(ChatBody(
                        messages: messages.filter { !$0.isError }.map { .init(role: $0.role.rawValue, content: $0.content) },
                        context: context
                    ))
                    var req = request("api/chat", method: "POST", body: body)
                    req.timeoutInterval = 180
                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await URLSession.shared.bytes(for: req)
                    } catch {
                        throw APIError.unreachable
                    }
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw APIError.server("The server couldn't start a chat.")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let event = try JSONDecoder().decode(ChatEvent.self, from: Data(line.dropFirst(6).utf8))
                        switch event.type {
                        case "text": continuation.yield(event.text ?? "")
                        case "error": throw APIError.server(event.message ?? "Something went wrong.")
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
