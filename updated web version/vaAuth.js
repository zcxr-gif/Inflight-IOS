// Premium auth modal for VA partnership + staff console.
// Distinct from the main tracker AuthUI (which is wired to Pro/Stripe and
// auto-redirects into the tracker on sign-in).
//
// Visual language matches va-ui.css. The modal also injects a minimal,
// self-contained stylesheet so it works on any page that loads this module.

import { supabase, getSession, signOut as serviceSignOut } from './vaService.js';
import { friendlyAuthError, vaToast } from './vaUI.js';

let injected = false;
let lastMode = 'signin';
let pendingConfirmEmail = null;

function injectStyles() {
    if (injected) return;
    injected = true;
    const style = document.createElement('style');
    style.textContent = `
        #va-auth-overlay {
            position: fixed; inset: 0; z-index: 99999;
            background: rgba(4, 4, 6, 0.78);
            -webkit-backdrop-filter: blur(18px);
            backdrop-filter: blur(18px);
            display: none;
            overflow-y: auto;
            -webkit-overflow-scrolling: touch;
            opacity: 0;
            transition: opacity 220ms ease;
            padding: max(20px, env(safe-area-inset-top, 0px)) 18px max(20px, env(safe-area-inset-bottom, 0px));
            font-family: 'Inter', system-ui, -apple-system, sans-serif;
            -webkit-font-smoothing: antialiased;
        }
        #va-auth-overlay.va-open {
            display: flex;
            align-items: center;
            justify-content: center;
        }
        #va-auth-overlay.va-visible { opacity: 1; }

        #va-auth-card {
            position: relative;
            width: 100%;
            max-width: 440px;
            margin: auto;
            background: linear-gradient(180deg, #1a1a1d 0%, #101013 100%);
            border: 1px solid rgba(255,255,255,0.12);
            border-radius: 24px;
            padding: 34px 30px 28px;
            box-shadow:
                0 40px 100px -20px rgba(0,0,0,0.75),
                0 0 0 1px rgba(255,255,255,0.02) inset;
            transform: translateY(14px) scale(0.97);
            opacity: 0;
            transition: transform 280ms cubic-bezier(0.16, 1, 0.3, 1), opacity 220ms ease;
            overflow: hidden;
            flex: 0 0 auto;
        }
        #va-auth-overlay.va-visible #va-auth-card {
            transform: translateY(0) scale(1);
            opacity: 1;
        }

        #va-auth-card::before {
            content: "";
            position: absolute;
            top: -110px; left: 50%;
            width: 340px; height: 230px;
            transform: translateX(-50%);
            background: radial-gradient(closest-side, rgba(59,130,246,0.32), transparent 70%);
            filter: blur(40px);
            pointer-events: none;
        }
        #va-auth-card::after {
            content: "";
            position: absolute;
            inset: 0;
            border-radius: 24px;
            padding: 1px;
            background: linear-gradient(140deg, rgba(255,255,255,0.12), rgba(255,255,255,0) 45%, rgba(96,165,250,0.10) 100%);
            -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
            -webkit-mask-composite: xor; mask-composite: exclude;
            pointer-events: none;
        }

        .va-auth-brand {
            position: relative;
            display: flex; align-items: center; gap: 11px;
            margin-bottom: 22px;
        }
        .va-auth-brand-logo {
            width: 36px; height: 36px;
            border-radius: 10px;
            object-fit: cover;
            box-shadow: 0 8px 22px -8px rgba(59,130,246,0.55);
        }
        .va-auth-brand-name {
            font-weight: 800; color: #ffffff;
            letter-spacing: -0.02em;
            font-size: 1rem;
        }
        .va-auth-brand-tag {
            margin-left: auto;
            font-size: 0.66rem; font-weight: 700; letter-spacing: 0.18em;
            color: #a1a1aa; text-transform: uppercase;
            padding: 4px 10px; border-radius: 999px;
            background: rgba(255,255,255,0.04);
            border: 1px solid rgba(255,255,255,0.08);
        }

        #va-auth-card h2 {
            position: relative;
            margin: 0 0 6px;
            font-size: 1.55rem; font-weight: 800; color: #ffffff;
            letter-spacing: -0.025em; line-height: 1.15;
        }
        #va-auth-card .va-auth-sub {
            position: relative;
            margin: 0 0 22px; color: #a1a1aa;
            font-size: 0.92rem; line-height: 1.5;
        }

        .va-auth-tabs {
            position: relative;
            display: flex; gap: 2px;
            background: rgba(255,255,255,0.04);
            border: 1px solid rgba(255,255,255,0.07);
            border-radius: 12px; padding: 4px;
            margin-bottom: 20px;
        }
        .va-auth-tab {
            flex: 1; background: transparent; border: 0; color: #a1a1aa;
            font-weight: 600; font-size: 0.88rem; padding: 9px 0;
            border-radius: 9px; cursor: pointer;
            transition: color 140ms ease, background 140ms ease, box-shadow 140ms ease;
            font-family: inherit;
        }
        .va-auth-tab:hover { color: #ffffff; }
        .va-auth-tab.active {
            background: linear-gradient(180deg, rgba(255,255,255,0.08), rgba(255,255,255,0.03));
            color: #ffffff;
            box-shadow: 0 1px 0 rgba(255,255,255,0.08) inset, 0 4px 12px -6px rgba(0,0,0,0.4);
        }

        #va-auth-form {
            position: relative;
            display: flex; flex-direction: column; gap: 14px;
        }
        .va-auth-field { display: flex; flex-direction: column; gap: 7px; }
        .va-auth-field label {
            font-size: 0.7rem; font-weight: 700; letter-spacing: 0.08em;
            color: #a1a1aa; text-transform: uppercase;
            display: flex; align-items: center; gap: 6px;
        }
        .va-auth-field label i { color: #71717a; font-size: 0.78rem; }

        .va-auth-input-wrap { position: relative; display: flex; align-items: center; }
        .va-auth-field input {
            width: 100%;
            background: rgba(255,255,255,0.03);
            border: 1px solid rgba(255,255,255,0.10);
            color: #ffffff;
            border-radius: 11px;
            padding: 12px 14px;
            font-size: 0.95rem; font-family: inherit;
            outline: none;
            transition: border-color 140ms ease, background 140ms ease, box-shadow 140ms ease;
        }
        .va-auth-field input::placeholder { color: #71717a; }
        .va-auth-field input:hover { border-color: rgba(255,255,255,0.18); }
        .va-auth-field input:focus {
            border-color: rgba(96,165,250,0.65);
            background: rgba(255,255,255,0.05);
            box-shadow: 0 0 0 4px rgba(96,165,250,0.18);
        }

        .va-auth-pw-toggle {
            position: absolute; right: 8px;
            background: transparent; border: 0;
            color: #71717a; cursor: pointer;
            padding: 6px 8px; border-radius: 7px;
            font-size: 0.85rem;
            transition: color 120ms, background 120ms;
        }
        .va-auth-pw-toggle:hover { color: #e4e4e7; background: rgba(255,255,255,0.04); }

        #va-auth-submit {
            margin-top: 6px;
            padding: 12px 16px;
            border-radius: 12px;
            background: #ffffff;
            color: #0a0a0a;
            font-weight: 700; font-size: 0.95rem;
            border: 0; cursor: pointer;
            font-family: inherit;
            transition: transform 120ms ease, box-shadow 160ms ease, background 160ms ease;
            box-shadow: 0 10px 30px -10px rgba(255,255,255,0.30);
            display: flex; align-items: center; justify-content: center; gap: 8px;
            min-height: 44px;
        }
        #va-auth-submit:hover:not(:disabled) {
            transform: translateY(-1px);
            background: #f4f4f5;
            box-shadow: 0 14px 34px -10px rgba(255,255,255,0.35);
        }
        #va-auth-submit:active:not(:disabled) { transform: translateY(0); }
        #va-auth-submit:disabled { opacity: 0.55; cursor: not-allowed; }
        #va-auth-submit .va-auth-spinner {
            width: 14px; height: 14px;
            border: 2px solid rgba(10,10,10,0.20);
            border-top-color: #0a0a0a;
            border-radius: 50%;
            animation: va-auth-spin 0.7s linear infinite;
        }
        @keyframes va-auth-spin { to { transform: rotate(360deg); } }

        #va-auth-msg {
            font-size: 0.85rem; min-height: 1.2em;
            padding: 0 2px;
            display: flex; align-items: center; gap: 6px;
            line-height: 1.4;
        }
        .va-auth-msg-err { color: #f87171; }
        .va-auth-msg-ok  { color: #4ade80; }

        #va-auth-close {
            position: absolute; top: 14px; right: 14px;
            background: rgba(255,255,255,0.05);
            border: 1px solid rgba(255,255,255,0.08);
            color: #a1a1aa;
            width: 32px; height: 32px;
            display: flex; align-items: center; justify-content: center;
            border-radius: 9px;
            cursor: pointer; padding: 0;
            font-size: 0.95rem;
            transition: all 140ms ease;
            z-index: 2;
        }
        #va-auth-close:hover {
            color: #ffffff;
            background: rgba(255,255,255,0.10);
            border-color: rgba(255,255,255,0.18);
        }

        .va-auth-footer {
            margin-top: 16px; font-size: 0.84rem; color: #a1a1aa; text-align: center;
            position: relative;
        }
        .va-auth-footer a {
            color: #60a5fa; text-decoration: none;
            font-weight: 500; transition: color 120ms;
        }
        .va-auth-footer a:hover { color: #93c5fd; text-decoration: underline; }

        .va-auth-fineprint {
            position: relative;
            margin-top: 16px;
            font-size: 0.74rem;
            color: #71717a;
            text-align: center;
            line-height: 1.55;
        }
        .va-auth-fineprint a {
            color: #a1a1aa; text-decoration: underline;
            text-decoration-color: rgba(161,161,170,0.35);
            text-underline-offset: 2px;
        }
        .va-auth-fineprint a:hover { color: #ffffff; }

        @media (max-width: 460px) {
            #va-auth-card {
                padding: 28px 20px 22px;
                border-radius: 20px;
            }
            #va-auth-card h2 { font-size: 1.3rem; }
            #va-auth-card .va-auth-sub { font-size: 0.88rem; margin-bottom: 18px; }
            .va-auth-brand { margin-bottom: 18px; }
            .va-auth-field input { padding: 12px 12px; font-size: 16px; }
            #va-auth-submit { padding: 13px 16px; font-size: 1rem; }
            #va-auth-close { top: 10px; right: 10px; }
        }
        @media (max-height: 720px) {
            #va-auth-card { padding: 24px 24px 20px; }
            .va-auth-brand { margin-bottom: 14px; }
            #va-auth-card h2 { font-size: 1.3rem; }
            #va-auth-card .va-auth-sub { margin-bottom: 14px; }
            .va-auth-tabs { margin-bottom: 14px; }
            #va-auth-form { gap: 11px; }
        }

        @media (prefers-reduced-motion: reduce) {
            #va-auth-overlay,
            #va-auth-card,
            #va-auth-submit,
            .va-auth-tab,
            .va-auth-field input { transition: none; }
            #va-auth-submit .va-auth-spinner { animation: none; }
        }

        /* "Already signed in" + "confirm email" sub-states */
        .va-auth-actions-stack {
            display: flex; flex-direction: column; gap: 10px;
            margin-top: 18px;
        }
        .va-auth-btn-primary, .va-auth-btn-ghost, .va-auth-btn-link {
            font-family: inherit; cursor: pointer;
            border-radius: 12px; padding: 12px 16px;
            font-size: 0.95rem; font-weight: 700;
            display: inline-flex; align-items: center; justify-content: center; gap: 8px;
            transition: transform 120ms, background 160ms, border-color 160ms, color 160ms;
            border: 1px solid transparent;
            min-height: 44px;
        }
        .va-auth-btn-primary {
            background: #ffffff; color: #0a0a0a;
            box-shadow: 0 10px 30px -10px rgba(255,255,255,0.30);
        }
        .va-auth-btn-primary:hover { background: #f4f4f5; transform: translateY(-1px); }
        .va-auth-btn-ghost {
            background: rgba(255,255,255,0.04);
            color: #ffffff;
            border-color: rgba(255,255,255,0.10);
        }
        .va-auth-btn-ghost:hover { background: rgba(255,255,255,0.08); border-color: rgba(255,255,255,0.18); }
        .va-auth-btn-link {
            background: transparent; border: 0;
            color: #60a5fa; font-weight: 500; font-size: 0.88rem;
            padding: 6px 8px; min-height: 0;
        }
        .va-auth-btn-link:hover { color: #93c5fd; text-decoration: underline; }

        .va-auth-success-icon {
            margin: 4px 0 14px;
            width: 56px; height: 56px;
            border-radius: 16px;
            background: linear-gradient(135deg, rgba(74,222,128,0.25), rgba(34,197,94,0.10));
            border: 1px solid rgba(74,222,128,0.30);
            color: #86efac;
            display: flex; align-items: center; justify-content: center;
            font-size: 1.4rem;
        }
        .va-auth-tips {
            margin-top: 14px;
            display: grid; gap: 8px;
        }
        .va-auth-tip {
            display: flex; align-items: center; gap: 10px;
            font-size: 0.84rem; color: #a1a1aa;
            padding: 9px 12px;
            background: rgba(255,255,255,0.03);
            border: 1px solid rgba(255,255,255,0.07);
            border-radius: 10px;
        }
        .va-auth-tip i { color: #71717a; font-size: 0.82rem; }
    `;
    document.head.appendChild(style);
}

