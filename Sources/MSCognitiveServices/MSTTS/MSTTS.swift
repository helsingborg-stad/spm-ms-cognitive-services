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

/// Errors caused by failrues in MSTTS
public enum MSTTSError : Error {
    case unsupportedVoiceProperties
    case missingConfig
    case serviceUnavailable
}
/// Status object used to indicate the status of MSTTS Voice fetches
public enum MSTTSFetchVoiceStatus {
    /// No status
    case none
    /// Completed
    case finished
    /// Failed with error
    case failed(Error)
}
/// MSSTS is a concrete implementation of the `TTSService` protocol. The class uses the MicrosoftCognitiveServicesSpeech framework to synthesize speech from text.
public class MSTTS: TTSService, MSSpeechSynthesizerDelegate, ObservableObject {
    /// The confiuratio needed to connect to microsft backend
    public struct Config : Equatable {
        /// The access key
        public let key: String
        /// The region of the service
        public let region: String
        /// Initializes a new confiuration
        /// - Parameters:
        ///   - key: The access key
        ///   - region: The region of the service
        public init(key: String, region: String) {
            self.key = key
            self.region = region
        }
    }
    /// Subject used when cancelling
    private let cancelledSubject: TTSStatusSubject = .init()
    /// Subject used when playback finishes
    private let finishedSubject: TTSStatusSubject = .init()
    /// Subject used when playback is started
    private let startedSubject: TTSStatusSubject = .init()
    /// Subject used when a word boundary is triggered
    private let speakingWordSubject: TTSWordBoundarySubject = .init()
    /// Subject used to trigger failures
    private let failureSubject: TTSFailedSubject = .init()
    /// Cancellables store
    private var cancellables = Set<AnyCancellable>()
    /// The synthesizer used to create and play audio
    private var synthesizer: MSSpeechSynthesizer
    /// Indicates whether or not audio can be played
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
    
    /// Indicates the current voice fetch status
    @Published public var fetchVoicesStatus:MSTTSFetchVoiceStatus = .none
    
    /// The id of the service
    public let id: TTSServiceIdentifier = "MSTTS"
    /// Indicates whether or not the service is available for use
    @Published public private(set) var available:Bool = false
    /// The available list of voices
    @Published public private(set) var voices = MSSpeechVoice.Directory() {
        didSet {
            updateAvailable()
        }
    }
    
    /// Pronounciations to be used when sytnhesizing
    public var pronunciations = [MSPronunciation]() {
        didSet {
            self.synthesizer.pronunciations = pronunciations
        }
    }
    /// Current configuration
    /// Updates the voices if config changes. Will remove voices if new value is nil
    public var config:Config? {
        set {
            let old = synthesizer.config
            synthesizer.config = newValue
            if newValue == nil {
                fetchVoicesStatus = .none
                voices = .init()
            } else if newValue != old {
                updateVoices()
            }
            updateAvailable()
        }
        get { return synthesizer.config }
    }
    /// Instance used for visualizing audio
    public weak var fft: FFTPublisher? {
        didSet {
            synthesizer.audioPlayer.fft = fft
        }
    }
    /// Initializes a new MSTTS object
    /// - Parameters:
    ///   - config: configuration to be used when fetching voices and syntheizing audio
    ///   - audioSwitchboard: the swiftboard used when playing audio
    ///   - fft: Instance used for visualizing audio
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
    /// Pause playback
    public final func pause() {
        synthesizer.pause()
    }
    /// Continue playback
    public final func `continue`() {
        synthesizer.continue()
    }
    /// Stop playback
    public func stop() {
        synthesizer.stopSpeaking()
    }
    /// Start playback of utterance
    /// - Parameter utterance: the utterance to play
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
    
    /// Update list of available voices
    private func updateVoices() {
        guard let config = config else {
            return
        }
        var p:AnyCancellable?
        p = MSSpeechVoice.publisher(using: config).receive(on: DispatchQueue.main).sink { [weak self] compl in
            switch compl {
            case .failure(let error): self?.fetchVoicesStatus = .failed(error)
            case .finished: break;
            }
            if let p = p {
                self?.cancellables.remove(p)
            }
        } receiveValue: { [weak self]  dir in
            self?.voices = dir
            self?.fetchVoicesStatus = .finished
            if let p = p {
                self?.cancellables.remove(p)
            }
        }
        if let p = p {
            cancellables.insert(p)
        }
    }
    /// Updates the available property
    private func updateAvailable() {
       available = config != nil && audioAvailable && voices.isEmpty == false
    }
}
