//
//  Locales.swift
//  TalkamaticSFI
//
//  Created by Tomas Green on 2022-01-12.
//
import Foundation
import Combine
import TextTranslator
import AsyncPublisher

/// Describes a language that can be translated with MSTextTranslator
public struct MSTextTranslationLanguage: Codable, Hashable, Equatable {
    private typealias Values = [String:[String:String]]
    /// The direction of a langauge, either ltr or rtl (no support for ttb or btt)
    public enum Direction: String, Codable, Hashable, Equatable {
        /// Left to right
        case leftToRight
        /// Right to left
        case rightToLeft
    }
    /// The key used when translating a text
    public let key:LanguageKey
    /// The name of the langauge in english
    public let name: String
    /// The name of the langauge in that language
    public let nativeName: String
    /// The langauge code
    public let code: String
    /// The language script (if any)
    public let script:String?
    /// The langauge direction
    public let direction:Direction
    /// The locale of the language, might indicate a country
    public var locale:Locale
    /// Initializes a new MSTextTranslationLanguage instance
    /// - Parameters:
    ///   - key: The key used when translating a text
    ///   - name: The name of the langauge in english
    ///   - nativeName: The name of the langauge in that language
    ///   - code: The langauge code
    ///   - script: The language script (if any)
    ///   - direction: The langauge direction
    ///   - locale: The locale of the language, might indicate a country
    public init(
        key:LanguageKey,
        name: String,
        nativeName: String,
        code: String,
        script:String? = nil,
        direction:Direction,
        locale:Locale
    ) {
        self.key = key
        self.name = name
        self.nativeName = nativeName
        self.code = code
        self.script = script
        self.direction = direction
        self.locale = locale
    }
    /// Fetch languages publisher
    /// - Parameters:
    ///   - continent: kontinent, like eur for europe. not sure if there's more than one
    ///   - version: default is 3.0
    /// - Returns: a fetch langauges publisher
    public static func fetchPublisher(continent:String? = "eur", version:String = "3.0") -> AnyPublisher<Set<Self>,Error> {
        let suffix = continent != nil ? "-\(continent!)" : ""
        guard let url = URL(string:"https://api\(suffix).cognitive.microsofttranslator.com/languages?api-version=\(version)") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        return URLSession.shared.dataTaskPublisher(for: url)
            .map { $0.data }
            .tryMap { data -> Set<Self> in
                let json = try JSONSerialization.jsonObject(with: data, options: [])
                guard let object = json as? [String: Any] else {
                    throw URLError(.badServerResponse)
                }
                guard let value = object["translation"] as? Values else {
                    throw URLError(.badServerResponse)
                }
                return convert(value)
            }.eraseToAnyPublisher()
    }
    /// Fetch languages
    /// - Parameters:
    ///   - continent: continent, like eur for europe. not sure if there's more than one
    ///   - version: default is 3.0
    /// - Returns: set of languages
    static public func fetch(continent:String? = "eur", version:String = "3.0") async throws -> Set<Self> {
        try await makeAsync(fetchPublisher(continent: continent, version: version))
    }
    /// Converts a dictionary to a set of languages
    /// - Parameter value: dictionary
    /// - Returns: set of languages
    static private func convert(_ value:Values) -> Set<Self> {
        var set = Set<Self>()
        for key in value.keys {
            let arr = key.split(separator: "-").map { String($0) }
            guard let code = arr.first else {
                continue
            }
            guard let obj = value[key] else {
                continue
            }
            guard let name = obj["name"] else {
                continue
            }
            guard let nativeName = obj["nativeName"] else {
                continue
            }
            guard let dir = obj["dir"] else {
                continue
            }
            let locale:Locale
            let script:String?
            let country:String?
            if arr.count > 1, let s = arr.last {
                if s.count == 2 {
                    script = nil
                    country = s
                } else if s.count > 2 {
                    script = s
                    country = nil
                } else {
                    script = nil
                    country = nil
                }
            } else {
                script = nil
                country = nil
            }
            if let c = country {
                locale = .init(identifier: "\(code)_\(c)")
            } else {
                /// Fixes microsofts wierd quirk with pt locales
                if code == "pt" && nativeName.contains("Brasil"){
                    locale = .init(identifier: "\(code)_BR")
                } else {
                    locale = .init(identifier: "\(code)")
                }
            }
            let d:Direction = dir == "ltr" ? .leftToRight : .rightToLeft
            
            set.insert(.init(
                key: key,
                name: name,
                nativeName: nativeName,
                code: code,
                script: script,
                direction: d,
                locale: locale
            ))
        }
        return set
    }
    /// Determines whether or not there is support for a specific locale
    /// - Parameters:
    ///   - locale: locale to search for
    ///   - exact: indicated wehether or not to match on the whole identifier, ie region and language, and not just language
    ///   - set: set to search
    /// - Returns: whether or not a langauge is available, either as exact match (language and region) or partial (language only)
    public static func hasSupport(for locale: Locale, exact:Bool = false, in set:Set<MSTextTranslationLanguage>) -> Bool {
        if exact {
            return set.contains { $0.locale.identifier == locale.identifier }
        }
        guard let code = locale.languageCode else {
            return false
        }
        return set.contains { $0.code == code }
    }
}
