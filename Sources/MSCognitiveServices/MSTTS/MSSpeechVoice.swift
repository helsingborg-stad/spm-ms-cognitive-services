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
    func capitalizingFirstLetter() -> String {
        return prefix(1).capitalized + dropFirst()
    }
    func deCapitalizingFirstLetter() -> String {
        return prefix(1).lowercased() + dropFirst()
    }
    mutating func capitalizeFirstLetter() {
        self = self.capitalizingFirstLetter()
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

internal struct MSSpeechVoice: Codable, Equatable {
    typealias MSLanguage = String
    typealias MSSpeechVoicesResult = [MSLanguage: [VoiceType: [MSSpeechVoice]]]
    enum MSVoiceError: Error {
        case urlParse
        case missingAuthenticationToken
        case missingAPIKey
        case missingRegion
        case missingContent
    }
    enum VoiceType: String, Codable {
        case standard
        case neural
    }
    enum VoiceStyle: String, Codable {
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
    var id: String {
        return shortName
    }
    var name: String
    var displayName: String
    var localName: String
    var shortName: String
    var gender: TTSGender
    var locale: String
    var language: String
    var sampleRateHertz: String
    var voiceType: VoiceType
    var status: String
    var styleList: [String]
    var rolePlayList: [String]

    init(from decoder: Decoder) throws {
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
    var outputFormat: SPXSpeechSynthesisOutputFormat {
        if sampleRateHertz == "24000" {
            return SPXSpeechSynthesisOutputFormat.riff24Khz16BitMonoPcm
        }
        return SPXSpeechSynthesisOutputFormat.riff16Khz16BitMonoPcm
    }
    static private var sub: AnyCancellable?
    static var voices = MSSpeechVoicesResult()
    static func getVoices(using config: MSTTS.Config, _ completionHandler: @escaping (Error?) -> Void) {
        if !voices.isEmpty {
            completionHandler(MSVoiceError.missingContent)
            return
        }
        let a = MSCognitiveAuthenticator(key: config.key, region: config.region)
        sub = a.getToken().sink { completion in
            switch completion {
            case .failure(let error): completionHandler(error)
            case .finished: break
            }
        } receiveValue: { token in
            guard let endpoint = URL(string: "https://\(config.region).tts.speech.microsoft.com/cognitiveservices/voices/list") else {
                return
            }
            var request = URLRequest(url: endpoint)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpMethod = "GET"
            URLSession.shared.dataTask(with: request) { (data, _, error) in
                DispatchQueue.main.async {
                    guard let data = data else {
                        completionHandler(error ?? MSVoiceError.missingContent)
                        return
                    }
                    let d = JSONDecoder()
                    d.keyDecodingStrategy = JSONDecoder.camelCapsToCamelCaseStrategy
                    do {
                        let voices = try d.decode([MSSpeechVoice].self, from: data)
                        var res = MSSpeechVoicesResult()
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
                        self.voices = res
                        completionHandler(nil)
                    } catch {
                        completionHandler(error)
                    }
                }
            }.resume()
        }
    }
    static func bestvoice(for locale: Locale, with gender: TTSGender) -> MSSpeechVoice? {
        let code = locale.languageCode ?? locale.identifier
        guard let voices = voices[code] else {
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
}
