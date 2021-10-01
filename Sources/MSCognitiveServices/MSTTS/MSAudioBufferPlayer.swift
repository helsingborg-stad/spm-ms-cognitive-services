import Foundation
import AVKit
import Combine
import FFTPublisher
import AudioSwitchboard

internal enum AudioPlayerStatus {
    case started
    case paused
    case stopped
    case cancelled
    case failed
}
internal struct AudioPlayerItem {
    var id: String
    var status: AudioPlayerStatus
    var error: Error?
}
internal class MSBufferAudioPlayer: ObservableObject {
    enum AudioBufferPlayerError: Error {
        case unableToInitlializeInputFormat
        case unableToInitlializeOutputFormat
        case unableToInitlializeAudioConverter
        case unableToInitlializeBufferFormat
        case unknownBufferType
        case unableToCreateBuffer
        case emptyBuffer
    }
    weak var fft: FFTPublisher?
    let statusSubject: PassthroughSubject<AudioPlayerItem, Never> = .init()
    let status: AnyPublisher<AudioPlayerItem, Never>
    let playbackTime: PassthroughSubject<Float, Never> = .init()
    private let outputFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)
    private var cancellable:AnyCancellable?
    private(set) var isPlaying: Bool = false
    private let audioSwitchboard:AudioSwitchboard
    private let player: AVAudioPlayerNode = AVAudioPlayerNode()
    private let bufferSize: UInt32 = 512
    private var currentlyPlaying: String? = nil {
        didSet {
            isPlaying = currentlyPlaying != nil
        }
    }
    init(_ audioSwitchboard:AudioSwitchboard) {
        self.audioSwitchboard = audioSwitchboard
        self.status = statusSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
    private func play(buffer: AVAudioBuffer, id: String) throws {
        func schedule(buffer: AVAudioPCMBuffer, id: String) {
            self.statusSubject.send(AudioPlayerItem(id: id, status: .started))
            self.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { (_) -> Void in
                DispatchQueue.main.async { [ weak self] in
                    guard let this = self else {
                        return
                    }
                    if this.currentlyPlaying == id {
                        this.currentlyPlaying = nil
                        this.stop()
                        this.statusSubject.send(AudioPlayerItem(id: id, status: .stopped))
                    }
                }
            }
        }
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer, pcmBuffer.frameLength > 0 else {
            throw AudioBufferPlayerError.emptyBuffer
        }
        if buffer.format.commonFormat == .otherFormat {
            schedule(buffer: pcmBuffer, id: id)
        } else {
            guard let outputFormat = outputFormat else {
                throw AudioBufferPlayerError.unableToInitlializeOutputFormat
            }
            guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                throw AudioBufferPlayerError.unableToInitlializeAudioConverter
            }
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: pcmBuffer.frameCapacity) else {
                throw AudioBufferPlayerError.unableToInitlializeBufferFormat
            }
            try converter.convert(to: convertedBuffer, from: pcmBuffer)
            schedule(buffer: convertedBuffer, id: id)
        }
    }
    private func postCurrentPosition(for rate: Float) {
        guard self.player.isPlaying else {
            return
        }
        if let nodeTime = self.player.lastRenderTime, let playerTime = self.player.playerTime(forNodeTime: nodeTime) {
            let elapsedSeconds = (Float(playerTime.sampleTime) / rate)
            self.playbackTime.send(elapsedSeconds)
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
            statusSubject.send(AudioPlayerItem(id: currentlyPlaying, status: .cancelled))
        }
        currentlyPlaying = nil
        audioSwitchboard.stop(owner: "MSBufferAudioPlayer")
        player.stop()
        self.fft?.end()
    }
    func play(using url: URL, id: String) {
        stop()
        currentlyPlaying = id
        cancellable?.cancel()
        cancellable = audioSwitchboard.claim(owner: "MSBufferAudioPlayer").sink { [weak self] in
            self?.stop()
        }
        do {
            guard let outputFormat = outputFormat else {
                throw AudioBufferPlayerError.unableToInitlializeInputFormat
            }
            let audioEngine = audioSwitchboard.audioEngine
            let audioFile = try AVAudioFile(forReading: url)
            
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
                throw AudioBufferPlayerError.unableToCreateBuffer
            }
            try audioFile.read(into: buffer)
            
            audioEngine.attach(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: outputFormat)
            let rate = Float(outputFormat.sampleRate)
            audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: self.bufferSize, format: audioEngine.mainMixerNode.outputFormat(forBus: 0)) { [weak self] (buffer, _) in
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
            try audioSwitchboard.start(owner: "MSBufferAudioPlayer")
            self.player.play()
            try play(buffer: buffer, id: id)
        } catch {
            stop()
            self.statusSubject.send(AudioPlayerItem(id: id, status: .failed, error: error))
        }
    }
}
