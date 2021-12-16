//
//  MSSpeechVoice.swift
//  speechtranslator
//
//  Created by Tomas Green on 2021-05-14.
//

import Foundation
import Combine
import AVFoundation
import TTS
import Shout
import MicrosoftCognitiveServicesSpeech

extension String {
    func deCapitalizingFirstLetter() -> String {
        return prefix(1).lowercased() + dropFirst()
    }
}
/// Extension of JSONDecoder used by voices api
extension JSONDecoder {
    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.intValue = intValue
            self.stringValue = String(intValue)
        }
    }
    /// Camel-Caps to Camel-Case decoding strategy
    static var camelCapsToCamelCaseStrategy = JSONDecoder.KeyDecodingStrategy.custom({ key -> CodingKey in
        let rawKey = key.last!.stringValue
        let camelCaseValue = rawKey.deCapitalizingFirstLetter()
        return JSONDecoder.AnyKey(stringValue: camelCaseValue)!
    })
}
/// Errors describing MSSpeechVoice failures
public enum MSSpeechVoiceError: Error {
    case missingContent
}
/// The MSSpeechVocie desbires voices available for playback using the Microsoft TTS
public struct MSSpeechVoice: Codable, Equatable {
    /// Description of Language from MS backend
    public typealias MSLanguage = String
    /// Dictionary of voices by language and type of voice
    public typealias Directory = [MSLanguage: [VoiceType: [MSSpeechVoice]]]
    
    /// Type of voice
    public enum VoiceType: String, Codable {
        /// Will be deprecated at some point since Microsoft is not longer training traditional voices
        case standard
        /// Neural, high quality machine learning enhanced voices
        case neural
    }
    /// The id of the voice
    public var id: String {
        return shortName
    }
    /// The name of the voice, unclear usecase
    public let name: String
    /// Name used for display
    public let displayName: String
    /// "Local name", unclear usecase
    public let localName: String
    /// Short name used when synthesizing text
    public let shortName: String
    /// The gender of the voice
    public let gender: TTSGender
    /// The locale of the voice
    public let locale: String
    /// The language of the voice
    public let language: String
    /// The available ample rate (max sample rate?)
    public let sampleRateHertz: String
    /// Type of voice
    public let voiceType: VoiceType
    /// Development status, like "preview"
    public let status: String
    /// Voice styles, like "calm" or "newscast"
    public let styleList: [String]
    /// Basically the age ot the voice
    public let rolePlayList: [String]
    
