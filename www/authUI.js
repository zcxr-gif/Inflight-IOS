// ─── Stripe configuration ─────────────────────────────────────────────────
// Replace with your Stripe publishable key if needed for client-side redirection.
const STRIPE_PUBLISHABLE_KEY = 'pk_live_51TRhge6y7GsJq8x0sd1UDluQGEmHK1i32pEubTnbDMji6PvqKINhgK1CNkDj3drjUcHcu5fpfGw5MK24363yDmGL00OInUnl1t';
// ──────────────────────────────────────────────────────────────────────────

export const AuthUI = {
    _isOpen: false,
    _mode: 'signin',
    _supabase: null,
    _tempSignUpData: null,
    _stripe: null,

    init(supabaseClient) {
        this._supabase = supabaseClient;
        this.setupRecoveryListener();
        this.checkPaymentStatus();
    },

    async checkPaymentStatus() {
        const urlParams = new URLSearchParams(window.location.search);
        const paymentStatus = urlParams.get('payment');
        const sessionId = urlParams.get('session_id');

        if (paymentStatus) {
            const newUrl = window.location.pathname;
            window.history.replaceState({}, document.title, newUrl);

            if (paymentStatus === 'success') {
                const pendingData = localStorage.getItem('inflight_pending_signup');
                
                if (sessionId && pendingData) {
                    try {
                        const userData = JSON.parse(pendingData);
                        
                        // 1. Invoke the Stripe Edge Function
                        const { data: result, error: functionError } = await this._supabase.functions.invoke('process-stripe-payment', {
                            body: { sessionId: sessionId }
                        });

                        if (functionError || (result && result.error)) {
                            throw new Error(result?.error || functionError?.message || "Failed to verify Stripe payment on the server.");
                        }

                        // 2. If it's a renewal, the user is already logged in, skip signInWithPassword
                        if (!userData.is_renew) {
                            const { error: loginError } = await this._supabase.auth.signInWithPassword({
                                email: userData.email,
                                password: userData.password
                            });

                            if (loginError) {
                                throw new Error("Account created, but auto-login failed: " + loginError.message);
                            }
                        }

                        localStorage.removeItem('inflight_pending_signup');
                        this.open();
                        return; 
                        
                    } catch (e) {
                        console.error("Stripe auto-processing failed:", e);
                        setTimeout(() => {
                            this.open('signin');
                            setTimeout(() => {
                                this.showError(`Error finalizing account: ${e.message}. If you were charged, please contact support.`);
                            }, 50);
                        }, 500);
                        return;
                    }
                }

                // Fallback
                setTimeout(() => {
                    this.open();
                    setTimeout(() => {
                        this.showSuccess("Payment successful! Welcome to InFlight Pro.");
                    }, 50);
                }, 500);

            } else if (paymentStatus === 'cancel') {
                const pendingData = localStorage.getItem('inflight_pending_signup');
                const parsedData = pendingData ? JSON.parse(pendingData) : null;
                
                localStorage.removeItem('inflight_pending_signup');
                
                setTimeout(() => {
                    this.open(parsedData?.is_renew ? 'renew' : 'signup');
                    setTimeout(() => {
                        this.showError("Payment was cancelled. You can complete your transaction when you're ready.");
                    }, 50);
                }, 500);
            }
        }
    },

    setupRecoveryListener() {
        this._supabase.auth.onAuthStateChange((event, session) => {
            if (event === 'PASSWORD_RECOVERY') {
                this.open('update_password');
            }
        });

        if (window.location.hash && window.location.hash.includes('type=recovery')) {
            window.history.replaceState(null, '', window.location.pathname);
            
            setTimeout(() => {
                this.open('update_password');
            }, 500);
        }
    },

    async open(mode = 'signin') {
        if (!this._supabase) {
            console.error("AuthUI: Supabase client not initialized. Call AuthUI.init(supabase) first.");
            return;
        }

        const { data } = await this._supabase.auth.getSession();
        
        if (data?.session?.user && mode !== 'update_password') {
            
            // Premium Access Gate: Verify subscription status from the database
            const { data: profile, error: profileError } = await this._supabase
                .from('profiles')
                .select('is_pro')
                .eq('id', data.session.user.id)
                .single();

            if (profile && profile.is_pro === false) {
                // Subscription is inactive, force them to the premium renewal flow
                this._mode = 'renew';
                this._tempSignUpData = { 
                    email: data.session.user.email,
                    is_renew: true 
                };
            } else {
                // Active Pro User -> Launch App
                import('./profileUI.js').then(module => {
                    if (!module.ProfileUI._supabase) {
                        module.ProfileUI.init(this._supabase);
                    }
                    module.ProfileUI.open(data.session.user);
                }).catch(err => console.error("Failed to load ProfileUI:", err));
                
                return; 
            }
        } else {
            this._mode = mode;
            this._tempSignUpData = null; 
        }
        
        if (!document.getElementById('auth-modal-overlay')) {
            this.renderContainer();
            this.injectStyles();
            this.attachGlobalListeners();
        }
        
        this.renderContent();
        
        setTimeout(() => {
            document.getElementById('auth-modal-overlay')?.classList.add('open');
            this._isOpen = true;
        }, 10);
    },

    close() {
        const overlay = document.getElementById('auth-modal-overlay');
        if (overlay) overlay.classList.remove('open');
        this._isOpen = false;
        this._tempSignUpData = null;
    },

    switchMode(mode) {
        if (this._mode === mode) return; 
        this._mode = mode;
        this.renderContent();
    },

    renderContainer() {
        const html = `
            <div id="auth-modal-overlay" class="auth-wrapper-layer">
                <div class="auth-modal-card" id="auth-modal-card"></div>
            </div>
        `;
        document.body.insertAdjacentHTML('beforeend', html);
    },

    renderContent() {
        const card = document.getElementById('auth-modal-card');
        if (!card) return;

        const isSignIn = this._mode === 'signin';
        const isSignUp = this._mode === 'signup';
        const isPayment = this._mode === 'payment';
        const isForgot = this._mode === 'forgot';
        const isUpdatePassword = this._mode === 'update_password';
        const isRenew = this._mode === 'renew';

        const showPaymentOptions = isPayment || isRenew;

        let html = `
            <div class="auth-premium-accent"></div>
            <button class="auth-close-btn" id="close-auth-ui" aria-label="Close">&times;</button>
            <div class="auth-header-section">
                <img src="Images/InflightPro.png" alt="InFlight Pro Logo" class="auth-brand-logo" onerror="this.style.display='none'">
        `;

        if (!showPaymentOptions && !isForgot && !isUpdatePassword) {
            html += `
                <div class="auth-toggle-container">
                    <div class="auth-toggle-pill">
                        <button class="auth-toggle-btn ${isSignIn ? 'active' : ''}" data-mode="signin">Sign In</button>
                        <button class="auth-toggle-btn ${isSignUp ? 'active' : ''}" data-mode="signup">Sign Up</button>
                    </div>
                </div>
            `;
        } else if (isPayment) {
            html += `
                <div class="auth-payment-header">
                    <h3 style="margin: 0; color: #0f172a; font-size: 1.25rem; font-weight: 700;">Start Your 7-Day Free Trial</h3>
                    <p style="margin: 6px 0 0; color: #64748b; font-size: 0.9rem;">$1.99/mo after trial ends. Cancel anytime.</p>
                </div>
            `;
        } else if (isRenew) {
            html += `
                <div class="auth-payment-header">
                    <div class="auth-status-badge">Access Expired</div>
                    <h3 style="margin: 0; color: #0f172a; font-size: 1.25rem; font-weight: 700;">Reactivate InFlight Pro</h3>
                    <p style="margin: 6px 0 0; color: #64748b; font-size: 0.9rem;">Resume your premium journey for $1.99/mo</p>
                </div>
            `;
        } else if (isForgot) {
            html += `
                <div class="auth-payment-header">
                    <h3 style="margin: 0; color: #0f172a; font-size: 1.25rem; font-weight: 700;">Reset Password</h3>
                    <p style="margin: 6px 0 0; color: #64748b; font-size: 0.9rem;">Enter your email to receive recovery instructions</p>
                </div>
            `;
        } else if (isUpdatePassword) {
            html += `
                <div class="auth-payment-header">
                    <h3 style="margin: 0; color: #0f172a; font-size: 1.25rem; font-weight: 700;">Set New Password</h3>
                    <p style="margin: 6px 0 0; color: #64748b; font-size: 0.9rem;">Please enter your new secure password</p>
                </div>
            `;
        }

        html += `</div><div class="auth-form-body">`;

        if (showPaymentOptions) {
            html += `
                <div id="stripe-checkout-section" class="stripe-hosted-container">
                    <button class="auth-submit-btn auth-submit-pro" id="stripe-checkout-btn">
                        <i class="fa-brands fa-stripe stripe-btn-logo"></i>
                        Checkout with Stripe
                    </button>
                    
                    <div class="auth-payment-badges">
                        <span class="badge-item"><i class="fa-brands fa-apple-pay"></i> Apple Pay</span>
                        <span class="badge-item"><i class="fa-brands fa-google-pay"></i> Google Pay</span>
                        <span class="badge-item"><i class="fa-solid fa-credit-card"></i> Cards</span>
                    </div>
                    
                    <p class="stripe-security-notice">
                        <i class="fa-solid fa-shield-halved"></i> 
                        Secure checkout hosted by <strong>Stripe</strong>
                    </p>
                </div>

                <div class="payment-or-divider"><span>OR PAY WITH</span></div>

                <div id="paypal-button-container" style="min-height: 50px; margin-bottom: 8px;"></div>

                <div id="auth-error-message" class="auth-error" style="display: none;"></div>
                <div id="auth-loading-message" style="display: none; text-align: center; color: #64748b; margin-bottom: 20px;">
                    <i class="fa-solid fa-circle-notch fa-spin" style="font-size: 1.5rem; margin-bottom: 12px; color: #2563eb;"></i>
                    <p style="margin: 0; font-size: 0.95rem; font-weight: 600;">Redirecting to Secure Payment...</p>
                </div>
                
            `;

            if (isRenew) {
                html += `<button class="auth-back-btn" id="auth-signout-btn">Sign Out</button>`;
            } else {
                html += `<button class="auth-back-btn" id="auth-back-to-signup">Back to Details</button>`;
            }

        } else if (isForgot) {
            html += `
                <div class="auth-input-group" id="auth-forgot-input-group">
                    <label>Email Address</label>
                    <div class="auth-field-wrapper">
                        <i class="fa-solid fa-envelope auth-field-icon"></i>
                        <input type="email" id="auth-forgot-email" placeholder="pilot@example.com" class="auth-input" required>
                    </div>
                </div>
                
                <div id="auth-error-message" class="auth-error" style="display: none;"></div>
                <div id="auth-success-message" class="auth-success" style="display: none;">
                    <i class="fa-solid fa-circle-check" style="margin-bottom: 8px; font-size: 1.5rem; color: #16a34a; display: block;"></i>
                    Reset link sent! Please check your inbox and follow the instructions.
                </div>

                <button class="auth-submit-btn" id="auth-submit-forgot-btn">Send Reset Link</button>
                <button class="auth-back-btn" id="auth-back-to-signin">Back to Sign In</button>
            `;
        } else if (isUpdatePassword) {
            html += `
                <div class="auth-input-group" id="auth-update-password-group">
                    <label>New Password</label>
                    <div class="auth-field-wrapper">
                        <i class="fa-solid fa-lock auth-field-icon"></i>
                        <input type="password" id="auth-new-password" placeholder="••••••••" class="auth-input" required>
                    </div>
                </div>
                <div class="auth-input-group" id="auth-update-confirm-group">
                    <label>Confirm Password</label>
                    <div class="auth-field-wrapper">
                        <i class="fa-solid fa-lock auth-field-icon"></i>
                        <input type="password" id="auth-confirm-password" placeholder="••••••••" class="auth-input" required>
                    </div>
                </div>
                
                <div id="auth-error-message" class="auth-error" style="display: none;"></div>
                <div id="auth-success-message" class="auth-success" style="display: none;"></div>

                <button class="auth-submit-btn" id="auth-submit-update-btn">Save New Password</button>
            `;
        } else {
            let formFields = '';
            
            if (isSignUp) {
                formFields += `
                    <div class="auth-premium-notice">
                        <i class="fa-solid fa-gem auth-premium-icon"></i>
                        <div class="auth-premium-text">
                            <strong>InFlight Pro</strong> is $1.99/mo after your <strong>7-day free trial</strong>.
                        </div>
                    </div>
                    <div class="auth-input-group">
                        <label>Full Name</label>
                        <div class="auth-field-wrapper">
                            <i class="fa-solid fa-user auth-field-icon"></i>
                            <input type="text" id="auth-name" placeholder="John Doe" class="auth-input" required>
                        </div>
                    </div>
                `;
            }

            const storedEmail = localStorage.getItem('inflight_remembered_email');
            const defaultEmail = isSignIn && storedEmail ? storedEmail : '';
            const defaultRememberChecked = (isSignIn && storedEmail) || localStorage.getItem('inflight_remember_preference') !== 'false' ? 'checked' : '';

            formFields += `
                <div class="auth-input-group">
                    <label>Email Address</label>
                    <div class="auth-field-wrapper">
                        <i class="fa-solid fa-envelope auth-field-icon"></i>
                        <input type="email" id="auth-email" placeholder="pilot@example.com" class="auth-input" value="${defaultEmail}" required>
                    </div>
                </div>
                
                <div class="auth-input-group">
                    <label>Password</label>
                    <div class="auth-field-wrapper">
                        <i class="fa-solid fa-lock auth-field-icon"></i>
                        <input type="password" id="auth-password" placeholder="••••••••" class="auth-input" required>
                    </div>
                </div>
            `;

            let optionsHtml = '';
            if (isSignIn) {
                optionsHtml = `
                    <div class="auth-options">
                        <label class="auth-checkbox">
                            <input type="checkbox" id="auth-remember" ${defaultRememberChecked}>
                            <span>Remember me</span>
                        </label>
                        <a href="#" class="auth-forgot-link" id="auth-forgot-password">Forgot password?</a>
                    </div>
                `;
            } else {
                optionsHtml = `
                    <div class="auth-options">
                        <label class="auth-checkbox">
                            <input type="checkbox" id="auth-terms" required>
                            <span>I agree to the <a href="terms.html" target="_blank" class="auth-terms-link">Terms of Use</a> & <a href="privacy.html" target="_blank" class="auth-terms-link">Privacy Policy</a></span>
                        </label>
                    </div>
                `;
            }

            const submitText = isSignIn ? "Sign In" : "Start 7-Day Free Trial";

            html += `
                ${formFields}
                ${optionsHtml}
                
                <div id="auth-success-message" class="auth-success" style="display: none;"></div>
                <div id="auth-error-message" class="auth-error" style="display: none;"></div>

                <button class="auth-submit-btn ${isSignUp ? 'auth-submit-pro' : ''}" id="auth-submit-btn">${submitText}</button>
            `;
        }

        html += `</div>`;
        card.innerHTML = html;
        this.attachContentListeners(); 

        if (showPaymentOptions) {
            this.loadPayPalAndRender();
            this.loadStripeAndRender();
        }
    },

    showError(message) {
        const errorDiv = document.getElementById('auth-error-message');
        if (errorDiv) {
            errorDiv.textContent = message;
            errorDiv.style.display = 'block';
            
            const successDiv = document.getElementById('auth-success-message');
            if (successDiv) successDiv.style.display = 'none';
        }
    },

    hideError() {
        const errorDiv = document.getElementById('auth-error-message');
        if (errorDiv) {
            errorDiv.style.display = 'none';
        }
    },

    showSuccess(message) {
        const successDiv = document.getElementById('auth-success-message');
        if (successDiv) {
            if (message) {
                successDiv.innerHTML = `<i class="fa-solid fa-circle-check" style="margin-bottom: 8px; font-size: 1.5rem; color: #16a34a; display: block;"></i>${message}`;
            }
            successDiv.style.display = 'block';
            
            const errorDiv = document.getElementById('auth-error-message');
            if (errorDiv) errorDiv.style.display = 'none';
        }
    },

    setLoading(buttonId, isLoading, originalText) {
        const btn = document.getElementById(buttonId);
        if (!btn) return;
        
        if (isLoading) {
            btn.disabled = true;
            btn.innerHTML = `<i class="fa-solid fa-circle-notch fa-spin"></i> Processing...`;
            btn.style.opacity = '0.7';
        } else {
            btn.disabled = false;
            btn.innerHTML = originalText;
            btn.style.opacity = '1';
        }
    },

    async loadPayPalAndRender() {
        if (!window.paypal) {
            const script = document.createElement('script');
            script.src = "https://www.paypal.com/sdk/js?client-id=AXjiYt3mjJBEkP4DnnXQLbx_YGlEoJgvtA_Yj-1MSIZFKT91tuFN9NL6HVmlThqqE7ZlazkquLkKleix&currency=USD&vault=true&intent=subscription&enable-funding=applepay";
            script.async = true;
            document.body.appendChild(script);

            await new Promise((resolve, reject) => {
                script.onload = resolve;
                script.onerror = reject;
            });
        }

        const container = document.getElementById('paypal-button-container');
        if (container) container.innerHTML = ''; 

        window.paypal.Buttons({
            createSubscription: function(data, actions) {
                return actions.subscription.create({
                    'plan_id': 'P-3S33604333332730HNGWPSWA' 
                });
            },
            onApprove: async (paymentData, actions) => {
                this.hideError();
                
                const loadingDiv = document.getElementById('auth-loading-message');
                const checkoutSection = document.getElementById('stripe-checkout-section');
                const btnContainer = document.getElementById('paypal-button-container');
                const backBtn = document.getElementById('auth-back-to-signup') || document.getElementById('auth-signout-btn');

                if (loadingDiv) loadingDiv.style.display = 'block';
                if (checkoutSection) checkoutSection.style.display = 'none';
                if (btnContainer) btnContainer.style.display = 'none';
                if (backBtn) backBtn.style.display = 'none';

                try {
                    const payload = {
                        email: this._tempSignUpData.email,
                        subscriptionID: paymentData.subscriptionID,
                        is_renew: this._tempSignUpData.is_renew || false
                    };

                    if (!payload.is_renew) {
                        payload.password = this._tempSignUpData.password;
                        payload.name = this._tempSignUpData.name;
                    }

                    const { data: result, error: functionError } = await this._supabase.functions.invoke('process-payment', {
                        body: payload
                    });

                    if (functionError) {
                        throw new Error(result?.error || functionError.message || "Payment verification failed.");
                    }

                    if (!payload.is_renew) {
                        const { error: loginError } = await this._supabase.auth.signInWithPassword({
                            email: this._tempSignUpData.email,
                            password: this._tempSignUpData.password,
                        });

                        if (loginError) {
                            throw new Error("Account created, but automatic login failed: " + loginError.message);
                        }
                    }

                    const overlay = document.getElementById('auth-modal-overlay');
                    if (overlay) overlay.classList.remove('open');
                    this._isOpen = false;
                    this._tempSignUpData = null;
                    
                    this.open(); 

                } catch (err) {
                    if (loadingDiv) loadingDiv.style.display = 'none';
                    if (checkoutSection) checkoutSection.style.display = 'block';
                    if (btnContainer) btnContainer.style.display = 'block';
                    if (backBtn) backBtn.style.display = 'block';
                    this.showError(err.message);
                }
            },
            onError: (err) => {
                this.showError("PayPal encountered an error. Please try again or use a different payment method.");
            }
        }).render('#paypal-button-container');
    },

    async loadStripeAndRender() {
        if (!window.Stripe) {
            const script = document.createElement('script');
            script.src = 'https://js.stripe.com/v3/';
            script.async = true;
            document.head.appendChild(script);
        }
    },

    async handleStripeHostedCheckout() {
        if (!this._tempSignUpData) {
            this.showError("Data missing. Please try again.");
            return;
        }

        this.hideError();
        const loadingDiv = document.getElementById('auth-loading-message');
        const checkoutSection = document.getElementById('stripe-checkout-section');
        const orDivider = document.querySelector('.payment-or-divider');
        const paypalContainer = document.getElementById('paypal-button-container');
        const backBtn = document.getElementById('auth-back-to-signup') || document.getElementById('auth-signout-btn');

        if (loadingDiv) loadingDiv.style.display = 'block';
        if (checkoutSection) checkoutSection.style.display = 'none';
        if (orDivider) orDivider.style.display = 'none';
        if (paypalContainer) paypalContainer.style.display = 'none';
        if (backBtn) backBtn.style.display = 'none';

        try {
            // Save state for cross-domain redirect
            localStorage.setItem('inflight_pending_signup', JSON.stringify({
                email: this._tempSignUpData.email,
                name: this._tempSignUpData.name,
                password: this._tempSignUpData.password,
                is_renew: this._tempSignUpData.is_renew || false
            }));

            const payload = {
                email: this._tempSignUpData.email,
                success_url: window.location.origin + '?payment=success&session_id={CHECKOUT_SESSION_ID}',
                cancel_url: window.location.origin + '?payment=cancel',
                is_renew: this._tempSignUpData.is_renew || false,
                trial_days: 7 // Instructs backend to apply trial if eligible
            };

            if (!payload.is_renew) {
                payload.name = this._tempSignUpData.name;
                payload.password = this._tempSignUpData.password;
            }

            const { data, error } = await this._supabase.functions.invoke('create-stripe-checkout', { body: payload });

            if (error || !data?.url) {
                throw new Error(data?.error || error?.message || 'Could not initialize Stripe Checkout.');
            }

            window.location.href = data.url;

        } catch (err) {
            localStorage.removeItem('inflight_pending_signup');
            
            if (loadingDiv) loadingDiv.style.display = 'none';
            if (checkoutSection) checkoutSection.style.display = 'block';
            if (orDivider) orDivider.style.display = 'flex';
            if (paypalContainer) paypalContainer.style.display = 'block';
            if (backBtn) backBtn.style.display = 'block';
            this.showError(err.message || 'Payment redirection failed. Please try again.');
        }
    },

    attachGlobalListeners() {
        document.getElementById('auth-modal-overlay')?.addEventListener('click', (e) => {
            if (e.target.id === 'auth-modal-overlay') this.close();
        });

        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape' && this._isOpen) {
                this.close();
            }
        });
    },

    attachContentListeners() {
        document.getElementById('close-auth-ui')?.addEventListener('click', () => this.close());

        const toggleBtns = document.querySelectorAll('.auth-toggle-btn');
        toggleBtns.forEach(btn => {
            btn.addEventListener('click', (e) => {
                this.switchMode(e.target.dataset.mode);
            });
        });

        document.getElementById('auth-submit-btn')?.addEventListener('click', async () => {
            this.hideError();
            const email = document.getElementById('auth-email')?.value;
            const password = document.getElementById('auth-password')?.value;
            const name = document.getElementById('auth-name')?.value || '';
            
            if (!email || !password) {
                this.showError("Please enter both email and password.");
                return;
            }

            if (this._mode === 'signup') {
                const termsCheckbox = document.getElementById('auth-terms');
                if (termsCheckbox && !termsCheckbox.checked) {
                    this.showError("Please agree to the Terms of Use and Privacy Policy.");
                    return; 
                }
                
                this._tempSignUpData = { email, password, name, is_renew: false };
                this.switchMode('payment');
                
            } else if (this._mode === 'signin') {
                this.setLoading('auth-submit-btn', true, 'Sign In');
                
                const { data, error } = await this._supabase.auth.signInWithPassword({
                    email: email,
                    password: password,
                });

                this.setLoading('auth-submit-btn', false, 'Sign In');

                if (error) {
                    this.showError(error.message);
                } else {
                    const rememberCheckbox = document.getElementById('auth-remember');
                    if (rememberCheckbox) {
                        localStorage.setItem('inflight_remember_preference', rememberCheckbox.checked);
                        if (rememberCheckbox.checked) {
                            localStorage.setItem('inflight_remembered_email', email);
                        } else {
                            localStorage.removeItem('inflight_remembered_email');
                        }
                    }

                    this.close();
                    this.open();
                }
            }
        });

        document.getElementById('auth-forgot-password')?.addEventListener('click', (e) => {
            e.preventDefault();
            this.switchMode('forgot');
        });

        document.getElementById('auth-back-to-signin')?.addEventListener('click', () => {
            this.switchMode('signin');
        });

        document.getElementById('auth-signout-btn')?.addEventListener('click', async () => {
            this.setLoading('auth-signout-btn', true, 'Signing out...');
            await this._supabase.auth.signOut();
            this._mode = 'signin';
            this._tempSignUpData = null;
            this.renderContent();
        });

        document.getElementById('auth-submit-forgot-btn')?.addEventListener('click', async () => {
            this.hideError();
            const email = document.getElementById('auth-forgot-email')?.value;
            
            if (!email) {
                this.showError("Please enter your email address first.");
                return;
            }

            this.setLoading('auth-submit-forgot-btn', true, 'Send Reset Link');
            
            const { data, error } = await this._supabase.auth.resetPasswordForEmail(email, {
                redirectTo: window.location.origin
            });
            
            this.setLoading('auth-submit-forgot-btn', false, 'Send Reset Link');

            if (error) {
                this.showError(error.message);
            } else {
                document.getElementById('auth-forgot-input-group').style.display = 'none';
                document.getElementById('auth-submit-forgot-btn').style.display = 'none';
                this.showSuccess();
            }
        });

        document.getElementById('auth-submit-update-btn')?.addEventListener('click', async () => {
            this.hideError();
            const newPassword = document.getElementById('auth-new-password')?.value;
            const confirmPassword = document.getElementById('auth-confirm-password')?.value;

            if (!newPassword || !confirmPassword) {
                this.showError("Please fill in both fields.");
                return;
            }

            if (newPassword !== confirmPassword) {
                this.showError("Passwords do not match.");
                return;
            }

            this.setLoading('auth-submit-update-btn', true, 'Save New Password');

            const { data, error } = await this._supabase.auth.updateUser({
                password: newPassword
            });

            this.setLoading('auth-submit-update-btn', false, 'Save New Password');

            if (error) {
                this.showError(error.message);
            } else {
                document.getElementById('auth-update-password-group').style.display = 'none';
                document.getElementById('auth-update-confirm-group').style.display = 'none';
                document.getElementById('auth-submit-update-btn').style.display = 'none';
                
                const successDiv = document.getElementById('auth-success-message');
                successDiv.innerHTML = '<i class="fa-solid fa-circle-check" style="margin-bottom: 8px; font-size: 1.5rem; color: #16a34a; display: block;"></i>Password updated successfully! Redirecting you...';
                this.showSuccess();
                
                setTimeout(() => {
                    this.close();
                    this.open();
                }, 2000);
            }
        });

        document.getElementById('auth-back-to-signup')?.addEventListener('click', () => {
            this.switchMode('signup');
        });

        document.getElementById('stripe-checkout-btn')?.addEventListener('click', () => {
            this.handleStripeHostedCheckout();
        });
    },

    injectStyles() {
        if (document.getElementById('auth-ui-styles')) return;
        
        const css = `
            .auth-wrapper-layer {
                position: fixed;
                inset: 0;
                background: rgba(15, 23, 42, 0.75);
                backdrop-filter: blur(12px);
                -webkit-backdrop-filter: blur(12px);
                display: flex;
                align-items: center;
                justify-content: center;
                opacity: 0;
                visibility: hidden;
                transition: all 0.4s cubic-bezier(0.16, 1, 0.3, 1);
                z-index: 9999;
                font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                padding: 20px;
                box-sizing: border-box;
                overflow-y: auto; 
            }
            
            .auth-wrapper-layer.open {
                opacity: 1;
                visibility: visible;
            }

            .auth-modal-card {
                background: #ffffff;
                width: 420px; 
                max-width: 100%;
                border-radius: 20px;
                position: relative;
                box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.25), 0 0 0 1px rgba(0, 0, 0, 0.05);
                transform: scale(0.95) translateY(15px);
                transition: all 0.4s cubic-bezier(0.16, 1, 0.3, 1);
                margin: auto; 
                overflow: hidden;
            }

            .auth-wrapper-layer.open .auth-modal-card {
                transform: scale(1) translateY(0);
            }

            .auth-premium-accent {
                height: 4px;
                width: 100%;
                background: linear-gradient(90deg, #2563eb, #38bdf8, #2563eb);
                background-size: 200% auto;
                animation: shine 3s linear infinite;
            }

            @keyframes shine {
                to { background-position: 200% center; }
            }

            .auth-close-btn {
                position: absolute;
                top: 16px;
                right: 16px;
                background: rgba(241, 245, 249, 0.5);
                border: none;
                color: #64748b;
                width: 32px;
                height: 32px;
                border-radius: 50%;
                font-size: 1.2rem;
                cursor: pointer;
                transition: all 0.2s ease;
                display: grid;
                place-items: center;
                line-height: 1;
                z-index: 10;
            }

            .auth-close-btn:hover {
                background: #e2e8f0;
                color: #0f172a;
                transform: rotate(90deg);
            }

            .auth-header-section {
                padding: 32px 28px 20px;
                text-align: center;
                position: relative;
            }

            .auth-status-badge {
                display: inline-block;
                background: #fee2e2;
                color: #b91c1c;
                font-size: 0.75rem;
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 0.05em;
                padding: 4px 10px;
                border-radius: 999px;
                margin-bottom: 12px;
                border: 1px solid #fca5a5;
            }

            .auth-brand-logo {
                height: 42px;
                width: auto;
                margin: 0 auto 20px;
                display: block;
                object-fit: contain;
            }

            .auth-toggle-container {
                display: flex;
                justify-content: center;
                width: 100%;
            }

            .auth-toggle-pill {
                display: flex;
                background: #f8fafc;
                border: 1px solid #e2e8f0;
                border-radius: 999px;
                padding: 4px;
                width: 100%;
            }

            .auth-toggle-btn {
                flex: 1;
                padding: 10px 16px;
                border: none;
                background: transparent;
                border-radius: 999px;
                font-size: 0.9rem;
                font-weight: 600;
                color: #64748b;
                cursor: pointer;
                transition: all 0.2s ease;
                font-family: inherit;
            }

            .auth-toggle-btn:hover:not(.active) {
                color: #334155;
            }

            .auth-toggle-btn.active {
                background: #ffffff;
                color: #0f172a;
                box-shadow: 0 2px 8px rgba(0, 0, 0, 0.08), 0 1px 2px rgba(0, 0, 0, 0.04);
            }

            .auth-form-body {
                padding: 0 28px 32px;
            }

            .auth-premium-notice {
                display: flex;
                align-items: flex-start;
                gap: 12px;
                background: linear-gradient(145deg, #f0f9ff, #e0f2fe);
                border: 1px solid #bae6fd;
                padding: 14px 16px;
                border-radius: 12px;
                margin-bottom: 20px;
                box-shadow: inset 0 2px 4px rgba(255, 255, 255, 0.5);
            }

            .auth-premium-icon {
                color: #0284c7;
                font-size: 1.1rem;
                margin-top: 2px;
            }

            .auth-premium-text {
                color: #0369a1;
                font-size: 0.85rem;
                line-height: 1.4;
            }

            .auth-premium-text strong {
                color: #075985;
            }

            .auth-input-group {
                margin-bottom: 16px;
            }

            .auth-input-group label {
                display: block;
                color: #334155;
                font-size: 0.85rem;
                font-weight: 600;
                margin-bottom: 8px;
            }

            .auth-field-wrapper {
                position: relative;
            }

            .auth-field-icon {
                position: absolute;
                left: 16px;
                top: 50%;
                transform: translateY(-50%);
                color: #94a3b8;
                font-size: 0.9rem;
                transition: color 0.2s;
            }

            .auth-input {
                width: 100%;
                background: #f8fafc;
                border: 1px solid #e2e8f0;
                border-radius: 10px;
                padding: 12px 16px 12px 42px;
                color: #0f172a;
                font-family: inherit;
                font-size: 0.95rem;
                transition: all 0.2s ease;
                outline: none;
                box-sizing: border-box;
            }

            .auth-input:hover {
                border-color: #cbd5e1;
                background: #ffffff;
            }

            .auth-input:focus {
                border-color: #2563eb;
                background: #ffffff;
                box-shadow: 0 0 0 4px rgba(37, 99, 235, 0.1);
            }

            .auth-input:focus + .auth-field-icon,
            .auth-input:not(:placeholder-shown) + .auth-field-icon {
                color: #2563eb;
            }

            .auth-input::placeholder {
                color: #94a3b8;
            }

            .auth-options {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 24px;
                font-size: 0.85rem;
            }

            .auth-checkbox {
                display: flex;
                align-items: center;
                gap: 8px;
                color: #475569;
                cursor: pointer;
                font-weight: 500;
            }
            
            .auth-checkbox input {
                accent-color: #2563eb;
                width: 16px;
                height: 16px;
                cursor: pointer;
            }

            .auth-forgot-link, .auth-terms-link {
                color: #2563eb;
                text-decoration: none;
                font-weight: 600;
                transition: color 0.2s;
            }

            .auth-forgot-link:hover, .auth-terms-link:hover {
                color: #1d4ed8;
            }
            
            .auth-terms-link:hover {
                text-decoration: underline;
            }

            .auth-error {
                background: #fef2f2;
                color: #dc2626;
                border: 1px solid #fecaca;
                padding: 12px;
                border-radius: 8px;
                font-size: 0.85rem;
                margin-bottom: 20px;
                text-align: center;
                font-weight: 500;
            }

            .auth-success {
                background: #f0fdf4;
                color: #166534;
                border: 1px solid #bbf7d0;
                padding: 16px;
                border-radius: 12px;
                font-size: 0.95rem;
                margin-bottom: 20px;
                text-align: center;
                font-weight: 500;
                line-height: 1.5;
            }

            .auth-submit-btn {
                width: 100%;
                background: #0f172a;
                color: #ffffff;
                border: none;
                border-radius: 10px;
                padding: 14px;
                font-size: 0.95rem;
                font-weight: 600;
                cursor: pointer;
                transition: all 0.2s ease;
                margin-bottom: 8px;
                box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
            }

            .auth-submit-pro {
                background: linear-gradient(135deg, #2563eb, #1d4ed8);
            }

            .auth-submit-btn:hover:not(:disabled) {
                transform: translateY(-1px);
                box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
            }

            .auth-submit-pro:hover:not(:disabled) {
                background: linear-gradient(135deg, #3b82f6, #2563eb);
                box-shadow: 0 10px 15px -3px rgba(37, 99, 235, 0.25), 0 4px 6px -2px rgba(37, 99, 235, 0.1);
            }

            .auth-submit-btn:active:not(:disabled) {
                transform: translateY(0);
            }

            .auth-submit-btn:disabled {
                cursor: not-allowed;
                opacity: 0.7;
            }

            .auth-back-btn {
                width: 100%;
                background: transparent;
                color: #64748b;
                border: 1px solid #e2e8f0;
                border-radius: 10px;
                padding: 12px;
                font-size: 0.9rem;
                font-weight: 600;
                cursor: pointer;
                transition: all 0.2s;
                margin-top: 12px;
            }

            .auth-back-btn:hover {
                background: #f8fafc;
                color: #0f172a;
                border-color: #cbd5e1;
            }

            /* Hosted Stripe Styles */
            .stripe-hosted-container {
                text-align: center;
                padding: 10px 0;
            }

            .stripe-btn-logo {
                font-size: 1.6rem;
                margin-right: 10px;
                vertical-align: middle;
            }

            .auth-payment-badges {
                display: flex;
                justify-content: center;
                gap: 12px;
                margin: 20px 0;
            }

            .badge-item {
                display: flex;
                align-items: center;
                gap: 6px;
                font-size: 0.75rem;
                color: #64748b;
                font-weight: 600;
                background: #f8fafc;
                padding: 6px 12px;
                border-radius: 8px;
                border: 1px solid #e2e8f0;
            }

            .badge-item i {
                font-size: 1.1rem;
                color: #0f172a;
            }

            .fa-apple-pay {
                font-size: 1.6rem !important;
            }

            .stripe-security-notice {
                font-size: 0.75rem;
                color: #94a3b8;
                margin-top: 12px;
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 6px;
            }

            .stripe-security-notice strong {
                color: #6366f1; /* Stripe Blurple */
            }

            .payment-or-divider {
                display: flex;
                align-items: center;
                gap: 12px;
                color: #64748b;
                font-size: 0.7rem;
                font-weight: 700;
                letter-spacing: 0.1em;
                margin: 24px 0 16px;
            }

            .payment-or-divider::before,
            .payment-or-divider::after {
                content: '';
                flex: 1;
                height: 1px;
                background: #e2e8f0;
            }

            @media (max-width: 480px) {
                .auth-header-section { padding: 24px 20px 16px; }
                .auth-form-body { padding: 0 20px 24px; }
                .auth-modal-card { border-radius: 16px; width: 95%; }
            }
        `;
        
        const style = document.createElement('style');
        style.id = 'auth-ui-styles';
        style.textContent = css;
        document.head.appendChild(style);
    }
};