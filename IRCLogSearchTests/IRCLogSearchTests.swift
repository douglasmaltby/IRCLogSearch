//
//  IRCLogSearchTests.swift
//  IRCLogSearchTests
//
//  Created by Douglas Maltby on 5/4/26.
//

import Testing
import Foundation
@testable import IRCLogSearch

struct IRCLogSearchTests {

    @Test func testTrimmingWhitespace() async throws {
        let testCases = [
            "  hello  ": "hello",
            "   ": "",
            "": "",
            "world": "world",
            " \t\n hello world \r\n ": "hello world"
        ]

        for (input, expected) in testCases {
            let result = input.trimmingWhitespace()
            #expect(result == expected)
        }
    }

    @Test func testParseStandardLine() async throws {
        let line = "[14:32:01] <Douglas> Hello Gemini!"
        guard let entry = LogEntry.parseLine(line, channel: "#general", id: 1) else {
            Issue.record("Failed to parse standard line")
            return
        }

        #expect(entry.id == 1)
        #expect(entry.channel == "#general")
        #expect(entry.timestamp == "14:32:01")
        #expect(entry.author == "Douglas")
        #expect(entry.message == "Hello Gemini!")
    }

    @Test func testParseSystemLine() async throws {
        let line = "[14:32:02] -!- Douglas joined"
        guard let entry = LogEntry.parseLine(line, channel: "#general", id: 2) else {
            Issue.record("Failed to parse system line")
            return
        }

        #expect(entry.id == 2)
        #expect(entry.channel == "#general")
        #expect(entry.timestamp == "14:32:02")
        #expect(entry.author == "System")
        #expect(entry.message == "-!- Douglas joined")
    }

    @Test func testStringInterning() async throws {
        var authorCache: [String: String] = [:]
        let intern: (String) -> String = { author in
            if let existing = authorCache[author] {
                return existing
            } else {
                authorCache[author] = author
                return author
            }
        }

        let line1 = "[14:32:01] <Douglas> Hello!"
        let line2 = "[14:32:02] <Douglas> World!"

        let entry1 = LogEntry.parseLine(line1, channel: "#general", id: 1, intern: intern)
        let entry2 = LogEntry.parseLine(line2, channel: "#general", id: 2, intern: intern)

        #expect(entry1 != nil)
        #expect(entry2 != nil)
        
        #expect(entry1?.author == "Douglas")
        #expect(entry2?.author == "Douglas")
    }
}
