# Quiz Champion Mobile App — Temporary Free Access

This version keeps the existing Quiz Champion web/PWA structure and adds mobile-friendly authentication.

## Changes in this version
- Temporary free-access mode: payment is NOT required to use quizzes after login.
- Login and student registration are available from the same authentication window.
- Email authentication: Supabase email OTP/magic-link flow.
- Mobile authentication: Supabase SMS OTP flow.
- Quiz/books/leaderboard remain protected behind login, but not payment.
- Payment page remains in the UI for future re-enablement, but it does not block access in this temporary version.

## Important Supabase setting for phone login
Phone authentication must be enabled in the Supabase project and an SMS provider must be configured. The frontend is already prepared to call `signInWithOtp({ phone })` and `verifyOtp({ phone, token, type: 'sms' })`.

## Mobile use
The `www/` folder can be served over HTTPS as a PWA and installed on Android/iPhone. The same source can also be wrapped with Capacitor when Android SDK/Xcode are available.