function escAttr(s) {
    return String(s ?? '').replace(/[&<>"']/g, c => ({
        '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
    }[c]));
}

async function renderSignedInState(overlay, session) {
    const user = session.user;
    const name = user.user_metadata?.if_username || user.email || 'Signed in';
    const email = user.email || '';
    overlay.innerHTML = `
        <div id="va-auth-card" role="dialog" aria-modal="true" aria-labelledby="va-auth-title">
            <button id="va-auth-close" type="button" aria-label="Close">
                <i class="fa-solid fa-xmark" aria-hidden="true"></i>
            </button>

            <div class="va-auth-brand">
                <img class="va-auth-brand-logo" src="Images/inflight.png" alt="">
                <span class="va-auth-brand-name">InFlight</span>
                <span class="va-auth-brand-tag">Partnership</span>
            </div>

            <h2 id="va-auth-title">You're already signed in</h2>
            <p class="va-auth-sub">Continue as <b>${escAttr(name)}</b>${email && email !== name ? ` <span style="color:#71717a;">(${escAttr(email)})</span>` : ''}, or switch to a different account.</p>

            <div class="va-auth-actions-stack">
                <button id="va-auth-continue" type="button" class="va-auth-btn-primary">
                    <i class="fa-solid fa-arrow-right"></i> Continue as ${escAttr(name)}
                </button>
                <button id="va-auth-switch" type="button" class="va-auth-btn-ghost">
                    <i class="fa-solid fa-arrow-right-arrow-left"></i> Use a different account
                </button>
            </div>
            <div id="va-auth-msg" role="status" aria-live="polite"></div>
        </div>
    `;
    overlay.querySelector('#va-auth-close').addEventListener('click', closeAuthModal);
    overlay.querySelector('#va-auth-continue').addEventListener('click', closeAuthModal);
    overlay.querySelector('#va-auth-switch').addEventListener('click', async () => {
        const msgEl = overlay.querySelector('#va-auth-msg');
        msgEl.className = '';
        msgEl.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> Signing out…';
        try {
            await serviceSignOut();
            render('signin');
        } catch (err) {
            msgEl.className = 'va-auth-msg-err';
            msgEl.innerHTML = `<i class="fa-solid fa-circle-exclamation"></i> ${escAttr(friendlyAuthError(err))}`;
        }
    });
}

