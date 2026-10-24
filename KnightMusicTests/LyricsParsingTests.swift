import XCTest
#if canImport(KnightMusic)
@testable import KnightMusic
#endif

final class LyricsParsingTests: XCTestCase {
    // MARK: TTML

    func testWordTimedTTMLKeepsSyllablesAsOneWordAndDropsBackingAndTranslation() throws {
        let doc = try XCTUnwrap(TtmlParser.parse(try Fixture.string("lyrics_word.ttml")))
        XCTAssertEqual(doc.timing, .word)
        XCTAssertEqual(doc.lines.count, 2)

        let line = doc.lines[0]
        XCTAssertEqual(line.startMs, 12_000)
        XCTAssertEqual(line.endMs, 14_250)
        XCTAssertEqual(line.text, "Morning comes enough,")
        XCTAssertEqual(line.words.map(\.text), ["Morning ", "comes ", "e", "nough,"])
        XCTAssertEqual(line.words.map(\.startMs), [12_000, 12_400, 12_700, 13_100])
        XCTAssertEqual(line.words.last?.endMs, 13_600)

        XCTAssertEqual(doc.lines[1].startMs, 60_500)
        XCTAssertEqual(doc.lines[1].text, "Last light")
    }

    func testLineTimedTTML() throws {
        let doc = try XCTUnwrap(TtmlParser.parse(try Fixture.string("lyrics_line.ttml")))
        XCTAssertEqual(doc.timing, .line)
        XCTAssertEqual(doc.lines.map(\.text), ["First line of the verse", "Second line & more"])
        XCTAssertEqual(doc.lines.map(\.startMs), [26_491, 30_760])
        XCTAssertTrue(doc.lines.allSatisfy { $0.words.isEmpty })
    }

    func testTTMLClockValues() {
        XCTAssertEqual(TtmlParser.milliseconds("12.5"), 12_500)
        XCTAssertEqual(TtmlParser.milliseconds("1:02.500"), 62_500)
        XCTAssertEqual(TtmlParser.milliseconds("01:00:01.25"), 3_601_250)
        XCTAssertEqual(TtmlParser.milliseconds("750ms"), 750)
        XCTAssertEqual(TtmlParser.milliseconds("3s"), 3_000)
        XCTAssertNil(TtmlParser.milliseconds(""))
        XCTAssertNil(TtmlParser.milliseconds("abc"))
    }

