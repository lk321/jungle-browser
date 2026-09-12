import Foundation

/// The two WebKit rule lists one filter feed compiles into. They are kept apart because
/// `ignore-previous-rules` only reaches rules inside its own list: an `$elemhide` exception
/// has to switch element hiding off on a site without also switching that site's network
/// blocking off, and one list cannot express both.
struct ContentBlockerRuleSet: Sendable {
    let network: String
    let cosmetic: String

    var isEmpty: Bool { network == "[]" && cosmetic == "[]" }
}

/// Translates EasyList-style filters into WebKit content rules. Everything this cannot say
/// precisely in WebKit's vocabulary is dropped rather than approximated: one rule WebKit
/// rejects fails the whole list, and a list that fails to compile is a browser with no
/// blocking at all.
nonisolated enum ContentBlockerRuleCompiler {
    /// Selectors per `css-display-none` rule. Element hiding is thousands of selectors that
    /// share one trigger, so they ride together; the chunk only keeps any single rule from
    /// growing unbounded.
    private static let selectorsPerRule = 1_000

    /// Modifiers that mean something other than "block this". Ignoring them turns a header
    /// rewrite or a parameter strip into a full block of the site it names, which is a broken
    /// page rather than a blocked ad.
    private static let unsupportedModifiers: Set<String> = [
        "csp", "removeparam", "queryprune", "replace", "method", "urltransform",
        "inline-script", "inline-font", "empty", "mp4", "redirect-rule", "permissions",
        "header", "to", "from", "app", "denyallow", "cookie", "stealth", "jsonprune", "hls"
    ]

    /// Exception modifiers that disable element hiding rather than a network load.
    private static let cosmeticExceptionModifiers: Set<String> = ["elemhide", "generichide", "specifichide"]

    /// Cosmetic syntax this deliberately does not translate: procedural and scriptlet filters
    /// are not CSS, and WebKit rejects the list that carries them.
    private static let proceduralMarkers = [
        ":has(", ":has-text", ":matches-", ":xpath", ":upward", ":style", ":contains",
        ":nth-ancestor", ":watch-attr", ":min-text-length", ":remove", ":others", ":-abp"
    ]

    static func compile(_ filters: String, maximumRuleCount: Int = 75_000) -> ContentBlockerRuleSet {
        var blocking: [ContentBlockerRule] = []
        var networkExceptions: [ContentBlockerRule] = []
        var cosmeticExceptions: [ContentBlockerRule] = []
        var genericSelectors: [String] = []
        var scopedSelectors: [CosmeticScope: [String]] = [:]
        var seenNetworkRules = Set<String>()
        var seenSelectors = Set<String>()

        filters.enumerateLines { rawLine, stop in
            guard blocking.count + networkExceptions.count < maximumRuleCount else {
                stop = true
                return
            }

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return }

            if let cosmetic = CosmeticFilter(line: line) {
                guard seenSelectors.insert("\(cosmetic.scope.deduplicationKey)##\(cosmetic.selector)").inserted else { return }
                if cosmetic.scope.isGeneric {
                    genericSelectors.append(cosmetic.selector)
                } else {
                    scopedSelectors[cosmetic.scope, default: []].append(cosmetic.selector)
                }
                return
            }

            let isException = line.hasPrefix("@@")
            let filter = isException ? String(line.dropFirst(2)) : line
            let parts = filter.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
            let modifiers = parts.count == 2 ? parts[1].split(separator: ",").map(String.init) : []
            guard !modifiers.contains(where: { unsupportedModifiers.contains(modifierName($0)) }) else { return }

            let disablesCosmetics = isException
                && modifiers.contains(where: { cosmeticExceptionModifiers.contains(modifierName($0)) })
            // A `$document` exception lifts everything on the site, so it belongs in both lists.
            let disablesEverything = isException && modifiers.contains("document")

            guard let urlFilter = makeURLFilter(from: String(parts[0])),
                  let trigger = makeTrigger(
                      urlFilter: urlFilter,
                      modifiers: disablesCosmetics ? modifiers.filter { !cosmeticExceptionModifiers.contains(modifierName($0)) } : modifiers
                  )
            else { return }
            let rule = ContentBlockerRule(trigger: trigger, action: isException ? .ignorePreviousRules : .block)
            guard seenNetworkRules.insert("\(isException ? "@" : "")\(rule.deduplicationKey)").inserted else { return }

            if disablesCosmetics || disablesEverything { cosmeticExceptions.append(rule) }
            if isException {
                guard !disablesCosmetics else { return }
                networkExceptions.append(rule)
            } else {
                blocking.append(rule)
            }
        }

        let cosmeticRules = makeCosmeticRules(
            generic: genericSelectors,
            scoped: scopedSelectors,
            maximumRuleCount: maximumRuleCount
        )
        return ContentBlockerRuleSet(
            network: encode(blocking + networkExceptions),
            // Exceptions last: `ignore-previous-rules` reaches backwards only.
            cosmetic: encode(cosmeticRules.isEmpty ? [] : cosmeticRules + cosmeticExceptions)
        )
    }

    private static func modifierName(_ modifier: String) -> String {
        String(modifier.prefix(while: { $0 != "=" })).trimmingCharacters(in: .whitespaces)
    }

    private static func encode(_ rules: [ContentBlockerRule]) -> String {
        guard !rules.isEmpty, let data = try? JSONEncoder().encode(rules) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Element hiding

    private static func makeCosmeticRules(
        generic: [String],
        scoped: [CosmeticScope: [String]],
        maximumRuleCount: Int
    ) -> [ContentBlockerRule] {
        var rules: [ContentBlockerRule] = []
        for chunk in generic.chunked(into: selectorsPerRule) {
            rules.append(ContentBlockerRule(trigger: .everyPage, action: .hide(chunk.joined(separator: ","))))
        }
        // Sorted so the same feed always compiles to the same bytes, which is what lets an
        // unchanged feed skip recompilation entirely.
        for scope in scoped.keys.sorted(by: { $0.deduplicationKey < $1.deduplicationKey }) {
            guard let selectors = scoped[scope] else { continue }
            for chunk in selectors.chunked(into: selectorsPerRule) {
                guard rules.count < maximumRuleCount else { return rules }
                rules.append(
                    ContentBlockerRule(
                        trigger: ContentBlockerRule.Trigger(
                            urlFilter: ".*",
                            resourceTypes: nil,
                            loadTypes: nil,
                            ifDomains: scope.ifDomains.nilIfEmpty,
                            unlessDomains: scope.ifDomains.isEmpty ? scope.unlessDomains.nilIfEmpty : nil
                        ),
                        action: .hide(chunk.joined(separator: ","))
                    )
                )
            }
        }
        return rules
    }

    /// One `domains##selector` line, or nothing when the line is not element hiding or uses
    /// syntax WebKit's selector compiler would reject.
    private nonisolated struct CosmeticFilter {
        let scope: CosmeticScope
        let selector: String

        init?(line: String) {
            // Exception and procedural separators share the `#` prefix; none of them is `##`.
            guard let separator = line.range(of: "##") else { return nil }
            guard !line.contains("#@#"), !line.contains("#?#"), !line.contains("#$#"), !line.contains("#%#") else { return nil }

            let selector = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !selector.isEmpty,
                  !selector.contains("{"), !selector.contains("}"), !selector.contains("\\"),
                  !ContentBlockerRuleCompiler.proceduralMarkers.contains(where: { selector.contains($0) })
            else { return nil }

            guard let scope = CosmeticScope(domainList: String(line[line.startIndex..<separator.lowerBound])) else { return nil }
            self.selector = selector
            self.scope = scope
        }
    }

    private nonisolated struct CosmeticScope: Hashable {
        let ifDomains: [String]
        let unlessDomains: [String]

        var isGeneric: Bool { ifDomains.isEmpty && unlessDomains.isEmpty }
        var deduplicationKey: String { "\(ifDomains.joined(separator: "|"))!\(unlessDomains.joined(separator: "|"))" }

        /// Nothing when the filter names sites this cannot express: a scope that loses every
        /// domain it had would hide the selector on every page the browser opens.
        init?(domainList: String) {
            let entries = domainList.split(separator: ",").map(String.init)
            ifDomains = ContentBlockerRuleCompiler.triggerDomains(entries.filter { !$0.hasPrefix("~") })
            unlessDomains = ContentBlockerRuleCompiler.triggerDomains(entries.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) })
            guard entries.isEmpty || !ifDomains.isEmpty || !unlessDomains.isEmpty else { return nil }
        }
    }

    // MARK: - Network patterns

    /// The regular expression WebKit matches a request URL against, or nothing when the
    /// pattern uses syntax that cannot be expressed exactly.
    static func makeURLFilter(from pattern: String) -> String? {
        guard !pattern.isEmpty, pattern.allSatisfy({ $0.isASCII }) else { return nil }

        if pattern.hasPrefix("||") {
            let rest = pattern.dropFirst(2)
            let host = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })).lowercased()
            guard host.contains("."), !host.contains(".."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
            // WebKit permits anchors only at the ends of a filter. URLs have a path, query,
            // port, or fragment after the host, so an explicit host delimiter stays precise
            // without relying on an unsupported in-expression end anchor.
            let base = "^https?://([A-Za-z0-9-]+\\.)*\(NSRegularExpression.escapedPattern(for: host))"
            let tail = String(rest.dropFirst(host.count))
            if tail.isEmpty || tail == "^" { return base + "[/:?]" }
            guard let tailFilter = expression(for: tail) else { return nil }
            return validated(base + tailFilter)
        }

        var body = pattern
        let anchorsStart = body.hasPrefix("|")
        if anchorsStart { body.removeFirst() }
        let anchorsEnd = body.hasSuffix("|")
        if anchorsEnd { body.removeLast() }
        // A pattern this short matches half the web; blocking on it costs more than it saves.
        guard body.filter({ $0 != "*" && $0 != "^" }).count >= 4, let expression = expression(for: body) else { return nil }
        return validated((anchorsStart ? "^" : "") + expression + (anchorsEnd ? "$" : ""))
    }

    /// Escapes a filter body into WebKit's regular-expression subset. Characters outside the
    /// set this understands end the translation instead of being guessed at.
    private static func expression(for body: String) -> String? {
        var output = ""
        for character in body {
            switch character {
            case "*":
                output += ".*"
            case "^":
                // ABP's separator. The literal set is spelled out because WebKit's matcher
                // has no shorthand class that means the same thing.
                output += "[/?&=:;,#]"
            case let value where value.isLetter || value.isNumber:
                output.append(value)
            case "-", "_", ".", "/", "%", "&", "=", "?", ":", ";", "+", ",", "~", "@", "!", "'", "(", ")", "$", "#":
                output += NSRegularExpression.escapedPattern(for: String(character))
            default:
                return nil
            }
        }
        return output.isEmpty ? nil : output
    }

    private static func validated(_ expression: String) -> String? {
        (try? NSRegularExpression(pattern: expression)) == nil ? nil : expression
    }

    /// Nothing when the filter names sites this cannot express. Dropping only the unusable
    /// domain would leave the rule with no scope at all, which turns "block this on those
    /// sites" into "block this everywhere" — a broken page rather than a blocked ad.
    private static func makeTrigger(urlFilter: String, modifiers: [String]) -> ContentBlockerRule.Trigger? {
        let resourceTypes = modifiers.compactMap(resourceType(from:))
        let loadType: [String]?
        if modifiers.contains("third-party") { loadType = ["third-party"] }
        else if modifiers.contains("~third-party") { loadType = ["first-party"] }
        else { loadType = nil }

        let domainModifier = modifiers.first(where: { $0.hasPrefix("domain=") })
        let entries = domainModifier.map { String($0.dropFirst("domain=".count)).split(separator: "|").map(String.init) } ?? []
        let positiveDomains = triggerDomains(entries.filter { !$0.hasPrefix("~") })
        let negativeDomains = triggerDomains(entries.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) })
        guard entries.isEmpty || !positiveDomains.isEmpty || !negativeDomains.isEmpty else { return nil }

        return ContentBlockerRule.Trigger(
            urlFilter: urlFilter,
            resourceTypes: resourceTypes.isEmpty ? nil : resourceTypes,
            loadTypes: loadType,
            ifDomains: negativeDomains.isEmpty ? positiveDomains.nilIfEmpty : nil,
            unlessDomains: positiveDomains.isEmpty ? negativeDomains.nilIfEmpty : nil
        )
    }

    /// Domains in the shape WebKit matches against. A leading `*` is what makes a domain cover
    /// its subdomains — a bare host matches only itself, which is not what a filter list means
    /// — and entity syntax such as `example.*` has no WebKit equivalent, so it is dropped
    /// rather than compiled into a rule that fails the whole list.
    static func triggerDomains(_ entries: [String]) -> [String] {
        entries.compactMap { entry in
            let domain = entry.trimmingCharacters(in: .whitespaces).lowercased()
            guard domain.contains("."), !domain.contains(".."), !domain.hasSuffix("."),
                  domain.allSatisfy({ $0.isASCII }),
                  domain.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
            else { return nil }
            return "*" + domain
        }
    }

    private static func resourceType(from modifier: String) -> String? {
        switch modifier {
        case "image": "image"
        case "script": "script"
        case "stylesheet": "style-sheet"
        case "font": "font"
        case "media": "media"
        case "popup": "popup"
        case "document", "subdocument": "document"
        case "xmlhttprequest", "ping", "websocket", "other": "raw"
        default: nil
        }
    }
}

