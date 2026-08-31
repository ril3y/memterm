import Foundation

// FR-44: one human-editable TOML file as the source of truth. The parser below
// is a deliberate subset (key = value, [section] headers, quoted strings, ints,
// floats, bools, # comments) — no package dependency for a config file.

public enum TomlValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

public func parseTomlSubset(_ text: String) -> [String: TomlValue] {
    var result: [String: TomlValue] = [:]
    var section = ""
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("[") && line.hasSuffix("]") {
            section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            continue
        }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { continue }
        let fullKey = section.isEmpty ? key : "\(section).\(key)"
        result[fullKey] = parseTomlValue(value)
    }
    return result
}

/// Removes a trailing `# comment`, respecting `#` inside quoted strings.
private func stripComment(_ line: String) -> String {
    var inString = false
    var escaped = false
    for (i, ch) in line.enumerated() {
        if escaped { escaped = false; continue }
        switch ch {
        case "\\" where inString: escaped = true
        case "\"": inString.toggle()
        case "#" where !inString:
            return String(line.prefix(i))
        default: break
        }
    }
    return line
}

private func parseTomlValue(_ raw: String) -> TomlValue {
    if raw.hasPrefix("\"") {
        var out = ""
        var escaped = false
        for ch in raw.dropFirst() {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                break
            } else {
                out.append(ch)
            }
        }
        return .string(out)
    }
    if raw == "true" { return .bool(true) }
    if raw == "false" { return .bool(false) }
    if let i = Int(raw) { return .int(i) }
    if let d = Double(raw) { return .double(d) }
    return .string(raw)
}
