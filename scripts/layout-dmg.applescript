on run arguments
    set installerFolder to (POSIX file (item 1 of arguments)) as alias
    tell application "Finder"
        open installerFolder
        set installerWindow to container window of installerFolder
        tell installerWindow
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set bounds to {120, 120, 760, 548}
        end tell
        set viewOptions to icon view options of installerWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff" of installerFolder
        set position of item "Bend.app" of installerFolder to {170, 200}
        set position of item "Applications" of installerFolder to {470, 200}
        update installerFolder without registering applications
        delay 2
        close installerWindow
    end tell
end run
