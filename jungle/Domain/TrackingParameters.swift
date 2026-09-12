import Foundation

/// Removes the campaign and click-attribution noise sites append to a link before it is
/// handed to someone else. The rule every entry below has to pass: deleting the parameter
/// must not change what the server renders. That is why `v`, `list` and `t` on YouTube,
/// `psc`, `th` and `smid` on Amazon, and `q` everywhere are absent — they select the page,
/// not the referrer. Anything not listed survives untouched, so an unknown site keeps its
/// link exactly as it was.
extension BrowserAddress {
    static func withoutTrackingParameters(_ url: URL) -> URL {
        guard isWebURL(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let site = components.host.flatMap(siteLabel(of:))
        var changed = false

        // The percent-encoded accessors keep every surviving pair byte-for-byte, so a link
        // with nothing to strip comes back identical instead of silently re-encoded.
        if let items = components.percentEncodedQueryItems {
            let kept = items.filter { !isTracking($0.name, site: site) }
            if kept.count != items.count {
                components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
                changed = true
            }
        }

        // Mercado Libre hides its tracking in the fragment. Only a fragment shaped like a
        // query is touched, so `#section-2` and `#:~:text=...` pass straight through.
        if let fragment = components.percentEncodedFragment, fragment.contains("=") {
            let pairs = fragment.split(separator: "&", omittingEmptySubsequences: false)
            let kept = pairs.filter { pair in
                guard pair.contains("=") else { return true }
                return !isTracking(String(pair.prefix { $0 != "=" }), site: site)
            }
            if kept.count != pairs.count {
                components.percentEncodedFragment = kept.isEmpty ? nil : kept.joined(separator: "&")
                changed = true
            }
        }

        // Amazon puts the search slot that produced the click in the path: `/dp/ASIN/ref=sr_1_3`.
        if site == "amazon" {
            let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            let kept = parts.filter { !$0.hasPrefix("ref=") }
            if kept.count != parts.count {
                components.percentEncodedPath = kept.joined(separator: "/")
                changed = true
            }
        }

        guard changed, let cleaned = components.url else { return url }
        return cleaned
    }

    /// The brand label of a host: `www.amazon.com.mx` is `amazon`, `youtu.be` is `youtu`.
    /// Everything trailing the brand has to be a suffix-shaped label, so a lookalike such as
    /// `amazon.com.attacker.example` resolves to `attacker` and never picks up Amazon's rules.
    private static func siteLabel(of host: String) -> String? {
        let labels = host.lowercased().split(separator: ".")
        guard labels.count >= 2 else { return nil }
        var index = labels.count - 2
        while index > 0, labels[index].count <= 3 { index -= 1 }
        return String(labels[index])
    }

    private static func isTracking(_ encodedName: String, site: String?) -> Bool {
        let name = (encodedName.removingPercentEncoding ?? encodedName).lowercased()
        if globalTrackingNames.contains(name) { return true }
        if globalTrackingPrefixes.contains(where: name.hasPrefix) { return true }
        guard let site, let rules = siteTrackingRules[site] else { return false }
        if rules.names.contains(name) { return true }
        return rules.prefixes.contains(where: name.hasPrefix)
    }
}

private struct SiteTrackingRules {
    let names: Set<String>
    let prefixes: [String]

