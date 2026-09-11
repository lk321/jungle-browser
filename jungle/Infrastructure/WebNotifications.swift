import AppKit
import UserNotifications
import WebKit

/// Website notifications, end to end: the page gets a `Notification` API, the answer to the
/// permission prompt is remembered per origin, and what the page posts shows up in macOS
/// Notification Center. Clicking a banner brings the tab that sent it to the front.
///
/// ponytail: WebKit's own notification plumbing is private API with no public presenter, so
/// the API is served from a page-world script instead. That covers in-page
/// `new Notification(...)`, which is what a call, a chat or a mail tab uses while it is open.
/// Notifications posted from a service worker (`registration.showNotification`) are not
/// covered; add them when a site that matters needs to notify with its tab closed.
@MainActor
final class WebNotifications: NSObject {
    static let shared = WebNotifications()
    static let handlerName = "jungleNotifications"

    private struct Posted {
        weak var webView: WKWebView?
        let scriptID: String
        let tabID: UUID
    }

    private var posted: [String: Posted] = [:]

    /// Called once at launch: without a delegate macOS swallows every banner while Jungle is
    /// the front app, which is exactly when a call or chat notification matters.
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    // MARK: Page messages

    func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let webView = message.webView,
              let tabID = WebViewPool.shared.tabID(for: webView)
        else { return }
        // The origin comes from the frame, never from the message: any script on the page can
        // reach a page-world handler and would otherwise name an origin it does not own.
        let origin = SitePermissions.describe(message.frameInfo.securityOrigin)

        switch type {
        case "requestPermission":
            Task { await requestPermission(origin: origin, in: webView) }
        case "show":
            guard let scriptID = body["id"] as? String else { return }
            show(
                title: (body["title"] as? String) ?? origin,
                body: (body["body"] as? String) ?? "",
                origin: origin,
                scriptID: scriptID,
                tabID: tabID,
                webView: webView
            )
        case "close":
            guard let scriptID = body["id"] as? String else { return }
            close(scriptID: scriptID, tabID: tabID)
        default:
            return
        }
    }

    /// Tells a freshly committed document what its origin already answered, so a site that was
    /// allowed once does not have to ask on every load.
    ///
    /// ponytail: sent right after the navigation commits rather than at document start, which
    /// no public API can seed. A page that reads `Notification.permission` in its very first
    /// inline script can still see `default` and ask again.
    func seedPermission(in webView: WKWebView) {
        guard let origin = SitePermissions.describe(webView.url),
              let decision = SitePermissions.decision(for: origin, kinds: [.notifications])
        else { return }
        report(decision ? "granted" : "denied", to: webView, resolvesRequest: false)
    }

    private func requestPermission(origin: String, in webView: WKWebView) async {
        let allowed = await SitePermissions.request([.notifications], origin: origin, in: webView.window)
        if allowed { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        report(allowed ? "granted" : "denied", to: webView, resolvesRequest: true)
    }

    private func report(_ permission: String, to webView: WKWebView, resolvesRequest: Bool) {
        let call = resolvesRequest ? "resolvePermission" : "setPermission"
        webView.evaluateJavaScript(
            "window.__jungleNotifications && window.__jungleNotifications.\(call)('\(permission)')",
            in: nil,
            in: .page
        ) { _ in }
    }

    private func show(title: String, body: String, origin: String, scriptID: String, tabID: UUID, webView: WKWebView) {
        // A page can only post once the user has allowed it, same as everywhere else.
        guard SitePermissions.decision(for: origin, kinds: [.notifications]) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.subtitle = origin
        content.sound = .default
        let identifier = "\(tabID.uuidString)|\(scriptID)"
        posted[identifier] = Posted(webView: webView, scriptID: scriptID, tabID: tabID)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    private func close(scriptID: String, tabID: UUID) {
        let identifier = "\(tabID.uuidString)|\(scriptID)"
        posted.removeValue(forKey: identifier)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    static let userScript = WKUserScript(
        source: """
        (function () {
            if (window.__jungleNotifications) { return; }
            const handler = window.webkit
                && window.webkit.messageHandlers
                && window.webkit.messageHandlers.\(handlerName);
            if (!handler) { return; }

            let permission = 'default';
            let nextID = 1;
            const live = new Map();
            const waiting = [];

            class JungleNotification extends EventTarget {
                constructor(title, options) {
                    super();
                    options = options || {};
                    this.title = String(title === undefined ? '' : title);
                    this.body = options.body === undefined ? '' : String(options.body);
                    this.tag = options.tag === undefined ? '' : String(options.tag);
                    this.icon = options.icon === undefined ? '' : String(options.icon);
                    this.badge = options.badge;
                    this.dir = options.dir || 'auto';
                    this.lang = options.lang || '';
                    this.silent = options.silent === true;
                    this.data = options.data === undefined ? null : options.data;
                    this.onclick = null;
                    this.onclose = null;
                    this.onshow = null;
                    this.onerror = null;
                    this.__id = 'n' + (nextID++);
                    live.set(this.__id, this);
                    handler.postMessage({ type: 'show', id: this.__id, title: this.title, body: this.body });
                    Promise.resolve().then(() => this.__fire('show'));
                }

                close() {
                    if (!live.delete(this.__id)) { return; }
                    handler.postMessage({ type: 'close', id: this.__id });
                    this.__fire('close');
                }

                __fire(name) {
                    const event = new Event(name);
                    const inline = this['on' + name];
                    if (typeof inline === 'function') { inline.call(this, event); }
                    this.dispatchEvent(event);
                }

                static requestPermission(callback) {
                    const answer = new Promise(function (resolve) {
                        waiting.push(function (value) {
                            if (typeof callback === 'function') { callback(value); }
                            resolve(value);
                        });
                    });
                    handler.postMessage({ type: 'requestPermission' });
                    return answer;
                }

                static get permission() { return permission; }
                static get maxActions() { return 0; }
            }

            window.__jungleNotifications = {
                setPermission: function (value) { permission = value; },
                resolvePermission: function (value) {
                    permission = value;
                    waiting.splice(0).forEach(function (resolve) { resolve(value); });
                },
                dispatch: function (id, name) {
                    const notification = live.get(id);
                    if (!notification) { return; }
                    if (name === 'close') { live.delete(id); }
                    notification.__fire(name);
                }
            };

            Object.defineProperty(window, 'Notification', {
                value: JungleNotification,
                configurable: true,
                writable: true
            });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .page
    )
}

extension WebNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            defer { completionHandler() }
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  let posted = WebNotifications.shared.posted.removeValue(forKey: identifier)
            else { return }
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .jungleFocusTab, object: nil, userInfo: ["tabID": posted.tabID])
            posted.webView?.evaluateJavaScript(
                "window.__jungleNotifications && window.__jungleNotifications.dispatch('\(posted.scriptID)', 'click')",
                in: nil,
                in: .page
            ) { _ in }
        }
    }
}

final class NotificationMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { WebNotifications.shared.handle(message) }
    }
}
