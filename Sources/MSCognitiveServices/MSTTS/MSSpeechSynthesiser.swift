//
//  MSSpeechSynthesiser.swift
//  speechtranslator
//
//  Created by Tomas Green on 2021-03-19.
//

import Foundation
import Combine
import AVFoundation
import TTS
import Shout
import CryptoKit
import MicrosoftCognitiveServicesSpeech
import AudioSwitchboard

// MARK: MSSpeechSynthesizerDelegate
/// Protocol implemeted by any object using the MSSpeechSynthesizer
protocol MSSpeechSynthesizerDelegate: AnyObject {
    /// Triggered while peparing an utterance for synthesis
    /// - Parameters:
    ///   - synthesizer: the originating synthesizer
    ///   - utterance: the utterance being prepared
    func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, preparing utterance: TTSUtterance)
    /// Triggered when starting an utterance for synthesis
    /// - Parameters:
    ///   - synthesizer: the originating synthesizer
    ///   - utterance: the started utterance
    func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, didStart utterance: TTSUtterance)
    /// Triggered when cancelling an utterance while being sythensizes (or prepared)
    /// - Parameters:
    ///   - synthesizer: the originating synthesizer
    ///   - utterance: the cancelled utterance
    func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, didCancel utterance: TTSUtterance)
    /// Triggered when an utterance is completed
    /// - Parameters:
    ///   - synthesizer: the originating synthesizer
    ///   - utterance: the finished utterance
    func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, didFinish utterance: TTSUtterance)
    /// Triggered when an utterance fails
    /// - Parameters:
    ///   - synthesizer: the originating synthesizer
    ///   - utterance: the failing utterance
    ///   - error: error causing the failure
    func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, didFail utterance: TTSUtterance, with error: Error)
    /// Triggered when an a segment of an utterance is being spoken
    /// - Parameters:
    ///   - synthesizer: the originating synthesizer
    ///   - word: the word being spoken
    ///   - range: the rang of the spoken text in reference to `utterance.speechString`
    ///   - utterance: the failing utterance
    func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, willSpeak word: String, at range: Range<String.Index>, utterance: TTSUtterance)
}

// MARK: MSPronunciation
/// Object used to replace values in strings that require some kind of special treatment, like a phonetic description.
public struct MSPronunciation {
    /// The pattern used with NSRegularExpression
    let pattern: String
    /// The string to replace the original with
    let replacement: String
    /// The regepx used when replacing strings
    let regexp: NSRegularExpression?
    /// The oroginal text to be replaced
    let original:String
    /// Initializes a new MSPronunciation
    /// - Parameters:
    ///   - string: The oroginal text to be replaced
    ///   - replacement: The regepx used when replacing strings
    public init(string: String, replacement: String) {
        self.original = string
        self.pattern = #"(\s+|^)(\#(string))(\W|$)"#
        self.replacement = replacement
        regexp = try? NSRegularExpression(pattern: pattern)
    }
    /// Execute replacement algorithm until no match can be found
    /// - Parameter string: the string used when searching and replacing values based on `original` and `replacement`
    /// - Returns: processed string
    func execute(using string: String) -> String {
        var string = string
        while let str = replace(using: string) {
            string = str
        }
        return string
    }
    /// Replace all occuranses of `original` with `replacement` in `string`
    /// - Parameter string: the string used when searching and replacing values based on `original` and `replacement`
    /// - Returns: processed string
    func replace(using string: String) -> String? {
        guard let regexp = regexp else {
            return nil
        }
        let result = regexp.matches(in: string, range: NSRange(location: 0, length: string.utf16.count))
        guard !result.isEmpty && result[0].numberOfRanges > 2 else {
            return nil
        }
        let r1 = result[0].range(at: 2)
        guard let range = Range(r1, in: string) else {
            return nil
        }
        return string.replacingCharacters(in: range, with: replacement)
    }
    /// Updates a string using an array of `MSPronunciation`
    /// - Parameters:
    ///   - string: the string to update
    ///   - pronunciations: the pronunciations
    /// - Returns: processed string
    static func update(string: String, using pronunciations: [MSPronunciation]) -> String {
        var string = string
        pronunciations.forEach { r in
            string = r.execute(using: string)
        }
        return string
    }

}

