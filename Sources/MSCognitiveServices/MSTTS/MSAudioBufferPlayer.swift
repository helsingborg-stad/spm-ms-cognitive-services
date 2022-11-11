import Foundation
import AVKit
import Combine
import FFTPublisher
import AudioSwitchboard

/// Status of the audio player
internal enum AudioPlayerStatus {
    case started
    case paused
    case stopped
    case cancelled
    case failed
}
/// Describes an playable item and it's status
internal struct AudioPlayerItem {
    /// The id of the item
    var id: String
    /// The audio player status in refernce to the specific `id`
    var status: AudioPlayerStatus
    /// An error that occured
    var error: Error?
}
/// Audioplayer based on the AVAudioEngine
internal class MSBufferAudioPlayer: ObservableObject {
    /// AudioBufferPlayer Errors
    enum AudioBufferPlayerError: Error {
        /// Triggered when audio input format cannot be determined
        case unableToInitlializeInputFormat
        /// Triggered when audio output format cannot be determined
        case unableToInitlializeOutputFormat
        /// Triggered if the audio converter cannot be configured (probaby due to unsupported formats)
        case unableToInitlializeAudioConverter
        /// Triggered if the audio file cannot be converted
        case unableToConvertFile
        /// Trigggered when the buffer format cannot be  determined
        case unableToInitlializeBufferFormat
        /// Triggered when an unknown buffertype is discovered
        case unknownBufferType
        /// Triggered when a PCMBuffer cannot be created
        case unableToCreateBuffer
        /// Triggered in case the buffer is empty when it shouldn't be
        case emptyBuffer
    }
    /// Instance used to produce and publish meter values
    weak var fft: FFTPublisher?
    /// Used to send player status updates
    let statusSubject: PassthroughSubject<AudioPlayerItem, Never> = .init()
    /// Status update publisher
    let status: AnyPublisher<AudioPlayerItem, Never>
    /// Used to publish playback time of the audio file.
    let playbackTime: PassthroughSubject<Float, Never> = .init()
    /// The output format used in the AVAudioEngine
    private let outputFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)
    /// Used to subscribe to the AudioSwitchboard claim publisher
    private var cancellable:AnyCancellable?
    /// Indicates whether or not the current utterance is playing
    private(set) var isPlaying: Bool = false
    /// Switchboard used to claim the audio channels
    private let audioSwitchboard:AudioSwitchboard
    /// The player used to play audio
    private let player: AVAudioPlayerNode = AVAudioPlayerNode()
    /// The audio buffer size. 512 is not officially supported by Apple but it works anyway. It's set to 512 to speed up FFT calculations and reduce lag.
    private let bufferSize: UInt32 = 512
    /// Id of the currently playing audio
    private var currentlyPlaying: String? = nil {
        didSet {
            isPlaying = currentlyPlaying != nil
        }
    }
    /// Initializes a MSBufferAudioPlayer
    /// - Parameter audioSwitchboard: Switchboard used to claim the audio channels
    init(_ audioSwitchboard:AudioSwitchboard) {
        self.audioSwitchboard = audioSwitchboard
        self.status = statusSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
    /// Play a bffer using the current `AVAudioPlayerNode`
    /// - Parameters:
    ///   - buffer: buffer to play
    ///   - id: the id of the buffer
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
            let ratio = outputFormat.sampleRate / pcmBuffer.format.sampleRate
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: pcmBuffer.frameCapacity * UInt32(ratio)) else {
                throw AudioBufferPlayerError.unableToInitlializeBufferFormat
            }
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = AVAudioConverterInputStatus.haveData
                return pcmBuffer
            }
            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            if let _ = error {
                throw AudioBufferPlayerError.unableToConvertFile
            }
            schedule(buffer: convertedBuffer, id: id)
        }
    }
    /// Posts the current position to `playbackTime`
    /// - Parameter rate: the rate of the player
    private func postCurrentPosition(for rate: Float) {
        guard self.player.isPlaying else {
            return
        }
        if let nodeTime = self.player.lastRenderTime, let playerTime = self.player.playerTime(forNodeTime: nodeTime) {
            let elapsedSeconds = (Float(playerTime.sampleTime) / rate)
            self.playbackTime.send(elapsedSeconds)
        }
    }
    /// Continue playing
    func `continue`() {
        guard currentlyPlaying != nil else {
            return
        }
        if !player.isPlaying {
            player.play()
        }
    }
    /// Pause playing
    func pause() {
        guard currentlyPlaying != nil else {
            return
        }
        if player.isPlaying {
            player.pause()
        }
    }
    // Stop playing
    func stop() {
        if let currentlyPlaying = currentlyPlaying {
            statusSubject.send(AudioPlayerItem(id: currentlyPlaying, status: .cancelled))
        }
        currentlyPlaying = nil
        audioSwitchboard.stop(owner: "MSBufferAudioPlayer")
        player.stop()
        self.fft?.end()
    }
    /// Play buffer from an audio file
    /// - Parameters:
    ///   - url: the url of the audio file
    ///   - id: an id represting the file
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
