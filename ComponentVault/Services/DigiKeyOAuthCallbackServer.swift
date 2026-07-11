import Foundation
import Network
import Security

enum DigiKeyOAuthCallbackServer {
    enum CallbackError: LocalizedError {
        case invalidCallbackURL
        case listenerFailed(String)
        case timeout
        case missingCertificate

        var errorDescription: String? {
            switch self {
            case .invalidCallbackURL: "callback_url non valido (serve porta esplicita)."
            case .listenerFailed(let detail): "Server OAuth non avviato: \(detail)"
            case .timeout: "Timeout OAuth: riprova o incolla il code manualmente."
            case .missingCertificate: "Certificato TLS localhost mancante nel bundle."
            }
        }
    }

    struct CallbackEndpoint: Sendable {
        let port: UInt16
        let usesTLS: Bool
        let expectedPath: String
    }

    static func endpoint(from callbackURL: String) -> CallbackEndpoint? {
        guard let url = URL(string: callbackURL), let port = url.port else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let usesTLS = url.scheme?.lowercased() == "https"
        return CallbackEndpoint(port: UInt16(port), usesTLS: usesTLS, expectedPath: path)
    }

    static func captureAuthorizationCode(
        callbackURL: String,
        onListenerReady: @escaping @Sendable () -> Void,
        timeout: TimeInterval = 90
    ) async throws -> String {
        guard let endpoint = endpoint(from: callbackURL) else {
            throw CallbackError.invalidCallbackURL
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let queue = DispatchQueue(label: "DigiKeyOAuthCallbackServer")
            let lock = NSLock()
            var completed = false
            var timeoutTask: DispatchWorkItem?
            var listener: NWListener?

            func finish(_ result: Result<String, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !completed else { return }
                completed = true

                timeoutTask?.cancel()
                listener?.cancel()
                listener = nil

                DispatchQueue.main.async {
                    switch result {
                    case .success(let code):
                        continuation.resume(returning: code)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }

            let parameters: NWParameters
            do {
                if endpoint.usesTLS {
                    guard let identity = try loadLocalhostIdentity() else {
                        finish(.failure(CallbackError.missingCertificate))
                        return
                    }
                    let tlsOptions = NWProtocolTLS.Options()
                    sec_protocol_options_set_local_identity(
                        tlsOptions.securityProtocolOptions,
                        sec_identity_create(identity)!
                    )
                    parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
                } else {
                    parameters = NWParameters.tcp
                }
            } catch {
                finish(.failure(error))
                return
            }

            parameters.allowLocalEndpointReuse = true
            parameters.acceptLocalOnly = true

            guard let nwPort = NWEndpoint.Port(rawValue: endpoint.port) else {
                finish(.failure(CallbackError.invalidCallbackURL))
                return
            }

            do {
                listener = try NWListener(using: parameters, on: nwPort)
            } catch {
                finish(.failure(CallbackError.listenerFailed(error.localizedDescription)))
                return
            }

            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        onListenerReady()
                    }
                case .failed(let error):
                    finish(.failure(CallbackError.listenerFailed(error.localizedDescription)))
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    defer { connection.cancel() }

                    guard let data,
                          let request = String(data: data, encoding: .utf8),
                          let requestLine = request.split(separator: "\r\n").first else {
                        sendHTTPResponse(connection, status: "400 Bad Request", body: "Bad request")
                        return
                    }

                    let parts = requestLine.split(separator: " ")
                    guard parts.count >= 2 else {
                        sendHTTPResponse(connection, status: "400 Bad Request", body: "Bad request")
                        return
                    }

                    let target = String(parts[1])
                    let split = target.split(separator: "?", maxSplits: 1)
                    let requestPath = String(split.first ?? "")
                    let query = split.count > 1 ? String(split[1]) : ""

                    guard pathsMatch(requestPath, expected: endpoint.expectedPath) else {
                        sendHTTPResponse(connection, status: "404 Not Found", body: "Percorso non valido")
                        return
                    }

                    if let code = authorizationCode(from: query), !code.isEmpty {
                        let body = """
                        <!DOCTYPE html>
                        <html><head><meta charset="utf-8"><title>ComponentVault</title></head>
                        <body style="font-family: -apple-system; padding: 2rem;">
                        <h2>Autenticazione DigiKey completata</h2>
                        <p>Puoi chiudere questa scheda e tornare a ComponentVault.</p>
                        </body></html>
                        """
                        sendHTTPResponse(connection, status: "200 OK", body: body)
                        finish(.success(code))
                    } else {
                        let body = """
                        <!DOCTYPE html>
                        <html><head><meta charset="utf-8"><title>ComponentVault</title></head>
                        <body style="font-family: -apple-system; padding: 2rem;">
                        <h2>ComponentVault — server OAuth attivo</h2>
                        <p>Completa il login su DigiKey; questa pagina si aggiornerà automaticamente.</p>
                        </body></html>
                        """
                        sendHTTPResponse(connection, status: "200 OK", body: body)
                    }
                }
            }

            listener?.start(queue: queue)

            timeoutTask = DispatchWorkItem {
                finish(.failure(CallbackError.timeout))
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutTask!)
        }
    }

    private static func pathsMatch(_ requestPath: String, expected: String) -> Bool {
        let normalizedRequest = requestPath.hasSuffix("/") && requestPath.count > 1
            ? String(requestPath.dropLast())
            : requestPath
        let normalizedExpected = expected.hasSuffix("/") && expected.count > 1
            ? String(expected.dropLast())
            : expected
        return normalizedRequest == normalizedExpected
    }

    private static func authorizationCode(from query: String) -> String? {
        for item in query.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0] == "code" {
                return String(pair[1]).removingPercentEncoding ?? String(pair[1])
            }
        }
        return nil
    }

    private static func sendHTTPResponse(_ connection: NWConnection, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in }
        )
    }

    private static func loadLocalhostIdentity() throws -> SecIdentity? {
        guard let url = Bundle.main.url(
            forResource: "localhost",
            withExtension: "p12",
            subdirectory: "DigiKeyOAuth"
        ) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let options = [kSecImportExportPassphrase as String: "componentvault"] as CFDictionary
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let identityRef = array.first?[kSecImportItemIdentity as String] else {
            return nil
        }
        // kSecImportItemIdentity restituisce SecIdentity come tipo tollerato.
        return unsafeBitCast(identityRef, to: SecIdentity.self)
    }
}
