/*
 * haptics.js — tiny, dependency-free haptic feedback helper.
 *
 * Exposes window.InflightHaptics with a handful of intent-named methods. It
 * routes to the native Capacitor Haptics plugin when the app is running inside
 * the iOS/Android shell, and degrades to the Web Vibration API (or a silent
 * no-op) everywhere else. Every call is wrapped so a missing plugin or a
 * rejected promise can never throw into a UI handler.
 *
 * Usage:  window.InflightHaptics?.tap?.();
 */
(function () {
    'use strict';

    function plugin() {
        try {
            return (window.Capacitor && window.Capacitor.Plugins && window.Capacitor.Plugins.Haptics) || null;
        } catch (_) {
            return null;
        }
    }

    // Capacitor's ImpactStyle / NotificationType enums are plain uppercase
    // strings, so we can pass them directly without importing the plugin.
    function impact(style) {
        var H = plugin();
        if (H && typeof H.impact === 'function') {
            try { H.impact({ style: style }).catch(function () {}); } catch (_) {}
            return;
        }
        // Web fallback — silently ignored on iOS WKWebView (no Vibration API).
        try { if (navigator && typeof navigator.vibrate === 'function') navigator.vibrate(8); } catch (_) {}
    }

    function notify(type) {
        var H = plugin();
        if (H && typeof H.notification === 'function') {
            try { H.notification({ type: type }).catch(function () {}); } catch (_) {}
            return;
        }
        impact('MEDIUM');
    }

    window.InflightHaptics = {
        // Light tap — the default for selecting list rows, tabs, chips.
        tap: function () { impact('LIGHT'); },
        light: function () { impact('LIGHT'); },
        medium: function () { impact('MEDIUM'); },
        heavy: function () { impact('HEAVY'); },
        // Selection change — segmented controls, toggles, pickers.
        select: function () {
            var H = plugin();
            if (H && typeof H.selectionChanged === 'function') {
                try { H.selectionChanged().catch(function () {}); } catch (_) {}
                return;
            }
            impact('LIGHT');
        },
        success: function () { notify('SUCCESS'); },
        warning: function () { notify('WARNING'); },
        error: function () { notify('ERROR'); }
    };
})();
