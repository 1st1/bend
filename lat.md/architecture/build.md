# Build and signing

Development builds, distribution signing, and isolated application profiles.

See [[lat.md/tests/build-tests|Test coverage]].

## Development signing

[build-app.sh](../../scripts/build-app.sh) packages and signs `dist/Bend Debug.app`, using `BEND_SIGNING_IDENTITY` when set and Yury's Developer ID Application certificate otherwise.

Requires macOS 26 or newer and a Swift 6 toolchain with a current macOS SDK (Xcode or Command Line Tools). From the repository root, build and open the signed app:

```sh
./scripts/build-app.sh --open
```

On another Mac, select an installed Apple-issued signing identity:

```sh
BEND_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build-app.sh --open
```

The certificate's Apple intermediate must also be installed; Developer ID G2 certificates require Apple's Developer ID G2 intermediate. `security find-identity -v -p codesigning` should list the identity as valid. For development without the packaging script's signing step, open [Package.swift](../../Package.swift) in Xcode or run `swift run Bend`.

The build explicitly supplies the installed SDK version to the linker while retaining macOS 26 as the deployment target in both [[Package.swift]] and the app bundle. Debug and production have the same minimum OS; Liquid Glass and WebKit extensions are available throughout the supported OS range. This prevents SwiftPM from stamping the deployment target as the linked SDK and making AppKit render legacy controls and toolbar chrome.