    func testHostileClockValuesNeverTrap() {
        XCTAssertNil(TtmlParser.milliseconds("inf"))
        XCTAssertNil(TtmlParser.milliseconds("nan"))
        XCTAssertNil(TtmlParser.milliseconds("1e999"))
        XCTAssertNil(TtmlParser.milliseconds("99999999999999999999"))
        XCTAssertNil(TtmlParser.milliseconds("-1"))
        XCTAssertNil(TtmlParser.milliseconds("infms"))
        let doc = TtmlParser.parse(#"<tt><body><div><p begin="1e999" end="2">bad</p><p begin="1.5" end="2"><span begin="nan" end="inf">x</span></p><p begin="3" end="4">ok</p></div></body></tt>"#)
        XCTAssertEqual(doc?.lines.map(\.text), ["x", "ok"])
    }

    func testMalformedTTML() {
        XCTAssertNil(TtmlParser.parse(""))
        XCTAssertNil(TtmlParser.parse("<tt><body><p begin=\"1\">unclosed"))
        XCTAssertNil(TtmlParser.parse("<tt><body></body></tt>"))
    }

    // MARK: LRC

    func testSyncedLRC() throws {
        let doc = try XCTUnwrap(LrcParser.parse(try Fixture.string("lyrics_synced.lrc")))
        XCTAssertEqual(doc.timing, .line)
        XCTAssertEqual(doc.lines.map(\.startMs), [12_340, 15_800, 21_000, 62_500])
        XCTAssertEqual(doc.lines.map(\.text), ["First synced line", "Second synced line", "", "Third line after a break"])
    }

    func testPlainTextIsUntimed() throws {
        let doc = try XCTUnwrap(LrcParser.plain("One\n\nTwo\n"))
        XCTAssertEqual(doc.timing, .none)
        XCTAssertEqual(doc.lines.map(\.text), ["One", "", "Two"])
        XCTAssertNil(LrcParser.plain("   \n "))
    }

    func testLRCWithoutStampsIsNotSynced() {
        XCTAssertNil(LrcParser.parse("just words\nno stamps"))
        XCTAssertNil(LrcParser.parse(""))
    }

    // MARK: Enhanced LRC (what LyricsView reads)

    func testEnhancedLRCEncodingIncludesClosingStamp() throws {
        let doc = try XCTUnwrap(TtmlParser.parse(try Fixture.string("lyrics_word.ttml")))
        XCTAssertEqual(EnhancedLrc.encode(doc.lines[0]),
                       "<00:12.000>Morning <00:12.400>comes <00:12.700>e<00:13.100>nough,<00:13.600>")
        XCTAssertEqual(EnhancedLrc.encode(.init(startMs: 1_000, endMs: nil, text: "plain", words: [])), "plain")
        XCTAssertEqual(EnhancedLrc.stamp(61_005), "<01:01.005>")
    }

    // MARK: Provider payloads & matching

    func testBetterLyricsWrapper() throws {
        let ttml = try XCTUnwrap(LyricsEnvelope.unwrap(try Fixture.data("lyrics_betterlyrics.json")))
        let doc = try XCTUnwrap(TtmlParser.parse(ttml))
        XCTAssertEqual(doc.timing, .word)
        XCTAssertEqual(doc.lines.first?.text, "Hello world")
        XCTAssertNil(LyricsEnvelope.unwrap(Data(#"{"error":"API key required"}"#.utf8)))
        XCTAssertNil(LyricsEnvelope.unwrap(Data()))
        XCTAssertEqual(LyricsEnvelope.unwrap(Data("<tt></tt>".utf8)), "<tt></tt>")
    }

    func testLrcRedPicksSameRecording() throws {
        let hits = try JSONDecoder().decode(LrcRedSearch.self, from: try Fixture.data("lrcred_search.json")).hits
        let best = LyricsMatcher.bestLrcRedHit(hits, title: "Instant Crush (feat. Julian Casablancas)", artist: "Daft Punk", durationSeconds: 338)
        XCTAssertEqual(best?.isrc, "USQX91300105")
        // A different recording (Live) or another song is never taken.
        XCTAssertNil(LyricsMatcher.bestLrcRedHit(hits, title: "Instant Crush", artist: "Someone Else", durationSeconds: 338))
        XCTAssertNil(LyricsMatcher.bestLrcRedHit(hits, title: "Instant Crush", artist: "Daft Punk", durationSeconds: 200))
        XCTAssertEqual(LyricsMatcher.bestLrcRedHit(hits, title: "Instant Crush (Live)", artist: "Daft Punk", durationSeconds: 338)?.isrc, "GBLIV1300001")
    }

    func testTitleCleaningForYouTubeNoise() {
        XCTAssertEqual(LyricsMatcher.cleanTitle("Song Name (Official Video)"), "Song Name")
        XCTAssertEqual(LyricsMatcher.cleanTitle("Song Name | Official Audio"), "Song Name")
        XCTAssertEqual(LyricsMatcher.cleanTitle("Song [HD] (Lyrics)"), "Song")
        XCTAssertEqual(LyricsMatcher.cleanTitle("Get Lucky (feat. Pharrell Williams)"), "Get Lucky")
        XCTAssertEqual(LyricsMatcher.cleanTitle("(Official Video)"), "(Official Video)")
        XCTAssertEqual(LyricsMatcher.primaryArtist("Daft Punk, Pharrell Williams & Nile Rodgers"), "Daft Punk")
        XCTAssertEqual(LyricsMatcher.primaryArtist("Solo"), "Solo")
    }

    func testRankingPrefersWordThenLineThenPlain() {
        let word = LyricsDocument(timing: .word, lines: [.init(startMs: 0, endMs: 1, text: "a", words: [.init(startMs: 0, endMs: 1, text: "a")])])
        let line = LyricsDocument(timing: .line, lines: [.init(startMs: 0, endMs: nil, text: "a", words: [])])
        let plain = LyricsDocument(timing: .none, lines: [.init(startMs: nil, endMs: nil, text: "a", words: [])])
        XCTAssertEqual(LyricsRanker.best([plain, nil, line, word])?.timing, .word)
        XCTAssertEqual(LyricsRanker.best([plain, line])?.timing, .line)
        XCTAssertEqual(LyricsRanker.best([nil, plain])?.timing, LyricsDocument.Timing.none)
        XCTAssertNil(LyricsRanker.best([nil, nil]))
        // Earlier sources win ties.
        let otherLine = LyricsDocument(timing: .line, lines: [.init(startMs: 5, endMs: nil, text: "b", words: [])])
        XCTAssertEqual(LyricsRanker.best([otherLine, line])?.lines.first?.text, "b")
    }
}