function renderConfirmEmailState(overlay, email) {
    overlay.innerHTML = `
        <div id="va-auth-card" role="dialog" aria-modal="true" aria-labelledby="va-auth-title">
            <button id="va-auth-close" type="button" aria-label="Close">
                <i class="fa-solid fa-xmark" aria-hidden="true"></i>
            </button>

            <div class="va-auth-brand">
                <img class="va-auth-brand-logo" src="Images/inflight.png" alt="">
                <span class="va-auth-brand-name">InFlight</span>
                <span class="va-auth-brand-tag">Partnership</span>
            </div>

            <div class="va-auth-success-icon">
                <i class="fa-solid fa-envelope-circle-check"></i>
            </div>
            <h2 id="va-auth-title">Confirm your email</h2>
            <p class="va-auth-sub">We sent a confirmation link to <b>${escAttr(email)}</b>. Open it on this device to finish creating your account.</p>

            <div class="va-auth-tips">
                <div class="va-auth-tip"><i class="fa-solid fa-clock"></i> The link expires in about an hour.</div>
                <div class="va-auth-tip"><i class="fa-solid fa-folder-open"></i> No email? Check spam or promotions.</div>
            </div>

            <div class="va-auth-actions-stack">
                <button id="va-auth-resend" type="button" class="va-auth-btn-ghost">
                    <i class="fa-solid fa-paper-plane"></i> Resend confirmation
                </button>
                <button id="va-auth-back-signin" type="button" class="va-auth-btn-link">
                    Already confirmed? Sign in
                </button>
            </div>
            <div id="va-auth-msg" role="status" aria-live="polite"></div>
        </div>
    `;
    overlay.querySelector('#va-auth-close').addEventListener('click', closeAuthModal);
    overlay.querySelector('#va-auth-back-signin').addEventListener('click', () => render('signin'));
    overlay.querySelector('#va-auth-resend').addEventListener('click', async (e) => {
        const btn = e.currentTarget;
        const msgEl = overlay.querySelector('#va-auth-msg');
        btn.disabled = true;
        msgEl.className = '';
        msgEl.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> Resending…';
        try {
            const { error } = await supabase.auth.resend({ type: 'signup', email });
            if (error) throw error;
            msgEl.className = 'va-auth-msg-ok';
            msgEl.innerHTML = '<i class="fa-solid fa-circle-check"></i> Sent again. Check your inbox.';
        } catch (err) {
            msgEl.className = 'va-auth-msg-err';
            msgEl.innerHTML = `<i class="fa-solid fa-circle-exclamation"></i> ${escAttr(friendlyAuthError(err))}`;
        } finally {
            setTimeout(() => { btn.disabled = false; }, 1200);
        }
    });
}

