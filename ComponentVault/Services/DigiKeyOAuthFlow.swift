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
    /// Redirect URI da registrare nel portale DigiKey per iPad/iOS.
    static let iosRedirectURI = "componentvault://digikey/callback"
    static let iosCallbackScheme = "componentvault"

    static func authorize(config: DigiKeyConfig) async throws -> String {
        var components = URLComponents(string: "\(config.apiBaseURL)/v1/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: iosRedirectURI),
        ]
        guard let authURL = components.url else {
            throw ProviderError.networkFailure("URL autorizzazione DigiKey non valido")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: iosCallbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL,
                      let code = DigiKeyAuthService.parseAuthorizationCode(from: callbackURL.absoluteString) else {
                    continuation.resume(throwing: ProviderError.networkFailure("Codice OAuth non ricevuto"))
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
