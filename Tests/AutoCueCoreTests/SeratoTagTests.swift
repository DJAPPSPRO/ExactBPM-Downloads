import XCTest
@testable import AutoCueCore

final class SeratoTagTests: XCTestCase {
    let cues = [
        HotCue(index: 0, name: "Intro", milliseconds: 581, color: 0x00CC00, bar: 1),
        HotCue(index: 1, name: "Drop 1", milliseconds: 19783, color: 0xCC0000, bar: 9),
        HotCue(index: 2, name: "Outro", milliseconds: 173403, color: 0xCC8800, bar: 73),
    ]

    /// Fake MP3: an ID3v2.3 tag with one text frame, then "audio" bytes.
    func fakeMP3() -> Data {
        var tag = ID3Tag(version: 3)
        var title = Data([0]); title.append(contentsOf: Array("Test".utf8))
        tag.frames = [ID3Frame(id: "TIT2", flags: [0, 0], body: title)]
        var d = tag.serialized(padding: 100)
        d.append(Data((0..<5000).map { UInt8($0 % 251) }))
        return d
    }

    func testMarkers2RoundTrip() throws {
        var m = SeratoMarkers2()
        m.replaceCues(cues)
        let obj = m.serialized()
        XCTAssertGreaterThanOrEqual(obj.count, 470)
        let back = try XCTUnwrap(SeratoMarkers2.parse(obj))
        XCTAssertEqual(back.cues.map(\.name), cues.map(\.name))
        XCTAssertEqual(back.cues.map(\.milliseconds), cues.map(\.milliseconds))
        XCTAssertEqual(back.cues.map(\.color), cues.map(\.color))
        XCTAssertEqual(back.entries.first?.name, "COLOR")
        XCTAssertEqual(back.entries.last?.name, "BPMLOCK")
    }

    func testRewriteKeepsAudioAndFrames() throws {
        let original = fakeMP3()
        let origTag = try ID3Tag.parse(original)
        let out = try SeratoCueFile.rewrite(fileData: original, cues: cues)
        let tag = try ID3Tag.parse(out)
        XCTAssertEqual(out[tag.audioStart...], original[origTag.audioStart...])
        XCTAssertEqual(tag.frames.first?.id, "TIT2")
        let geob = try XCTUnwrap(tag.frames.first { $0.id == "GEOB" })
        let g = try XCTUnwrap(GEOBFrame.parse(geob.body))
        XCTAssertEqual(g.description, "Serato Markers2")
        XCTAssertEqual(SeratoMarkers2.parse(g.object)?.cues.count, 3)
        // rewriting again replaces instead of stacking a second GEOB
        let twice = try SeratoCueFile.rewrite(fileData: out, cues: Array(cues.prefix(2)))
        let t2 = try ID3Tag.parse(twice)
        XCTAssertEqual(t2.frames.filter { $0.id == "GEOB" }.count, 1)
        XCTAssertEqual(twice[t2.audioStart...], original[origTag.audioStart...])
    }

    func testFileWithoutTagGetsOne() throws {
        let audio = Data((0..<3000).map { UInt8($0 % 200) })
        let out = try SeratoCueFile.rewrite(fileData: audio, cues: cues)
        let tag = try ID3Tag.parse(out)
        XCTAssertEqual(Data(out[tag.audioStart...]), audio)
        XCTAssertEqual(tag.frames.count, 1)
    }

    /// Payload produced by the Python reference writer used for the first three hand-checked tracks.
    func testParsesReferencePayload() throws {
        let b64 = "AQFDT0xPUgAAAAAEAP///0NVRQAAAAASAAAAAAJFAADMAAAASW50cm8AQlBNTE9DSwAAAAAB\nAAA"
        var obj = Data([1, 1]); obj.append(contentsOf: Array(b64.utf8)); obj.append(0)
        let m = try XCTUnwrap(SeratoMarkers2.parse(obj))
        XCTAssertEqual(m.cues.first?.name, "Intro")
        XCTAssertEqual(m.cues.first?.milliseconds, 581)
        XCTAssertEqual(m.cues.first?.color, 0x00CC00)

        // and our writer produces exactly the same bytes
        var fresh = SeratoMarkers2()
        fresh.replaceCues([HotCue(index: 0, name: "Intro", milliseconds: 581, color: 0x00CC00, bar: 1)])
        var expected = obj
        expected.append(Data(count: 470 - expected.count))
        XCTAssertEqual(fresh.serialized(), expected)
    }

    func testCueCountAndFirstBeatFormatting() throws {
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0].milliseconds, 581)
        XCTAssertEqual(cues[0].name, "Intro")
        XCTAssertEqual(cues[0].bar, 1)
    }
}