// MARK: UtteranceFileInfo
/// Used by the synthesiser to determine the file status of an utterance.
private struct UtteranceFileInfo {
    /// The audio file name
    let audioFileName: String
    /// The word baoundary json file name
    let wordBoundaryName: String
    /// The audio file url
    let audioFileUrl: URL
    /// The word boundar json file url
    let wordBoundaryUrl: URL
    /// Word boundarys read
    let wordBoundaries: [MSWordBoundary]
    /// Describes whether or not the utterance can be played from cache or not
    var playFromCache: Bool
    
    /// Initializes a new object based on the supplied parameters
    /// - Parameters:
    ///   - utterance: the utterance
    ///   - ssml: the computed ssml based on the `utterance.speechString`
    init(utterance: TTSUtterance,ssml:String) {
        let fm = FileManager.default
        let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MSTTSCache4")
        let id = Self.hash(string: ssml)
        self.audioFileName = id + "\(utterance.voice.locale.identifier).wav"
        self.wordBoundaryName = id + "\(utterance.voice.locale.identifier).json"
        self.audioFileUrl = cacheDir.appendingPathComponent(audioFileName)
        self.wordBoundaryUrl = cacheDir.appendingPathComponent(wordBoundaryName)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: false, attributes: nil)
        var hasWordBoundaryFile = fm.fileExists(atPath: audioFileUrl.path)
        if hasWordBoundaryFile {
            do {
                let wordBoundaryData = try Data(contentsOf: wordBoundaryUrl)
                wordBoundaries = try JSONDecoder().decode([MSWordBoundary].self, from: wordBoundaryData)
            } catch {
                hasWordBoundaryFile = false
                try? fm.removeItem(atPath: wordBoundaryUrl.path)
                wordBoundaries = []
            }
        } else {
            wordBoundaries = []
        }
        if !fm.fileExists(atPath: audioFileUrl.path) || !hasWordBoundaryFile {
            try? fm.removeItem(atPath: audioFileUrl.path)
            try? fm.removeItem(atPath: wordBoundaryUrl.path)
            playFromCache = false
        } else {
            playFromCache = true
        }
    }
    /// Deletes all cache
    func deleteCache() {
        try? FileManager.default.removeItem(atPath: audioFileUrl.path)
        try? FileManager.default.removeItem(atPath: wordBoundaryUrl.path)
        debugPrint("DELETED MSTTS file cache",audioFileUrl.path,wordBoundaryUrl.path)
    }
    /// Hashes a string using SHA256
    /// - Parameter string: the string to hash
    /// - Returns: a SHA256 hashed string value
    static func hash(string:String) -> String {
        let inputString = string
        let inputData = Data(inputString.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: MSWordBoundary
/// Internal word boundar object used for processing
private struct MSWordBoundary: Codable {
    /// The utterance id
    let utterance: TTSUtterance.ID
    /// The start of a word in a string
    let startIndex: Int
    /// The end of a word in a string
    let endIndex: Int
    /// The word itself
    let word: String
    /// The audio offset in time from start
    let audioOffset: Float
}

// MARK: MSSpeechSynthesizer
/// The MSSpeechSynthesizer is used to synthesise text to speech and playback of audio
class MSSpeechSynthesizer {
    
    /// Errors describing utterance failures
    enum MSUtteranceError: Error {
        case missingVoice
        case cancelledWhileDownloading
    }
    /// Errors decribing synhesis errors
    enum MSSpeechSynthesizerError: Error {
        case cancellationError(String)
    }
    
    /// Logging events for debug
    private var logger = Shout("MSSpeechSynthesizer")
    /// Microsoft sythensiser
    private var synthesizer: SPXSpeechSynthesizer?
    /// Currently utterance for processing and playback
    private var currentUtterance: TTSUtterance?
    /// Cancellable attatched to the audioplayer status
    private var playerPublisher: AnyCancellable?
    /// Cancellable attatched to the audioplayer playback time
    private var timePublisher: AnyCancellable?
    /// Current word boundaries
    private var wordBoundaries = [MSWordBoundary]()
    /// Audioplayer used for playback
    private (set) var audioPlayer:MSBufferAudioPlayer
    /// Delegate used for triggering events
    weak var delegate: MSSpeechSynthesizerDelegate?
    
    /// Indicates whether or not word boundary processing is enabled
    var enableWordBoundary = true
    /// Pronunciations to be used for replacing strings
    var pronunciations = [MSPronunciation]()
    /// Configuration used to communicate with Microsoft backend
    var config: MSTTS.Config?
    
    /// Initializes
    /// - Parameters:
    ///   - config: Configuration used to communicate with Microsoft backend
    ///   - audioSwitchboard: Swiftboard used to manage audio
    init(_ config: MSTTS.Config?, audioSwitchboard:AudioSwitchboard) {
        self.config = config
        self.audioPlayer = MSBufferAudioPlayer(audioSwitchboard)
    }
    /// Stop playback
    func stopSpeaking() {
        do {
            if let utterance = currentUtterance {
                self.delegate?.speechSynthesizer(self, didCancel: utterance)
            }
            currentUtterance = nil
            try synthesizer?.stopSpeaking()
            if audioPlayer.isPlaying {
                audioPlayer.stop()
            }
            synthesizer = nil
        } catch {
            debugPrint(error)
            currentUtterance = nil
            synthesizer = nil
            logger.error(error)
        }
    }
    /// Pause playback
    func pause() {
        audioPlayer.pause()
    }
    /// Continue playback
    func `continue`() {
        audioPlayer.continue()
    }
    /// Generate and play an utterance using a specific voice
    /// - Parameters:
    ///   - utterance: utterance to be used
    ///   - voice: voice to be used
    func speak(_ utterance: TTSUtterance, using voice:MSSpeechVoice) {
        if utterance.id == currentUtterance?.id {
            return
        }
        if currentUtterance != nil {
            stopSpeaking()
        }
        currentUtterance = utterance
        self.delegate?.speechSynthesizer(self, preparing: utterance)
        let ssml = convertToSSML(utterance: utterance, voice: voice, pronunciations: pronunciations)
        let fileInfo = UtteranceFileInfo(utterance: utterance,ssml:ssml)
        if fileInfo.playFromCache {
            self.wordBoundaries = fileInfo.wordBoundaries
            self.synthesizeSSMLToAudioPlayer(utterance: utterance, voice: voice, ssml: ssml, fileInfo: fileInfo)
            return
        }
        self.wordBoundaries = []
        createFile(utterance: utterance, voice: voice, ssml: ssml, fileInfo: fileInfo) { [weak self] error in
            guard let this = self else {
                return
            }
            if let error = error {
                this.delegate?.speechSynthesizer(this, didFail: utterance, with: error)
            } else if this.currentUtterance != utterance {
                this.delegate?.speechSynthesizer(this, didFail: utterance, with: MSUtteranceError.cancelledWhileDownloading)
            } else {
                this.synthesizeSSMLToAudioPlayer(utterance: utterance, voice: voice, ssml: ssml, fileInfo: fileInfo)
            }
        }
    }
    /// Play an utterance using a `MSBufferAudioPlayer`
    /// - Parameters:
    ///   - utterance: utterance reference
    ///   - voice: voice to be used
    ///   - ssml: ssml to be spoken
    ///   - fileInfo: audio and word boundary file info
    private func synthesizeSSMLToAudioPlayer(utterance: TTSUtterance, voice: MSSpeechVoice, ssml: String, fileInfo: UtteranceFileInfo) {
        playerPublisher = audioPlayer.status.sink { [weak self] (item) in
            guard let this = self, item.id == utterance.id else {
                return
            }
            if item.status == .cancelled {
                if this.currentUtterance == utterance {
                    this.playerPublisher = nil
                    this.currentUtterance = nil
                    this.wordBoundaries = []
                }
                this.delegate?.speechSynthesizer(this, didCancel: utterance)
            } else if item.status == .started {
                this.delegate?.speechSynthesizer(this, didStart: utterance)
            } else if item.status == .stopped {
                if this.currentUtterance == utterance {
                    this.playerPublisher = nil
                    this.currentUtterance = nil
                    this.wordBoundaries = []
                }
                this.delegate?.speechSynthesizer(this, didFinish: utterance)
            } else if item.status == .failed, let error = item.error {
                this.delegate?.speechSynthesizer(this, didFail: utterance, with: error)
                fileInfo.deleteCache()
            }
        }
        self.audioPlayer.play(using: fileInfo.audioFileUrl, id: utterance.id)
        func talk(time: Float) {
            guard let word = wordBoundaries.first else {
                timePublisher = nil
                return
            }
            guard word.audioOffset - 0.1 <= time, let range = Range(NSRange(location: word.startIndex, length: word.endIndex - word.startIndex), in: utterance.speechString) else {
                return
            }
            delegate?.speechSynthesizer(self, willSpeak: word.word, at: range, utterance: utterance)
            wordBoundaries.removeFirst()
            talk(time: time)
        }
        timePublisher = audioPlayer.playbackTime.sink { time in
            talk(time: time)
        }
    }
    /// Downloads an audio file and creates a word baoundary json later uses for playback
    /// - Parameters:
    ///   - utterance: the utterance
    ///   - voice: the voice to be used
    ///   - ssml: ssml to be used for synthesis
    ///   - fileInfo: file info object used to extract file urls
    ///   - completionHandler: completion closure
    private func createFile(utterance: TTSUtterance, voice: MSSpeechVoice, ssml: String, fileInfo: UtteranceFileInfo, completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let config = config else {
                throw MSSpeechSynthesizerError.cancellationError("missing configuration")
            }
            let speechConfig = try SPXSpeechConfiguration(subscription: config.key, region: config.region)
            speechConfig.speechSynthesisVoiceName = voice.shortName
            speechConfig.setSpeechSynthesisOutputFormat(voice.outputFormat)
            if enableWordBoundary {
                speechConfig.requestWordLevelTimestamps()
            }
            let audioConfig = try SPXAudioConfiguration(wavFileOutput: fileInfo.audioFileUrl.path)
            let synthesizer = try SPXSpeechSynthesizer(speechConfiguration: speechConfig, audioConfiguration: audioConfig)
            if enableWordBoundary {
                var currentIndex = utterance.speechString.startIndex
                guard self.wordBoundaries.isEmpty else {
                    return
                }
                synthesizer.addSynthesisWordBoundaryEventHandler { [weak self] (_, args) in
                    guard let this = self else {
                        return
                    }
                    let r1 = NSRange(location: Int(args.textOffset), length: Int(args.wordLength))
                    guard let r2 = Range(r1, in: ssml) else {
                        return
                    }
                    var word = String(ssml[r2])
                    if let rep = this.pronunciations.first(where: { $0.replacement == word}) {
                        word = rep.original
                    }
                    guard let range = utterance.speechString.range(of: word, options: .literal, range: currentIndex ..< utterance.speechString.endIndex) else {
                        return
                    }
                    currentIndex = range.upperBound
                    let offset = (Float(args.audioOffset) / 10000) / 1000
                    let start = range.lowerBound.utf16Offset(in: utterance.speechString)
                    let end = range.upperBound.utf16Offset(in: utterance.speechString)
                    this.wordBoundaries.append(MSWordBoundary(utterance: utterance.id, startIndex: start, endIndex: end, word: word, audioOffset: offset))
                    do {
                        try JSONEncoder().encode(this.wordBoundaries).write(to: fileInfo.wordBoundaryUrl)
                    } catch {
                        this.logger.error(error)
                        fileInfo.deleteCache()
                    }
                }
            }
            self.synthesizer = synthesizer
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let result = try synthesizer.speakSsml(ssml)
                    if result.reason == SPXResultReason.canceled {
                        let cancellationDetails = try SPXSpeechSynthesisCancellationDetails(fromCanceledSynthesisResult: result)
                        DispatchQueue.main.async {
                            completionHandler(MSSpeechSynthesizerError.cancellationError(cancellationDetails.errorDetails ?? "Cancelled"))
                            fileInfo.deleteCache()
                        }
                    } else {
                        DispatchQueue.main.async {
                            completionHandler(nil)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        completionHandler(error)
                        fileInfo.deleteCache()
                    }
                }
                self?.synthesizer = nil
            }
        } catch {
            completionHandler(error)
            fileInfo.deleteCache()
            self.synthesizer = nil
        }
    }
}

