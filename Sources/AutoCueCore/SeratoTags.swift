import Foundation

// MARK: - ID3v2 container (v2.3 / v2.4)

struct ID3Frame {
    var id: String
    var flags: [UInt8]
    var body: Data
}

struct ID3Tag {
    var version: UInt8 = 3
    var frames: [ID3Frame] = []
    /// Byte offset where the audio starts in the original file.
    var audioStart: Int = 0

    static func syncsafe(_ b: Data, _ at: Int) -> Int {
        (Int(b[at]) << 21) | (Int(b[at + 1]) << 14) | (Int(b[at + 2]) << 7) | Int(b[at + 3])
    }

    static func be32(_ b: Data, _ at: Int) -> Int {
        (Int(b[at]) << 24) | (Int(b[at + 1]) << 16) | (Int(b[at + 2]) << 8) | Int(b[at + 3])
    }

    static func syncsafeBytes(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
    }

    static func be32Bytes(_ n: Int) -> [UInt8] {
        [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    }

    /// Parses the tag at the start of `data`. A file with no ID3v2 tag yields an empty v2.3 tag.
    static func parse(_ input: Data) throws -> ID3Tag {
        let data = Data(input) // re-base indices at 0
        guard data.count >= 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return ID3Tag() }
        let ver = data[3], flags = data[5]
        guard ver == 3 || ver == 4 else {
            throw AutoCueError.unsupportedFile("ID3v2.\(ver) tag: re-save the file's tags (e.g. in Music or Mp3tag) and try again")
        }
        guard flags & 0x80 == 0 else {
            throw AutoCueError.unsupportedFile("Tag uses ID3 unsynchronisation, which AutoCue doesn't rewrite")
        }
        let size = syncsafe(data, 6)
        let end = min(10 + size, data.count)
        var pos = 10
        if flags & 0x40 != 0, data.count >= 14 { // extended header
            pos += ver == 3 ? be32(data, 10) + 4 : syncsafe(data, 10)
        }
        var tag = ID3Tag(version: ver)
        while pos + 10 <= end && data[pos] != 0 {
            guard let id = String(bytes: data[pos..<(pos + 4)], encoding: .isoLatin1) else { break }
            let fsz = ver == 3 ? be32(data, pos + 4) : syncsafe(data, pos + 4)
            guard fsz >= 0, pos + 10 + fsz <= end else { break }
            tag.frames.append(ID3Frame(id: id, flags: [data[pos + 8], data[pos + 9]], body: data[(pos + 10)..<(pos + 10 + fsz)]))
            pos += 10 + fsz
        }
        tag.audioStart = 10 + size + ((ver == 4 && flags & 0x10 != 0) ? 10 : 0)
        return tag
    }

    func serialized(padding: Int = 2048) -> Data {
        var body = Data()
        for f in frames {
            body.append(contentsOf: Array(f.id.utf8.prefix(4)))
            body.append(contentsOf: version == 3 ? ID3Tag.be32Bytes(f.body.count) : ID3Tag.syncsafeBytes(f.body.count))
            body.append(contentsOf: f.flags)
            body.append(f.body)
        }
        body.append(Data(count: padding))
        var out = Data([0x49, 0x44, 0x33, version, 0, 0])
        out.append(contentsOf: ID3Tag.syncsafeBytes(body.count))
        out.append(body)
        return out
    }
}

/// GEOB frame body: encoding, MIME, filename, description, object data.
struct GEOBFrame {
    var mime: String
    var filename: String
    var description: String
    var object: Data

