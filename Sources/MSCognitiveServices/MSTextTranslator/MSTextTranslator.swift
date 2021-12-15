import Foundation
import Combine
import Shout
import TextTranslator

// https://docs.microsoft.com/en-us/azure/cognitive-services/translator/request-limits
let maxChars = 9999
let maxStrings = 99

/// Used to store cancellables
private var cancellables = Set<AnyCancellable?>()
private func reduce(_ texts: inout [String], _ res: [String] = [], _ count: Int = 0) throws -> ([String], Int) {
    guard texts.isEmpty == false, let string = texts.first else {
        return (res, count)
    }
    // utf16 count is neded for some emojis. 
    let numChars = string.utf16.count
    if res.count == 0, numChars > maxChars {
        throw MSTranslatorError.maximumNumberOfCharsExceeded
    }
    if res.count + 1 >= maxStrings {
        return (res, count)
    }
    if numChars + count > maxChars {
        return (res, count)
    }
    var r = [string]
    r.append(contentsOf: res)
    texts.removeFirst()
    return try reduce(&texts, r, count + numChars)
}
struct MSTranslationResult: Codable {
    var text: String
    var translations: [LanguageKey: TranslatedValue]
}
public enum MSTranslatorError: Error {
    case missingAuthenticator
    case resultCountMissmatch
    case resultMissing
    case maximumNumberOfCharsExceeded
}
public struct MSTranslatorBackendError: Error {
    var code:Int
    var message:String
    init(dict:[String:Any]) {
        code = dict["code"] as? Int ?? -1
        message = dict["message"] as? String ?? "unkown error"
    }
}
struct MSRequest: Codable {
    let text: String
}
struct MSResult: Codable {
    struct Translation: Codable {
        let text: String
        let to: String
    }
    var translations: [Translation]
}
private extension TextTranslationTable {
    mutating func updateTranslations(forKey key:String, from: LanguageKey, to: [LanguageKey], using result:MSTranslationResult) {
        self.set(value: result.text, for: key, in: from)
        for (langKey, value) in result.translations {
            self.set(value: value, for: key, in: langKey)
            for l in to {
                guard let t = l.split(separator: "-").first else {
                    continue
                }
                let lang = String(t)
                if langKey == lang {
                    self.set(value: value, for: key, in: l)
                }
            }
        }
    }
}
func convertVariables(string:String,find:String,replaceWith:String) -> String {
    let regex = try! NSRegularExpression(pattern: find, options: NSRegularExpression.Options.caseInsensitive)
    let range = NSMakeRange(0, string.count)
    return regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: replaceWith)
}
private func getTranslations(token: String, texts: [String], from: LanguageKey, to: [LanguageKey]) -> AnyPublisher<[MSTranslationResult],Error> {
    guard let endpoint = URL(string: "https://api-eur.cognitive.microsofttranslator.com/translate") else {
        return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
    }
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
        return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
    }
    components.queryItems = [
        URLQueryItem(name: "api-version", value: "3.0"),
        URLQueryItem(name: "to", value: to.joined(separator: ",")),
        URLQueryItem(name: "from", value: from),
        URLQueryItem(name: "textType", value: "html")
    ]
    guard let url = components.url else {
        return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
    }
    var request: URLRequest
    request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
    request.httpMethod = "POST"
    do {
        request.httpBody = try JSONEncoder().encode(texts.map(MSRequest.init))
    } catch {
        return Fail(error: error).eraseToAnyPublisher()
    }
    return URLSession.shared.dataTaskPublisher(for: request)
        .tryMap {
            let json = try JSONSerialization.jsonObject(with: $0.data, options: []) as? [String: Any]
            if let error = json?["error"] as? [String: AnyHashable] {
                throw MSTranslatorBackendError(dict: error)
            }
            return $0.data
        }
        .decode(type: [MSResult].self, decoder: JSONDecoder())
        .tryMap { results in
            var final = [MSTranslationResult]()
            if results.count != texts.count {
                throw MSTranslatorError.resultCountMissmatch
            }
            for (index, value) in texts.enumerated() {
                var dict = [String: String]()
                for translation in results[index].translations {
                    dict[translation.to] = convertVariables(string: translation.text, find: "<span translate='no'>string</span>", replaceWith: "%@")
                }
                final.append(MSTranslationResult(text: convertVariables(string: value, find: "<span translate='no'>string</span>", replaceWith: "%@"), translations: dict))
            }
            return final
        }
        .eraseToAnyPublisher()
}

