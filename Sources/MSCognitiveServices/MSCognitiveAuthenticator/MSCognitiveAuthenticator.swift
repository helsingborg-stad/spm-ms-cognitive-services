import Foundation
import Combine

// https://www.microsoft.com/en-us/translator/business/translator-api/
// https://firebase.google.com/docs/ml-kit/ios/translate-text
// https://www.microsoft.com/en-us/translator/business/languages/

/// Describes failures occuring in the `MSCognitiveAuthenticator`
public enum MSCognitiveAuthenticatorError: Error {
    case missingAPIKey
    case missingRegion
    case unableToParseIssueToken
}

/// Used to issue tokens used to communicate with microsoft cognitive services.
public final class MSCognitiveAuthenticator {
    /// Token lifetime
    private let tokenRefreshDuration: TimeInterval = 8 * 60
    /// Token age
    private var tokenAge = Date()
    /// Access key
    private let key: String
    /// Service region
    private let region: String
    /// Instantiates a new `MSCognitiveAuthenticator`
    /// - Parameters:
    ///   - key: access key
    ///   - region: service region
    public init(key: String, region: String) {
        self.key = key
        self.region = region
    }
    /// Currently valid token
    private(set) var token: String? {
        didSet {
            tokenAge = Date().addingTimeInterval(tokenRefreshDuration)
        }
    }
    /// Fetches access tokens from service backend unless a valid token is already available.
    /// - Returns: completion publisher
    public final func getToken() -> AnyPublisher<String,Error> {
        if let token = self.token, tokenAge > Date() {
            return CurrentValueSubject(token).eraseToAnyPublisher()
        }
        guard let endpoint = URL(string: "https://\(region).api.cognitive.microsoft.com/sts/v1.0/issueToken") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var request = URLRequest(url: endpoint)
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        request.httpMethod = "POST"
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { (data: Data, response: URLResponse) -> String in
                guard let t = String(data: data, encoding: .utf8) else {
                    throw MSCognitiveAuthenticatorError.unableToParseIssueToken
                }
                self.token = t
                return t
            }
            .eraseToAnyPublisher()
    }
}
