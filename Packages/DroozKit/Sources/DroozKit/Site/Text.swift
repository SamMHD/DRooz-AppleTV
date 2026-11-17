import Foundation

/// Small NSRegularExpression wrapper (works on every platform the package targets).
public struct Rx: @unchecked Sendable {
    let re: NSRegularExpression

    public init(_ pattern: String, dotAll: Bool = false) {
        // Patterns are compile-time constants: a bad one is a programming error.
        re = try! NSRegularExpression(pattern: pattern, options: dotAll ? [.dotMatchesLineSeparators] : [])
    }

    /// Capture groups of the first match; index 0 is the whole match, a missing group is "".
    public func firstGroups(in s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Self.groups(m, ns)
    }

    public func allGroups(in s: String) -> [[String]] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { Self.groups($0, ns) }
    }

    public func matches(_ s: String) -> Bool { firstGroups(in: s) != nil }

    public func replace(in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    private static func groups(_ m: NSTextCheckingResult, _ ns: NSString) -> [String] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

/// Helpers for the site's Persian-digit metadata strings.
public enum PersianText {
    private static let persian = Array("۰۱۲۳۴۵۶۷۸۹")
    private static let arabic = Array("٠١٢٣٤٥٦٧٨٩")
    private static let score = Rx(#"([\d.]+)\s*از\s*10"#)
    private static let votes = Rx(#"با\s*([\d.]+)\s*(هزار|میلیون)?\s*رای"#)
    private static let minutesRx = Rx(#"(\d+)\s*دقیقه"#)
    private static let critics = Rx(#"منتقدین\s*:\s*(\d+)"#)
    private static let thousands = Rx(#"(?<=\d)[٬،,](?=\d)"#)
    private static let spaces = Rx(#"\s+"#)

    /// Persian/Arabic digits to ASCII, `٫` to `.`; thousands separators between digits are dropped.
    public static func digits(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if let i = persian.firstIndex(of: c) ?? arabic.firstIndex(of: c) {
                out.append(Character(String(i)))
            } else if c == "٫" {
                out.append(".")
            } else {
                out.append(c)
            }
        }
        return thousands.replace(in: out, with: "")
    }

    /// The form site text is compared in: Arabic ي/ى/ك become Persian ی/ک, ZWNJ and NBSP become a space,
    /// bidi marks and tatweel are dropped, and runs of spaces collapse.
    public static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x064A, 0x0649: out.append("ی")
            case 0x0643: out.append("ک")
            case 0x200C, 0x00A0, 0x202F, 0x2009: out.append(" ")
            case 0x200D, 0x200E, 0x200F, 0x0640, 0xFEFF: break
            default: out.append(u)
            }
        }
        return spaces.replace(in: String(out), with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func rating(_ s: String) -> Rating? {
        let t = digits(s)
        guard let sc = score.firstGroups(in: t).flatMap({ Double($0[1]) }),
              let v = votes.firstGroups(in: t), let base = Double(v[1]) else { return nil }
        let mult: Double = v[2] == "هزار" ? 1_000 : v[2] == "میلیون" ? 1_000_000 : 1
        return Rating(score: sc, votes: Int((base * mult).rounded()))
    }

    public static func minutes(_ s: String) -> Int? { minutesRx.firstGroups(in: digits(s)).flatMap { Int($0[1]) } }

    public static func criticsScore(_ s: String) -> Int? { critics.firstGroups(in: digits(s)).flatMap { Int($0[1]) } }
}

extension String {
    /// ASCII digits to Persian digits.
    public var persianDigits: String {
        String(map { c -> Character in
            if let d = c.wholeNumberValue, c.isASCII { return Array("۰۱۲۳۴۵۶۷۸۹")[d] }
            return c
        })
    }

    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Text after the first `:` (all of it when there is none), trimmed.
    func afterColon() -> String {
        guard let i = firstIndex(of: ":") else { return trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(self[index(after: i)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
