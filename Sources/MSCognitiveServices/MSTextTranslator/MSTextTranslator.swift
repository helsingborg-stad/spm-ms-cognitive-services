import Foundation
import Combine
import Shout
import TextTranslator

// https://docs.microsoft.com/en-us/azure/cognitive-services/translator/request-limits
let maxChars = 9999
let maxStrings = 99
let charsPerMinute = 30000
var totalChars = 0

private func reduce(_ texts: inout [String], _ res: [String] = [], _ count: Int = 0) throws -> ([String], Int) {
    guard texts.isEmpty == false, let string = texts.first else {
        return (res, count)
    }
    let numChars = string.count
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
    case urlParse
    case missingAuthenticator
    case missingAPIKey
    case missingToken
    case unableToParseIssueToken
    case unableToTranslate
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
    var strings: [String] {
        return translations.compactMap { (translation) -> String in
            return translation.text
        }
    }
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
        return Fail(error: MSTranslatorError.urlParse).eraseToAnyPublisher()
    }
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
        return Fail(error: MSTranslatorError.urlParse).eraseToAnyPublisher()
    }
    components.queryItems = [
        URLQueryItem(name: "api-version", value: "3.0"),
        URLQueryItem(name: "to", value: to.joined(separator: ",")),
        URLQueryItem(name: "from", value: from),
        URLQueryItem(name: "textType", value: "html")
    ]
    guard let url = components.url else {
        return Fail(error: MSTranslatorError.urlParse).eraseToAnyPublisher()
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
private var cancellables = Set<AnyCancellable>()

func add(_ cancellable:AnyCancellable?) {
    guard let cancellable = cancellable else {
        return
    }
    cancellables.insert(cancellable)
}
func remove(_ cancellable:AnyCancellable?) {
    guard let cancellable = cancellable else {
        return
    }
    cancellables.remove(cancellable)
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
                    getTranslations(token: token, texts: texts, from: from, to: [to])
                }
                .sink { completion in
                    switch completion {
                    case .failure(let error): completionSubject.send(completion: .failure(error))
                    case .finished: break;
                    }
                    remove(c)
                } receiveValue: { results in
                    translated.append(contentsOf: results)
                    fetch()
                    remove(c)
                }
                add(c)
            } catch {
                completionSubject.send(completion: .failure(error))
                return
            }
        }
        fetch()
        return completionSubject.eraseToAnyPublisher()
    }
//    private func translate(texts: [String], from: LanguageKey, to: [LanguageKey]) -> AnyPublisher<[MSTranslationResult],Error> {
//        let completionSubject = PassthroughSubject<[MSTranslationResult],Error>()
//        var untranslated = texts
//        var translated = [MSTranslationResult]()
//        func fetch(texts: [String], languages: [LanguageKey], numchars: Int) {
//            guard let authenticator = authenticator else {
//                completionSubject.send(completion: .failure(MSTranslatorError.missingAuthenticator))
//                return
//            }
//            var languages = languages
//            var langs = [LanguageKey]()
//            for lang in languages {
//                if numchars * (1 + langs.count) >= (maxChars/(1 + langs.count)) {
//                    break
//                }
//                langs.append(lang)
//            }
//            /// if langs is empty it means that the translations for all languages are completed.
//            guard !langs.isEmpty else {
//                fetch()
//                return
//            }
//            // any language not translated is going to be on the next iteration
//            languages.removeAll { langs.contains($0) }
//
//            var c:AnyCancellable?
//            c = authenticator.getToken().flatMap { token in
//                getTranslations(token: token, texts: texts, from: from, to: langs)
//            }
//            .sink { [weak self] completion in
//                switch completion {
//                case .failure(let error): completionSubject.send(completion: .failure(error))
//                case .finished: break;
//                }
//                if let c = c {
//                    self?.fetches.remove(c)
//                }
//            } receiveValue: { [weak self] results in
//                translated.append(contentsOf: results)
//                fetch(texts: texts, languages: languages, numchars: numchars)
//                if let c = c {
//                    self?.fetches.remove(c)
//                }
//            }
//            if let c = c {
//                fetches.insert(c)
//            }
//        }
//        func fetch() {
//            do {
//                if untranslated.isEmpty {
//                    completionSubject.send(translated)
//                    return
//                }
//                let (res, numchars) = try reduce(&untranslated)
//                var c = 0
//                res.forEach { s in
//                    c += s.count
//                }
//                if res.isEmpty {
//                    completionSubject.send(translated)
//                    return
//                }
//                fetch(texts: res, languages: to, numchars: numchars)
//            } catch {
//                completionSubject.send(completion: .failure(error))
//                return
//            }
//        }
//        fetch()
//        return completionSubject.eraseToAnyPublisher()
//    }
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
        return self.translate(texts: untranslated, from: from, to: to).map { results -> TextTranslationTable in
            for res in results {
                guard let key = keys[res.text] else {
                    continue
                }
                table.updateTranslations(forKey:key, from: from, to: [to], using: res)
            }
            return table
        }.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
    final public func translate(_ texts: [TranslationKey : String], from: LanguageKey, to: [LanguageKey], storeIn table: TextTranslationTable) -> FinishedPublisher {
        let completionSubject = FinishedSubject()
        var to = to
        to.removeAll { $0 == from }
        if to.isEmpty {
            logger.info("No strings required translation (0 languages to translate into)")
            return CurrentValueSubject(table).receive(on: DispatchQueue.main).eraseToAnyPublisher()
        }
        func translate(in language:LanguageKey, storeIn table:TextTranslationTable) {
            var c:AnyCancellable?
            c = self.translate(texts, from: from, to: language, storeIn: table).sink { compl in
                switch compl {
                case .failure(let error): completionSubject.send(completion: .failure(error))
                case .finished: break;
                }
                remove(c)
            } receiveValue: { table in
                guard let lang = to.first else {
                    completionSubject.send(table)
                    return
                }
                to.removeFirst()
                translate(in: lang, storeIn: table)
                remove(c)
            }
            add(c)
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
