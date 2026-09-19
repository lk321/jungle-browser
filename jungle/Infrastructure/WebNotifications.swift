import AppKit
import UserNotifications
import WebKit

/// Website notifications, end to end: the page gets a `Notification` API, the answer to the
/// permission prompt is remembered per origin, and what the page posts shows up in macOS
/// Notification Center. Clicking a banner brings the tab that sent it to the front.
///
/// ponytail: WebKit's own notification plumbing is private API with no public presenter, so
/// the API is served from a page-world script instead. It covers `new Notification(...)`,
/// `registration.showNotification(...)` called from the page, and the permission as read
/// through `navigator.permissions` — Google Chat and Calendar use the last two. A service
/// worker posting with every tab of its site closed is still not covered.
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
        // A site allowed before macOS was ever asked (or in a build macOS never registered)
        // would post into nothing, and the site itself never asks again.
        if SitePermissions.decisions(for: .notifications).values.contains(true) {
            Task { await ensureAuthorized() }
        }
    }

    /// Asks macOS once, the first time Jungle has something to show. Without it every banner
    /// is dropped silently: Jungle is not even listed in System Settings › Notifications.
    private static func ensureAuthorized() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
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
            Task { await requestPermission(origin: origin, in: webView, frame: message.frameInfo) }
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

    private func requestPermission(origin: String, in webView: WKWebView, frame: WKFrameInfo) async {
        let isNewAnswer = SitePermissions.decision(for: origin, kinds: [.notifications]) == nil
        let allowed = await SitePermissions.request([.notifications], origin: origin, in: webView.window)
        if allowed { await Self.ensureAuthorized() }
        // The answer is baked into the script every document starts with, so tabs pick it up
        // on their next load without asking again.
        if isNewAnswer { WebViewPool.shared.reinstallUserScripts() }
        // Answered in the frame that asked: a chat embedded from another origin asks from
        // its own iframe, and an answer sent to the main frame never reached it.
        webView.evaluateJavaScript(
            "window.__jungleNotifications && window.__jungleNotifications.resolvePermission('\(allowed ? "granted" : "denied")')",
            in: frame,
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
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task {
            await Self.ensureAuthorized()
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func close(scriptID: String, tabID: UUID) {
        let identifier = "\(tabID.uuidString)|\(scriptID)"
        posted.removeValue(forKey: identifier)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// The answers are written into the script, so every frame knows its origin's permission
    /// before the page's own first line runs. Seeding it after the commit came too late: Chat
    /// and Calendar had already read `default` and never posted a thing.
    static func userScript() -> WKUserScript {
        let decisions = SitePermissions.decisions(for: .notifications)
            .mapValues { $0 ? "granted" : "denied" }
        let json = (try? JSONSerialization.data(withJSONObject: decisions))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return WKUserScript(
            source: scriptSource.replacingOccurrences(of: "__JUNGLE_DECISIONS__", with: json),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
    }

    private static let scriptSource = """
        (function () {
            if (window.__jungleNotifications) { return; }
            const handler = window.webkit
                && window.webkit.messageHandlers
                && window.webkit.messageHandlers.\(handlerName);
            if (!handler) { return; }

            let permission = (__JUNGLE_DECISIONS__)[location.origin] || 'default';
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

            // Sites check this before they post; WebKit's own answer knows nothing of ours.
            if (navigator.permissions && typeof navigator.permissions.query === 'function') {
                const query = navigator.permissions.query.bind(navigator.permissions);
                navigator.permissions.query = function (descriptor) {
                    if (!descriptor || descriptor.name !== 'notifications') { return query(descriptor); }
                    const status = new EventTarget();
                    status.name = 'notifications';
                    status.state = permission === 'default' ? 'prompt' : permission;
                    status.onchange = null;
                    return Promise.resolve(status);
                };
            }

            // A page with a service worker posts through its registration rather than the
            // constructor. Called from the page, it can go through the same path.
            if (window.ServiceWorkerRegistration) {
                ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
                    if (permission !== 'granted') {
                        return Promise.reject(new TypeError('No notification permission has been granted for this origin.'));
                    }
                    new JungleNotification(title, options);
                    return Promise.resolve();
                };
                ServiceWorkerRegistration.prototype.getNotifications = function () {
                    return Promise.resolve([]);
                };
            }
        })();
        """
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
