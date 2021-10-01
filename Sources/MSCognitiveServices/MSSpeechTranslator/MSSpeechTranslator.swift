//
//  MSSpeechTranslator.swift
//  speechtranslator
//
//  Created by Tomas Green on 2021-03-19.
//

import Foundation
import Combine
import Shout
import FFTPublisher
import AVFoundation
import MicrosoftCognitiveServicesSpeech
import AudioSwitchboard

public class MSSpeechTranslator: ObservableObject {
    public struct Config {
        public let key: String
        public let region: String
        public init(key: String, region: String) {
            self.key = key
            self.region = region
        }
    }
    public struct Result {
        public struct Value {
            public var locale: Locale
            public var text: String
        }
        public var translation: Value
        public var transcript: Value
    }
    public typealias TranslationEvent = PassthroughSubject<Result, Never>
    public typealias StatusEvent = PassthroughSubject<Void, Never>

    public let finished: TranslationEvent = .init()
    public let intermediateResult: TranslationEvent = .init()
    public let started: StatusEvent = .init()
    public let stopped: StatusEvent = .init()

    public var contextualStrings: [String] = [] {
        didSet {
            updateContextualStrings()
        }
    }
    private var config: Config
    private var recognizer: SPXTranslationRecognizer?
    private var phraseListGrammar: SPXPhraseListGrammar?
    private var logger = Shout("MSSpeechTranslator")
    private var mic:MicrophoneListener

    public weak var fft: FFTPublisher? {
        didSet {
            mic.fft = fft
        }
    }
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var translationLanguage: Locale
    @Published public private(set) var spokenLanguage: Locale

    public init(config: Config, audioSwitchboard:AudioSwitchboard, spokenLanguage: Locale = Locale(identifier: "sv_SE"), translationLanguage: Locale = Locale(identifier: "en_US")) {
        self.config = config
        self.mic = MicrophoneListener(audioSwitchboard)
        self.translationLanguage = translationLanguage
        self.spokenLanguage = spokenLanguage
        self.prepare()
    }
    func updateContextualStrings() {
        guard let recognizer = recognizer else {
            return
        }
        guard let phraseListGrammar = SPXPhraseListGrammar(recognizer: recognizer) else {
            return
        }
        for string in contextualStrings {
            phraseListGrammar.addPhrase(string)
        }
        self.phraseListGrammar = phraseListGrammar
    }
    public func stop() {
        isRecording = false
        mic.stop()
        guard let r = recognizer else {
            return
        }
        self.phraseListGrammar = nil
        self.recognizer = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try r.stopContinuousRecognition()
            } catch {
                self.logger.error(error)
            }
        }
    }
    public func start() {
        self.isRecording = true
        mic.start()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if self?.recognizer == nil {
                self?.prepare()
            }
            guard let recognizer = self?.recognizer else {
                self?.logger.error("failure")
                return
            }
            do {
                try recognizer.startContinuousRecognition()
            } catch {
                self?.logger.error(error)
                DispatchQueue.main.async {
                    self?.isRecording = false
                }
            }
        }
    }
    public func set(spokenLanguage: Locale, translationLanguage: Locale) {
        guard self.spokenLanguage != spokenLanguage || self.translationLanguage != translationLanguage else {
            return
        }
        self.stop()
        self.spokenLanguage = spokenLanguage
        self.translationLanguage = translationLanguage
        self.prepare()
    }
    private func createResult(from result: SPXTranslationRecognitionResult) -> Result {
        let target = translationLanguage
        let source = spokenLanguage
        let code = target.languageCode ?? target.identifier
        let translation = Result.Value(locale: target, text: (result.translations[code] as? String) ?? "")
        let transcript = Result.Value(locale: source, text: result.text ?? "")
        return Result(translation: translation, transcript: transcript)
    }
    private func prepare() {
        do {
            let target = translationLanguage
            let source = spokenLanguage
            let translationConfig = try SPXSpeechTranslationConfiguration(subscription: config.key, region: config.region)
            translationConfig.addTargetLanguage(target.identifier.replacingOccurrences(of: "_", with: "-"))
            translationConfig.speechRecognitionLanguage = source.identifier.replacingOccurrences(of: "_", with: "-")
            translationConfig.enableDictation()

            let audioConfig = SPXAudioConfiguration()
            let reco = try SPXTranslationRecognizer(speechTranslationConfiguration: translationConfig, audioConfiguration: audioConfig)

            reco.addRecognizingEventHandler { [weak self] (_, e) in
                self?.logger.info("recognized")
                guard let res = self?.createResult(from: e.result) else {
                    return
                }
                DispatchQueue.main.async {
                    self?.intermediateResult.send(res)
                }
            }
            reco.addSessionStartedEventHandler { [weak self] (_, _) in
                self?.logger.info("started")
                DispatchQueue.main.async {
                    self?.started.send()
                }
            }
            reco.addCanceledEventHandler { [weak self] (_, _) in
                self?.logger.info("cancelled")
            }
            reco.addSessionStoppedEventHandler { [weak self] (_, _) in
                self?.logger.info("stopped")
                DispatchQueue.main.async {
                    self?.stopped.send()
                }
            }
            reco.addRecognizedEventHandler { [weak self] (_, e) in
                self?.logger.info("finished session")
                guard let res = self?.createResult(from: e.result) else {
                    return
                }
                DispatchQueue.main.async {
                    self?.finished.send(res)
                }
            }
            self.recognizer = reco
            self.updateContextualStrings()
        } catch {
            self.phraseListGrammar = nil
            self.recognizer = nil
            logger.error(error)
        }
    }
}
