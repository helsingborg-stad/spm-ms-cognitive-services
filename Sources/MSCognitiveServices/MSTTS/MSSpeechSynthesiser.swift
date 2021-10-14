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
protocol MSSpeechSynthesizerDelegate: AnyObject {
    func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, preparing utterance: TTSUtterance)
    func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, didStart utterance: TTSUtterance)
    func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, didCancel utterance: TTSUtterance)
    func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, didFinish utterance: TTSUtterance)
    func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, didFail utterance: TTSUtterance, with error: Error)
    func speechSynthesizer(_ synthesizer: MSSpeechSynthesizer, willSpeak word: String, at range: Range<String.Index>, utterance: TTSUtterance)
}

public struct MSPronunciation {
    let pattern: String
    let replacement: String
    let regexp: NSRegularExpression?
    let original:String
    public init(string: String, replacement: String) {
        self.original = string
        self.pattern = #"(\s+|^)(\#(string))(\W|$)"#
        self.replacement = replacement
        regexp = try? NSRegularExpression(pattern: pattern)
    }
    func execute(using string: String) -> String {
        var string = string
        while let str = replace(using: string) {
            string = str
        }
        return string
    }
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
}

private struct UtteranceFileInfo {
    let audioFileName: String
    let wordBoundaryName: String
    let audioFileUrl: URL
    let wordBoundaryUrl: URL
    let wordBoundaries: [MSWordBoundary]
    var playFromCache: Bool
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
    func deleteCache() {
        try? FileManager.default.removeItem(atPath: audioFileUrl.path)
        try? FileManager.default.removeItem(atPath: wordBoundaryUrl.path)
        debugPrint("DELETED MSTTS file cache",audioFileUrl.path,wordBoundaryUrl.path)
    }
    static func hash(string:String) -> String {
        let inputString = string
        let inputData = Data(inputString.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: MSWordBoundary
private struct MSWordBoundary: Codable {
    let utterance: TTSUtterance.ID
    let startIndex: Int
    let endIndex: Int
    let word: String
    let audioOffset: Float
}

// MARK: MSSpeechSynthesizer
class MSSpeechSynthesizer {
    enum MSUtteranceError: Error {
        case missingVoice
        case cancelledWhileDownloading
    }
    enum MSSpeechSynthesizerError: Error {
        case cancellationError(String)
    }

    private var logger = Shout("MSSpeechSynthesizer")
    private var synthesizer: SPXSpeechSynthesizer?
    private var currentUtterance: TTSUtterance?
    private var gettingVoices = false
    public var config: MSTTS.Config?
    private var playerPublisher: AnyCancellable?
    private var timePublisher: AnyCancellable?
    private var wordBoundaries = [MSWordBoundary]()
    private (set) var audioPlayer:MSBufferAudioPlayer

    weak var delegate: MSSpeechSynthesizerDelegate?
    var enableWordBoundary = true
    var pronunciations = [MSPronunciation]()

    init(_ config: MSTTS.Config?, audioSwitchboard:AudioSwitchboard) {
        self.config = config
        self.audioPlayer = MSBufferAudioPlayer(audioSwitchboard)
    }
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
    func pause() {
        audioPlayer.pause()
    }
    func `continue`() {
        audioPlayer.continue()
    }
    func speak(_ utterance: TTSUtterance) {
        if utterance.id == currentUtterance?.id {
            return
        }
        if currentUtterance != nil {
            stopSpeaking()
        }
        currentUtterance = utterance
        self.delegate?.speechSynthesizer(self, preparing: utterance)
        if !MSSpeechVoice.voices.isEmpty {
            self.synthesize()
            return
        }
        if gettingVoices {
            return
        }
        guard let config = config else {
            delegate?.speechSynthesizer(self, didFail: utterance, with: MSSpeechSynthesizerError.cancellationError("missing configuration"))
            return
        }
        gettingVoices = true
        MSSpeechVoice.getVoices(using: config) { [weak self] (error) in
            if let error = error {
                self?.logger.error(error)
            }
            self?.gettingVoices = false
            self?.synthesize()
        }
    }
    private func synthesize() {
        guard let utterance = currentUtterance else {
            return
        }
        guard let voice = MSSpeechVoice.bestvoice(for: utterance.voice.locale, with: utterance.voice.gender) else {
            self.delegate?.speechSynthesizer(self, didFail: utterance, with: MSUtteranceError.missingVoice)
            return
        }
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
func convertToSSML(utterance: TTSUtterance, voice: MSSpeechVoice, pronunciations:[MSPronunciation]) -> String {
    return """
    <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="http://www.w3.org/2001/mstts" xmlns:emo="http://www.w3.org/2009/10/emotionml" xml:lang="\(voice.locale.replacingOccurrences(of: "_", with: "-"))">
    <voice name="\(voice.shortName)">
        <mstts:silence type="Leading" value="0" />
        <prosody rate="\(utterance.voice.rate ?? 1)">
            \(update(string: utterance.speechString, using: pronunciations))
        </prosody>
        <mstts:silence type="Tailing" value="0" />
    </voice>
    </speak>
    """
}
func update(string: String, using pronunciations: [MSPronunciation]) -> String {
    var string = string
    pronunciations.forEach { r in
        string = r.execute(using: string)
    }
    return string
}
