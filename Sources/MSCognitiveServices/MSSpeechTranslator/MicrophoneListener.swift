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

class MicrophoneListener: ObservableObject {
    private let audioSwitchboard:AudioSwitchboard
    @Published var running: Bool = false
    private var switchBoardSubscriber:AnyCancellable?
    weak var fft: FFTPublisher?
    init(_ audioSwitchboard: AudioSwitchboard) {
        self.audioSwitchboard = audioSwitchboard
    }
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
    func start() {
        running = true
        if fft == nil {
            return
        }
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
    }
    func stop() {
        running = false
        audioSwitchboard.stop(owner: "MSMicrophoneListener")
        fft?.end()
    }
}
