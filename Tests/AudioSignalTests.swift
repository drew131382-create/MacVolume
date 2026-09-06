import Foundation

@main
struct AudioSignalTests {
    static func main() {
        // Exercise the actual render function, especially peaks formerly limited
        // by the automatic call multiplier even at a user volume of 100%.
        for index in -10000...10000 {
            let sample = Float(index) / 10000
            precondition(ProcessTapController.renderSample(sample, gain: 1) == sample)
            precondition(ProcessTapController.renderSample(sample, gain: 0.5) == sample * 0.5)
            precondition(ProcessTapController.renderSample(sample, gain: 0) == 0)
            let boosted = ProcessTapController.renderSample(sample, gain: 3)
            precondition(boosted.isFinite && abs(boosted) <= 1)
        }
        print("PASS: 20,001 samples preserve unity/attenuation/mute; explicit boost is bounded")
    }
}
