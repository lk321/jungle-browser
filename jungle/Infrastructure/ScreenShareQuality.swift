import WebKit

/// Keeps a shared screen sharp. A screen is text, and WebKit treats a `getDisplayMedia` track
/// the way it treats a camera: it captures at whatever size the page did not ask for, and when
/// bandwidth or the encoder tightens, WebRTC keeps the frame rate and drops the resolution.
/// For a face that is the right trade; for a document it is what made a Meet share unreadable.
///
/// Chrome makes the opposite trade for screens on its own. This does the same, and only for
/// display tracks, so a camera on a poor network still degrades the way it always did:
/// - asks the capture for the display's full backing pixels, unless the page named a size;
/// - marks the track `contentHint = 'detail'`, which libwebrtc reads as screen content;
/// - sets `maintain-resolution` on any sender carrying it.
///
/// ponytail: the global `PeerConnectionVideoScalingAdaptationDisabled` preference would be one
/// line, and it would also freeze camera video on a bad connection instead of softening it.
enum ScreenShareQuality {
    static let userScript = WKUserScript(
        source: scriptSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        // The page's own world: that is where the page calls `getDisplayMedia`.
        in: .page
    )

    static let scriptSource = """
    (function () {
        'use strict';
        // The prototype, not `navigator.mediaDevices`: WebKit hands the page a different
        // instance after document start, and a method set on the first one is lost with it.
        const Devices = window.MediaDevices;
        if (!Devices || typeof Devices.prototype.getDisplayMedia !== 'function') { return; }

        // A clone keeps its settings, so `displaySurface` also finds the copies a page makes.
        function isDisplayTrack(track) {
            if (!track || track.kind !== 'video') { return false; }
            try { return 'displaySurface' in track.getSettings(); } catch (error) { return false; }
        }

        // Only a size the page left open. A number or an `ideal` of its own is its choice to make.
        function withFullResolution(constraints) {
            const video = constraints && constraints.video;
            if (video === false) { return constraints; }
            const scale = window.devicePixelRatio || 1;
            const wanted = {
                width: Math.round(screen.width * scale),
                height: Math.round(screen.height * scale)
            };
            const merged = Object.assign({}, typeof video === 'object' && video ? video : {});
            for (const key of ['width', 'height']) {
                const current = merged[key];
                if (current === undefined) {
                    merged[key] = { ideal: wanted[key] };
                } else if (typeof current === 'object' && current !== null && current.ideal === undefined) {
                    merged[key] = Object.assign({}, current, { ideal: wanted[key] });
                }
            }
            return Object.assign({}, constraints || {}, { video: merged });
        }

        function sharpen(track) {
            if (!isDisplayTrack(track)) { return; }
            if (!track.contentHint) { track.contentHint = 'detail'; }
        }

        function keepResolution(sender) {
            if (!sender || !isDisplayTrack(sender.track)) { return; }
            try {
                const parameters = sender.getParameters();
                if (parameters.degradationPreference === 'maintain-resolution') { return; }
                parameters.degradationPreference = 'maintain-resolution';
                // Before negotiation a sender may refuse new parameters; the hint still applies.
                const result = sender.setParameters(parameters);
                if (result && typeof result.catch === 'function') { result.catch(function () {}); }
            } catch (error) {}
        }

        const getDisplayMedia = Devices.prototype.getDisplayMedia;
        Devices.prototype.getDisplayMedia = function (constraints) {
            return getDisplayMedia.call(this, withFullResolution(constraints)).then(function (stream) {
                stream.getVideoTracks().forEach(sharpen);
                return stream;
            });
        };

        const Connection = window.RTCPeerConnection;
        const Sender = window.RTCRtpSender;
        if (!Connection || !Sender) { return; }

        const addTrack = Connection.prototype.addTrack;
        Connection.prototype.addTrack = function (track) {
            sharpen(track);
            const sender = addTrack.apply(this, arguments);
            keepResolution(sender);
            return sender;
        };

        const addTransceiver = Connection.prototype.addTransceiver;
        Connection.prototype.addTransceiver = function (trackOrKind) {
            if (typeof trackOrKind === 'object') { sharpen(trackOrKind); }
            const transceiver = addTransceiver.apply(this, arguments);
            keepResolution(transceiver && transceiver.sender);
            return transceiver;
        };

        const replaceTrack = Sender.prototype.replaceTrack;
        Sender.prototype.replaceTrack = function (track) {
            sharpen(track);
            const sender = this;
            return replaceTrack.apply(this, arguments).then(function (value) {
                keepResolution(sender);
                return value;
            });
        };
    })();
    """
}
