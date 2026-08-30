import Foundation
import WebKit

/// Runs the only Chrome-extension capability that WebKit can support safely:
/// Manifest V3 `declarativeNetRequest` static block rules. No extension code,
/// background worker, popup, or content script is loaded into the browser.
@MainActor
final class ChromeDeclarativeExtensionRuntime {
    static let shared = ChromeDeclarativeExtensionRuntime()

    private static let storageKey = "jungle.chrome-declarative-extensions"
    private static let maximumRuleCount = 25_000

    private let ruleListStore = WKContentRuleListStore.default()
    private let defaults = UserDefaults.standard
    private(set) var extensions: [BrowserExtension]

    private init() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let savedExtensions = try? JSONDecoder().decode([BrowserExtension].self, from: data)
        else {
            extensions = []
            return
        }
        extensions = savedExtensions
    }

    func start() {
        Task { [weak self] in
            await self?.applyEnabledRules()
        }
    }

    func install(from directory: URL) async throws -> BrowserExtension {
        let accessedSecurityScopedResource = directory.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScopedResource { directory.stopAccessingSecurityScopedResource() }
        }

        let manifestURL = directory.appending(path: "manifest.json")
        let manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        let manifest = try JSONDecoder().decode(ChromeExtensionManifest.self, from: manifestData)
        guard manifest.manifestVersion == 3 else { throw ChromeExtensionError.requiresManifestV3 }
        let resources = manifest.declarativeNetRequest?.ruleResources.filter(\.isEnabled) ?? []
        guard !resources.isEmpty else { throw ChromeExtensionError.requiresStaticNetworkRules }

        var rules: [ChromeDeclarativeNetRequestRule] = []
        let packagePath = directory.standardizedFileURL.path + "/"
        for resource in resources {
            let ruleURL = directory.appending(path: resource.path).standardizedFileURL
            guard ruleURL.path.hasPrefix(packagePath) else { throw ChromeExtensionError.invalidPackage }
            let data = try Data(contentsOf: ruleURL, options: .mappedIfSafe)
            let decodedRules = try JSONDecoder().decode([ChromeDeclarativeNetRequestRule].self, from: data)
            rules.append(contentsOf: decodedRules)
            guard rules.count <= Self.maximumRuleCount else { throw ChromeExtensionError.tooManyRules }
        }

        let compilation = ChromeDeclarativeRuleCompiler.compile(rules)
        guard compilation.ruleCount > 0 else { throw ChromeExtensionError.noSupportedRules }

        let extensionID = UUID()
        let ruleListIdentifier = "jungle.extension.\(extensionID.uuidString.lowercased())"
        guard let ruleList = await compile(compilation.source, identifier: ruleListIdentifier) else {
            throw ChromeExtensionError.invalidRules
        }

        let browserExtension = BrowserExtension(
            id: extensionID,
            name: manifest.name,
            version: manifest.version,
            ruleCount: compilation.ruleCount,
            unsupportedRuleCount: compilation.unsupportedRuleCount,
            ruleListIdentifier: ruleListIdentifier
        )
        extensions.append(browserExtension)
        save()
        await applyEnabledRules(preloaded: [browserExtension.id: ruleList])
        return browserExtension
    }

    func setEnabled(_ isEnabled: Bool, for extensionID: UUID) async {
        guard let index = extensions.firstIndex(where: { $0.id == extensionID }) else { return }
        extensions[index].isEnabled = isEnabled
        save()
        await applyEnabledRules()
    }

    func remove(_ extensionID: UUID) async {
        guard let index = extensions.firstIndex(where: { $0.id == extensionID }) else { return }
        let browserExtension = extensions.remove(at: index)
        save()
        await removeRuleList(identifier: browserExtension.ruleListIdentifier)
        await applyEnabledRules()
    }

    private func applyEnabledRules(preloaded: [UUID: WKContentRuleList] = [:]) async {
        var activeLists: [String: WKContentRuleList] = [:]
        for browserExtension in extensions where browserExtension.isEnabled {
            let list: WKContentRuleList?
            if let preloadedList = preloaded[browserExtension.id] {
                list = preloadedList
            } else {
                list = await lookUp(identifier: browserExtension.ruleListIdentifier)
            }
            guard let list else { continue }
            activeLists[browserExtension.ruleListIdentifier] = list
        }
        ContentBlocking.shared.setExtensionRuleLists(activeLists)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(extensions) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func lookUp(identifier: String) async -> WKContentRuleList? {
        guard let ruleListStore else { return nil }
        return await withCheckedContinuation { continuation in
            ruleListStore.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func compile(_ source: String, identifier: String) async -> WKContentRuleList? {
        guard let ruleListStore else { return nil }
        return await withCheckedContinuation { continuation in
            ruleListStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func removeRuleList(identifier: String) async {
        guard let ruleListStore else { return }
        await withCheckedContinuation { continuation in
            ruleListStore.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }
}

private struct ChromeExtensionManifest: Decodable {
    let manifestVersion: Int
    let name: String
    let version: String
    let declarativeNetRequest: DeclarativeNetRequest?

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case name
        case version
        case declarativeNetRequest = "declarative_net_request"
    }

    struct DeclarativeNetRequest: Decodable {
        let ruleResources: [RuleResource]

        enum CodingKeys: String, CodingKey {
            case ruleResources = "rule_resources"
        }
    }

    struct RuleResource: Decodable {
        let path: String
        let isEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case path
            case isEnabled = "enabled"
        }
    }
}

struct ChromeDeclarativeNetRequestRule: Decodable {
    let action: Action
    let condition: Condition

    struct Action: Decodable {
        let type: String
    }

    struct Condition: Decodable {
        let urlFilter: String?
        let regexFilter: String?
        let resourceTypes: [String]?
        let excludedResourceTypes: [String]?
        let domains: [String]?
        let excludedDomains: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "urlFilter"
            case regexFilter = "regexFilter"
            case resourceTypes = "resourceTypes"
            case excludedResourceTypes = "excludedResourceTypes"
            case domains
            case excludedDomains
        }
    }
}

enum ChromeDeclarativeRuleCompiler {
    struct Compilation {
        let source: String
        let ruleCount: Int
        let unsupportedRuleCount: Int
    }

    static func compile(_ chromeRules: [ChromeDeclarativeNetRequestRule]) -> Compilation {
        var rules: [WebKitContentRule] = []
        var unsupportedRuleCount = 0
        for chromeRule in chromeRules {
            guard let rule = makeRule(from: chromeRule) else {
                unsupportedRuleCount += 1
                continue
            }
            rules.append(rule)
        }
        let data = (try? JSONEncoder().encode(rules)) ?? Data("[]".utf8)
        return Compilation(
            source: String(decoding: data, as: UTF8.self),
            ruleCount: rules.count,
            unsupportedRuleCount: unsupportedRuleCount
        )
    }

    private static func makeRule(from chromeRule: ChromeDeclarativeNetRequestRule) -> WebKitContentRule? {
        let condition = chromeRule.condition
        guard chromeRule.action.type == "block",
              condition.regexFilter == nil,
              condition.resourceTypes?.isEmpty != true,
              condition.excludedResourceTypes?.isEmpty != false,
              condition.domains?.isEmpty != false,
              condition.excludedDomains?.isEmpty != false,
              let filter = condition.urlFilter,
              let urlFilter = webKitURLFilter(from: filter)
        else { return nil }
        let resourceTypes = condition.resourceTypes?.compactMap(WebKitContentRule.resourceType(from:))
        guard condition.resourceTypes == nil || resourceTypes?.count == condition.resourceTypes?.count else { return nil }
        return WebKitContentRule(
            trigger: .init(urlFilter: urlFilter, resourceTypes: resourceTypes?.isEmpty == false ? resourceTypes : nil),
            action: .init(type: "block")
        )
    }

    /// DNR URL filters are glob patterns, not regular expressions. Translate only
    /// their documented literal, `*`, `^`, and anchor forms so an imported package
    /// never contributes an unbounded or arbitrary regular expression to WebKit.
    private static func webKitURLFilter(from filter: String) -> String? {
        guard !filter.isEmpty, filter.count <= 512 else { return nil }
        if filter.hasPrefix("||"), filter.hasSuffix("^") {
            let domain = String(filter.dropFirst(2).dropLast())
            guard domain.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$", options: .regularExpression) != nil,
                  domain.contains("."), !domain.contains("..")
            else { return nil }
            return "^https?://([A-Za-z0-9-]+\\.)*\(NSRegularExpression.escapedPattern(for: domain))[/:?]"
        }

        let anchoredAtStart = filter.hasPrefix("|")
        let anchoredAtEnd = filter.hasSuffix("|") && filter.count > 1
        let pattern = filter
            .dropFirst(anchoredAtStart ? 1 : 0)
            .dropLast(anchoredAtEnd ? 1 : 0)
        var result = anchoredAtStart ? "^" : ""
        for character in pattern {
            switch character {
            case "*": result += ".*"
            case "^": result += "[^A-Za-z0-9_.%-]"
            default: result += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        if anchoredAtEnd { result += "$" }
        return result.isEmpty ? nil : result
    }
}

private struct WebKitContentRule: Encodable {
    let trigger: Trigger
    let action: Action

    struct Trigger: Encodable {
        let urlFilter: String
        let resourceTypes: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case resourceTypes = "resource-type"
        }
    }

    struct Action: Encodable {
        let type: String
    }

    nonisolated static func resourceType(from chromeResourceType: String) -> String? {
        switch chromeResourceType {
        case "main_frame", "sub_frame": "document"
        case "stylesheet": "style-sheet"
        case "script": "script"
        case "image": "image"
        case "font": "font"
        case "media": "media"
        case "xmlhttprequest", "ping", "websocket", "other": "raw"
        default: nil
        }
    }
}

enum ChromeExtensionError: LocalizedError {
    case requiresManifestV3
    case requiresStaticNetworkRules
    case tooManyRules
    case invalidPackage
    case noSupportedRules
    case invalidRules

    var errorDescription: String? {
        switch self {
        case .requiresManifestV3: "Only unpacked Chrome Manifest V3 extensions are supported."
        case .requiresStaticNetworkRules: "This extension has no enabled declarative network-rule set."
        case .tooManyRules: "This extension exceeds Jungle’s 25,000-rule performance limit."
        case .invalidPackage: "This extension refers to a rule file outside its selected folder."
        case .noSupportedRules: "This extension does not contain compatible block rules."
        case .invalidRules: "WebKit could not compile this extension’s rules."
        }
    }
}