function render(mode) {
    const overlay = document.getElementById('va-auth-overlay');
    if (mode === 'awaiting-confirmation') {
        renderConfirmEmailState(overlay, pendingConfirmEmail || '');
        return;
    }

    const isSignUp = mode === 'signup';
    lastMode = isSignUp ? 'signup' : 'signin';

    overlay.innerHTML = `
        <div id="va-auth-card" role="dialog" aria-modal="true" aria-labelledby="va-auth-title">
            <button id="va-auth-close" type="button" aria-label="Close">
                <i class="fa-solid fa-xmark" aria-hidden="true"></i>
            </button>

            <div class="va-auth-brand">
                <img class="va-auth-brand-logo" src="Images/inflight.png" alt="">
                <span class="va-auth-brand-name">InFlight</span>
                <span class="va-auth-brand-tag">Partnership</span>
            </div>

            <h2 id="va-auth-title">${isSignUp ? 'Create your account' : 'Welcome back'}</h2>
            <p class="va-auth-sub">${isSignUp
                ? 'Free account — no card required. Used to apply for the VA partnership program and manage your roster.'
                : 'Sign in to manage your virtual airline, submit events, or access the staff console.'}</p>

            <div class="va-auth-tabs" role="tablist">
                <button type="button" class="va-auth-tab ${!isSignUp ? 'active' : ''}" data-mode="signin" role="tab" aria-selected="${!isSignUp}">Sign in</button>
                <button type="button" class="va-auth-tab ${isSignUp ? 'active' : ''}" data-mode="signup" role="tab" aria-selected="${isSignUp}">Sign up</button>
            </div>

            <form id="va-auth-form" autocomplete="on" novalidate>
                ${isSignUp ? `
                    <div class="va-auth-field">
                        <label><i class="fa-solid fa-at"></i> IFC handle</label>
                        <div class="va-auth-input-wrap">
                            <input name="if_username" type="text" required autocomplete="username" placeholder="CaptainSmith" maxlength="40">
                        </div>
                    </div>` : ''}
                <div class="va-auth-field">
                    <label><i class="fa-solid fa-envelope"></i> Email</label>
                    <div class="va-auth-input-wrap">
                        <input name="email" type="email" required autocomplete="email" placeholder="you@example.com" inputmode="email">
                    </div>
                </div>
                <div class="va-auth-field">
                    <label><i class="fa-solid fa-lock"></i> Password</label>
                    <div class="va-auth-input-wrap">
                        <input name="password" type="password" required minlength="6"
                               autocomplete="${isSignUp ? 'new-password' : 'current-password'}"
                               placeholder="${isSignUp ? 'At least 6 characters' : 'Your password'}">
                        <button type="button" class="va-auth-pw-toggle" aria-label="Show password" data-pw-toggle>
                            <i class="fa-solid fa-eye" aria-hidden="true"></i>
                        </button>
                    </div>
                </div>
                <button id="va-auth-submit" type="submit">
                    <span class="va-auth-label">${isSignUp ? 'Create account' : 'Sign in'}</span>
                    <i class="fa-solid fa-arrow-right" style="font-size:0.8rem;" aria-hidden="true"></i>
                </button>
                <div id="va-auth-msg" role="status" aria-live="polite"></div>
            </form>

            ${!isSignUp ? `
                <div class="va-auth-footer">
                    <a href="#" id="va-auth-forgot">Forgot your password?</a>
                </div>
            ` : `
                <div class="va-auth-fineprint">
                    By creating an account you agree to our
                    <a href="terms.html" target="_blank" rel="noopener">Terms</a> and
                    <a href="privacy.html" target="_blank" rel="noopener">Privacy Policy</a>.
                </div>
            `}
        </div>
    `;

    overlay.querySelector('#va-auth-close').addEventListener('click', closeAuthModal);
    overlay.querySelectorAll('.va-auth-tab').forEach(b => {
        b.addEventListener('click', () => {
            render(b.dataset.mode);
            overlay.classList.add('va-visible');
        });
    });
    overlay.querySelector('#va-auth-form').addEventListener('submit', (e) => handleSubmit(e, isSignUp));

    const forgot = overlay.querySelector('#va-auth-forgot');
    if (forgot) forgot.addEventListener('click', (e) => { e.preventDefault(); handleForgot(); });

    const pwToggle = overlay.querySelector('[data-pw-toggle]');
    if (pwToggle) {
        pwToggle.addEventListener('click', () => {
            const input = pwToggle.closest('.va-auth-input-wrap').querySelector('input');
            const showing = input.type === 'text';
            input.type = showing ? 'password' : 'text';
            pwToggle.innerHTML = showing
                ? '<i class="fa-solid fa-eye" aria-hidden="true"></i>'
                : '<i class="fa-solid fa-eye-slash" aria-hidden="true"></i>';
            pwToggle.setAttribute('aria-label', showing ? 'Show password' : 'Hide password');
        });
    }

    // Autofocus first empty input (skip on mobile to avoid keyboard jump)
    const isTouch = window.matchMedia('(hover: none)').matches;
    if (!isTouch) {
        setTimeout(() => {
            const inputs = overlay.querySelectorAll('input');
            for (const input of inputs) {
                if (!input.value) { input.focus(); break; }
            }
        }, 60);
    }
}

