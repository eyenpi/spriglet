# Privacy

Spriglet is a local desktop companion. The app contains no accounts, analytics, advertising, server connection, or network client.

It responds to clicks and dragging in its own window and keyboard commands while using Spriglet. It does not capture your screen, monitor global keystrokes, read other apps' contents, or request Screen Recording, Accessibility, Input Monitoring, or Automation permission. It exposes its own name, status, and actions to macOS accessibility clients without using accessibility access to control another app.

Your choices stay in this app's local preferences: the pet's name and stable traits, size, activity frequency, parked mode, automatic moments, pause, visibility, click-through, Spaces behavior, sound preference, a display-relative home position, and whether you completed the welcome. A display identifier helps restore the pet to the same display. The app does not transmit it. One bounded last-good preference payload provides recovery if the current copy is damaged.

Recent petting, firefly games, and completed placement changes contribute three small, capped values with their last update times. Their influence decays and expires after 24 hours. Spriglet keeps no interaction event history or information about other apps. Clear Recent Preferences removes these values from both the current preferences and their single recovery copy; it keeps the name, traits, and other choices.

Optional sounds are short original files bundled with the app. Sound starts off, uses no microphone, and contacts no service. Automatic activity remains silent. Disabling sound or suspending the companion stops playback.

Launch at login is an explicit Settings choice managed by macOS through `SMAppService`. Spriglet reads the system registration status; it does not register itself merely because it launches or opens Settings. The OS may require your approval in Login Items. No login choice is sent to a server or duplicated in app preferences as a replacement for that system state.

Developer Diagnostics is separate from everyday Settings and is available in Debug builds or with the explicit `--diagnostics` launch flag. Checks run only when requested and measure this process and its rendering callbacks. Copy Report writes the report to your clipboard only when you select it. Reports can include the macOS version, executable path, process ID, timing, and memory measurements; review a report before sharing it in a public issue. Temporary review runs, including launches with `--diagnostics`, suppress preference learning, saved-choice changes, sound output, and login registration changes.

The privacy manifest declares access to this app's own preferences. No data is collected or uploaded by Spriglet. GitHub separately handles visits to the source repository and any information you choose to submit in an issue.
