# Command panel

Command discovery, validation, and execution in the command popup.

See [[lat.md/tests/commands-tests|Test coverage]].

## Command popup

[[Sources/Browse/BrowseApp.swift#AppDelegate#showCommands]] opens a searchable Command-Shift-P action menu for the active pane and tab, sharing the [[lat.md/architecture/address-entry#Location popup]] controller, glass shell, rows, positioning, and keyboard navigation.

[[Sources/Browse/BrowseApp.swift#AppDelegate#popupCommands]] supplies [[lat.md/architecture/ai|Chat]], Summarize Page using Local AI, favorite/remove favorite, duplicate tab, close tab, pin/unpin tab and pane, hide/show sidebar, Settings, Print, History, and developer tools. Labels reflect current state; unavailable actions remain visible but dimmed. Favorites retain the existing Google-account customization flow. Pin protection, private-window favorite restrictions, and print/inspector availability follow existing action rules.

Queries match words across action titles and descriptions without address autocompletion. Arrow keys select available actions without replacing the query; Return or a click executes, and Escape dismisses. Empty matches show a message. Execution rechecks availability and the original window, tab, and focused pane, dismissing the popup and restoring browser focus before invoking the action. Switching from initial location entry to commands retains the new blank item.

[[Sources/Browse/BrowserStore.swift#BrowserStore#duplicateTab]] inserts a selected copy immediately after the source in its workspace. The same action is available in sidebar tab context menus and favorite tile context menus when the favorite has an open tab. It copies current addresses, title, split axes, ratios, automatic-sizing flags, and focused-pane position with fresh identities. The dedicated Command-click destination is remapped to its copied pane and persists across restart; [[lat.md/tests/link-navigation-tests#Dedicated pane window restoration]] covers main and secondary windows. Copies start unpinned without favorite associations or shared live controllers; page forms and navigation history are not cloned. [[lat.md/tests/commands-tests#Command popup actions]] covers commands and native popup interactions.

## Command shortcuts

[[Sources/Browse/PopupCommand.swift#MenuShortcut]] derives each command's shortcut from the live native menu by action selector and optional tag, so the native keyboard binding is the single source of truth.

[[Sources/Browse/PopupCommand.swift#PopupCommand]] associates menu-backed commands with their selectors rather than copying shortcut strings. The popup renders a trailing shortcut label, including on disabled commands, and removes manual shortcut text from descriptions. New commands with a menu action automatically reflect that action's current binding; missing bindings and hidden aliases produce no label. Selector tags distinguish actions such as zoom directions.

The [[Sources/Browse/BrowserView.swift#SidebarTabMenu|sidebar tab context menu]] displays each action’s current native shortcut when assigned. Its actions target the tab that opened the menu.

Settings → Shortcuts lists customizable commands from [[Sources/Browse/BrowseApp.swift#AppDelegate#popupCommands]], including unavailable commands and those with no assigned binding. Back, Forward, and Reload Page share their editable bindings with the View menu. What’s New is available from the app menu and palette without a shortcut editor entry. Copy Page URL (Option-Command-C) copies the focused pane’s address as plain text from the Edit menu or command popup.

[[Sources/Browse/CommandShortcuts.swift#CommandShortcuts]] captures menu defaults before applying profile-specific overrides. Edits update native key equivalents immediately. Conflicts with other menu commands, including active hidden aliases, preserve the previous binding. Leaving Shortcuts or reopening Settings dismisses the warning for a rejected binding. Commands without a dedicated selector use View → Commands and resolve availability against the current browser context. Selection shortcuts read the focused page’s selection at invocation.
