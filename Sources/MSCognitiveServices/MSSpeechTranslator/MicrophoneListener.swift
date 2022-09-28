//
//  AudioVisualizerObserver.swift
//  speechtranslator
//
//  Created by Tomas Green on 2021-03-31.
//
import Foundation
import AVKit
import Combine
import Accelerate
import Shout
import FFTPublisher
import AudioSwitchboard

/// The purpose of the microphone listener is to gather audiodata and run it through the FFTPublisher.
class MicrophoneListener: ObservableObject {
    /// Switchboard used to claim and release audio ownership
    private let audioSwitchboard:AudioSwitchboard
    /// Indicates whether or not the listerner is running
    @Published var running: Bool = false
    /// FFTPublisher, weak reference!
    weak var fft: FFTPublisher?
    /// Initializes a new listener
    /// - Parameter audioSwitchboard: Switchboard used to claim and release audio ownership
    init(_ audioSwitchboard: AudioSwitchboard) {
        self.audioSwitchboard = audioSwitchboard
    }
    /// Start "recording"
    private func record() {
        audioSwitchboard.claim(owner: "MSMicrophoneListener")
        let audioEngine = audioSwitchboard.audioEngine
        let rate = Float(audioEngine.inputNode.inputFormat(forBus: 0).sampleRate)
        let sinkNode = AVAudioSinkNode { [weak self] (_, frames, buffer) -> OSStatus in
            self?.fft?.consume(buffer: buffer, frames: frames, rate: rate)
            return noErr
        }
        
        audioEngine.attach(sinkNode)
        audioEngine.connect(audioEngine.inputNode, to: sinkNode, format: nil)
        try? audioSwitchboard.start(owner: "MSMicrophoneListener")
    }
    /// Start listening. This function will ask for recording permissions
    func start() {
        running = true
        if fft == nil {
            return
        }
        #if os(iOS) || os(tvOS) || os(watchOS)
        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.recordPermission == .granted {
            record()
            return
        }
        if audioSession.recordPermission == .denied {
            return
        }
        if audioSession.recordPermission == .undetermined {
            audioSession.requestRecordPermission { _ in
                if audioSession.recordPermission == .denied {
                } else {
                    self.start()
                }
            }
            return
        }
        #else
        record()
        #endif
    }
    /// Stop listening, relase switchboard ownership and end FFT.
    func stop() {
        running = false
        audioSwitchboard.stop(owner: "MSMicrophoneListener")
        fft?.end()
    }
}