function setSubmitBusy(btn, busy, busyLabel) {
    const label = btn.querySelector('.va-auth-label');
    const arrow = btn.querySelector('i');
    const spinner = btn.querySelector('.va-auth-spinner');
    if (busy) {
        btn.disabled = true;
        if (label) {
            btn.dataset.origLabel = btn.dataset.origLabel || label.textContent;
            label.textContent = busyLabel;
        }
        if (arrow) arrow.style.display = 'none';
        if (!spinner) {
            const s = document.createElement('span');
            s.className = 'va-auth-spinner';
            btn.appendChild(s);
        }
    } else {
        btn.disabled = false;
        if (label && btn.dataset.origLabel) {
            label.textContent = btn.dataset.origLabel;
            delete btn.dataset.origLabel;
        }
        if (arrow) arrow.style.display = '';
        if (spinner) spinner.remove();
    }
}

function showMsg(msgEl, kind, html) {
    msgEl.className = kind === 'err' ? 'va-auth-msg-err' : kind === 'ok' ? 'va-auth-msg-ok' : '';
    msgEl.innerHTML = html;
}

function validIfUsername(name) {
    if (!name) return false;
    const trimmed = name.trim();
    if (trimmed.length < 2 || trimmed.length > 40) return false;
    // IFC handles are alphanumeric + _ — keep this loose, IFC is the source of truth.
    return /^[A-Za-z0-9._\- ]+$/.test(trimmed);
}

