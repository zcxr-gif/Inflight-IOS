// Shared UI utilities for the VA Partnership pages.
// Replaces native confirm/prompt/alert with design-consistent modals,
// adds a toast system, an account menu chip, and helpers for the
// auth flow (friendly error messages, debounced auth subscription).
//
// All visuals are defined in va-ui.css so this module stays
// lightweight and the design system stays in one place.

import { supabase } from './vaService.js';

// ---------------------------------------------------------------------------
// Toast
// ---------------------------------------------------------------------------

let toastHost = null;

function ensureToastHost() {
    if (toastHost && document.body.contains(toastHost)) return toastHost;
    toastHost = document.createElement('div');
    toastHost.className = 'va-toast-host';
    toastHost.setAttribute('aria-live', 'polite');
    toastHost.setAttribute('aria-atomic', 'true');
    document.body.appendChild(toastHost);
    return toastHost;
}

export function vaToast({ type = 'info', message = '', duration = 3800 } = {}) {
    const host = ensureToastHost();
    const t = document.createElement('div');
    t.className = `va-toast va-toast-${type}`;
    const icon = type === 'ok' ? 'fa-circle-check'
               : type === 'err' ? 'fa-circle-exclamation'
               : type === 'warn' ? 'fa-triangle-exclamation'
               : 'fa-circle-info';
    t.innerHTML = `
        <i class="fa-solid ${icon}" aria-hidden="true"></i>
        <span class="va-toast-msg"></span>
        <button class="va-toast-close" type="button" aria-label="Dismiss">
            <i class="fa-solid fa-xmark" aria-hidden="true"></i>
        </button>
    `;
    t.querySelector('.va-toast-msg').textContent = message;
    host.appendChild(t);
    // animate in
    requestAnimationFrame(() => t.classList.add('va-toast-visible'));

    const remove = () => {
        if (!t.parentNode) return;
        t.classList.remove('va-toast-visible');
        setTimeout(() => t.remove(), 220);
    };
    t.querySelector('.va-toast-close').addEventListener('click', remove);
    if (duration > 0) setTimeout(remove, duration);
    return remove;
}

// ---------------------------------------------------------------------------
// Modal infrastructure
// ---------------------------------------------------------------------------

function ensureDialogHost() {
    let host = document.getElementById('va-dialog-host');
    if (host) return host;
    host = document.createElement('div');
    host.id = 'va-dialog-host';
    document.body.appendChild(host);
    return host;
}

function openDialog({ render, onMount }) {
    const host = ensureDialogHost();
    const overlay = document.createElement('div');
    overlay.className = 'va-dialog-overlay';
    overlay.innerHTML = `
        <div class="va-dialog" role="dialog" aria-modal="true">
            ${render()}
        </div>
    `;
    host.appendChild(overlay);

    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';

    let resolved = false;
    let resolveFn;
    const promise = new Promise(r => { resolveFn = r; });

    const close = (value) => {
        if (resolved) return;
        resolved = true;
        overlay.classList.remove('va-visible');
        document.removeEventListener('keydown', onKey);
        document.body.style.overflow = prevOverflow;
        setTimeout(() => overlay.remove(), 200);
        resolveFn(value);
    };

    function onKey(e) {
        if (e.key === 'Escape') { e.stopPropagation(); close(null); }
    }
    document.addEventListener('keydown', onKey);

    // backdrop close — but only when the press starts AND ends on the
    // backdrop, so dragging selection inside the dialog doesn't dismiss.
    let pressedBackdrop = false;
    overlay.addEventListener('pointerdown', (e) => {
        pressedBackdrop = e.target === overlay;
    });
    overlay.addEventListener('pointerup', (e) => {
        if (pressedBackdrop && e.target === overlay) close(null);
        pressedBackdrop = false;
    });

    if (onMount) onMount(overlay, close);

    requestAnimationFrame(() => {
        requestAnimationFrame(() => overlay.classList.add('va-visible'));
    });
    return { overlay, close, promise };
}

function escAttr(s) {
    return String(s ?? '').replace(/[&<>"']/g, c => ({
        '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
    }[c]));
}

