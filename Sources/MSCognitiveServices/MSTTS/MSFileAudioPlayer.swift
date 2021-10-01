import Foundation
import AVKit
import Combine
import FFTPublisher
import AudioSwitchboard

internal enum MSFileAudioPlayerStatus {
    case started
    case paused
    case stopped
    case cancelled
    case failed
}
internal struct MSFileAudioPlayerItem {
    var id: String
    var status: MSFileAudioPlayerStatus
    var error: Error?
}
internal class MSFileAudioPlayer: ObservableObject {
    weak var fft: FFTPublisher?
    let status: PassthroughSubject<MSFileAudioPlayerItem, Never> = .init()
    let playbackTime: PassthroughSubject<Float, Never> = .init()
    
    private var cancellable:AnyCancellable?
    private(set) var isPlaying = false
    private var playing = false
    private let audioSwitchboard:AudioSwitchboard
    private let player = AVAudioPlayerNode()
    private let bufferSize: UInt32 = 512
    init(_ audioSwitchboard: AudioSwitchboard) {
        self.audioSwitchboard = audioSwitchboard
    }
    private var currentlyPlaying: String? = nil {
        didSet {
            isPlaying = currentlyPlaying != nil
        }
    }
    private func postCurrentPosition(for rate: Float) {
        guard self.player.isPlaying else {
            return
        }
        if let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) {
            let elapsedSeconds = (Float(playerTime.sampleTime) / rate)
            playbackTime.send(elapsedSeconds)
        }
    }
    func `continue`() {
        guard currentlyPlaying != nil else {
            return
        }
        if !player.isPlaying {
            player.play()
        }
    }
    func pause() {
        guard currentlyPlaying != nil else {
            return
        }
        if player.isPlaying {
            player.pause()
        }
    }
    func stop() {
        if let currentlyPlaying = currentlyPlaying {
            status.send(MSFileAudioPlayerItem(id: currentlyPlaying, status: .cancelled))
        }
        audioSwitchboard.stop(owner: "MSFileAudioPlayer")
        player.stop()
        currentlyPlaying = nil
        self.fft?.end()
    }
    func play(using url: URL, id: String) {
        stop()
        currentlyPlaying = id
        cancellable?.cancel()
        cancellable = audioSwitchboard.claim(owner: "MSFileAudioPlayer").sink { [weak self] in
            self?.stop()
        }
        do {
            let audioEngine = audioSwitchboard.audioEngine
            let audioFile = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
            let mainMixer = audioEngine.mainMixerNode
            audioEngine.attach(player)
            audioEngine.connect(player, to: mainMixer, format: mainMixer.outputFormat(forBus: 0))
            let rate = Float(mainMixer.outputFormat(forBus: 0).sampleRate)
            mainMixer.installTap(onBus: 0, bufferSize: self.bufferSize, format: mainMixer.outputFormat(forBus: 0)) { [weak self] (buffer, _) in
                guard let this = self else {
                    return
                }
                buffer.frameLength = this.bufferSize
                DispatchQueue.main.async {
                    guard this.player.isPlaying else {
                        return
                    }
                    this.fft?.consume(buffer: buffer.audioBufferList, frames: buffer.frameLength, rate: rate)
                    this.postCurrentPosition(for: rate)
                }
            }
            try audioSwitchboard.start(owner: "MSFileAudioPlayer")
            player.play()
            player.scheduleFile(audioFile, at: nil, completionCallbackType: .dataPlayedBack) {  [weak self] (_) in
                guard let this = self else {
                    return
                }
                DispatchQueue.main.async {
                    if this.currentlyPlaying == id {
                        this.currentlyPlaying = nil
                        this.stop()
                        this.status.send(MSFileAudioPlayerItem(id: id, status: .stopped))
                    }
                }
            }
            self.status.send(MSFileAudioPlayerItem(id: id, status: .started))
        } catch {
            self.status.send(MSFileAudioPlayerItem(id: id, status: .failed, error: error))
        }
    }
}
