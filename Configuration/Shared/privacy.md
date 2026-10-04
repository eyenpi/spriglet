# {{privacyTitle}}

Effective date: October 4, 2026.

{{appName}} is a local desktop companion developed by {{publisher}}. This policy describes the current Mallow preview.

## App data

The app has no accounts, advertising, analytics, remote assistant service or server connection. It does not capture the screen, inspect other applications, read documents, record audio or monitor global keyboard events. No plugins are active in this preview.

Character state is held in memory for the current session. The app saves one local preference recording whether you dismissed the Mallow introduction; no demo progress or interaction history is saved. The rewrite does not read or migrate the old companion's saved preferences and does not delete those preferences. It does not register a login item.

The app creates an empty lock file in its local Application Support directory to prevent overlapping launches from creating duplicate companions. It contains no personal data or interaction history; macOS releases the lock when the app exits, including after a crash.

## Desktop interaction

macOS supplies display measurements, pointer position, display/session notifications, Reduce Motion, Low Power Mode and thermal state. The app uses these locally to place and animate the character. It observes outside mouse clicks only to return Mallow to its resting peek; it neither records click histories nor reads clicked content. Escape is handled only when this app receives keyboard input.

## Local development tools

The repository includes explicit build, test, scene-preview and packaging commands. They produce local files when a developer runs them. The ordinary app does not create diagnostic reports or upload artifacts.

## Support and website

You may choose to email [{{supportEmail}}](mailto:{{supportEmail}}). Include only the information you want to share. Your email provider and the recipient's provider process the message.

The website at [{{websiteURL}}]({{websiteURL}}) is hosted through Cloudflare. Hosting necessarily processes ordinary request information to serve pages and protect the service. The app itself makes no connection to that website.

## Questions and changes

Contact [{{supportEmail}}](mailto:{{supportEmail}}) for questions. Future capabilities or data handling changes require an updated policy before they are enabled.
