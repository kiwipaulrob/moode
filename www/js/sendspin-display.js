/**
 * SendSpin Metadata Display for moOde
 *
 * Polls the metadata API endpoint directly and shows/hides the SendSpin
 * overlay based on whether valid metadata is present. Caches last known
 * values to avoid unnecessary DOM updates that cause flickering.
 *
 * The overlay shows when a track is playing (valid title found in metadata),
 * and hides when playback stops or metadata is cleared.
 */
(function() {
    'use strict';

    // Only run on the main playback page, not on config pages
    var path = window.location.pathname;
    if (path !== '/' && path !== '/index.php' && path.endsWith('.php')) {
        return;  // Don't show overlay on any .php page except index
    }

    var pollTimer = null;
    var overlayshown = false;

    // Cache last known values to avoid unnecessary DOM updates
    var lastTitle = '';
    var lastArtist = '';
    var lastAlbum = '';
    var lastCoverUrl = '';

    function showOverlay() {
        if (overlayshown) return;
        var overlay = document.getElementById('sendspin-overlay');
        if (overlay) {
            overlay.classList.remove('hide');
            overlayshown = true;
        }
    }

    function hideOverlay() {
        if (!overlayshown) return;
        var overlay = document.getElementById('sendspin-overlay');
        if (overlay) {
            overlay.classList.add('hide');
            overlayshown = false;
        }
    }

    function updateMetadata() {
        fetch('command/renderer.php?cmd=get_sendspinmeta')
            .then(function(r) { return r.text(); })
            .then(function(data) {
                if (!data || data === '') {
                    hideOverlay();
                    return;
                }

                var parts = data.split('~~~');
                var title = (parts[0] || '').trim();
                var artist = (parts[1] || '').trim();
                var album = (parts[2] || '').trim();
                var coverUrl = (parts[4] || '').trim();

                // No valid track data — hide overlay
                if (title === '' || title === 'SendSpin') {
                    hideOverlay();
                    return;
                }

                // Show overlay (guarded — no-op if already shown)
                showOverlay();

                // Only update DOM elements when content actually changes
                if (title !== lastTitle) {
                    var titleEl = document.getElementById('sendspin-title');
                    if (titleEl) titleEl.textContent = title;
                    lastTitle = title;
                }

                if (artist !== lastArtist) {
                    var artistEl = document.getElementById('sendspin-artist');
                    if (artistEl) artistEl.textContent = artist;
                    lastArtist = artist;
                }

                if (album !== lastAlbum) {
                    var albumEl = document.getElementById('sendspin-album');
                    if (albumEl) albumEl.textContent = album;
                    lastAlbum = album;
                }

                if (coverUrl !== lastCoverUrl) {
                    var coverEl = document.getElementById('sendspin-coverart');
                    if (coverEl) {
                        if (coverUrl) {
                            coverEl.innerHTML = '<img src="' + coverUrl + '" alt="cover">';
                        } else {
                            coverEl.innerHTML = '<img src="images/default-album-cover.png" alt="cover">';
                        }
                    }
                    lastCoverUrl = coverUrl;
                }
            })
            .catch(function() {
                // Fetch or parse failed silently — keep current overlay state
            });
    }

    function startPolling() {
        if (pollTimer) clearInterval(pollTimer);
        updateMetadata();
        pollTimer = setInterval(updateMetadata, 2000);
    }

    function stopPolling() {
        if (pollTimer) {
            clearInterval(pollTimer);
            pollTimer = null;
        }
    }

    // Protect overlay elements from moOde's main.js clearing them
    function protectOverlayElements() {
        var ids = ['sendspin-title', 'sendspin-artist', 'sendspin-album', 'sendspin-coverart'];
        var observer = new MutationObserver(function(mutations) {
            mutations.forEach(function(m) {
                if (m.type === 'childList' && m.target.children.length === 0 && overlayshown) {
                    // Element was cleared by moOde JS — reapply last value
                    var el = m.target;
                    if (el.id === 'sendspin-title' && lastTitle) el.textContent = lastTitle;
                    else if (el.id === 'sendspin-artist' && lastArtist) el.textContent = lastArtist;
                    else if (el.id === 'sendspin-album' && lastAlbum) el.textContent = lastAlbum;
                    else if (el.id === 'sendspin-coverart' && lastCoverUrl) {
                        el.innerHTML = '<img src="' + lastCoverUrl + '" alt="cover">';
                    }
                }
            });
        });

        ids.forEach(function(id) {
            var el = document.getElementById(id);
            if (el) {
                observer.observe(el, {childList: true, subtree: true, characterData: false});
            }
        });
    }

    // Turn Off button handler
    document.addEventListener('click', function(e) {
        var target = e.target;
        if (target && (target.classList.contains('disconnect-sendspin') ||
            target.closest('.disconnect-sendspin'))) {
            e.preventDefault();
            hideOverlay();
            stopPolling();
            fetch('command/renderer.php?cmd=disconnect_renderer', {
                method: 'POST',
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: 'job=sendspinsvc'
            });
        }
    });

    // Start when the DOM is ready
    function init() {
        protectOverlayElements();
        startPolling();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