/// Maxamium tts rate
let MSVoiceSynthesisMaximumRate:Double = 300
/// Minumum tts rate
let MSVoiceSynthesisMinimumRate:Double = -100
/// Default tts rate
let MSVoiceSynthesisDefaultRate:Double = 0

/// Maxamium tts pitch
let MSVoiceSynthesisMaximumPitch:Double = 50
/// Minumum tts pitch
let MSVoiceSynthesisMinimumPitch:Double = -50
/// Default tts pitch
let MSVoiceSynthesisDefaultPitch:Double = 0

/// Converts the rate of the voice from the standard TTSUtterance value to a MSTTS compatible number
/// - Parameter value: the rate from a TTSUtterance
/// - Returns: converted value, positive and negative percentage from normal 0%
func convertVoiceRate(_ value:Double) -> Double {
    let minRate = MSVoiceSynthesisMinimumRate + 100
    let maxRate = MSVoiceSynthesisMaximumRate + 100
    let defRate = MSVoiceSynthesisDefaultRate + 100
    var val = defRate * value
    val = min(max(val,minRate),maxRate) - 100
    return Double(Int(val))
}

/// Converts the pitch of the voice from the standard TTSUtterance value to a MSTTS compatible number
/// - Parameter value: the pitch from a TTSUtterance
/// - Returns: converted value, positive and negative percentage from normal 0%
func convertVoicePitch(_ value:Double) -> Double {
    let minPitch = MSVoiceSynthesisMinimumPitch + 50
    let maxPitch = MSVoiceSynthesisMaximumPitch + 50
    let defPitch = MSVoiceSynthesisDefaultPitch + 50
    var val = defPitch * value
    val = min(max(val,minPitch),maxPitch) - 50
    return Double(Int(val))
}

/// Creates an an from a `TTSUtterance`, a `MSSpeechVoice` and a list of `MSPronunciation`
/// - Parameters:
///   - utterance: the utterance
///   - voice: the voice
///   - pronunciations: the pronunciations
/// - Returns: ssml represeting the above parameters
func convertToSSML(utterance: TTSUtterance, voice: MSSpeechVoice, pronunciations:[MSPronunciation]) -> String {
    return """
    <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="http://www.w3.org/2001/mstts" xmlns:emo="http://www.w3.org/2009/10/emotionml" xml:lang="\(voice.locale.replacingOccurrences(of: "_", with: "-"))">
        <voice name="\(voice.shortName)">
        <mstts:silence type="Leading" value="0" />
        <prosody rate="\(convertVoiceRate(utterance.voice.rate ?? 1))%" pitch="\(convertVoicePitch(utterance.voice.pitch ?? 1))%">
            \(MSPronunciation.update(string: utterance.speechString, using: pronunciations))
        </prosody>
        <mstts:silence type="Tailing" value="0" />
    </voice>
    </speak>
    """
}
