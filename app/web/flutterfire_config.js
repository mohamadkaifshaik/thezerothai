// ADR-0032 D10, C4: web ships no Analytics and no Crashlytics. firebase_core_web injects
// firebase-<service>.js from www.gstatic.com for every registered service at Firebase.initializeApp;
// this stops the analytics script from being downloaded at all. It must run before flutter_bootstrap.js.
// Kept as an external same-origin file so the CSP (script-src 'self') needs no new hash.
// Verified against firebase_core_web 3.12.0, lib/src/firebase_core_web.dart (_ignoredServiceScripts).
window.flutterfire_ignore_scripts = ['analytics'];