async function handleSubmit(e, isSignUp) {
    e.preventDefault();
    const form = e.currentTarget;
    const data = Object.fromEntries(new FormData(form).entries());
    const msg = form.querySelector('#va-auth-msg');
    const btn = form.querySelector('#va-auth-submit');

    // Client-side validation up front — surfaces issues before we round-trip.
    if (isSignUp && !validIfUsername(data.if_username)) {
        showMsg(msg, 'err', '<i class="fa-solid fa-circle-exclamation"></i> IFC handle needs 2–40 characters (letters, numbers, dots, dashes, underscores).');
        form.querySelector('input[name="if_username"]')?.focus();
        return;
    }
    if (!data.email || !/.+@.+\..+/.test(data.email)) {
        showMsg(msg, 'err', "<i class=\"fa-solid fa-circle-exclamation\"></i> That email address doesn't look right.");
        form.querySelector('input[name="email"]')?.focus();
        return;
    }
    if (!data.password || data.password.length < 6) {
        showMsg(msg, 'err', '<i class="fa-solid fa-circle-exclamation"></i> Your password needs at least 6 characters.');
        form.querySelector('input[name="password"]')?.focus();
        return;
    }

    showMsg(msg, '', '');
    setSubmitBusy(btn, true, isSignUp ? 'Creating account…' : 'Signing in…');

    try {
        if (isSignUp) {
            const { error } = await supabase.auth.signUp({
                email: data.email,
                password: data.password,
                options: {
                    data: { if_username: (data.if_username || '').trim() },
                    emailRedirectTo: window.location.origin + '/va-apply.html'
                }
            });
            if (error) throw error;
            const sess = await getSession();
            if (sess) {
                vaToast({ type: 'ok', message: `Welcome aboard, ${(data.if_username || '').trim() || 'pilot'}.` });
                closeAuthModal();
            } else {
                pendingConfirmEmail = data.email;
                render('awaiting-confirmation');
            }
        } else {
            const { error } = await supabase.auth.signInWithPassword({
                email: data.email,
                password: data.password
            });
            if (error) throw error;
            vaToast({ type: 'ok', message: 'Signed in.' });
            closeAuthModal();
        }
    } catch (err) {
        showMsg(msg, 'err', `<i class="fa-solid fa-circle-exclamation"></i> ${escAttr(friendlyAuthError(err))}`);
    } finally {
        setSubmitBusy(btn, false);
    }
}

