import WebKit

/// Gives the play, next and previous keys back once a page's sound is over. WebKit makes the
/// app the system's Now Playing app for any audio of a second or more — a chat notification,
/// a ringtone, a UI cue — and keeps it that way until the page closes, measured: a pinned chat
/// tab held the media keys for good, and Music or Spotify never heard them.
///
/// WebKit only lets go for media that is muted, so a short sound that ends or is stopped is
/// muted, and unmuted right before it plays again. The page never sees it: `muted` still reads
/// what the page last wrote, and a page muting the sound itself takes it back from this script.
///
/// ponytail: short `<audio>` only. A paused video or song is exactly what the play key should
/// resume, and a video player saves `muted` as the user's choice for the next video.
enum MediaKeyRelease {
    static let userScript = WKUserScript(
        source: scriptSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        // The page's own world: a sound made with `new Audio()` is never in the document, so
        // only the page's `play` ever reaches it.
        in: .page
    )

    static let scriptSource = """
    (function () {
        'use strict';
        const Media = window.HTMLMediaElement;
        const Audio = window.HTMLAudioElement;
        const muted = Media && Object.getOwnPropertyDescriptor(Media.prototype, 'muted');
        if (!Audio || !muted || !muted.get || !muted.set || typeof Media.prototype.play !== 'function') { return; }

        // Longer than any notification or ringtone loop, shorter than a song.
        const cueSeconds = 30;
        const released = new WeakSet();
        const watched = new WeakSet();

        function release(event) {
            const media = event.target;
            if (!(media instanceof Audio) || released.has(media) || muted.get.call(media)) { return; }
            if (!isFinite(media.duration) || media.duration >= cueSeconds) { return; }
            released.add(media);
            muted.set.call(media, true);
        }

        function restore(media) {
            if (!released.has(media)) { return; }
            released.delete(media);
            muted.set.call(media, false);
        }

        Object.defineProperty(Media.prototype, 'muted', {
            configurable: true,
            enumerable: muted.enumerable,
            get: function () { return released.has(this) ? false : muted.get.call(this); },
            set: function (value) {
                released.delete(this);
                muted.set.call(this, value);
            }
        });

        // Unmuted before the original runs, so not a moment of the sound is lost.
        const play = Media.prototype.play;
        Media.prototype.play = function () {
            restore(this);
            if (!watched.has(this)) {
                watched.add(this);
                // A sound outside the document sends its events to itself alone.
                this.addEventListener('pause', release);
                this.addEventListener('ended', release);
            }
            return play.apply(this, arguments);
        };

        // What starts without `play()`: `autoplay`, and the page's native controls.
        document.addEventListener('play', function (event) { restore(event.target); }, true);
        document.addEventListener('pause', release, true);
        document.addEventListener('ended', release, true);
    })();
    """
}
