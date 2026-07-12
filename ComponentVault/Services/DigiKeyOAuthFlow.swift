import Foundation

#if canImport(AuthenticationServices) && canImport(UIKit)
import AuthenticationServices
import UIKit

@MainActor
private final class DigiKeyOAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DigiKeyOAuthPresenter()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        return scenes.first?.windows.first ?? ASPresentationAnchor()
    }
}

enum DigiKeyOAuthFlow {
    /// Schema interno catturato dall'app dopo il bridge HTTPS sul server.
    static let appCallbackScheme = "componentvault"

    static func authorize(config: DigiKeyConfig) async throws -> String {
        let redirectURI = config.iosOAuthRedirectURI
        var components = URLComponents(string: "\(config.apiBaseURL)/v1/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        guard let authURL = components.url else {
            throw ProviderError.networkFailure("URL autorizzazione DigiKey non valido")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: appCallbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL,
                      let code = DigiKeyAuthService.parseAuthorizationCode(from: callbackURL.absoluteString) else {
                    continuation.resume(throwing: ProviderError.networkFailure(
                        "Codice OAuth non ricevuto. Usa la connessione manuale e incolla l'URL dal browser."
                    ))
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = DigiKeyOAuthPresenter.shared
            session.prefersEphemeralWebBrowserSession = false
            guard session.start() else {
                continuation.resume(throwing: ProviderError.networkFailure("Impossibile avviare login DigiKey"))
                return
            }
        }
    }
}
#endif
