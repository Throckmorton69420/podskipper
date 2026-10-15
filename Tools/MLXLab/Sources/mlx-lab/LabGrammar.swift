import Foundation

/// Pass 40 lab only (not in the app): one-line answer grammars tried against
/// the JSON-schema grammar on his transcripts. Without spaces Qwen3.5 4B
/// named nothing in 2 of 4 Theo parts; with single spaces it found the same
/// ads with 31 % fewer answer tokens but moved boundaries (85–94 → 91–94).
/// Neither is in the app; see the Pass 40 evidence.
extension JudgePrompt {
    /// An xgrammar EBNF for `{"parts":[…]}` with the schema's
    /// fields in its order, written without whitespace.
    static func compactGrammar(maxParts: Int, labels: [String], sponsor: Int, why: Int?, funny: Bool,
                               spaced: Bool = false) -> String {
        let colon = spaced ? ": " : ":", comma = spaced ? ", " : ","
        func lit(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var part = lit("{\"first_line\"" + colon) + " int " + lit(comma + "\"last_line\"" + colon) + " int "
        if why != nil { part += lit(comma + "\"why\"" + colon + "\"") + " why " + lit("\"") + " " }
        part += lit(comma + "\"label\"" + colon + "\"") + " label " + lit("\"" + comma + "\"sponsor\"" + colon + "\"") + " sponsor " + lit("\"")
        if funny { part += " " + lit(comma + "\"funny\"" + colon) + " bool" }
        part += " " + lit("}")
        var rules = [
            "root ::= " + lit("{\"parts\"" + colon + "[") + " parts? " + lit("]}"),
            "parts ::= part (" + lit(comma) + " part){0,\(maxParts - 1)}",
            "part ::= " + part,
            #"int ::= "0" | [1-9] [0-9]{0,5}"#,
            "label ::= " + labels.map(lit).joined(separator: " | "),
            "sponsor ::= char{0,\(sponsor)}",
            #"char ::= [^"\\\x00-\x1f] | "\\" ["\\/bfnrt]"#,
        ]
        if let why { rules.append("why ::= char{0,\(why)}") }
        if funny { rules.append(#"bool ::= "true" | "false""#) }
        return rules.joined(separator: "\n")
    }

}
