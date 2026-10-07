# Disposable Browser

A macOS-first, keyboard-invoked peek browser. Native Swift/AppKit panel with
WKWebView; no bundled Chromium or shared cross-language core.

## Build and launch (macOS 14+)

Install Xcode 26+ or command-line tools providing Swift 6.2+ (required by
KeyboardShortcuts 3.1.0). Confirm with `swift --version`, then:

```sh
bash scripts/build-macos.sh
open "dist/Disposable Browser.app"
```

The first build downloads KeyboardShortcuts 3.1.0. The script runs tests, builds
a release app bundle, and signs it locally (ad hoc). This is a development build,
not a notarized distribution. Keep the bundle in a stable location for Accessibility
permission; rebuilding may require granting permission again.

## Use

- On first launch, set **Show / dismiss browser** in Settings. The separate
  **Search selected text** shortcut is optional. No global shortcuts are claimed
  without your choice.
- Enable **Search selected text when opening** to search the source app's selection
  with the main shortcut. This is off by default. With no readable selection or
  denied Accessibility access, it opens focused manual search. When already open,
  the shortcut dismisses without reading selection.
- On macOS 26+, navigation and Settings controls use native Liquid Glass; macOS
  14–25 use native materials. Website content stays opaque.
- The globe in the menu bar opens the browser, Settings, or quits the app.
- Choose Google or DuckDuckGo in Settings.
- **Website view** defaults to **Mobile**, requesting a mobile Safari layout for
  the narrow panel. **Desktop** uses WebKit's native user agent. The choice is
  saved; changing it reloads an open page without replacing its URL or cookies.
  Websites can ignore the requested user agent; this is not full device emulation.
- The panel opens at the right edge of the screen containing the pointer. It
  can be moved and resized. This initial version does not inspect the source
  window's geometry or guarantee placement beside it.
- Enter searches or HTTP(S) addresses. Bare domains open over HTTPS.
- **Escape**, **⌘W**, the close button, or the toggle shortcut dismiss the
  panel, discard its page/navigation stack, and attempt to restore the source app.
- The compact native header has one search/address pill and icon controls.
  Drag its background to move the panel; native traffic lights and resizing remain.
- While waiting for a search, one native frosted window material covers the header
  and body, with the centered prompt **A quick look?**. Navigation replaces the
  waiting body with opaque website content below the toolbar's safe area; reopening
  after dismissal restores the prompt and focused search.
  System accessibility settings control the material's appearance.
- **⌘L** focuses the search field. The **Back** chevron navigates within the current
  lookup and is disabled when there is no previous page.
- The **Open in Browser** arrow icon sends the current HTTP(S) URL to your default
  browser. It is disabled without an eligible URL. Both icons have tooltips and
  accessibility names. Loading, errors, and selection notices appear only as needed;
  there is no permanent title/help/cookies row in the panel.
- Selected-text search reads Accessibility selection before showing the panel;
  selected text is always searched, not interpreted as an address.

Enable selection access using the button in Settings and macOS **Privacy & Security
→ Accessibility**. Unsupported apps or empty selections fall back to manual input
with an explanatory message. There is no clipboard mutation, simulated copy,
screen capture, or permission request during ordinary searches.

## Session and privacy

Dismissal destroys the webview, but WebKit cookies and site storage persist, so
logins can survive. **This is not private browsing.** Queries are sent to your
chosen search engine. The app does not store its own query history. Settings and
shortcuts use UserDefaults. Mobile view overrides the user agent with a mobile
Safari identity; Desktop view removes that override. Neither changes browser
security, cookie storage, or the actual WebKit engine.

## Verification

```sh
swift test
```

The search/address and shortcut tests also run on Linux with Swift installed.
The native tests run only on macOS and check view-mode UA choices, compact header
layout/accessibility, and transient notices. A macOS build and the checks below
are required before considering the interaction verified:

1. Set both shortcuts; summon from another app and type into the field and a page.
2. Search selected Unicode text in Safari, TextEdit, a PDF reader, and your editor.
   Check the no-selection and permission-denied messages too.
3. Dismiss with Escape, ⌘W, close button, and toggle shortcut. Check focus returns
   to the source app and reopening has no previous page or back stack.
4. Check Spaces, fullscreen apps, multiple displays, dragging, and resizing.
5. Check redirects, back navigation, target-blank links, network failures, and
   opening in the default browser. Downloads and new popup windows are not supported.
6. Confirm sign-ins persist after dismissal and restarting the app.
7. Switch Website view with a page open: check it reloads at the same URL with
   cookies retained. Reopen and restart to check the saved choice. Compare a Google
   search in Mobile and Desktop at the normal narrow width; sites may serve
   different layouts, and Desktop content can overflow.

Windows and Linux desktop implementations are not included yet. Future ports
should share the behavior contract and fixtures rather than a Rust FFI core.
