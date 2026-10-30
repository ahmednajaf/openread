import XCTest
import BackgroundTasks
@testable import OpenRead

final class SpeechComputeJobTests: XCTestCase {
    @MainActor func testUnsupportedBackgroundGPUFallsBackWithoutLaunchingAJob() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Background GPU jobs require iOS 26.") }
        guard !BGTaskScheduler.supportedResources.contains(.gpu) else {
            throw XCTSkip("Run the user-started background-GPU scenario on TestFlight hardware.")
        }
        let job = await SpeechComputeJob.start(title: "Test reading", passages: 3) { XCTFail("An unlaunched job cannot expire.") }
        XCTAssertNil(job)
    }
    @MainActor func testCancelledNarrationDoesNotStartGPUWork() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Background GPU jobs require iOS 26.") }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await SpeechComputeJob.start(title: "Cancelled reading", passages: 3) { XCTFail("A cancelled request cannot become a running job.") }
        }
        let job = await task.value
        XCTAssertNil(job)
    }
}
