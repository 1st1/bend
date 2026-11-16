# Changelog

User-facing changes to Bend, maintained with Changie. Versions use `MAJOR.MINOR.PATCH`.

Earlier prototype builds used the version `0.1` without a versioned changelog; `0.1.0` records that baseline.


## v0.8.2
### Fixed
- Keep HTTPS certificate inspection available when WebKit omits the loaded page’s server trust, including on x.com.
- Filter weak fuzzy address suggestions, prefer complete fuzzy address matches over matching prefixes with extra suffixes, and show cached favicons in address suggestions and browsing history.

## v0.8.1
### Fixed
- Match IPv4-like address input against visited IP address prefixes instead of unrelated numbers in page titles or URLs.
- Keep favorites and sidebar controls at their normal width after closing the last regular tab, including after restarting Bend.

## v0.8.0
### Added
- Find visited pages with editor-style fuzzy address matching: type github/jit to open github.com/1st1/jit, with matched characters highlighted and consecutive text and word boundaries ranked above scattered matches.
- Read dated release notes at bend://log, with What's New opening once after a newer version or build is installed.
- Let AI read Bend release notes and request system details or a one-time current location, with approval required before sharing system or location data.
- Show keyboard shortcuts beside command-menu actions, automatically matching their native menu bindings.
- Explain or summarize selected text locally from the command menu. Let chat read selected text or share a visible-page screenshot after approval, with a screenshot preview before sharing.
- Continue past a website certificate error after explicit confirmation, including for local routers. Sites with an accepted exception show a red domain menu and a Not Secure explanation.
- Configure Enter, Command-Enter, Option-Enter, and Shift-Enter independently in Settings → AI. Enter and Command-Enter send by default; Option-Enter and Shift-Enter insert a new line.
- Choose Local in the model selector for on-device Apple Intelligence chat with browser tools, and summarize pages from the Command-Shift-P menu without sending page content to the cloud.
### Changed
- Disable extension actions and content access on native bend:// pages while keeping extensions available on websites.
### Fixed
- Keep pane frames and headers fixed when scrolling empty pages; scroll only the page contents.
- Keep webpage selections, including images, selected when moving focus to chat and typing a message.

## v0.7.0
### Added
- Add website file uploads, camera and microphone capture controls, and per-site camera, microphone, and location blocking.
- Toggle the active tab’s chat with Command-Shift-C.
### Changed
- Remember website camera, microphone, and location permissions, manage Ask/Allow/Block in Websites settings, hide unavailable passkey settings, and provide compact searchable site controls with certificate inspection, domain labels, and extension actions.
- Reduce sidebar spacing above and below favorite tiles.
### Fixed
- Restore camera and microphone access for video calls and other website media capture.
- Keep embedded website permissions separate from their parent sites and immediately stop camera or microphone capture when access is blocked.

## v0.6.0
### Added
- Chat with AI about the current tab's panes in a resizable sidebar, with streaming Markdown, clickable citations, web search, and expandable tool details.
- Sign in with an OpenAI account to use your ChatGPT plan, or connect with an OpenAI, Anthropic, or Vercel AI Gateway API key. Choose models, test connections, and customize the system prompt in Settings.
- Let AI read pages, open and navigate panes, click controls, and fill ordinary fields, with individual tool switches and action approval buttons in chat.
- Search saved AI conversations and restore their messages and pane layouts. Chat visibility and panel width persist across restarts.
- Selectively clear browsing history, AI chats, download records, cache, and site data from Privacy settings.
- Choose Google, DuckDuckGo, Kagi, or a custom search URL as the default search engine.
- Return panes to their original pinned URL from the pane header or command popup.
- Configure shared glass style, tint, and darkening for the media player and AI chat input, plus transparency for both user and assistant bubbles, in UI settings.
### Changed
- Use Enter for a chat newline and Command-Enter to send. Escape stops a response; Up and Down recall previous prompts when the input is empty, and Escape clears a recalled prompt.
- Float the frosted chat input and media controls over scrolling content, fade messages and tabs beneath their toolbars, and center a compact glass Latest button in chat.
- Keep both chat bubble types within 90% of the transcript width, use dark-grey assistant bubbles, and preserve native text styling when recalling prompts.
- Present Settings as a modal window with Escape and Command-W dismissal. Account sign-in opens in an interactive Bend WebKit popup above Settings.
- Hide the pane zoom button in single-pane tabs.
### Fixed
- Keep fitting panes visible when space runs out and offer to move overflowing panes into separate tabs without reloading them.
- Open link-created tabs in the background and return to their surviving origin when closed.
- Open chat links in the tab's designated link pane or sole remaining pane when a cited pane no longer exists, and label AI Chat History tabs correctly.
- Keep chat controls and input spacing aligned on either sidebar side, focus chat immediately, and switch instantly between tabs with and without chat.
- Prevent a crash when closing a tab with active AI chat and extensions.
- Use bend URLs and friendly names for native pages while preserving compatibility with legacy browse URLs.
### Security
- Keep AI unavailable in private windows, require explicit approval for browser actions, and exclude editable drafts and sensitive fields from page reads and filling.
- Bound untrusted AI counters and outputs, validate OAuth callbacks and signed identity claims, and release malformed or stalled loopback connections.

