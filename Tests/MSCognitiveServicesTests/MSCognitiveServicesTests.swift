import XCTest
import AudioSwitchboard
import Combine

@testable import MSCognitiveServices
let switchboard = AudioSwitchboard()
var cancellables = Set<AnyCancellable>()

final class MSCognitiveServicesTests: XCTestCase {
    func testConvertPitchAndRate() throws {
        XCTAssertTrue(convertVoiceRate(0.5) == -50)
        XCTAssertTrue(convertVoiceRate(1.5) == 50)
        XCTAssertTrue(convertVoiceRate(1.222) == 22)
        XCTAssertTrue(convertVoiceRate(0) == MSVoiceSynthesisMinimumRate)
        XCTAssertTrue(convertVoiceRate(1) == MSVoiceSynthesisDefaultRate)
        XCTAssertTrue(convertVoiceRate(4) == MSVoiceSynthesisMaximumRate)
        XCTAssertFalse(convertVoiceRate(5) == 400)
        
        XCTAssertTrue(convertVoicePitch(0.5) == -50)
        XCTAssertTrue(convertVoicePitch(1.5) == 50)
        XCTAssertTrue(convertVoicePitch(1.222) == 22)
        XCTAssertTrue(convertVoicePitch(0) == MSVoiceSynthesisMinimumPitch)
        XCTAssertTrue(convertVoicePitch(1) == MSVoiceSynthesisDefaultPitch)
        XCTAssertTrue(convertVoicePitch(4) == MSVoiceSynthesisMaximumPitch)
        XCTAssertFalse(convertVoicePitch(3) == 300)
    }
}
