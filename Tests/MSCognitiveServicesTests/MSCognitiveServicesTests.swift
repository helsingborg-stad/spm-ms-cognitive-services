import XCTest
import AudioSwitchboard
import Combine

@testable import MSCognitiveServices
let switchboard = AudioSwitchboard()
var cancellables = Set<AnyCancellable>()

final class MSCognitiveServicesTests: XCTestCase {
    func testConvertPitch() throws {
        XCTAssert(convertVoiceAdjustmentParameter(0.5) == -50)
        XCTAssert(convertVoiceAdjustmentParameter(1.5) == 50)
        XCTAssert(convertVoiceAdjustmentParameter(1.222) == 22)
        XCTAssert(convertVoiceAdjustmentParameter(1) == 0)
    }
}