nonisolated private struct ContentBlockerRule: Encodable, Sendable {
    struct Trigger: Encodable {
        static let everyPage = Trigger(urlFilter: ".*", resourceTypes: nil, loadTypes: nil, ifDomains: nil, unlessDomains: nil)

        let urlFilter: String
        let resourceTypes: [String]?
        let loadTypes: [String]?
        let ifDomains: [String]?
        let unlessDomains: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case resourceTypes = "resource-type"
            case loadTypes = "load-type"
            case ifDomains = "if-domain"
            case unlessDomains = "unless-domain"
        }
    }

    struct Action: Encodable {
        enum Kind: String, Encodable {
            case block
            case ignorePreviousRules = "ignore-previous-rules"
            case cssDisplayNone = "css-display-none"
        }

        static let block = Action(type: .block, selector: nil)
        static let ignorePreviousRules = Action(type: .ignorePreviousRules, selector: nil)
        static func hide(_ selector: String) -> Action { Action(type: .cssDisplayNone, selector: selector) }

        let type: Kind
        let selector: String?
    }

    let trigger: Trigger
    let action: Action

    var deduplicationKey: String {
        "\(trigger.urlFilter)|\(action.type.rawValue)|\(trigger.loadTypes?.joined(separator: ",") ?? "")"
            + "|\(trigger.resourceTypes?.joined(separator: ",") ?? "")"
    }
}

nonisolated private extension Array where Element == String {
    var nilIfEmpty: [String]? { isEmpty ? nil : self }

    func chunked(into size: Int) -> [[String]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
