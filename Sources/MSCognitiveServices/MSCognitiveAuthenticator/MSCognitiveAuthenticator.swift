import Foundation
import Combine

// https://www.microsoft.com/en-us/translator/business/translator-api/
// https://firebase.google.com/docs/ml-kit/ios/translate-text
// https://www.microsoft.com/en-us/translator/business/languages/

public enum MSCognitiveAuthenticatorError: Error {
    case urlParse
    case missingAPIKey
    case missingRegion
    case unableToParseIssueToken
}

public final class MSCognitiveAuthenticator {
    private let tokenRefreshDuration: TimeInterval = 8 * 60
    private var tokenAge = Date()
    private let key: String
    private let region: String
    public init(key: String, region: String) {
        self.key = key
        self.region = region
    }
    private(set) var token: String? {
        didSet {
            tokenAge = Date().addingTimeInterval(tokenRefreshDuration)
        }
    }
    public final func getToken() -> AnyPublisher<String,Error> {
        if let token = self.token, tokenAge > Date() {
            return CurrentValueSubject(token).eraseToAnyPublisher()
        }
        guard let endpoint = URL(string: "https://\(region).api.cognitive.microsoft.com/sts/v1.0/issueToken") else {
            return Fail(error: MSCognitiveAuthenticatorError.urlParse).eraseToAnyPublisher()
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
