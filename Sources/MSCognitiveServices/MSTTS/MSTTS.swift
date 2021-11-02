//
//  MSSpeech.swift
//  LaibanApp-iOS
//
//  Created by Tomas Green on 2020-09-28.
//  Copyright © 2020 Helsingborg Kommun. All rights reserved.
//

import AVFoundation
import Combine
import UIKit
import TTS
import Shout
import FFTPublisher
import AudioSwitchboard
// https://github.com/Azure-Samples/cognitive-services-speech-sdk/issues/102
public enum MSTTSError : Error {
    case unsupportedVoiceProperties
    case missingConfig
    case serviceUnavailable
}

public class MSTTS: TTSService, MSSpeechSynthesizerDelegate, ObservableObject {
    public struct Config : Equatable {
        public let key: String
        public let region: String
        public init(key: String, region: String) {
            self.key = key
            self.region = region
        }
    }
    private let cancelledSubject: TTSStatusSubject = .init()
    private let finishedSubject: TTSStatusSubject = .init()
    private let startedSubject: TTSStatusSubject = .init()
    private let speakingWordSubject: TTSWordBoundarySubject = .init()
    private let failureSubject: TTSFailedSubject = .init()
    private let voicesSubject = PassthroughSubject<MSSpeechVoice.Directory,Error>()
    private var cancellables = Set<AnyCancellable>()
    private var synthesizer: MSSpeechSynthesizer
    private var audioAvailable:Bool = true {
        didSet {
            updateAvailable()
        }
    }
    
    public var cancelledPublisher: TTSStatusPublisher  { cancelledSubject.eraseToAnyPublisher() }
    public var finishedPublisher: TTSStatusPublisher { finishedSubject.eraseToAnyPublisher() }
    public var startedPublisher: TTSStatusPublisher { startedSubject.eraseToAnyPublisher() }
    public var speakingWordPublisher: TTSWordBoundaryPublisher { speakingWordSubject.eraseToAnyPublisher() }
    public var failurePublisher: TTSFailedPublisher { failureSubject.eraseToAnyPublisher() }
    
    public let id: TTSServiceIdentifier = "MSTTS"
    @Published public private(set) var available:Bool = false
    @Published public private(set) var voices = MSSpeechVoice.Directory() {
        didSet {
            updateAvailable()
        }
    }
    
    public var pronunciations = [MSPronunciation]() {
        didSet {
            self.synthesizer.pronunciations = pronunciations
        }
    }
    /// Updates the voices if config changes. Will remove voices if new value is nil
    public var config:Config? {
        set {
            var old = synthesizer.config
            synthesizer.config = newValue
            if newValue == nil {
                voices = .init()
            } else if newValue != old {
                updateVoices()
            }
            updateAvailable()
        }
        get { return synthesizer.config }
    }
    public weak var fft: FFTPublisher? {
        didSet {
            synthesizer.audioPlayer.fft = fft
        }
    }
    public init(config: Config?, audioSwitchboard:AudioSwitchboard, fft: FFTPublisher? = nil) {
        self.synthesizer = MSSpeechSynthesizer(config,audioSwitchboard: audioSwitchboard)
        synthesizer.audioPlayer.fft = fft
        synthesizer.delegate = self
        updateVoices()
        self.audioAvailable = audioSwitchboard.availableServices.contains(.play)
        
        audioSwitchboard.$availableServices.sink { [weak self] services in
            if services.contains(.play) == false {
                self?.stop()
                self?.audioAvailable = false
            } else {
                self?.audioAvailable = true
            }
        }.store(in: &cancellables)
    }
    public final func pause() {
        synthesizer.pause()
    }
    public final func `continue`() {
        synthesizer.continue()
    }
    public func stop() {
        synthesizer.stopSpeaking()
    }
    public func start(utterance: TTSUtterance) {
        if available == false {
            failureSubject.send(TTSFailure(utterance: utterance, error: MSTTSError.serviceUnavailable))
            return
        }
        guard let voice = MSSpeechVoice.bestvoice(in: voices, for: utterance.voice.locale, with: utterance.voice.gender) else {
            failureSubject.send(TTSFailure(utterance: utterance, error: MSTTSError.unsupportedVoiceProperties))
            return
        }
        synthesizer.speak(utterance, using: voice)
    }
    
    // MARK: MSSpeechSynthesizerDelegate
    internal func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, preparing utterance: TTSUtterance) {

    }
    internal func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, didStart utterance: TTSUtterance) {
        startedSubject.send(utterance)
    }
    internal func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, didCancel utterance: TTSUtterance) {
        cancelledSubject.send(utterance)
    }
    internal func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, didFinish utterance: TTSUtterance) {
        finishedSubject.send(utterance)
    }
    internal func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, didFail utterance: TTSUtterance, with error: Error) {
        failureSubject.send(TTSFailure(utterance: utterance, error: error))
    }
    internal func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, willSpeak word: String, at range: Range<String.Index>, utterance: TTSUtterance) {
        speakingWordSubject.send(TTSWordBoundary(utterance: utterance, wordBoundary: TTSUtteranceWordBoundary(string: word, range: range)))
    }
    /// Checks whether or not there is support for perticular locale (and gender)
    /// - Parameters:
    ///   - locale: the locale to check for
    ///   - gender: the gender (optional
    /// - Returns: true if there is support, false if not
    /// - Note: Returns false if unavailable
    public func hasSupportFor(locale: Locale, gender: TTSGender?) -> Bool {
        if available == false {
            return false
        }
        if let gender = gender, gender != .other {
            return MSSpeechVoice.hasSupport(for: locale, in: voices, gender: gender)
        }
        return MSSpeechVoice.hasSupport(for: locale, in: voices)
    }
    /// Fetches voices using the current config and assigns voices to instance
    /// - Returns: completion publisher
    public func updateVoicesPublisher() -> AnyPublisher<MSSpeechVoice.Directory,Error> {
        guard let config = config else {
            return Fail(error: MSTTSError.missingConfig).eraseToAnyPublisher()
        }
        return MSSpeechVoice.publisher(using: config).receive(on: DispatchQueue.main).map({ [weak self] res -> MSSpeechVoice.Directory in
            self?.voices = res
            return res
        }).eraseToAnyPublisher()
    }
    private func updateVoices() {
        var p:AnyCancellable?
        p = self.updateVoicesPublisher().replaceError(with: [:]).sink { [weak self] _ in
            if let p = p {
                self?.cancellables.remove(p)
            }
        }
        if let p = p {
            cancellables.insert(p)
        }
    }
    private func updateAvailable() {
       available = config != nil && audioAvailable && voices.isEmpty == false
    }
}
