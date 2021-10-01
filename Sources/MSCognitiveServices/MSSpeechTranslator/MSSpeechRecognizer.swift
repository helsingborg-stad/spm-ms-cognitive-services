//
//  MSSpeechSynth2.swift
//  speechtranslator
//
//  Created by Tomas Green on 2021-04-23.
//

/*
import Foundation
import Combine
import AVFoundation
import FFTPublisher
import MicrosoftCognitiveServicesSpeech
import AudioSwitchboard
import STT

public class MSSpeechRecognizer: ObservableObject,STTService {
    public struct Config {
        public let key: String
        public let region: String
        public init(key: String, region: String) {
            self.key = key
            self.region = region
        }
    }
    
    public var locale: Locale = .current
    public var contextualStrings: [String] = []
    public var mode: STTMode = .unspecified
    private var resultSubject: STTRecognitionSubject = .init()
    private var statusSubject: STTStatusSubject = .init()
    private var errorSubject: STTErrorSubject = .init()
    
    public var resultPublisher: STTRecognitionPublisher
    public var statusPublisher: STTStatusPublisher
    public var errorPublisher: STTErrorPublisher
    public var available: Bool {
        return true
    }
    

    typealias StatusEvent = PassthroughSubject<Void, Never>
    typealias RecognitionEvent = PassthroughSubject<String, Never>
    let finished: RecognitionEvent = .init()
    let intermediateResult: RecognitionEvent = .init()
    let started: StatusEvent = .init()
    let stopped: StatusEvent = .init()

    private let config: Config
    private let mic:Microphone
    private var recognizer: SPXSpeechRecognizer?
    private var cancellable: AnyCancellable?
    init(config: Config, audioSwitchboard:AudioSwitchboard, fft: FFTPublisher? = nil) {
        self.config = config
        self.mic = Microphone(audioSwitchboard)
        self.fft = fft
        resultPublisher = resultSubject.eraseToAnyPublisher()
        statusPublisher = statusSubject.eraseToAnyPublisher()
        errorPublisher = errorSubject.eraseToAnyPublisher()
    }
    weak var fft: FFTPublisher? {
        didSet {
            mic.fft = fft
        }
    }
    public func stop() {
        try? recognizer?.stopContinuousRecognition()
        mic.stop()
    }
    public func done() {
        
    }
    public func start() {

        self.statusSubject.send(.preparing)
        let format = mic.format
        guard let f = SPXAudioStreamFormat(usingPCMWithSampleRate: UInt(format.sampleRate), bitsPerSample: UInt(format.streamDescription.pointee.mBitsPerChannel), channels: UInt(format.channelCount)) else {
            print("no format")
            return
        }
        guard let stream = SPXPushAudioInputStream(audioFormat: f) else {
            print("no stream")
            return
        }
        guard let audioConfig = SPXAudioConfiguration(streamInput: stream) else {
            print("no audioconfig")
            return
        }
        do {
            let speechConfig = try SPXSpeechConfiguration(subscription: config.key, region: config.region)
            speechConfig.speechRecognitionLanguage = "en-US"
            speechConfig.enableAudioLogging()
            let recognizer = try SPXSpeechRecognizer(speechConfiguration: speechConfig, audioConfiguration: audioConfig)
            recognizer.addRecognizingEventHandler { (_, e) in
                guard let text = e.result.text else {
                    return
                }
                DispatchQueue.main.async {
                    self.resultSubject.send(.init(text, confidence: 1, locale: self.locale, final: false))
                }
            }
            recognizer.addRecognizedEventHandler { (_, e) in
                guard let text = e.result.text else {
                    return
                }
                debugPrint(e.result.properties)
                DispatchQueue.main.async {
                    self.resultSubject.send(.init(text, confidence: 1, locale: self.locale, final: true))
                }
            }
            recognizer.addSessionStartedEventHandler { (_, _) in
                DispatchQueue.main.async {
                    self.statusSubject.send(.recording)
                }
            }
            recognizer.addSessionStoppedEventHandler { (_, _) in
                DispatchQueue.main.async {
                    self.statusSubject.send(.idle)
                }
            }
            self.recognizer = recognizer
            try recognizer.startContinuousRecognition()
            cancellable = mic.dataPublisher.sink { data in
                stream.write(data)
            }
            mic.start()
        } catch {
            self.errorSubject.send(error)
        }
    }
}

private class Microphone {
    private let bufferSize: UInt32 = 512
    private let audioSwitchboard:AudioSwitchboard
    init(_ audioSwitchboard:AudioSwitchboard) {
        self.audioSwitchboard = audioSwitchboard
    }
    let dataPublisher: PassthroughSubject<Data, Never> = .init()
    weak var fft: FFTPublisher?
    /// we need to compress the data before sending it to microsoft, using pcmFormatInt16 does a little but we have to somehow impact the samplerate as well. 16khz should be sufficient
    var format: AVAudioFormat {
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audioSwitchboard.audioEngine.inputNode.inputFormat(forBus: 0).sampleRate, channels: 1, interleaved: true)!
    }
    func stop() {
        audioSwitchboard.stop(owner: "MSSpeechRecognizer.Microphone")
    }
    func start() {
        stop()
        audioSwitchboard.claim(owner: "MSSpeechRecognizer.Microphone")
        let audioEngine = audioSwitchboard.audioEngine
        let rate = Float(audioEngine.inputNode.inputFormat(forBus: 0).sampleRate)
        let downMixer = AVAudioMixerNode()
        audioEngine.attach(downMixer)
        audioEngine.connect(audioEngine.inputNode, to: downMixer, format: format)
        downMixer.installTap(onBus: downMixer.nextAvailableInputBus, bufferSize: self.bufferSize, format: format) { [weak self] (buffer, _) in
            guard let this = self else {
                return
            }
            buffer.frameLength = this.bufferSize
            this.fft?.consume(buffer: buffer.audioBufferList, frames: buffer.frameLength, rate: rate)
            if let audioBuffer = buffer.audioBufferList.pointee.mBuffers.mData {
                let data = Data(bytes: audioBuffer, count: Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize))
                this.dataPublisher.send(data)
            } else {
                print("no buffer")
            }
        }
        try? audioSwitchboard.start(owner: "MSSpeechRecognizer.Microphone")

    }
}
*/
