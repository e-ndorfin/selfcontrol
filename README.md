# [SelfControl][website]

<p align="center">
    <img src="./.github/docs/screenshot.png" />
</p>

## About

SelfControl is a free and open-source application for macOS that lets you block **your own** access to distracting websites, your mail servers, or anything else on the Internet. Just set a period of time to block for, add sites to your blocklist, and click "Start Block". Until that timer expires, you will be unable to access those sites—even if you restart your computer or delete the application.

## Weekly scheduling

The **Schedule** section shows Monday–Sunday and all 24 hours. Drag across the
calendar to select half-hour periods; start a drag on a selected cell to erase.
The **Add time** controls provide the same selection without dragging. Adjacent
periods, including periods across midnight or Sunday/Monday, form one block.

Add your websites, select **Enable weekly schedule**, and click **Save schedule**.
macOS requests administrator authorization to install/update the background
helper. After saving, the helper runs the schedule even when the app is closed
and loads it again after a restart. Times follow the Mac's current time zone;
after sleep, the helper resumes any currently scheduled period. The Mac must be
awake for a new block to start.

Use **Open Schedule** in the timer window to edit a running block. **Add websites…** adds
sites to both an active block and future scheduled blocks without altering the
calendar. The timer's original **Add to Block** action also updates the saved
schedule. Shared-list edits apply automatically; calendar edits require **Save schedule**.
Allowlist blocks retain their existing restriction on adding blocked websites.

The original timer is available under **Block now**. When manual and scheduled
blocklist periods overlap, their websites are combined and the later end time
wins. An incompatible manual allowlist is allowed to finish before the saved
schedule resumes; its status is shown in the Schedule section.

Run `tests/run-schedule-checks.sh` for date-boundary, daylight-saving,
configuration-validation, persistence-failure, and daemon enforcement checks.
The daemon checks use mocked enforcement and do not change network rules.

### Two-minute website breaks

During a blocklist block, click **2-Minute Website Break…** in the timer window
and choose a blocked website. The daemon allows that website and its listed
subdomains for two minutes, then restores blocking even if the app is closed.
One break total is available every 30 minutes, measured from the request; using
another website or reopening the app does not reset the cooldown. The saved
blocklist and weekly schedule remain unchanged. The button shows the remaining
break time and cooldown.

This limited exception requires no friend/supervisor password or routine Mac
administrator prompt. Installing the updated app/helper can still require normal
macOS administrator authorization. Breaks support domain entries in blocklist
mode, not IP addresses, port-specific rules, or allowlists. Existing blocks from
older versions without saved ownership need to finish first unless their owner
can be recovered from the shared schedule configuration.

### Private browser extension

The [Add to SelfControl extension](BrowserExtension/README.md) adds the current
website to the shared saved list and a compatible running block with one click.
It leaves the page open and requires no password for routine additions. Initial
setup installs/updates the privileged helper through normal macOS authorization.
The installer defaults to Helium; the extension is installed locally through
**Developer mode → Load unpacked**, with optional Google Chrome registration.
Run `tests/run-browser-checks.sh` for the browser and native messaging checks;
these use mocked enforcement and do not modify network rules.

### Friend-held password

Password protection starts off. **Set a password** lets your friend enter and
confirm their password. Once enabled, **Turn off password** requires that current
password. There is no forgotten-password or administrator-reset flow, and one
approved change does not create an unlocked editing session.

Approval applies to removing blocked websites, adding allowed websites in
allowlist mode, removing/moving scheduled time, disabling an enabled schedule,
changing list modes, or weakening domain coverage/cache/network options. Adding
blocked websites, extending time, adding scheduled periods, and strengthening
coverage do not require the friend password. The password also approves changes
during an active block. Approved schedule edits apply immediately: removing the
current period or disabling the schedule ends its block; an overlapping manual
timer keeps its separately recorded end time. Approved list edits replace the
active rules as well as the future shared list. Without a password set, these
edits are unrestricted. Shared-list edits and imports are checked by the helper, including
manual/CLI starts using a different list. Cancelled or rejected shared-list edits
restore the approved list/options.

The verifier is stored only in the helper's root-owned, mode-0600 settings file;
it is omitted from status replies. It uses a random salt and PBKDF2-HMAC-SHA256
with 600,000 iterations, following [OWASP's password storage guidance](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).
Incorrect attempts are throttled, with the throttle persisted across restarts.
The plaintext password is not saved in user defaults or logged.

macOS administrator authorization remains separate: installing/updating the
helper and privileged block operations may ask for the Mac administrator
password. It never substitutes for the friend password. The bundled recovery
helper refuses to clear blocks while friend protection is enabled. A Mac owner
who retains administrator access can deliberately replace software or alter
system files; this feature does not prevent those external modifications.

## Credits

Developed by [Charlie Stigler](http://charliestigler.com), [Steve Lambert](http://visitsteve.com), and [others](https://github.com/SelfControlApp/selfcontrol/graphs/contributors). Your contributions very welcome!

SelfControl is now available in 12 languages thanks to [the fine translators credited here](https://github.com/SelfControlApp/selfcontrol/wiki/Translation-Credits).

## License

SelfControl is free software under the GPL. See [this file](./COPYING) for more details.

## Building For Development

Users should always download the latest version of SelfControl from [our website][website]. If you want to contribute to SelfControl, you'll need to learn to build it for development. This can only be done on a Mac running a modern version of macOS.

1. Clone the SelfControl repo from GitHub.
2. Make sure you have a recent version of Xcode and the Xcode command-line tools installed.
3. Install [CocoaPods](https://cocoapods.org/): `sudo gem install cocoapods`
4. Install the SelfControl dependencies using CocoaPods: `pod install`
5. Open the `selfcontrol.xcworkspace` file (**NOT** `selfcontrol.xcodeproj`)
6. Build and run (you may need to update/remove code signing settings to make it build properly)

[website]: https://selfcontrolapp.com/
