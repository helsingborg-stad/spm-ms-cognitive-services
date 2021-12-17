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

/// The MSSpeechTranslator is an abstraction layer for SPXTranslationRecognizer
public class MSSpeechTranslator: ObservableObject {
    /// Configuration used when communicating with backend
    public struct Config {
        /// Access key
        public let key: String
        /// Service region
        public let region: String
        /// Initializes a new config
        /// - Parameters:
        ///   - key: acess key
        ///   - region: service region
        public init(key: String, region: String) {
            self.key = key
            self.region = region
        }
    }
    /// Describes the end result of the processed speech including transcription and translation
    public struct Result {
        /// Resulting value
        public struct Value {
            /// The locale of the text
            public var locale: Locale
            /// The transcribed/translated value
            public var text: String
        }
        /// The translated result
        public var translation: Value
        /// The transcribed result
        public var transcript: Value
    }
    /// Translation event subject
    public typealias TranslationEvent = PassthroughSubject<Result, Never>
    /// Status event subject
    public typealias StatusEvent = PassthroughSubject<Void, Never>
    
    /// Triggers when a translation has completed
    public let finished: TranslationEvent = .init()
    /// Triggers whenever a preliminary result is returned from the server
    public let intermediateResult: TranslationEvent = .init()
    /// Triggeres When the service has started
    public let started: StatusEvent = .init()
    /// Triggeres When the service has ended
    public let stopped: StatusEvent = .init()
    
    /// Contextual strings used to improve speech recognition.
    /// - note: The strings must be in the language that is being recognized.
    public var contextualStrings: [String] = [] {
        didSet {
            updatePhraseListGrammar()
        }
    }
    /// Configuration used to communicate with backend
    private var config: Config
    /// The current recognizer used for speech recognition/speech translation
    private var recognizer: SPXTranslationRecognizer?
    /// Used together with the `contextualStrings` to improve speech recognition
    private var phraseListGrammar: SPXPhraseListGrammar?
    /// Loggning events
    private var logger = Shout("MSSpeechTranslator")
    /// Used to capture audio data and process it for the FFT
    private var mic:MicrophoneListener
    /// Used to publish audio data for a visual representation
    public weak var fft: FFTPublisher? {
        didSet {
            mic.fft = fft
        }
    }
    /// Indicates whether or not the speech translator is recording
    @Published public private(set) var isRecording: Bool = false
    /// Language used for translation
    @Published public private(set) var translationLanguage: Locale
    /// Language used for transcription
    @Published public private(set) var spokenLanguage: Locale
    
    /// Initializes a new instance
    /// - Parameters:
    ///   - config: Configuration used to communicate with backendt
    ///   - audioSwitchboard: Swiftboard used by the `MicrophoneListener` to claim and release recording ownership
    ///   - spokenLanguage: Language used for transcription
    ///   - translationLanguage: Language used for transcription
    public init(config: Config, audioSwitchboard:AudioSwitchboard, spokenLanguage: Locale = Locale(identifier: "sv_SE"), translationLanguage: Locale = Locale(identifier: "en_US")) {
        self.config = config
        self.mic = MicrophoneListener(audioSwitchboard)
        self.translationLanguage = translationLanguage
        self.spokenLanguage = spokenLanguage
        self.prepare()
    }
    /// Updates the `phraseListGrammar` property based on the avialable `contextualStrings`
    func updatePhraseListGrammar() {
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
    /// Stop the speech translation
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
    /// Start translating speech
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
    /// Updates the language properties and re initiates the service
    /// - Parameters:
    ///   - spokenLanguage: language used for transcription
    ///   - translationLanguage: language used for translation
    public func set(spokenLanguage: Locale, translationLanguage: Locale) {
        guard self.spokenLanguage != spokenLanguage || self.translationLanguage != translationLanguage else {
            return
        }
        self.stop()
        self.spokenLanguage = spokenLanguage
        self.translationLanguage = translationLanguage
        self.prepare()
    }
    /// Create a `Result` object based on a `SPXTranslationRecognitionResult`
    /// - Parameter result: result generated by the speech transaltor
    /// - Returns: result object
    private func createResult(from result: SPXTranslationRecognitionResult) -> Result {
        let target = translationLanguage
        let source = spokenLanguage
        let code = target.languageCode ?? target.identifier
        let translation = Result.Value(locale: target, text: (result.translations[code] as? String) ?? "")
        let transcript = Result.Value(locale: source, text: result.text ?? "")
        return Result(translation: translation, transcript: transcript)
    }
    /// Prepares the speech translator for recording
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
            self.updatePhraseListGrammar()
        } catch {
            self.phraseListGrammar = nil
            self.recognizer = nil
            logger.error(error)
        }
    }
}
