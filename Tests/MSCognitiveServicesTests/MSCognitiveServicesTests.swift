import XCTest
import AudioSwitchboard
import Combine

@testable import MSCognitiveServices
let switchboard = AudioSwitchboard()
private var cancellables = Set<AnyCancellable>()

final class MSCognitiveServicesTests: XCTestCase {
    func testConvertPitchAndRate() throws {
        XCTAssertTrue(convertVoiceRate(0.5) == -50)
        XCTAssertTrue(convertVoiceRate(1.5) == 50)
        XCTAssertTrue(convertVoiceRate(1.222) == 22)
        XCTAssertTrue(convertVoiceRate(0) == MSVoiceSynthesisMinimumRate)
        XCTAssertTrue(convertVoiceRate(1) == MSVoiceSynthesisDefaultRate)
        XCTAssertTrue(convertVoiceRate(4) == MSVoiceSynthesisMaximumRate)
        XCTAssertFalse(convertVoiceRate(5) == 400)
        
        XCTAssertTrue(convertVoicePitch(0.5) == -25)
        XCTAssertTrue(convertVoicePitch(1.5) == 25)
        XCTAssertTrue(convertVoicePitch(1.222) == 11)
        XCTAssertTrue(convertVoicePitch(0) == MSVoiceSynthesisMinimumPitch)
        XCTAssertTrue(convertVoicePitch(1) == MSVoiceSynthesisDefaultPitch)
        XCTAssertTrue(convertVoicePitch(2) == MSVoiceSynthesisMaximumPitch)
        XCTAssertFalse(convertVoicePitch(3) == 300)
    }
    func testTextTranslationLangauages() async throws {
        let values = try await MSTextTranslationLanguage.fetch()
        XCTAssertFalse(values.isEmpty)
        XCTAssertTrue(values.contains { $0.locale.identifier == "pt_BR" && $0.key == "pt" })
    }
    func testTextTranslatorLanguages() async {
        let t = MSTextTranslator()
        let expectation = XCTestExpectation(description: "testTextTranslatorLanguages")
        t.$fetchLanguagesStatus.sink { status in
            switch status {
            case .finished:
                XCTAssert(t.languages.isEmpty == false)
                expectation.fulfill()
            case .failed(let error): XCTFail(error.localizedDescription)
            case .none: break
            }
        }.store(in: &cancellables)
        
        wait(for: [expectation], timeout: 10)
    }
}