## v0.5.0
### Added
- Use Command-Shift-P to search tab and pane actions, and duplicate complete tabs from the command popup or tab context menu.
- Use the native macOS Dock animation and progress reporting for downloads.
- Add website security controls for fraudulent-site warnings, JavaScript, HTTP warnings, and cookie blocking, plus website data management. JavaScript changes take effect on the next navigation.
- Add Privacy settings for tracking prevention, Apple Pay disclosure, and ad measurement. Ad measurement is off by default; additional WebKit privacy protections are enabled.
- Install Mouse Gestures for Safari in Bend, with an App Store handoff when needed, and use its default new-tab gesture.
### Changed
- Check for Bend updates hourly and on launch when the last check was at least ten minutes ago.
- Explain extension permissions in a readable dialog with website access, extension icons, and expandable technical details.
### Fixed
- Preserve the reusable Command-click destination when duplicating a tab, including after restarting the browser.
- Remind users how to connect Bend to the 1Password desktop app in extension settings.

## v0.4.0
### Added
- Open 1Password and Dark Reader settings directly from their cards in Extensions settings.
- Print the focused web page with Command-P or File → Print, using the native macOS print dialog and PDF options.
### Changed
- Refine the address popup with native Liquid Glass, a compact search field, lighter result typography, and subtler shortcut hints.
- Show Open Link in New Tab first in the right-click link menu, and open it in the background without switching away from the current page.
### Fixed
- Use paired macOS selection colors for address autocomplete and selected suggestions, retaining full text contrast on selected rows.
- Open Foxy Gestures settings by supplying browser information and handling unavailable Firefox settings and permission checks. Explain the remaining limitation on default right-button gestures.
- Share cookies and website data across tabs and panes within each private window, keeping separate private windows isolated and clearing their data on closure.
### Known limitations
- WebKit may finish loading extension request-blocking rules after the initial page navigation.

## v0.3.0
### Added
- Choose whether the sidebar docks on the left or right in UI settings.
- Check for new Bend releases and offer an update button, with verified downloads, installation, and relaunch through Sparkle.
### Changed
- Keep untouched panes evenly sized when opening or moving panes, while preserving manually resized layouts.
- Show centered stacked favicons for multi-pane tabs, with the active pane in front. Round favicon corners in tabs and pane titles.
- Center stacked favicons vertically and quickly fade them when switching panes or adding a pane.
### Fixed
- Keep website favicons across browser restarts without loading background tabs. Private browsing icons remain in memory only.
- Show the packaged app version in About Bend instead of the old prototype label.
- Keep the Settings sidebar fixed in width when SwiftUI resets its native layout constraints.

## v0.2.0
### Added
- Show the page URL when hovering its pane title.
- Private windows with Command-Shift-N, temporary history, isolated cookies and website storage for each pane, and per-extension private browsing permissions. Extension pages and popups are unavailable in private windows to keep website cookies isolated.
- Customize Option-click link destinations and open links in a new pane, tab, or window from the context menu.
- Show hidden-tab counts in small pills at the sidebar scroll edges.
### Changed
- Match favorite buttons to tab corners, hover backgrounds, and selected glass styling.
### Fixed
- Avoid unnecessary URL preview truncation and stale title URLs when hovering page links.
- Activate the browser when clicking a pane title in an inactive window.
- Preserve native window focus when clicking pane titles without interrupting pane dragging.
- Fade partially scrolled sidebar tabs smoothly at both edges, including beneath favorites.
- Honor the configured Option-click link destination on macOS 26 instead of WebKit’s default download action.
- Keep short notification sounds out of the media player; show unknown-duration and live playback after seven seconds.
- Retry favicon loading when in-page navigation changes the URL during an icon request.

## v0.1.1
### Changed
- Bend now requires macOS 26 or later, with Liquid Glass and extension support available on every supported macOS version.
### Fixed
- Prevent native extension connections from stalling background work on Macs with limited CPU resources.

## v0.1.0

Initial prototype baseline. Detailed change tracking begins with the next release.