    /// Initializes a new voice from a decoder
    /// - Parameter decoder: the decoder
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try values.decode(String.self, forKey: .name)
        self.displayName = try values.decode(String.self, forKey: .displayName)
        self.localName = try values.decode(String.self, forKey: .localName)
        self.shortName = try values.decode(String.self, forKey: .shortName)
        let g = try values.decode(String.self, forKey: .gender)
        if g == "Female" {
            self.gender = .female
        } else {
            self.gender = .male
        }
        self.styleList = (try? values.decode([String].self, forKey: .styleList)) ?? []
        self.rolePlayList = (try? values.decode([String].self, forKey: .rolePlayList)) ?? []
        self.locale = try values.decode(String.self, forKey: .locale).replacingOccurrences(of: "-", with: "_")
        self.language = self.locale.split(separator: "_").dropLast().joined()
        self.sampleRateHertz = try values.decode(String.self, forKey: .sampleRateHertz)
        let v = try values.decode(String.self, forKey: .voiceType)
        if v == "Neural" {
            self.voiceType = .neural
        } else {
            self.voiceType = .standard
        }
        self.status = try values.decode(String.self, forKey: .status)
    }
    /// The output format of the voice, used by the `MSAudioBufferPlayer`
    public var outputFormat: SPXSpeechSynthesisOutputFormat {
        if sampleRateHertz == "24000" {
            return SPXSpeechSynthesisOutputFormat.riff24Khz16BitMonoPcm
        } else if sampleRateHertz == "16000" {
            return SPXSpeechSynthesisOutputFormat.riff16Khz16BitMonoPcm
        }
        return SPXSpeechSynthesisOutputFormat.riff8Khz16BitMonoPcm
    }
    /// Creates a publsiher for fetching voices from the microsoft backend
    /// - Parameters:
    ///   - token: the access token to be used
    ///   - region: the region to fetch from
    /// - Returns: a completion publisher
    public static func publisher(token:String, region:String) -> AnyPublisher<Directory,Error> {
        guard let endpoint = URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/voices/list") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        let d = JSONDecoder()
        d.keyDecodingStrategy = JSONDecoder.camelCapsToCamelCaseStrategy
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "GET"
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { $0.data }
            .decode(type: [MSSpeechVoice].self, decoder: d)
            .map { voices -> Directory in
                var res = Directory()
                for identifier in Locale.availableIdentifiers {
                    let lang = Locale(identifier: identifier)
                    guard let code = lang.languageCode else {
                        continue
                    }
                    let arr = voices.filter({ v in v.locale == lang.identifier || v.language == code })
                    var dict = [VoiceType: [MSSpeechVoice]]()
                    dict[.standard] = arr.filter({ v in (v.locale == lang.identifier || v.language == code) && v.voiceType == .standard })
                    dict[.neural] = arr.filter({ v in (v.locale == lang.identifier || v.language == code) && v.voiceType == .neural })
                    res[code] = dict
                }
                return res
            }.eraseToAnyPublisher()
    }
    /// Creates a publsiher for fetching voices from the microsoft backend
    /// - Parameter config: the configuration to be used when fetching vocies
    /// - Returns: a completion publisher
    public static func publisher(using config: MSTTS.Config) -> AnyPublisher<Directory,Error> {
        MSCognitiveAuthenticator(key: config.key, region: config.region).getToken().flatMap { token -> AnyPublisher<Directory,Error> in
            Self.publisher(token: token, region: config.region)
        }.eraseToAnyPublisher()
    }
    /// Returns the best avaiblable voice based on locale and gender
    /// - Parameters:
    ///   - dictionary: all availble voices to choose from
    ///   - locale: locale of the boice
    ///   - gender: gender of the voice
    /// - Returns: voice (if avaible) based on the locale and gender
    public static func bestvoice(in dictionary:Directory, for locale: Locale, with gender: TTSGender) -> MSSpeechVoice? {
        let code = locale.languageCode ?? locale.identifier
        guard let voices = dictionary[code] else {
            return nil
        }
        if locale.regionCode != nil {
            if let arr = voices[.neural], let v = arr.first(where: { v in v.gender == gender && v.locale == locale.identifier }) {
                return v
            } else if let arr = voices[.standard], let v = arr.first(where: { v in v.gender == gender && v.locale == locale.identifier }) {
                return v
            } else if let arr = voices[.neural], let v = arr.first(where: { v in v.locale == locale.identifier }) {
                return v
            } else if let arr = voices[.standard], let v = arr.first(where: { v in v.locale == locale.identifier }) {
                return v
            }
        }
        if let arr = voices[.neural], let v = arr.first(where: { v in v.gender == gender }) {
            return v
        } else if let arr = voices[.standard], let v = arr.first(where: { v in v.gender == gender }) {
            return v
        } else if let v = voices[.neural]?.first ?? voices[.standard]?.first {
            return v
        }
        return nil
    }
    /// Determines whether or not there is support for a specific locale and gender
    /// - Parameters:
    ///   - locale: locale to search for
    ///   - dictionary: dictionary to search
    ///   - gender: the gender of the voicie
    /// - Returns: whether or not a voice is available
    public static func hasSupport(for locale: Locale, in dictionary:Directory, gender:TTSGender) -> Bool {
        let code = locale.languageCode ?? locale.identifier
        guard let voices = dictionary[code] else {
            return false
        }
        if let arr = voices[.neural], arr.contains(where: { v in v.gender == gender }) {
            return true
        } else if let arr = voices[.standard], arr.contains(where: { v in v.gender == gender }) {
            return true
        }
        return false
    }
    /// Determines whether or not there is support for a specific locale
    /// - Parameters:
    ///   - locale: locale to search for
    ///   - dictionary: dictionary to search
    /// - Returns: whether or not a voice is available
    public static func hasSupport(for locale: Locale, in dictionary:Directory) -> Bool {
        let code = locale.languageCode ?? locale.identifier
        guard let voices = dictionary[code] else {
            return false
        }
       
        if let a = voices[.neural], a.count > 0 {
            return true
        } else if let a = voices[.standard], a.count > 0 {
            return true
        }
        return false
    }
}