public final class MSTextTranslator: TextTranslationService, ObservableObject {
    public struct Config: Equatable {
        var key: String
        var region: String
        public init(key: String, region: String) {
            self.key = key
            self.region = region
        }
    }
    private var authenticator: MSCognitiveAuthenticator?
    public var logger = Shout("MSTranslator")
    public var config:Config? {
        didSet {
            if config == oldValue {
                return
            }
            guard let config = config else {
                self.authenticator = nil
                return
            }
            self.authenticator = MSCognitiveAuthenticator(key: config.key, region: config.region)
        }
    }
    public init(config: Config? = nil) {
        if let config = config {
            self.authenticator = MSCognitiveAuthenticator(key: config.key, region: config.region)
        }
    }
    private func translate(texts: [String], from: LanguageKey, to: LanguageKey) -> AnyPublisher<[MSTranslationResult],Error> {
        let completionSubject = PassthroughSubject<[MSTranslationResult],Error>()
        var untranslated = texts
        var translated = [MSTranslationResult]()
        func fetch() {
            do {
                if untranslated.isEmpty {
                    completionSubject.send(translated)
                    return
                }
                let (res, _) = try reduce(&untranslated)
                if res.isEmpty {
                    completionSubject.send(translated)
                    return
                }
                guard let authenticator = authenticator else {
                    completionSubject.send(completion: .failure(MSTranslatorError.missingAuthenticator))
                    return
                }
                var c:AnyCancellable?
                c = authenticator.getToken().flatMap { token in
                    getTranslations(token: token, texts: res, from: from, to: [to])
                }
                .sink { [weak self] completion in
                    switch completion {
                    case .failure(let error):
                        self?.logger.error(error)
                        completionSubject.send(completion: .failure(error))
                        self?.logger.error("Error while translating from \(from) to \(to)", texts)
                    case .finished: break;
                    }
                    cancellables.remove(c)
                } receiveValue: { results in
                    translated.append(contentsOf: results)
                    fetch()
                    cancellables.remove(c)
                }
                cancellables.insert(c)
            } catch {
                completionSubject.send(completion: .failure(error))
                return
            }
        }
        fetch()
        return completionSubject.eraseToAnyPublisher()
    }
    private func translate(_ texts: [TranslationKey : String], from: LanguageKey, to: LanguageKey, storeIn table: TextTranslationTable) -> FinishedPublisher {
        var table = table
        var untranslated = [String]()
        var keys = [String:String]()
        for (key,value) in texts {
            if !table.translationExists(forKey: key, in: to) {
                untranslated.append(convertVariables(string: value, find: "%@", replaceWith: "<span translate='no'>string</span>"))
                keys[value] = key
            }
        }
        if untranslated.isEmpty {
            logger.info("No strings required translation")
            return CurrentValueSubject(table).receive(on: DispatchQueue.main).eraseToAnyPublisher()
        }
        logger.info("\(untranslated.count) strings requires translation")
        return self.translate(texts: untranslated, from: from, to: to).map { [weak self] results -> TextTranslationTable in
            for res in results {
                guard let key = keys[res.text] else {
                    continue
                }
                self?.logger.info("adding translation for \(key) with result", res)
                table.updateTranslations(forKey:key, from: from, to: [to], using: res)
            }
            return table
        }.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
    final public func translate(_ texts: [TranslationKey : String], from: LanguageKey, to: [LanguageKey], storeIn table: TextTranslationTable) -> FinishedPublisher {
        let completionSubject = FinishedSubject()
        
        var to = to
        to.removeAll { $0 == from }
        let languages = to
        if to.isEmpty {
            logger.info("No strings required translation (0 languages to translate into)")
            return CurrentValueSubject(table).receive(on: DispatchQueue.main).eraseToAnyPublisher()
        }
        func translate(in language:LanguageKey, storeIn table:TextTranslationTable) {
            var c:AnyCancellable?
            c = self.translate(texts, from: from, to: language, storeIn: table).sink { [weak self] compl in
                switch compl {
                case .failure(let error):
                    completionSubject.send(completion: .failure(error))
                    self?.logger.error(error)
                case .finished: break;
                }
                cancellables.remove(c)
            } receiveValue: { [weak self] table in
                guard let lang = to.first else {
                    completionSubject.send(table)
                    self?.logger.info("Completed translations from \(from) to \(languages)")
                    return
                }
                to.removeFirst()
                translate(in: lang, storeIn: table)
                cancellables.remove(c)
            }
            cancellables.insert(c)
        }
        guard let lang = to.first else {
            return CurrentValueSubject(table).receive(on: DispatchQueue.main).eraseToAnyPublisher()
        }

        translate(in: lang, storeIn: table)
        return completionSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
    final public func translate(_ texts: [String], from: LanguageKey, to: [LanguageKey], storeIn table: TextTranslationTable) -> FinishedPublisher {
        var dict = [TranslationKey : String]()
        texts.forEach { s in
            dict[s] = s
        }
        return translate(dict, from: from, to: to, storeIn: table)
    }
    final public func translate(_ text: String, from: LanguageKey, to: LanguageKey) -> TranslatedPublisher {
        return translate(texts: [text], from: from, to: to).tryMap { results -> TranslatedString in
            for res in results  {
                for (langKey, value) in res.translations {
                    guard let t = to.split(separator: "-").first else {
                        continue
                    }
                    let lang = String(t)
                    if langKey == lang {
                        return TranslatedString(language: lang, key: res.text, value: value)
                    }
                }
            }
            throw MSTranslatorError.resultMissing
        }.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
}