// ---------------------------------------------------------------------------
// Confirm dialog
// ---------------------------------------------------------------------------

export function vaConfirm({
    title = 'Are you sure?',
    message = '',
    confirmLabel = 'Confirm',
    cancelLabel = 'Cancel',
    danger = false,
    icon = null
} = {}) {
    const iconClass = icon || (danger ? 'fa-triangle-exclamation' : 'fa-circle-question');
    const { close, promise } = openDialog({
        render: () => `
            <div class="va-dialog-icon ${danger ? 'va-dialog-icon-danger' : ''}">
                <i class="fa-solid ${iconClass}" aria-hidden="true"></i>
            </div>
            <h2 class="va-dialog-title">${escAttr(title)}</h2>
            ${message ? `<p class="va-dialog-msg">${escAttr(message)}</p>` : ''}
            <div class="va-dialog-actions">
                <button type="button" class="va-btn va-btn-ghost" data-action="cancel">${escAttr(cancelLabel)}</button>
                <button type="button" class="va-btn ${danger ? 'va-btn-danger-solid' : 'va-btn-primary'}" data-action="confirm">${escAttr(confirmLabel)}</button>
            </div>
        `,
        onMount: (overlay, close) => {
            overlay.querySelector('[data-action="cancel"]').addEventListener('click', () => close(false));
            overlay.querySelector('[data-action="confirm"]').addEventListener('click', () => close(true));
            setTimeout(() => overlay.querySelector('[data-action="confirm"]')?.focus(), 80);
        }
    });
    return promise.then(v => v === true);
}

// ---------------------------------------------------------------------------
// Prompt dialog (single-line input with optional preset chips)
// ---------------------------------------------------------------------------

export function vaPrompt({
    title = 'Enter a value',
    message = '',
    label = '',
    placeholder = '',
    defaultValue = '',
    confirmLabel = 'Submit',
    cancelLabel = 'Cancel',
    required = false,
    multiline = false,
    presets = null,                 // array of strings — quick fill
    inputMaxLength = null,
    inputType = 'text',             // 'text' | 'password' | 'email' | ...
    danger = false,
    icon = null,
} = {}) {
    const iconClass = icon || (danger ? 'fa-triangle-exclamation' : 'fa-pen');
    const inputHtml = multiline
        ? `<textarea class="va-input va-textarea" data-input ${required ? 'required' : ''}
                ${inputMaxLength ? `maxlength="${inputMaxLength}"` : ''}
                placeholder="${escAttr(placeholder)}">${escAttr(defaultValue)}</textarea>`
        : `<input class="va-input" data-input type="${escAttr(inputType)}" ${required ? 'required' : ''}
                ${inputMaxLength ? `maxlength="${inputMaxLength}"` : ''}
                ${inputType === 'password' ? 'autocomplete="new-password"' : ''}
                value="${escAttr(defaultValue)}" placeholder="${escAttr(placeholder)}">`;

    const { close, promise } = openDialog({
        render: () => `
            <div class="va-dialog-icon ${danger ? 'va-dialog-icon-danger' : ''}">
                <i class="fa-solid ${iconClass}" aria-hidden="true"></i>
            </div>
            <h2 class="va-dialog-title">${escAttr(title)}</h2>
            ${message ? `<p class="va-dialog-msg">${escAttr(message)}</p>` : ''}
            <form class="va-dialog-form" data-form>
                ${label ? `<label class="va-field-label" style="margin-bottom:6px;">${escAttr(label)}</label>` : ''}
                ${inputHtml}
                ${Array.isArray(presets) && presets.length ? `
                    <div class="va-dialog-presets" data-presets>
                        ${presets.map(p => `<button type="button" class="va-chip" data-preset>${escAttr(p)}</button>`).join('')}
                    </div>` : ''}
                <div class="va-dialog-err va-hidden" data-err></div>
                <div class="va-dialog-actions">
                    <button type="button" class="va-btn va-btn-ghost" data-action="cancel">${escAttr(cancelLabel)}</button>
                    <button type="submit" class="va-btn ${danger ? 'va-btn-danger-solid' : 'va-btn-primary'}" data-action="confirm">${escAttr(confirmLabel)}</button>
                </div>
            </form>
        `,
        onMount: (overlay, close) => {
            const input = overlay.querySelector('[data-input]');
            const err = overlay.querySelector('[data-err]');
            const form = overlay.querySelector('[data-form]');

            overlay.querySelector('[data-action="cancel"]').addEventListener('click', () => close(null));
            overlay.querySelectorAll('[data-preset]').forEach(b => {
                b.addEventListener('click', () => {
                    input.value = b.textContent;
                    input.focus();
                });
            });

            form.addEventListener('submit', (e) => {
                e.preventDefault();
                const value = (input.value || '').trim();
                if (required && !value) {
                    err.classList.remove('va-hidden');
                    err.textContent = 'This field is required.';
                    input.focus();
                    return;
                }
                close(value);
            });

            // Focus input on mount
            setTimeout(() => {
                input.focus();
                if (input.setSelectionRange && typeof input.value === 'string') {
                    try { input.setSelectionRange(input.value.length, input.value.length); } catch (_) {}
                }
            }, 80);
        }
    });
    return promise;
}