[[releases#Version and build identity]] defines the checked-in app version and separate bundle build number. The package and executable product are named Bend. Development uses the Debug compilation configuration and the isolated [[lat.md/architecture/build#Build profile isolation|Bend Debug profile]]. Production retains the existing identity and data. Internal Swift module names and `browse://` addresses remain stable. The legacy `BROWSE_SIGNING_IDENTITY` override is honored when the Bend override is unset.

The script enables Hardened Runtime and verifies the signature before reporting success and does not fall back to ad-hoc or self-signed signing. Apple-issued development or Developer ID signing uses a stable team partition for Keychain access; switching identities can still require one new approval. A self-signed identity supplied explicitly through the override does not prevent recurring WebCrypto prompts because macOS assigns it a per-build code-hash partition. The build does not alter Keychain access lists or key data.

Packaging creates a separate bundle in a temporary directory under `dist`, then signs and verifies it before replacing the installed bundle by rename. It does not overwrite the executable mapped by a running Bend process. Signing or verification failure leaves the previous build intact; publication failure restores the previous bundle. The script leaves Bend running and asks for a restart to use the new build. Extension packages, enablement, grants, and WebKit data remain outside the app bundle.

## Application icon

The app uses the supplied painted Bend artwork, with the untouched 2048×2048 source preserved in [BendIcon-original.jpg](../../Assets/BendIcon-original.jpg).

The generated icon uses a top-aligned square crop that trims extra wall below and equally at the sides, vertically centering the B's main body rather than its trailing brush stroke.

[generate-app-icon.swift](../../scripts/generate-app-icon.swift) renders the artwork with rounded corners, transparent margins, and a subtle shadow into standard and Retina icon sizes. Run `swift scripts/generate-app-icon.swift` on macOS to regenerate [AppIcon.png](../../Assets/AppIcon.png) and [AppIcon.icns](../../Assets/AppIcon.icns). [build-app.sh](../../scripts/build-app.sh) copies the ICNS into bundle resources and sets the icon entry in Info.plist before signing.

## Production installer

[build-prod.sh](../../scripts/build-prod.sh) creates a signed, notarized drag-to-Applications DMG, separate from the fast [[lat.md/architecture/build#Development signing|development build]].

Run `./scripts/build-prod.sh` on macOS with Python 3 and Apple’s build tools; no logged-in Finder session is required. It invokes the app builder with `--production --output` into its private payload directory, selecting Release compilation and the production profile; it never copies the development app. It validates the production profile marker and bundle identity before notarization. It defaults to the saved `bend-notary` Keychain profile; `--keychain-profile NAME` or `BEND_NOTARY_PROFILE` selects another. Signing uses the same Developer ID identity override as the development build. Credentials stay in Keychain; BEND_NOTARY_KEYCHAIN explicitly selects the temporary keychain used by [[releases#GitHub build workflow]]. The script builds the host architecture and names the installer `dist/Bend-VERSION-ARCH.dmg` from the app plist and executable, without implying a universal build.

A private copy of the app receives a timestamped Developer ID Application signature, is submitted with `notarytool`, and has its accepted ticket stapled and validated before packaging. The development bundle stays separate from this stapled copy. [render-dmg-background.swift](../../scripts/render-dmg-background.swift) draws a Retina installer background with instructions and an arrow. [[scripts/dmgbuild.sh]] creates the compressed disk image without Finder automation, using pinned Python dependencies in [[scripts/dmgbuild-requirements.txt]]. [[scripts/dmg-settings.py]] writes the background, fixed icon-view layout, and Applications shortcut directly; its window content remains 640 by 400 points with 96-point icons. The helper caches its isolated environment under the ignored build directory.

The compressed, read-only DMG is signed, notarized, stapled, and checked by Gatekeeper and disk-image verification before replacing an existing installer. Successful builds remove their own `dist/notary-*` folder; failed builds retain app and DMG submission results and service logs for troubleshooting. Cleanup leaves other builds’ log folders untouched. Rejected or timed-out submissions and failed checks abort publication. Stapling retries briefly while Apple's ticket propagates. dmgbuild owns temporary image mounting and detachment; packaging failures abort publication. [[lat.md/tests/build-tests#Production installer publication]] checks failure preservation and sequencing with isolated command stand-ins; real notarization and disk-image layout verification require a native production run.

## Build profile isolation

[[Sources/Browse/AppProfile.swift#AppProfile]] separates Bend Debug from production Bend across app identity, file storage, preferences, window state, and WebKit storage. Existing production data remains in place.

The default [[scripts/build-app.sh]] produces `dist/Bend Debug.app`, with bundle identifier `dev.yury.browse.debug`, Debug compilation, and data under `~/Library/Application Support/Bend Debug`. Production builds explicitly define `BEND_PRODUCTION`, retain `dev.yury.browse.prototype` and `~/Library/Application Support/BrowsePrototype`, and are packaged as `Bend.app` inside the production DMG. Unpackaged SwiftPM and Xcode runs default to the debug profile even when optimized. The compiler-selected profile cannot silently change when a bundle is renamed or moved; `--print-build-profile` reads the profile preferences and prints the executable’s selected identity without opening the browser.

[[Sources/Browse/BrowserWindows.swift#BrowserWindows#init]] and [[Sources/Browse/BrowserStore.swift#BrowserStore#init]] select the profile root for windows, sessions, history, website settings, download history, and owned extension packages and configuration. [[Sources/Browse/InputDiagnostics.swift#InputDiagnostics#start]] places diagnostic files under that root. UserDefaults domains and window autosave names are distinct, while the application menus, About panel, and browser windows use the selected app name. Settings’ SwiftUI preferences and native diagnostic preference reads use the same profile domain. Packaged apps use standard UserDefaults, isolated by bundle identity; named suites are used only when the host identifier differs, as in SwiftPM tools and tests. Foundation rejects a named suite equal to the running app’s own bundle ID.

Debug uses stable, dedicated website-data and extension-controller identifiers. Production keeps WebKit’s existing default stores. [[Sources/Browse/ExtensionManager.swift#ExtensionManager#init]] uses the profile stores unless callers supply isolated test stores. Website navigation, extension authentication, and download retries use the same selected website store. Cookies, local storage, cache, service workers, extension settings, and filtering databases are separate. User-selected files and the system Downloads folder remain ordinary shared filesystem locations; each profile separately saves its download destination and history. No production profile is copied into Debug. [[lat.md/tests/build-tests#Build profile isolation]] verifies identity and persistence boundaries, including actual cookie isolation.
