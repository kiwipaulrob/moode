(function() {
    'use strict';

    var path = window.location.pathname;
    if (path !== '/' && path !== '/index.php') {
        return;
    }

    var pollTimer = null;

    function showIndicator(title, artist, album, coverUrl) {
        var indicator = document.getElementById('inpsrc-indicator');
        var msg = document.getElementById('inpsrc-msg');
        var cover = document.getElementById('inpsrc-cover');
        var metadata = document.getElementById('inpsrc-metadata');
        var backdrop = document.getElementById('inpsrc-backdrop');

        if (!indicator || !msg) return;

        // Switch msg class to metadata mode (matching moOde pattern)
        msg.classList.remove('inpsrc-msg-default');
        msg.classList.add('inpsrc-msg-metadata');
        msg.style.width = '100%';

        // Message area: renderer name + Turn Off button
        msg.innerHTML = '<span id="inpsrc-msg-text">SendSpin Active</span>' +
            '<button class="btn turnoff-renderer" data-job="sendspinsvc"><i class="fa-regular fa-sharp fa-xmark"></i></button>';

        // Cover art image
        if (cover) {
            if (coverUrl) {
                cover.innerHTML = '<img class="inpsrc-metadata-cover" src="' + coverUrl + '">';
            } else {
                cover.innerHTML = '';
            }
        }

        // Backdrop (blurred background)
        if (backdrop) {
            if (coverUrl) {
                backdrop.innerHTML = '<img class="ss-backdrop" src="' + coverUrl + '">';
            } else {
                backdrop.innerHTML = '';
            }
        }

        // Metadata text: Artist - Title / Album
        if (metadata) {
            if (artist && title) {
                metadata.innerHTML = '<b>' + artist + ' - ' + title + '</b><br><span>' + (album || '') + '</span>';
            } else {
                metadata.innerHTML = '';
            }
            metadata.style.display = '';
        }

        // Style indicator (shows the backdrop color overlay)
        var styleEl = document.getElementById('inpsrc-style');
        if (styleEl) styleEl.style.display = 'block';

        // Show the indicator
        indicator.classList.remove('hide');
        indicator.style.display = 'block';
    }

    function hideIndicator() {
        var indicator = document.getElementById('inpsrc-indicator');
        var msg = document.getElementById('inpsrc-msg');
        var metadata = document.getElementById('inpsrc-metadata');
        var cover = document.getElementById('inpsrc-cover');
        var backdrop = document.getElementById('inpsrc-backdrop');

        if (indicator) {
            indicator.style.display = '';
            indicator.classList.add('hide');
        }
        if (msg) {
            msg.innerHTML = '';
            msg.classList.remove('inpsrc-msg-metadata');
            msg.classList.add('inpsrc-msg-default');
        }
        if (metadata) {
            metadata.innerHTML = '';
            metadata.style.display = 'none';
        }
        if (cover) cover.innerHTML = '';
        if (backdrop) backdrop.innerHTML = '';
    }

    function fetchMetadata() {
        fetch('command/renderer.php?cmd=get_sendspinmeta')
            .then(function(r) { return r.text(); })
            .then(function(data) {
                if (!data || data === '') {
                    hideIndicator();
                    return;
                }
                var parts = data.split('~~~');
                var title = (parts[0] || '').trim();
                var artist = (parts[1] || '').trim();
                var album = (parts[2] || '').trim();
                var coverUrl = (parts[4] || '').trim();

                if (title === '' || title === 'SendSpin') {
                    hideIndicator();
                    return;
                }

                showIndicator(title, artist, album, coverUrl);
            })
            .catch(function() {});
    }

    // Turn Off button
    document.addEventListener('click', function(e) {
        var btn = (e.target.closest && e.target.closest('[data-job="sendspinsvc"]'));
        if (btn || (e.target.classList && e.target.classList.contains('turnoff-renderer') && e.target.getAttribute('data-job') === 'sendspinsvc')) {
            e.preventDefault();
            hideIndicator();
            if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
            fetch('command/renderer.php?cmd=disconnect_renderer', {
                method: 'POST',
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: 'job=sendspinsvc'
            });
        }
    });

    function start() {
        fetchMetadata();
        pollTimer = setInterval(fetchMetadata, 3000);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
    } else {
        start();
    }
})();