    init(_ names: Set<String>, prefixes: [String] = []) {
        self.names = names
        self.prefixes = prefixes
    }
}

/// Analytics and ad-network parameters that mean the same thing on every host.
private let globalTrackingNames: Set<String> = [
    "gclid", "gclsrc", "gcl_au", "dclid", "gbraid", "wbraid", "gad_source", "gad_campaignid",
    "fbclid", "fb_action_ids", "fb_action_types", "fb_ref", "fb_source",
    "msclkid", "twclid", "ttclid", "igshid", "igsh", "yclid", "ysclid", "li_fat_id",
    "mc_cid", "mc_eid", "mkt_tok", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
    "epik", "s_kwcid", "ef_id", "rb_clickid", "irclickid", "irgwc", "cjevent", "awc",
    "ranmid", "raneaid", "ransiteid", "wickedid", "_openstat", "_branch_match_id",
    "_ga", "_gl", "ga_source", "ga_medium", "ga_campaign", "ga_content", "ga_term", "ga_place",
    "ref_src", "ref_url", "soc_src", "soc_trk", "cmpid", "campaign_id", "ncid", "icid",
    "guccounter", "guce_referrer", "guce_referrer_sig",
    "sc_campaign", "sc_channel", "sc_content", "sc_medium", "sc_outcome", "sc_geo", "sc_country",
    "at_medium", "at_campaign", "at_custom1", "at_custom2", "at_custom3", "at_custom4"
]

private let globalTrackingPrefixes = ["utm_", "pk_", "mtm_", "piwik_", "matomo_", "hsa_", "vero_", "oly_", "itm_"]

/// Host-scoped parameters. These names are only safe to drop on the site that issues them:
/// `ref` is a referrer on Amazon and Facebook and could be content anywhere else, and `si`
/// is a share identifier on YouTube and Spotify and nothing in particular elsewhere.
private let siteTrackingRules: [String: SiteTrackingRules] = {
    let youtube = SiteTrackingRules(["si", "pp", "feature", "kw", "gclid", "ab_channel"])
    let mercado = SiteTrackingRules([
        "tracking_id", "polycard_client", "wid", "sid", "search_layout", "position", "type",
        "deal_print_id", "c_id", "c_uid", "da_id", "matt_tool", "matt_word", "matt_source",
        "is_advertising", "ad_domain", "ad_click_id", "ad_group_id", "pdp_filters", "from",
        "component_id", "backend_model", "logistic_type", "tracking_source"
    ], prefixes: ["reco_", "mtb_"])
    let facebook = SiteTrackingRules([
        "ref", "refsrc", "refid", "eav", "mibextid", "rdid", "share_url", "_rdr", "extid",
        "comment_tracking", "dti", "hc_location", "hc_ref", "notif_t", "notif_id", "paipv", "idorvanity"
    ], prefixes: ["__"])

    return [
        "amazon": SiteTrackingRules([
            "ref", "ref_", "qid", "sr", "sprefix", "crid", "dib", "dib_tag", "content-id",
            "_encoding", "linkcode", "linkid", "tag", "ascsubtag", "camp", "creative",
            "creativeasin", "ie", "pldnsite", "spia", "spla"
        ], prefixes: ["pd_rd_", "pf_rd_", "sb-ci-"]),
        "youtube": youtube,
        "youtu": youtube,
        "mercadolibre": mercado,
        "mercadolivre": mercado,
        "facebook": facebook,
        "fb": facebook,
        "instagram": SiteTrackingRules(["igshid", "igsh", "hl_src"]),
        "twitter": SiteTrackingRules(["s", "t", "cxt", "src", "twgr", "twcamp", "twterm"]),
        "x": SiteTrackingRules(["s", "t", "cxt", "src", "twgr", "twcamp", "twterm"]),
        "tiktok": SiteTrackingRules([
            "is_from_webapp", "sender_device", "sender_web_id", "web_id", "_r", "_t", "u_code",
            "share_app_id", "share_link_id", "share_item_id", "tt_from", "source", "refer",
            "enter_from", "checksum", "preview_pb", "social_sharing"
        ]),
        "linkedin": SiteTrackingRules(["trk", "trkinfo", "trackingid", "refid", "lipi", "licu", "midtoken", "midsig", "eblink", "originaltrk"]),
        "reddit": SiteTrackingRules(["share_id", "correlation_id", "ref", "ref_source", "rdt", "$deep_link", "$original_url", "chainedposts"]),
        "spotify": SiteTrackingRules(["si", "nd", "nd_lfid", "context"]),
        "aliexpress": SiteTrackingRules([
            "spm", "scm", "scm_id", "scm-url", "pvid", "btsid", "ws_ab_test", "gatewayadapt",
            "gps-id", "curpageloguid", "ad_pvid", "srcsns", "businesstype", "templateid",
            "blanktest", "utparam", "tt", "sk", "terminal_id", "mall_affr"
        ], prefixes: ["algo_", "aff_", "pdp_ext_"]),
        "ebay": SiteTrackingRules(["_trkparms", "_trksid", "_from", "amdata", "mkcid", "mkrid", "mkevt", "campid", "toolid", "customid", "norover"]),
        "google": SiteTrackingRules(["ved", "ei", "sa", "oq", "sclient", "sourceid", "uact", "sca_esv", "biw", "bih", "dpr", "aqs", "cad", "source", "gs_lcrp", "gs_lp", "gs_ssp"]),
        "pinterest": SiteTrackingRules(["epik", "invite_code", "sender", "sfo"]),
        "temu": SiteTrackingRules(["refer_page_name", "refer_page_id", "refer_page_sn", "refer_share_id", "refer_share_uin", "refer_share_channel", "top_gallery_url"], prefixes: ["_x_", "_oak_"]),
        "walmart": SiteTrackingRules(["athbdg", "athcpid", "athena", "athasset", "athcgid", "athiev", "athancid", "from", "sid"])
    ]
}()
