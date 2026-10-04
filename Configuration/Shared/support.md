# {{supportTitle}}

{{appName}} is an early native desktop companion for Apple silicon Macs running macOS 26 or later. The current character is Mallow.

## Interacting with Mallow

{{interactionHelp}}

Mallow starts with its face visible below the notch. A short hover gives a small acknowledgement; a click brings it out. Touch it again for a wave or swing. Drag the character to pick it up. Release near the notch to let it catch; release away from it for gravity and a soft landing. Click elsewhere to bring it home.

## Where it lives

On a notched display, Mallow uses the actual housing geometry reported by macOS. Displays without a notch use a small resting place near the upper right edge, below the menu bar. The bottom resting surface clears the space reserved by macOS. The app does not inspect other windows or assume it knows the exact Dock icon shelf.

## Keeping your work clear

Mallow stays in the resting peek until invited and returns after you leave it alone. The transparent margins of its window pass clicks through. Reduce Motion limits decorative movement; Low Power Mode and thermal pressure lower animation cadence. Animation stops during system or display sleep, screen lock, an inactive session or critical thermal pressure. Waking, unlocking and changing Spaces return Mallow to its resting home. Home stays on the initial primary display as you move between apps unless you choose another display in Settings. Unplugging the chosen display uses the current primary display while preserving your saved choice; Mallow returns when that display reconnects.

## Settings

Open the small native Settings window from the leaf menu or by right-clicking Mallow and choosing {{settingsMenu}}. Choose Small, Medium or Large character size; Gentle, Standard or Lively movement intensity; a home display; and Automatic, Top left, Top center or Top right location. Automatic uses the actual notch when present and the upper-right fallback otherwise. Changes apply immediately and are saved locally for the next launch. Reduce Motion takes priority over movement intensity. Changing size or home ends an active drag and returns Mallow to its updated home. A disconnected saved display remains selected in Settings until it returns or you choose another.

Settings can also be opened with Command-comma when {{appName}} is active or through Mallow’s VoiceOver custom action. Opening Settings gives its window keyboard focus; closing the window leaves Mallow running.

## Launch at login

Choose {{launchAtLogin}} from the leaf menu, Mallow’s right-click menu or Settings to start {{appName}} when you sign in. It is off by default on a new installation. Menus read the current macOS registration each time they open. Settings refreshes when it regains focus or the registration changes. A checkmark means macOS reports it as enabled. A dash means it is registered but needs approval; it will not launch at login yet. Choose {{openLoginItemsSettings}} to review approval in System Settings > General > Login Items & Extensions. Turn off {{launchAtLogin}} to cancel a pending registration or disable future login launches.

An unavailable state or failed change is shown separately from the actual registration. Failed changes display the macOS error immediately; the last failure also remains in the menu for the running session. Reopening the menu reflects changes made in System Settings. Startup never re-registers the app or overrides your macOS choice. Repeated Finder or login launches share the same instance lock, so only one companion can start in the app’s container. Quitting leaves login registration as you chose it; disabling it keeps the current companion running.

## Menu-bar controls and recovery

{{menuControlsHelp}}

{{recoveryHelp}}

Pause freezes the current pose and lets desktop clicks pass through; pausing an active drag releases it and returns Mallow home. Resume continues without simulating paused time. The visibility label reflects whether Mallow is actually visible; Show is unavailable while the display or session is suspended. Pause and Resume reflect your animation choice, independently of system suspension.

Settings exposes the same Show and Animate controls for this session, alongside saved preferences. Help is available offline and preserves keyboard focus in your current app. Closing either window keeps {{appName}} running. Right-click Mallow brings it home and opens the same typed controls as the leaf menu, including Settings, login status and {{quitApp}}. There is no Dock icon or action card.

## Local preview and troubleshooting

This rewrite is a local preview, not an Apple-notarized release. Installing a downloaded unsigned build may be blocked by macOS. For bugs, include the app version, macOS version, display arrangement, what you did and whether Reduce Motion or Low Power Mode was enabled. Avoid including private desktop content in screenshots.

## Contact

Email [{{supportEmail}}](mailto:{{supportEmail}}) or visit [support]({{supportURL}}). Sending a support message is your choice; the app does not send diagnostics or messages on your behalf.

[Back to {{appName}}]({{websiteURL}}) · [{{privacyTitle}}]({{privacyPolicyURL}})
