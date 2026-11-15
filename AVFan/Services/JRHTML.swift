//
//  JRHTML.swift
//  AVFan
//
//  Small inert HTML tree used by SubtitleCat parsing. Ported from AVDB's
//  shared helper; ranking/page types are not included.
//

import Foundation

enum JRError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

// Small inert HTML tree: handles quoted attributes and void tags, strips scripts/styles.
// Only known metadata/card selectors are consumed; there is no browser or JS runtime.
final class JRNode {
    let tag: String; let attrs: [String: String]
    var children: [JRNode] = []; var raw = ""
    init(_ tag: String, _ attrs: [String: String] = [:]) { self.tag = tag; self.attrs = attrs }
    private var cachedText: String?
    var text: String {
        if let cachedText { return cachedText }
        let value = JRHTML.text(raw + children.map(\.text).joined(separator: " "))
        cachedText = value
        return value
    }
    func all(_ predicate: (JRNode) -> Bool) -> [JRNode] {
        var found: [JRNode] = []
        var pending = Array(children.reversed())
        while let node = pending.popLast() {
            if predicate(node) { found.append(node) }
            pending.append(contentsOf: node.children.reversed())
        }
        return found
    }
    func has(_ name: String) -> Bool { attrs[name] != nil }
    func cls(_ value: String) -> Bool { (attrs["class"] ?? "").split(separator: " ").contains(Substring(value)) }
}
enum JRHTML {
    private static let expressions = NSCache<NSString, NSRegularExpression>()
    static func matches(_ pattern: String, _ s: String) -> [[String]] {
        let key = pattern as NSString
        let re: NSRegularExpression
        if let cached = expressions.object(forKey: key) { re = cached }
        else {
            guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
            expressions.countLimit = 32
            expressions.setObject(compiled, forKey: key)
            re = compiled
        }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)
    private static let numericEntity = try! NSRegularExpression(pattern: #"&#(x[0-9a-f]+|[0-9]+);"#, options: .caseInsensitive)
    static func text(_ input: String) -> String {
        var s = input
        if s.contains("&") {
            for (a,b) in [("&amp;","&"),("&quot;","\""),("&#39;","'"),("&apos;","'"),("&lt;","<"),("&gt;",">"),("&nbsp;"," ")] { s = s.replacingOccurrences(of: a, with: b) }
            let ns = s as NSString
            let output = NSMutableString(string: s)
            // Reverse range replacement is bounded, unlike rescanning the whole
            // string for every numeric entity (including duplicate entities).
            for m in numericEntity.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let value = ns.substring(with: m.range(at: 1))
                let hex = value.lowercased().hasPrefix("x")
                if let n = UInt32(hex ? String(value.dropFirst()) : value, radix: hex ? 16 : 10), let scalar = UnicodeScalar(n) {
                    output.replaceCharacters(in: m.range, with: String(scalar))
                }
            }
            s = output as String
        }
        return whitespace.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static let inertBlocks = try! NSRegularExpression(pattern: #"<(script|style|template)\b[^>]*>.*?</\1\s*>|<!--.*?-->"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    static func tree(_ html: String) throws -> JRNode {
        let inert = inertBlocks.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: "")
        let root = JRNode("root"); var stack = [root]
        let void: Set<String> = ["img","input","meta","link","br","hr","source","wbr","area","embed"]
        var tokenCount = 0
        for token in tokens(inert) {
            tokenCount += 1
            if tokenCount % 1024 == 0 { try Task.checkCancellation() }
            guard tokenCount <= 500_000, stack.count <= 128 else { throw JRError.message("页面结构超出安全解析限制，请在来源浏览器查看完整内容") }
            let t = token
            if t.hasPrefix("</") {
                let name = t.dropFirst(2).prefix { $0.isLetter || $0.isNumber }.lowercased()
                if let idx = stack.lastIndex(where: { $0.tag == name }), idx > 0 { stack.removeSubrange(idx...) }
            } else if t.hasPrefix("<") {
                guard let name = matches(#"^<([a-z][a-z0-9-]*)"#,t).first?[1] else { continue }
                var attrs: [String:String] = [:]
                for m in matches(#"\s([a-z_:][a-z0-9_:.-]*)(?:\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+)))?"#,t) { attrs[m[1].lowercased()] = text(m[2].isEmpty ? (m[3].isEmpty ? m[4] : m[3]) : m[2]) }
                let n = JRNode(name.lowercased(), attrs); stack.last!.children.append(n)
                if !void.contains(n.tag) && !t.hasSuffix("/>") { stack.append(n) }
            } else { let n = JRNode("text"); n.raw = t; stack.last!.children.append(n) }
        }
        return root
    }
    // Quote-aware split. A tag regex stops at the first unquoted '>' inside a real attribute.
    static func tokens(_ html: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inTag = false
        var quote: Character?
        for ch in html {
            if inTag {
                current.append(ch)
                if let q = quote {
                    if ch == q { quote = nil }
                } else if ch == "\"" || ch == "'" {
                    quote = ch
                } else if ch == ">" {
                    result.append(current)
                    current = ""
                    inTag = false
                }
            } else if ch == "<" {
                if !current.isEmpty { result.append(current); current = "" }
                current = "<"
                inTag = true
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
