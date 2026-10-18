// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo_Watch_App

@Suite struct PomodoroTimePresentationTests {
    @Test("hours round upward until the exact sixty-minute boundary")
    func hoursPhase() {
        let twoHours = PomodoroTimePresentation.make(remaining: 2 * 60 * 60)
        let oneHourTwenty = PomodoroTimePresentation.make(remaining: 80 * 60)
        let boundary = PomodoroTimePresentation.make(remaining: 60 * 60)

        #expect(twoHours.digits == "02")
        #expect(twoHours.value == 2)
        #expect(twoHours.unit == .hours)
        #expect(oneHourTwenty.digits == "02")
        #expect(oneHourTwenty.unit == .hours)
        #expect(boundary.digits == "60")
        #expect(boundary.unit == .minutes)
    }

    @Test("minutes hand off to seconds at exactly one minute")
    func minuteAndSecondPhases() {
        let minuteFraction = PomodoroTimePresentation.make(remaining: 60.1)
        let boundary = PomodoroTimePresentation.make(remaining: 60)
        let fractionalSecond = PomodoroTimePresentation.make(remaining: 59.1)

        #expect(minuteFraction.digits == "02")
        #expect(minuteFraction.unit == .minutes)
        #expect(boundary.digits == "60")
        #expect(boundary.unit == .seconds)
        #expect(fractionalSecond.digits == "60")
        #expect(fractionalSecond.unit == .seconds)
    }

    @Test("invalid and completed values become zero")
    func invalidValues() {
        let invalidValues: [TimeInterval] = [0, -1, .infinity, -.infinity, .nan]
        for value in invalidValues {
            let presentation = PomodoroTimePresentation.make(remaining: value)
            #expect(presentation.digits == "00")
            #expect(presentation.isComplete)
        }
    }

    @Test("picker maximum and overflow stay within two digits")
    func maximumAndOverflow() {
        let pickerMaximum = PomodoroTimePresentation.make(remaining: 23 * 3600 + 59 * 60 + 59)
        let ninetyNineHours = PomodoroTimePresentation.make(remaining: 99 * 3600)
        let overflow = PomodoroTimePresentation.make(remaining: 99 * 3600 + 0.1)

        #expect(pickerMaximum.digits == "24")
        #expect(pickerMaximum.unit == .hours)
        #expect(ninetyNineHours.digits == "99")
        #expect(!ninetyNineHours.isOverflow)
        #expect(overflow.digits == "99")
        #expect(overflow.isOverflow)
    }

    @Test("accessibility includes state unit and overflow semantics")
    func accessibilityCopy() {
        let running = PomodoroTimePresentation.make(remaining: 25 * 60)
        let stopped = PomodoroTimePresentation.make(remaining: 59)
        let complete = PomodoroTimePresentation.make(remaining: 0)
        let overflow = PomodoroTimePresentation.make(remaining: 100 * 3600)

        #expect(running.accessibilityValue(isRunning: true) == "Running, 25 minutes remaining")
        #expect(stopped.accessibilityValue(isRunning: false) == "Stopped, 59 seconds remaining")
        #expect(complete.accessibilityValue(isRunning: false) == "Timer complete")
        #expect(
            overflow.accessibilityValue(isRunning: true) == "Running, More than 99 hours remaining")
        #expect(running.accessibilityHint(isRunning: true) == "Double-tap to stop the timer")
        #expect(stopped.accessibilityHint(isRunning: false) == "Double-tap to start the timer")
    }
}
