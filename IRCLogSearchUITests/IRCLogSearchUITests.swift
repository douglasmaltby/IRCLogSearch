//
//  IRCLogSearchUITests.swift
//  IRCLogSearchUITests
//
//  Created by Douglas Maltby on 5/4/26.
//

import XCTest

final class IRCLogSearchUITests: XCTestCase {

    override func setUpWithError() throws {
        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // Put teardown code here.
    }

    @MainActor
    func testSearchAndClearFishbone() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--test-log-folder",
            "/Users/douglasmaltby/Temp/TWiT (1A921)/Channels/#unfiltered"
        ]
        app.launch()

        // Wait for the Outline (SwiftUI Table) view to appear and populate
        let outline = app.outlines["ResultsTable"]
        XCTAssertTrue(outline.waitForExistence(timeout: 10.0), "The results table view should load")

        // Wait for the log entries to populate (any outline row)
        let firstRow = outline.outlineRows.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10.0), "The log entries should populate")

        // Search for "fishbone"
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "The search field should exist")
        searchField.click()
        searchField.typeText("fishbone")
        searchField.typeKey("\r", modifierFlags: [])

        // Wait for filtering to complete (exactly 1 row should match)
        let expectationOneRow = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 1"),
            object: outline.outlineRows
        )
        let filterResult = XCTWaiter.wait(for: [expectationOneRow], timeout: 5.0)
        XCTAssertEqual(filterResult, .completed, "There should be exactly one matching record for 'fishbone'")

        // Clear the search field using bulletproof keyboard event sequence
        searchField.click()
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: []) // send backspace
        searchField.typeKey("\r", modifierFlags: []) // commit the empty search

        // Wait for results to return to full logs. Since we capped it at 5,000,
        // it will load instantly and the app remains fully responsive!
        let expectationMultipleRows = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 1"),
            object: outline.outlineRows
        )
        let clearResult = XCTWaiter.wait(for: [expectationMultipleRows], timeout: 5.0)
        XCTAssertEqual(clearResult, .completed, "The table should successfully load multiple results after clearing search")
    }
}