async function handleForgot() {
    const overlay = document.getElementById('va-auth-overlay');
    const emailInput = overlay.querySelector('input[name="email"]');
    const msg = overlay.querySelector('#va-auth-msg');
    const email = (emailInput?.value || '').trim();
    if (!email) {
        showMsg(msg, 'err', '<i class="fa-solid fa-circle-exclamation"></i> Enter your email above first.');
        emailInput?.focus();
        return;
    }
    if (!/.+@.+\..+/.test(email)) {
        showMsg(msg, 'err', "<i class=\"fa-solid fa-circle-exclamation\"></i> That email address doesn't look right.");
        emailInput?.focus();
        return;
    }
    showMsg(msg, '', '<i class="fa-solid fa-paper-plane"></i> Sending reset link…');
    try {
        const { error } = await supabase.auth.resetPasswordForEmail(email, {
            redirectTo: window.location.origin + '/va-reset.html'
        });
        if (error) throw error;
        showMsg(msg, 'ok', `<i class="fa-solid fa-circle-check"></i> Reset link sent to <b>${escAttr(email)}</b>. Check your inbox.`);
    } catch (err) {
        showMsg(msg, 'err', `<i class="fa-solid fa-circle-exclamation"></i> ${escAttr(friendlyAuthError(err))}`);
    }
}

