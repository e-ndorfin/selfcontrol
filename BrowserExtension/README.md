# Add to SelfControl (private Helium / Chrome extension)

Click the pinned icon on a website to save its main domain and visited hostname
in SelfControl's shared blocklist. A compatible running block gains those sites
immediately. With no block running, the sites are saved for future manual and
weekly blocks. The current page is left open without reloading; loaded content
may remain visible until another network request or navigation.

Routine additions do not request your Mac or friend's password. Initial setup
uses macOS administrator authorization to install/update the privileged helper.
Other SelfControl actions retain their existing authorization and friend checks.

## Install

Use the updated, locally signed SelfControl app from this repository (4.1.4,
build 415 or later). Build the workspace using your local signing identity. On
this Mac, the existing client/helper trust rules already match the local Apple
Development certificate. For a command-line build, disable the shared PCH to
avoid the repository's parallel version-header generation race:

```sh
xcodebuild -workspace selfcontrol.xcworkspace -scheme SelfControl \
  -configuration Debug -derivedDataPath build/browser-derived \
  GCC_PRECOMPILE_PREFIX_HEADER=NO \
  CODE_SIGN_IDENTITY='Apple Development: agarioloki@icloud.com (TMPW7QR9HJ)' \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=78A9HB362L build
```

Install the resulting `SelfControl.app` in `/Applications`, then:

```sh
cd BrowserExtension
npm ci
npm run build
python3 scripts/install.py
```

Run the installer as your normal signed-in user, without `sudo`. Enter any Mac
administrator credentials only in the macOS authentication dialog. The installer
updates the daemon and initializes an absent shared policy without enabling a
weekly schedule or changing a running block. Existing saved configuration is
preserved. Use `--app /absolute/path/SelfControl.app` for another installation.

Then in **Helium**:

1. Open `helium://extensions` and turn on **Developer mode**.
2. Choose **Load unpacked** and select
   `~/Library/Application Support/SelfControl/BrowserExtension`.
3. Pin **Add to SelfControl** in Helium's extensions menu.
4. Click its icon when viewing a distracting website.

The extension ID is fixed by the checked-in public manifest key. There is no
Web Store account, upload, or publication step. Source changes require rebuilding,
rerunning the installer, and clicking **Reload** on Helium's extensions page.
The installer defaults to Helium's user-data directory,
`~/Library/Application Support/net.imput.helium`. Use `--browser chrome` to register
Google Chrome instead, or `--browser-profile-dir /absolute/user-data/directory`
for a browser launched with a custom user-data directory. Native-host manifests
are placed at the root of that directory, not inside `Default` or `Profile 1`.
`--register-only` skips daemon setup when that setup has already succeeded.

## Feedback and troubleshooting

- **Green `+`**: saved, and added to the current block if one is running.
- **Green `OK`**: the site is already present in every applicable list.
- **Amber `!`**: saved for future blocks, but current enforcement failed; retry.
- **Red `!`**: unsupported page or unsuccessful addition. Hover for the reason.

The tooltip distinguishes saving for later from adding to a running block.
Only public HTTP/HTTPS DNS websites are supported. Browser pages, local hosts,
IP addresses, allowlist mode, and legacy blocks are rejected. Main domains are
selected using the Public Suffix List, including private suffixes: a page on
`alice.github.io` adds that tenant, not all of `github.io`.

Coverage follows SelfControl's existing network rules and domain-coverage options.
Adding both the main domain and visited hostname does not create a wildcard rule
for every possible subdomain.

If the helper is unavailable or outdated, rerun the installer. You can inspect
readiness without printing the site's list or changing any settings:

```sh
/Applications/SelfControl.app/Contents/MacOS/selfcontrol-cli --browser-status
```

Native messages contain domains only, never the URL path, query, page text, or
credentials. Native mode reserves stdout for length-prefixed JSON and does not
start the CLI's telemetry. It uses the existing signed CLI and XPC trust rules;
there is no background HTTP server. Chrome's native-host manifest authorizes
only this extension's origin, which the native helper checks again.

## Verify

From the repository root:

```sh
tests/run-schedule-checks.sh
tests/run-browser-checks.sh
```

Both focused suites use mocked enforcement and do not modify network rules.
Browser tests cover URL/domain selection, UI feedback, repeated clicks, native
framing and origin checks, helper compatibility, and partial failures. Daemon
regressions cover persistence, user ownership, friend protection, running blocks,
concurrent additions, and stale GUI saves.

## Remove the extension

Remove it from `helium://extensions`, then delete:

- `~/Library/Application Support/net.imput.helium/NativeMessagingHosts/org.eyebeam.selfcontrol.browser.json`
- `~/Library/Application Support/SelfControl/browser-native-host`
- `~/Library/Application Support/SelfControl/BrowserExtension`

Removing the extension does not remove previously added websites or alter any
SelfControl blocks or password protection.
