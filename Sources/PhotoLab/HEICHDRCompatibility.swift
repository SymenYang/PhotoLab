import Foundation
import ImageIO

/// Read-only file access; normalization changes only a private in-memory container.
/// Deliberately limited to the gain-map layout validated by our Hasselblad fixtures.
enum HEICHDRCompatibility {
    static func source(url: URL, hdr: Bool) -> CGImageSource? {
        if hdr, ["heic", "heif"].contains(url.pathExtension.lowercased()),
           let original = try? Data(contentsOf: url, options: .mappedIfSafe),
           let normalized = normalizedData(original),
           let source = CGImageSourceCreateWithData(normalized as CFData, nil) {
            return source
        }
        return CGImageSourceCreateWithURL(url as CFURL, nil)
    }

    static func normalizedData(_ original: Data) -> Data? {
        try? normalize(original)
    }

    private enum Unsupported: Error { case layout }
    private struct Box {
        let type: String
        let start: Int
        let end: Int
        let headerSize: Int
        var body: Int { start + headerSize }
    }
    private struct Extent {
        let item: Int
        let method: Int
        let offset: Int
        let length: Int
        let field: Int
    }
    private static func require(_ condition: Bool) throws {
        if !condition { throw Unsupported.layout }
    }
    private static func uint(_ data: Data, _ offset: Int, _ count: Int) throws -> Int {
        try require(offset >= 0 && count > 0 && count <= 4 && offset <= data.count - count)
        return data[offset..<offset + count].reduce(0) { ($0 << 8) | Int($1) }
    }
    private static func bytes(_ value: Int, _ count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private static func boxes(_ data: Data, _ range: Range<Int>) throws -> [Box] {
        try require(range.lowerBound >= 0 && range.upperBound <= data.count)
        var result = [Box](), p = range.lowerBound
        while p < range.upperBound {
            try require(range.upperBound - p >= 8 && result.count < 4096)
            var size = try uint(data, p, 4)
            var headerSize = 8
            if size == 1 {
                try require(range.upperBound - p >= 16)
                let high = try uint(data, p + 8, 4), low = try uint(data, p + 12, 4)
                try require(high <= Int.max >> 32)
                size = (high << 32) | low
                headerSize = 16
            }
            try require(size >= headerSize && size <= range.upperBound - p)
            result.append(Box(type: String(decoding: data[p + 4..<p + 8], as: UTF8.self), start: p, end: p + size, headerSize: headerSize))
            p += size
        }
        return result
    }
    private static func one(_ boxes: [Box], _ type: String) throws -> Box {
        let matching = boxes.filter { $0.type == type }
        try require(matching.count == 1)
        return matching[0]
    }
    private static func payload(_ data: Data, _ box: Box) -> Data { Data(data[box.body..<box.end]) }
    private static func box(_ type: String, _ body: Data) -> Data {
        bytes(body.count + 8, 4) + Data(type.utf8) + body
    }
    private static func replaceChildren(_ data: Data, _ children: [Box], _ updates: [String: Data]) -> Data {
        var result = Data()
        for child in children { result.append(updates[child.type].map { box(child.type, $0) } ?? Data(data[child.start..<child.end])) }
        return result
    }

    private static func normalize(_ original: Data) throws -> Data {
        let top = try boxes(original, 0..<original.count)
        let ftyp = try one(top, "ftyp")
        try require(ftyp.end - ftyp.body >= 8)
        let brands = stride(from: ftyp.body, to: ftyp.end - 3, by: 4).map {
            String(decoding: original[$0..<$0 + 4], as: UTF8.self)
        }
        try require(brands.contains("heic") || brands.contains("heix"))
        let metaBox = try one(top, "meta"), mdat = try one(top, "mdat")
        // Bound parser work; only consume existing padding, never move encoded media.
        try require(metaBox.headerSize == 8 && metaBox.end - metaBox.body <= 1024 * 1024)
        guard let free = top.first(where: { $0.type == "free" && $0.start == metaBox.end && $0.end == mdat.start }) else { throw Unsupported.layout }
        let meta = payload(original, metaBox)
        try require(try uint(meta, 0, 4) == 0)
        let children = try boxes(meta, 4..<meta.count)
        let pitm = payload(meta, try one(children, "pitm"))
        try require(pitm.count == 6 && (try uint(pitm, 0, 4)) == 0)
        let primary = try uint(pitm, 4, 2)

        let iinf = payload(meta, try one(children, "iinf"))
        try require(iinf.count >= 6 && (try uint(iinf, 0, 4)) == 0)
        let infos = try boxes(iinf, 6..<iinf.count)
        try require(infos.count == (try uint(iinf, 4, 2)))
        var types = [Int: String]()
        for info in infos {
            try require(info.type == "infe")
            let p = payload(iinf, info)
            try require(p.count >= 12 && p[0] == 2 && (try uint(p, 6, 2)) == 0)
            let id = try uint(p, 4, 2)
            try require(types[id] == nil)
            types[id] = String(decoding: p[8..<12], as: UTF8.self)
        }
        let tmaps = types.filter { $0.value == "tmap" }.map(\.key)
        try require(tmaps.count == 1 && types[primary] == "grid")
        let tmap = tmaps[0]
        let iref = payload(meta, try one(children, "iref"))
        try require(try uint(iref, 0, 4) == 0)
        var references = [(String, Int, [Int])]()
        for ref in try boxes(iref, 4..<iref.count) {
            let p = payload(iref, ref), id = try uint(p, 0, 2), count = try uint(p, 2, 2)
            try require(p.count == 4 + count * 2)
            references.append((ref.type, id, try (0..<count).map { try uint(p, 4 + $0 * 2, 2) }))
        }
        let derived = references.filter { $0.0 == "dimg" && $0.1 == tmap }
        try require(derived.count == 1 && derived[0].2.count == 2 && derived[0].2[0] == primary)
        let gain = derived[0].2[1]
        try require(types[gain] == "grid" && references.contains { $0.0 == "auxl" && $0.1 == gain && $0.2 == [primary] })

        let iprp = payload(meta, try one(children, "iprp"))
        let pc = try boxes(iprp, 0..<iprp.count)
        let ipco = payload(iprp, try one(pc, "ipco"))
        let props = try boxes(ipco, 0..<ipco.count)
        try require(props.count < 126)
        let ipma = payload(iprp, try one(pc, "ipma"))
        try require(try uint(ipma, 0, 4) == 0)
        let entryCount = try uint(ipma, 4, 4)
        try require(entryCount <= 4096)
        var associations = [Int: [Int]](), order = [Int](), p = 8
        for _ in 0..<entryCount {
            let id = try uint(ipma, p, 2), count = try uint(ipma, p + 2, 1)
            p += 3
            try require(p <= ipma.count - count && associations[id] == nil)
            let entries = ipma[p..<p + count].map(Int.init)
            try require(entries.allSatisfy { ($0 & 127) > 0 && ($0 & 127) <= props.count })
            associations[id] = entries; order.append(id); p += count
        }
        try require(p == ipma.count)
        func properties(_ id: Int) -> [Box] { (associations[id] ?? []).map { props[($0 & 127) - 1] } }
        func geometry(_ id: Int) throws -> (Int, Int, Int) {
            let properties = properties(id)
            try require(!properties.contains { ["imir", "clap"].contains($0.type) })
            let size = payload(ipco, try one(properties, "ispe"))
            let rotation = payload(ipco, try one(properties, "irot"))
            try require(size.count == 12 && (try uint(size, 0, 4)) == 0 && rotation.count == 1 && rotation[0] == 1)
            let w = try uint(size, 4, 4), h = try uint(size, 8, 4)
            try require(w > h && h > 0)
            return (w, h, Int(rotation[0]))
        }
        let baseSize = try geometry(primary), tmapSize = try geometry(tmap), gainSize = try geometry(gain)
        try require(baseSize == tmapSize && gainSize.0 == baseSize.0 / 2 && abs(gainSize.1 - baseSize.1 / 2) <= 1)
        let aux = payload(ipco, try one(properties(gain), "auxC"))
        try require(aux == Data(repeating: 0, count: 4) + Data("urn:iso:std:iso:ts:21496:-1\0".utf8))

        var iloc = payload(meta, try one(children, "iloc"))
        try require(iloc.count >= 8 && iloc.prefix(6) == Data([1, 0, 0, 0, 0x44, 0]))
        let itemCount = try uint(iloc, 6, 2)
        try require(itemCount <= 4096)
        let idat = payload(meta, try one(children, "idat"))
        var extents = [Extent](), seen = Set<Int>(); p = 8
        for _ in 0..<itemCount {
            let id = try uint(iloc, p, 2), method = try uint(iloc, p + 2, 2)
            try require(method <= 1 && (try uint(iloc, p + 4, 2)) == 0 && seen.insert(id).inserted)
            let count = try uint(iloc, p + 6, 2); p += 8
            try require(count > 0 && count <= 4096)
            for _ in 0..<count {
                let offset = try uint(iloc, p, 4), length = try uint(iloc, p + 4, 4)
                if method == 1 { try require(offset <= idat.count && length <= idat.count - offset) }
                else { try require(offset >= mdat.body && offset <= mdat.end && length <= mdat.end - offset) }
                extents.append(Extent(item: id, method: method, offset: offset, length: length, field: p)); p += 8
            }
        }
        try require(p == iloc.count)
        let tmExtents = extents.filter { $0.item == tmap }
        try require(tmExtents.count == 1 && tmExtents[0].method == 1)
        let tm = tmExtents[0]
        try require(tm.length == 61 || tm.length == 62)
        let metadata = Data(idat[tm.offset..<tm.offset + tm.length])
        let iso = tm.length == 62 ? Data(metadata.dropFirst()) : metadata
        try require((tm.length == 61 || metadata[0] == 0) && iso.prefix(5) == Data(repeating: 0, count: 5))
        for i in 0..<7 { try require(try uint(iso, 9 + i * 8, 4) > 0) }
        // Do not insert into overlapping/shared item extents.
        for e in extents where e.method == 1 && e.item != tmap {
            try require(e.offset + e.length <= tm.offset || e.offset >= tm.offset + tm.length)
        }

        var newIPCO = ipco
        newIPCO.append(box("ispe", Data(repeating: 0, count: 4) + bytes(baseSize.1, 4) + bytes(baseSize.0, 4)))
        var newIPMA = Data(ipma.prefix(8))
        for id in order {
            var entries = associations[id]!
            if id == tmap {
                entries.removeAll { ["ispe", "irot"].contains(props[($0 & 127) - 1].type) }
                entries.append(props.count + 1)
            }
            try require(entries.count <= 255)
            newIPMA.append(bytes(id, 2) + bytes(entries.count, 1) + Data(entries.map { UInt8($0) }))
        }
        var updates = ["iprp": replaceChildren(iprp, pc, ["ipco": newIPCO, "ipma": newIPMA])]
        if tm.length == 61 {
            var newIDAT = idat
            newIDAT.insert(0, at: tm.offset)
            for e in extents where e.method == 1 {
                if e.item == tmap { iloc.replaceSubrange(e.field + 4..<e.field + 8, with: bytes(62, 4)) }
                else if e.offset >= tm.offset { iloc.replaceSubrange(e.field..<e.field + 4, with: bytes(e.offset + 1, 4)) }
            }
            updates["idat"] = newIDAT; updates["iloc"] = iloc
        }
        let newMeta = box("meta", Data(meta.prefix(4)) + replaceChildren(meta, children, updates))
        let freeSize = mdat.start - metaBox.start - newMeta.count
        try require(freeSize >= 8 && freeSize <= free.end - free.start)
        let header = newMeta + box("free", Data(repeating: 0, count: freeSize - 8))
        var result = original
        result.replaceSubrange(metaBox.start..<mdat.start, with: header)
        return result
    }
}