// Attach backdrop-close handlers ONCE per overlay. We use pointer events
// with drag detection so that scrolling inside the modal on iOS Safari
// can't synthesize a stray click on the backdrop and close it.
function attachBackdropHandlers(overlay) {
    if (overlay.__vaBackdrop) return;
    overlay.__vaBackdrop = true;

    let pressedOnBackdrop = false;
    let pressX = 0, pressY = 0;
    let pressAt = 0;

    const onDown = (e) => {
        pressedOnBackdrop = e.target === overlay;
        pressX = e.clientX ?? 0;
        pressY = e.clientY ?? 0;
        pressAt = Date.now();
    };
    const onUp = (e) => {
        const was = pressedOnBackdrop;
        pressedOnBackdrop = false;
        if (!was) return;
        if (e.target !== overlay) return;
        // Ignore taps within 350ms of opening — covers iOS Safari ghost
        // clicks that can land on the backdrop right after the trigger
        // button is tapped.
        if (Date.now() - overlay.__vaOpenedAt < 350) return;
        const moved = Math.hypot((e.clientX ?? 0) - pressX, (e.clientY ?? 0) - pressY);
        if (moved > 8) return;  // user was scrolling, not tapping
        closeAuthModal();
    };

    if ('PointerEvent' in window) {
        overlay.addEventListener('pointerdown', onDown);
        overlay.addEventListener('pointerup', onUp);
    } else {
        // Fallback for very old browsers
        overlay.addEventListener('mousedown', onDown);
        overlay.addEventListener('mouseup', onUp);
        overlay.addEventListener('touchstart', (e) => {
            const t = e.touches[0];
            onDown({ target: e.target, clientX: t?.clientX, clientY: t?.clientY });
        }, { passive: true });
        overlay.addEventListener('touchend', (e) => {
            const t = e.changedTouches[0];
            onUp({ target: e.target, clientX: t?.clientX, clientY: t?.clientY });
        });
    }
}

export async function openAuthModal(mode = 'signin') {
    injectStyles();
    let overlay = document.getElementById('va-auth-overlay');
    if (!overlay) {
        overlay = document.createElement('div');
        overlay.id = 'va-auth-overlay';
        document.body.appendChild(overlay);
    }
    attachBackdropHandlers(overlay);
    overlay.__vaOpenedAt = Date.now();

    // If a session already exists, show the "already signed in" state
    // rather than the sign-in form. Avoids the confusing case where a
    // tracker page opens the auth modal but the user has been signed
    // in this whole time on another tab.
    let session = null;
    try { session = await getSession(); } catch (_) {}
    if (session && (mode === 'signin' || mode === 'signup')) {
        await renderSignedInState(overlay, session);
    } else {
        render(mode);
    }

    overlay.classList.add('va-open');
    // Force layout so the transition actually runs.
    // eslint-disable-next-line no-unused-expressions
    overlay.offsetHeight;
    requestAnimationFrame(() => {
        requestAnimationFrame(() => overlay.classList.add('va-visible'));
    });

    document.addEventListener('keydown', escListener);
    document.body.style.overflow = 'hidden';
}

export function closeAuthModal() {
    const overlay = document.getElementById('va-auth-overlay');
    if (!overlay) return;
    overlay.classList.remove('va-visible');
    document.removeEventListener('keydown', escListener);
    document.body.style.overflow = '';
    setTimeout(() => {
        if (!overlay.classList.contains('va-visible')) {
            overlay.classList.remove('va-open');
        }
    }, 240);
}

function escListener(e) {
    if (e.key === 'Escape') closeAuthModal();
}