    static func parse(_ body: Data) -> GEOBFrame? {
        let b = Data(body)
        guard b.count > 1 else { return nil }
        let enc = b[0]
        var pos = 1
        func latin1String() -> String? {
            guard let z = b[pos...].firstIndex(of: 0) else { return nil }
            let s = String(bytes: b[pos..<z], encoding: .isoLatin1)
            pos = z + 1
            return s
        }
        func encodedString() -> String? {
            if enc == 1 || enc == 2 { // UTF-16: double-null terminated, 2-byte aligned
                var i = pos
                while i + 1 < b.count && !(b[i] == 0 && b[i + 1] == 0) { i += 2 }
                guard i + 1 < b.count else { return nil }
                let s = String(bytes: b[pos..<i], encoding: enc == 1 ? .utf16 : .utf16BigEndian)
                pos = i + 2
                return s ?? ""
            }
            guard let z = b[pos...].firstIndex(of: 0) else { return nil }
            let s = String(bytes: b[pos..<z], encoding: enc == 3 ? .utf8 : .isoLatin1)
            pos = z + 1
            return s ?? ""
        }
        guard let mime = latin1String(), let fn = encodedString(), let desc = encodedString() else { return nil }
        return GEOBFrame(mime: mime, filename: fn, description: desc, object: b[pos...])
    }

    func serialized() -> Data {
        var d = Data([0])
        d.append(contentsOf: Array(mime.utf8)); d.append(0)
        d.append(contentsOf: Array(filename.utf8)); d.append(0)
        d.append(contentsOf: Array(description.utf8)); d.append(0)
        d.append(object)
        return d
    }
}

// MARK: - Serato Markers2

struct SeratoMarkers2 {
    struct Entry { var name: String; var data: Data }
    var entries: [Entry] = []

    static func parse(_ object: Data) -> SeratoMarkers2? {
        let o = Data(object)
        guard o.count > 2, o[0] == 1, o[1] == 1 else { return nil }
        let end = o[2...].firstIndex(of: 0) ?? o.count
        var b64 = String(decoding: o[2..<end], as: UTF8.self).replacingOccurrences(of: "\n", with: "")
        switch b64.count % 4 {
        case 1: b64 += "A=="
        case 2: b64 += "=="
        case 3: b64 += "="
        default: break
        }
        guard let p = Data(base64Encoded: b64), p.count >= 2, p[0] == 1, p[1] == 1 else { return nil }
        var m = SeratoMarkers2()
        var i = 2
        while i < p.count && p[i] != 0 {
            guard let z = p[i...].firstIndex(of: 0), z + 5 <= p.count else { break }
            let name = String(decoding: p[i..<z], as: UTF8.self)
            let len = ID3Tag.be32(p, z + 1)
            guard z + 5 + len <= p.count else { break }
            m.entries.append(Entry(name: name, data: p[(z + 5)..<(z + 5 + len)]))
            i = z + 5 + len
        }
        return m
    }

    static func cueData(_ c: HotCue) -> Data {
        var d = Data([0, UInt8(c.index)])
        d.append(contentsOf: ID3Tag.be32Bytes(c.milliseconds))
        d.append(0)
        d.append(contentsOf: [UInt8((c.color >> 16) & 0xFF), UInt8((c.color >> 8) & 0xFF), UInt8(c.color & 0xFF)])
        d.append(contentsOf: [0, 0])
        d.append(contentsOf: Array(c.name.utf8)); d.append(0)
        return d
    }

    var cues: [HotCue] {
        entries.compactMap { e -> HotCue? in
            let d = Data(e.data)
            guard e.name == "CUE", d.count >= 13 else { return nil }
            let ms = ID3Tag.be32(d, 2)
            let color = (UInt32(d[7]) << 16) | (UInt32(d[8]) << 8) | UInt32(d[9])
            let nameEnd = d[12...].firstIndex(of: 0) ?? d.count
            return HotCue(index: Int(d[1]), name: String(decoding: d[12..<nameEnd], as: UTF8.self),
                          milliseconds: ms, color: color, bar: 0)
        }
    }

