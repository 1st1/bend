# Command panel

Command discovery, validation, and execution in the command popup.

See [[lat.md/tests/commands-tests|Test coverage]].

## Command popup

[[Sources/Browse/BrowseApp.swift#AppDelegate#showCommands]] opens a searchable Command-Shift-P action menu for the active pane and tab, sharing the [[lat.md/architecture/address-entry#Location popup]] controller, glass shell, rows, positioning, and keyboard navigation.

[[Sources/Browse/BrowseApp.swift#AppDelegate#popupCommands]] supplies favorite/remove favorite, duplicate tab, close tab, pin/unpin tab and pane, hide/show sidebar, Settings, Print, History, and developer tools. Labels reflect current state; unavailable actions remain visible but dimmed. Favorites retain the existing Google-account customization flow. Pin protection, private-window favorite restrictions, and print/inspector availability follow existing action rules.

Queries match words across action titles and descriptions without address autocompletion. Arrow keys select available actions without replacing the query; Return or a click executes, and Escape dismisses. Empty matches show a message. Execution rechecks availability and the original window, tab, and focused pane, dismissing the popup and restoring browser focus before invoking the action. Switching from initial location entry to commands retains the new blank item.

[[Sources/Browse/BrowserStore.swift#BrowserStore#duplicateTab]] inserts a selected copy immediately after the source in its workspace. The same action is available in sidebar tab context menus and favorite tile context menus when the favorite has an open tab. It copies current addresses, title, split axes, ratios, automatic-sizing flags, and focused-pane position with fresh identities. The dedicated Command-click destination is remapped to its copied pane and persists across restart; [[lat.md/tests/link-navigation-tests#Dedicated pane window restoration]] covers main and secondary windows. Copies start unpinned without favorite associations or shared live controllers; page forms and navigation history are not cloned. [[lat.md/tests/commands-tests#Command popup actions]] covers commands and native popup interactions.
