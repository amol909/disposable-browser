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
permission.

Ad hoc signatures change with every build, so macOS drops Accessibility access after
each rebuild. To keep it, sign with a certificate: set `CODESIGN_IDENTITY`, or write the
identity hash to `.codesign-identity` in the repository root (git-ignored). List
identities with `security find-identity -v -p codesigning`. Without an identity, the
script signs ad hoc and prints a warning.

## Use

- On first launch, set **Show / dismiss browser** in Settings. The separate
  **Search selected text** shortcut is optional. No global shortcuts are claimed
  without your choice.
- Enable **Search selected text when opening** to search the source app's selection
  with the main shortcut. This is off by default. With no readable selection, it
  opens focused manual search. Without Accessibility access, it opens manual search
  with a notice, as the selection shortcut does. When already open, the shortcut
  dismisses without reading selection.
- On macOS 26+, toolbar and Settings controls use native Liquid Glass; macOS
  14–25 use native materials. Website content stays opaque. The build script records
  the real SDK version in the binary, because SwiftPM records the deployment target;
  without that step, macOS shows the pre-Liquid Glass compatibility appearance.
- The globe in the menu bar opens the browser, Settings, or quits the app.
- Choose Google or DuckDuckGo in Settings.
- **Website view** defaults to **Mobile**, requesting a mobile Safari layout for
  the narrow panel. **Desktop** uses WebKit's native user agent. The choice is
  saved; changing it reloads an open page without replacing its URL or cookies.
  Websites can ignore the requested user agent; this is not full device emulation.
- The panel opens at the right edge of the screen containing the pointer. It
  can be moved and resized. This initial version does not inspect the source
  window's geometry or guarantee placement beside it.
- Enter searches or HTTP(S) addresses. Bare domains and IPv4 addresses open over
  HTTPS. Numbers (`3.14`), versions (`v1.2`), and email addresses are searched.
- **Escape**, **⌘W**, the close button, or the toggle shortcut dismiss the
  panel, discard its page/navigation stack, and attempt to restore the source app. If
  you switched to another app while the panel was open, that app stays in front.
- The compact native toolbar has **Back**, one search/address field, and **Open in
  Browser**, in Safari's order. While browsing, the field shows only the host (for
  example `google.com`); focusing it shows the full URL. Drag the toolbar background
  to move the panel; native traffic lights and resizing remain.
- While waiting for a search, the panel is only its toolbar: a slim bar on a
  translucent native material, with focused search. Notices make the bar grow just
  enough to show them, and the bar resizes only horizontally. Navigation expands the
  panel downward from the bar's top edge to the page height in a smooth animation
  (instant with **Reduce motion**). The page gets its final size before the animation,
  so it does not re-layout on every frame. Dismissal discards the page and
  returns to the bar. The expanded height you set by resizing is kept for later lookups.
  On macOS 26+, the page scrolls under the glass toolbar with a soft blur edge, and
  WebKit receives the covered area as obscured insets. On macOS 14–25, the page
  starts below the toolbar. System accessibility settings control the material's appearance.
- **⌘L** focuses the search field. The **Back** chevron navigates within the current
  lookup and is disabled when there is no previous page.
- The **Open in Browser** compass icon sends the current HTTP(S) URL to your default
  browser. It is disabled without an eligible URL. Both icons have tooltips and
  accessibility names. A thin accent line under the toolbar shows load progress.
  Errors and selection notices appear in a small floating banner only as needed;
  there is no permanent title/help/cookies row in the panel.
- Shortcuts act when pressed, not when released. Selected-text search shows the focused
  bar at once and reads the Accessibility selection in the background, then searches it.
  Escape closes the panel during the read too. If you type before the read ends, your
  text is kept. Selected text is always searched, not interpreted as an address. Line breaks and
  repeated spaces become single spaces, and selections longer than 500 characters
  are cut at a word boundary.
- Native text views give their selection directly. For page selections in Safari,
  Chromium browsers, and Electron apps, the app reads WebKit/Chromium text-marker
  ranges. Electron apps (for example Slack or VS Code) expose text only after a client
  sets `AXManualAccessibility`; the app sets it once per running app, which turns on
  that app's accessibility tree and can cost it some performance. Chromium browsers
  also accept it. Each Accessibility request times out after 0.5 seconds, so a hung
  app cannot freeze the panel.

Enable selection access using the button in Settings and macOS **Privacy & Security
→ Accessibility**. Settings shows whether access is allowed. It updates when macOS reports an
Accessibility change and when you return to the app; it does not poll.
With ad hoc signing, macOS drops access after a rebuild; if the status shows not
allowed, remove and re-add the app in that list, or sign with a certificate (see above). Unsupported apps or empty selections fall back to manual input
with an explanatory message. By default there is no clipboard mutation, simulated
copy, screen capture, or permission request during ordinary searches.

Some apps draw their own text and report no selection to Accessibility at all, for
example GPUI terminals such as Herdr. For those, turn on **Copy selection when it can't
be read** in Settings (off by default). When an app cannot report a selection:

- If that app changed the clipboard in the last 15 seconds while it was in front (for
  example a copy-on-select terminal), its clipboard text is searched at once. To know
  this, Disposable Browser checks the clipboard change count four times a second and
  notes the frontmost app; it does not read clipboard contents until you search.
- Otherwise it presses the app's Copy menu item (or sends ⌘C), reads the copied text,
  and restores every previous clipboard item. Clipboard managers may record the copy.
  A typed ⌘C needs the source app to have keyboard focus, so the panel hides for about
  50 ms while it is sent. Apps with a Copy menu item do not need this.

Apps that report an empty selection never receive Copy. A copy made in the source app
within 15 seconds is searched even if you meant a newer, uncopied selection. Selection reads log their outcome (never the text) under the subsystem
`com.amol909.disposable-browser`.

## Startup

The app keeps one hidden webview ready, with its web content process already started, so
opening and the first page load do not wait for WebKit. It prepares the next one after
each dismissal. This costs the memory of one idle web process while the panel is hidden.

Measure opening and first-load times (results print as `BENCHMARK` lines):

```sh
DISPOSABLE_BROWSER_BENCHMARK=1 swift test --filter StartupBenchmarkTests
```

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
   Clicked `mailto:`, `tel:`, `sms:`, and FaceTime links open their system app; other
   custom schemes are blocked.
6. Confirm sign-ins persist after dismissal and restarting the app.
7. Switch Website view with a page open: check it reloads at the same URL with
   cookies retained. Reopen and restart to check the saved choice. Compare a Google
   search in Mobile and Desktop at the normal narrow width; sites may serve
   different layouts, and Desktop content can overflow.

Windows and Linux desktop implementations are not included yet. Future ports
should share the behavior contract and fixtures rather than a Rust FFI core.

## License

MIT. See [LICENSE](LICENSE).