    /// Replaces every hot cue, keeping loops, flips, track color and BPM lock untouched.
    mutating func replaceCues(_ cues: [HotCue]) {
        let others = entries.filter { $0.name != "CUE" }
        var out: [Entry] = []
        if let color = others.first(where: { $0.name == "COLOR" }) { out.append(color) }
        else { out.append(Entry(name: "COLOR", data: Data([0, 0xFF, 0xFF, 0xFF]))) }
        out += cues.map { Entry(name: "CUE", data: SeratoMarkers2.cueData($0)) }
        out += others.filter { $0.name != "COLOR" }
        if !out.contains(where: { $0.name == "BPMLOCK" }) { out.append(Entry(name: "BPMLOCK", data: Data([0]))) }
        entries = out
    }

    func serialized() -> Data {
        var p = Data([1, 1])
        for e in entries {
            p.append(contentsOf: Array(e.name.utf8)); p.append(0)
            p.append(contentsOf: ID3Tag.be32Bytes(e.data.count))
            p.append(e.data)
        }
        p.append(0)
        var b64 = p.base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        var lines: [String] = []
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let next = b64.index(idx, offsetBy: 72, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[idx..<next]))
            idx = next
        }
        var out = Data([1, 1])
        out.append(contentsOf: Array(lines.joined(separator: "\n").utf8))
        out.append(0)
        if out.count < 470 { out.append(Data(count: 470 - out.count)) }
        return out
    }
}

// MARK: - public read/write API

public enum SeratoCueFile {
    static let markersDesc = "Serato Markers2"

    /// Hot cues currently stored in the file's Serato Markers2 tag (empty if none).
    public static func readCues(url: URL) throws -> [HotCue] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let tag = try ID3Tag.parse(data)
        for f in tag.frames where f.id == "GEOB" {
            if let g = GEOBFrame.parse(f.body), g.description == markersDesc, let m = SeratoMarkers2.parse(g.object) {
                return m.cues.sorted { $0.index < $1.index }
            }
        }
        return []
    }

    /// Returns the file bytes with the hot cues replaced. Audio bytes are copied unchanged.
    static func rewrite(fileData data: Data, cues: [HotCue]) throws -> Data {
        var tag = try ID3Tag.parse(data)
        guard tag.audioStart <= data.count else { throw AutoCueError.tagWriteFailed("corrupt ID3 tag size") }
        var markers = SeratoMarkers2()
        var kept: [ID3Frame] = []
        for f in tag.frames {
            if f.id == "GEOB", let g = GEOBFrame.parse(f.body), g.description.hasPrefix("Serato Markers") {
                // Keep loops etc. from an existing Markers2; drop the legacy "Serato Markers_" copy
                // so older readers can't fall back to stale cues.
                if g.description == markersDesc, let m = SeratoMarkers2.parse(g.object) { markers = m }
                continue
            }
            kept.append(f)
        }
        markers.replaceCues(cues)
        let geob = GEOBFrame(mime: "application/octet-stream", filename: "", description: markersDesc, object: markers.serialized())
        kept.append(ID3Frame(id: "GEOB", flags: [0, 0], body: geob.serialized()))
        tag.frames = kept
        var out = tag.serialized()
        out.append(data[(data.startIndex + tag.audioStart)...])
        return out
    }

    /// Writes cues into the file in place (atomic replace), then reads them back to verify.
    public static func write(cues: [HotCue], to url: URL) throws {
        guard url.pathExtension.lowercased() == "mp3" else {
            throw AutoCueError.unsupportedFile("Only MP3 files are supported right now")
        }
        let data = try Data(contentsOf: url)
        let newData = try rewrite(fileData: data, cues: cues)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).autocue-tmp")
        try? FileManager.default.removeItem(at: tmp)
        do {
            try newData.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw AutoCueError.tagWriteFailed(error.localizedDescription)
        }
        let back = try readCues(url: url)
        let ok = back.count == cues.count && zip(back, cues.sorted { $0.index < $1.index }).allSatisfy {
            $0.index == $1.index && $0.milliseconds == $1.milliseconds && $0.name == $1.name && $0.color == $1.color
        }
        if !ok { throw AutoCueError.verifyFailed(url.lastPathComponent) }
    }
}