// ---------------------------------------------------------------------------
// Friendly auth error messages
// ---------------------------------------------------------------------------

const AUTH_ERROR_MAP = [
    [/invalid login credentials/i,
        "That email or password didn't match. Check your spelling, or try \"Forgot password\"."],
    [/user already registered/i,
        "An account with that email already exists. Try signing in instead, or use \"Forgot password\"."],
    [/email not confirmed/i,
        "You haven't confirmed your email yet. Check your inbox (and spam) for the confirmation link."],
    [/password should be at least/i,
        "Your password needs to be at least 6 characters."],
    [/email rate limit exceeded/i,
        "Too many emails sent recently. Wait a few minutes and try again."],
    [/over.{0,3}email.{0,3}send.{0,3}rate/i,
        "Too many emails sent recently. Wait a few minutes and try again."],
    [/network|failed to fetch|load failed/i,
        "Couldn't reach InFlight. Check your connection and try again."],
    [/jwt expired|token has expired|invalid token/i,
        "Your session expired. Sign in again to continue."],
    [/auth\s*session\s*missing/i,
        "You're not signed in. Sign in again to continue."],
    [/anonymous sign-ins are disabled/i,
        "Anonymous sign-in is disabled. Use email and password."],
    [/captcha/i,
        "The captcha couldn't be verified. Reload the page and try again."],
    [/signup.*disabled|signups.*not allowed/i,
        "New sign-ups are temporarily disabled."],
    [/email.+invalid|invalid.+email/i,
        "That email address doesn't look right."],
    [/same password/i,
        "Your new password can't be the same as your old one."],
];

export function friendlyAuthError(err) {
    if (!err) return 'Something went wrong.';
    const raw = typeof err === 'string' ? err : (err.message || String(err));
    for (const [re, friendly] of AUTH_ERROR_MAP) {
        if (re.test(raw)) return friendly;
    }
    return raw;
}

// ---------------------------------------------------------------------------
// Debounced auth subscription
//
// `supabase.auth.onAuthStateChange` fires for SIGNED_IN, SIGNED_OUT,
// TOKEN_REFRESHED, USER_UPDATED, PASSWORD_RECOVERY, INITIAL_SESSION.
// Pages don't want to rebuild on every token refresh — they really
// just care whether the session identity changed.
// ---------------------------------------------------------------------------

export function subscribeAuth(handler, { events = ['SIGNED_IN', 'SIGNED_OUT', 'USER_UPDATED', 'PASSWORD_RECOVERY'] } = {}) {
    let lastUserId = null;
    let initialised = false;
    return supabase.auth.onAuthStateChange((event, session) => {
        if (!events.includes(event)) return;
        const uid = session?.user?.id || null;
        // Skip duplicate events for the same user (USER_UPDATED for e.g.
        // email change shouldn't rebuild; SIGNED_IN duplicates either).
        if (initialised && event !== 'PASSWORD_RECOVERY' && uid === lastUserId) return;
        lastUserId = uid;
        initialised = true;
        try { handler(event, session); }
        catch (e) { console.error('[vaUI] auth handler failed', e); }
    });
}

