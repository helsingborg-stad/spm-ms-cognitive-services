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

public class MSTTS: TTSService, MSSpeechSynthesizerDelegate {
    public struct Config {
        public let key: String
        public let region: String
        public init(key: String, region: String) {
            self.key = key
            self.region = region
        }
    }
    public let id: TTSServiceIdentifier = "MSTTS"
    private let cancelledSubject: TTSStatusSubject = .init()
    private let finishedSubject: TTSStatusSubject = .init()
    private let startedSubject: TTSStatusSubject = .init()
    private let speakingWordSubject: TTSWordBoundarySubject = .init()
    private let failureSubject: TTSFailedSubject = .init()
    private var cancellables = Set<AnyCancellable>()
    
    public var cancelledPublisher: TTSStatusPublisher  { cancelledSubject.eraseToAnyPublisher() }
    public var finishedPublisher: TTSStatusPublisher { finishedSubject.eraseToAnyPublisher() }
    public var startedPublisher: TTSStatusPublisher { startedSubject.eraseToAnyPublisher() }
    public var speakingWordPublisher: TTSWordBoundaryPublisher { speakingWordSubject.eraseToAnyPublisher() }
    public var failurePublisher: TTSFailedPublisher { failureSubject.eraseToAnyPublisher() }
    public var available:Bool {
        return config != nil && audioAvailable
    }
    private var audioAvailable:Bool = true
    private var synthesizer: MSSpeechSynthesizer
    public var pronunciations = [MSPronunciation]() {
        didSet {
            self.synthesizer.pronunciations = pronunciations
        }
    }
    public var config:Config? {
        set { synthesizer.config = newValue }
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
        synthesizer.speak(utterance)
    }
    
    // MARK: MSSpeechSynthesizerDelegate
    internal func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, preparing utterance: TTSUtterance) {
        //preparing.send(utterance)
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
}
