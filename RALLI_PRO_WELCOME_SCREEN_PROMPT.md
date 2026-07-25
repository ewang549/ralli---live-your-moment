# Build Prompt: "Ralli Pro" beta welcome screen

Small, self-contained addition. Add a one-time welcome screen shown before login, on first launch only, thanking beta users and granting them "Ralli Pro" for free. This is cosmetic/messaging for now — no real paywall or entitlement system exists yet, so this just needs to *feel* like a premium unlock, not build actual subscription infrastructure.

Do not touch anything else in the app. Follow `RALLI_DESIGN_SYSTEM.md` (coral accent, warm neutrals, soft glass).

---

## 1. The "Pro" wordmark treatment

Wherever "Ralli Pro" appears (this welcome screen now; likely a badge/profile label later), style it as: **"Ralli"** in the normal wordmark style/color, and **"Pro"** in a distinct **cool gold/metallic gradient** — a genuinely premium-looking gold (think a warm brass-to-champagne gradient, not flat yellow), with a subtle shine/sheen. This should read as a special, valuable label sitting next to the normal coral brand, not just recolored text.

- Build this as a small reusable component (e.g. `RalliProBadge` or an extension on `RalliWordmark`) so it can be reused consistently anywhere "Pro" needs to appear later — profile, settings, etc.
- Gold treatment: a linear gradient (e.g. deep gold → bright champagne → deep gold) as the text fill/foreground, bold weight, maybe a very subtle glow/shine. Keep it tasteful — premium, not gaudy, not clashing with the coral system elsewhere on screen.

## 2. First-launch welcome screen (before login)

- Add a new full-screen view shown **once**, on the very first app launch, **before** the Welcome/sign-in screen (`WelcomeView` in `AuthGateView.swift`) — so it's the first thing a fresh install ever shows, ahead of sign up/log in.
- Persist a flag (e.g. `UserDefaults`, similar to how `PushNotifications.hasPrimed` is tracked) so it only ever shows once per install, never again after the user dismisses/continues past it — not on every launch, not after logging in and out.
- Content, warm and appreciative in tone:
  - A headline thanking them for being an early tester — e.g. **"Thank you for being one of our first."**
  - A line explaining the gift: something like **"As a valued beta user, you've got Ralli Pro — on us."**, with "Ralli Pro" rendered using the gold treatment from §1.
  - A short line on what that means in spirit (keep vague since there's no real feature list yet) — e.g. "Every premium feature we build, free for as long as you're with us in beta."
  - A single clear continue action (coral primary button) — e.g. **"Let's go"** or **"Continue"** — that dismisses the screen and proceeds to the normal Welcome/sign-in flow.
- Visual feel: make it feel like a genuine "unlock" moment — full-bleed warm background (matches onboarding's existing gradient treatment), the gold "Ralli Pro" as the visual centerpiece, generous spacing, maybe a subtle celebratory touch (a soft glow, gentle scale-in animation on appear) — but keep it to one screen, no multi-step flow.

## 3. No real backend/entitlement work needed

This is presentation only for now — do not build a subscription/entitlement system, App Store In-App Purchase products, or any backend flag for "who has Pro." Every beta user simply sees this screen once; there's nothing to gate or check elsewhere in the app yet. Keep the scope exactly to the welcome screen and the reusable gold "Pro" label component.

---

## Acceptance

- A brand-new install shows the welcome screen first, before the sign-in screen, with the correct thank-you copy and a gold-treated "Ralli Pro."
- Dismissing it moves straight into the normal sign-up/login flow.
- Force-quitting and relaunching does **not** show it again.
- The gold "Pro" styling is a reusable component, not one-off inline styling, so it can be dropped in elsewhere later without rebuilding it.
- Nothing else in the app changes — verify Pulse, camera, and login still work exactly as before.