// ---------------------------------------------------------------------------
// Account menu
//
// Drops a clickable chip into `container`. The chip shows the user's
// initial + email; clicking it reveals a small menu with: copy user
// ID, sign out. The menu is keyboard-accessible.
// ---------------------------------------------------------------------------

function userInitial(user) {
    const seed = (user.user_metadata?.if_username || user.email || 'U').trim();
    return (seed[0] || 'U').toUpperCase();
}

function userDisplayName(user) {
    return user.user_metadata?.if_username || user.email || 'Signed in';
}

export function renderAccountMenu(container, { user, onSignOut, signOutLabel = 'Sign out', extraItems = [] } = {}) {
    if (!container) return;
    if (!user) { container.innerHTML = ''; return; }

    const initial = userInitial(user);
    const display = userDisplayName(user);
    const email = user.email || '';

    container.classList.add('va-account-menu-wrap');
    container.innerHTML = `
        <button type="button" class="va-account-chip" aria-haspopup="menu" aria-expanded="false">
            <span class="va-account-avatar">${escAttr(initial)}</span>
            <span class="va-account-name">${escAttr(display)}</span>
            <i class="fa-solid fa-chevron-down va-account-chev" aria-hidden="true"></i>
        </button>
        <div class="va-account-menu" role="menu" hidden>
            <div class="va-account-id">
                <div class="va-account-id-name">${escAttr(display)}</div>
                ${email && email !== display ? `<div class="va-account-id-email">${escAttr(email)}</div>` : ''}
            </div>
            <div class="va-account-sep"></div>
            <button type="button" class="va-account-item" data-action="copy-id" role="menuitem">
                <i class="fa-solid fa-fingerprint"></i>
                <span>Copy user ID</span>
            </button>
            ${extraItems.map((it, i) => `
                <button type="button" class="va-account-item" data-extra="${i}" role="menuitem">
                    <i class="fa-solid ${escAttr(it.icon || 'fa-arrow-right')}"></i>
                    <span>${escAttr(it.label)}</span>
                </button>
            `).join('')}
            <div class="va-account-sep"></div>
            <button type="button" class="va-account-item va-account-item-danger" data-action="signout" role="menuitem">
                <i class="fa-solid fa-right-from-bracket"></i>
                <span>${escAttr(signOutLabel)}</span>
            </button>
        </div>
    `;

    const chip = container.querySelector('.va-account-chip');
    const menu = container.querySelector('.va-account-menu');
    const setOpen = (open) => {
        chip.setAttribute('aria-expanded', open ? 'true' : 'false');
        menu.hidden = !open;
        container.classList.toggle('va-open', open);
    };
    let open = false;
    chip.addEventListener('click', (e) => {
        e.stopPropagation();
        open = !open;
        setOpen(open);
    });
    document.addEventListener('click', (e) => {
        if (open && !container.contains(e.target)) { open = false; setOpen(false); }
    });
    document.addEventListener('keydown', (e) => {
        if (open && e.key === 'Escape') { open = false; setOpen(false); chip.focus(); }
    });

    menu.querySelector('[data-action="copy-id"]').addEventListener('click', async () => {
        open = false; setOpen(false);
        try {
            await navigator.clipboard.writeText(user.id);
            vaToast({ type: 'ok', message: 'User ID copied to clipboard.' });
        } catch (_) {
            vaToast({ type: 'err', message: 'Could not copy. Your browser blocked clipboard access.' });
        }
    });

    extraItems.forEach((it, i) => {
        const btn = menu.querySelector(`[data-extra="${i}"]`);
        if (btn && it.onClick) {
            btn.addEventListener('click', () => {
                open = false; setOpen(false);
                it.onClick();
            });
        }
    });

    menu.querySelector('[data-action="signout"]').addEventListener('click', async () => {
        open = false; setOpen(false);
        const ok = await vaConfirm({
            title: 'Sign out?',
            message: `You're signed in as ${display}. You'll need to sign in again to come back.`,
            confirmLabel: 'Sign out',
            cancelLabel: 'Stay signed in',
            icon: 'fa-right-from-bracket'
        });
        if (!ok) return;
        if (onSignOut) await onSignOut();
    });
}
