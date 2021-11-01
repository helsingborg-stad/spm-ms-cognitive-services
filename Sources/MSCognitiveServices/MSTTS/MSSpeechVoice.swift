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
    static var camelCapsToCamelCaseStrategy = JSONDecoder.KeyDecodingStrategy.custom({ key -> CodingKey in
        let rawKey = key.last!.stringValue
        let camelCaseValue = rawKey.deCapitalizingFirstLetter()
        return JSONDecoder.AnyKey(stringValue: camelCaseValue)!
    })
}
public enum MSSpeechVoiceError: Error {
    case missingContent
}
public struct MSSpeechVoice: Codable, Equatable {
    public typealias MSLanguage = String
    public typealias Directory = [MSLanguage: [VoiceType: [MSSpeechVoice]]]
    
    public enum VoiceType: String, Codable {
        case standard
        case neural
    }
    public enum VoiceStyle: String, Codable {
        case affectionate = "affectionate"
        case angry = "angry"
        case assistant = "assistant"
        case calm = "calm"
        case chat = "chat"
        case cheerful = "cheerful"
        case customerservice = "customerservice"
        case depressed = "depressed"
        case disgruntled = "disgruntled"
        case embarrassed = "embarrassed"
        case empathetic = "empathetic"
        case fearful = "fearful"
        case gentle = "gentle"
        case lyrical = "lyrical"
        case newscast = "newscast"
        case newscastCasual = "newscast-casual"
        case newscastFormal = "newscast-formal"
        case sad = "sad"
        case serious = "serious"
    }
    public var id: String {
        return shortName
    }
    public let name: String
    public let displayName: String
    public let localName: String
    public let shortName: String
    public let gender: TTSGender
    public let locale: String
    public let language: String
    public let sampleRateHertz: String
    public let voiceType: VoiceType
    public let status: String
    public let styleList: [String]
    public let rolePlayList: [String]

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
    public var outputFormat: SPXSpeechSynthesisOutputFormat {
        if sampleRateHertz == "24000" {
            return SPXSpeechSynthesisOutputFormat.riff24Khz16BitMonoPcm
        } else if sampleRateHertz == "16000" {
            return SPXSpeechSynthesisOutputFormat.riff16Khz16BitMonoPcm
        }
        return SPXSpeechSynthesisOutputFormat.riff8Khz16BitMonoPcm
    }
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
    public static func publisher(using config: MSTTS.Config) -> AnyPublisher<Directory,Error> {
        MSCognitiveAuthenticator(key: config.key, region: config.region).getToken().flatMap { token -> AnyPublisher<Directory,Error> in
            Self.publisher(token: token, region: config.region)
        }.eraseToAnyPublisher()
    }
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
