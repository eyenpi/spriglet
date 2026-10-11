# Drop to Mallow screenshot set

These captures use synthetic content, production native card views, the production drop callback and the production Mallow renderer on a clean simulated backdrop. They contain no personal desktop content. The runner exercises real fast Vision OCR and the production data-detector fallback, with Foundation Models disabled to make this reduced-mode evidence reproducible. An isolated fake Reminders writer verifies Add and Undo without changing personal Apple Reminders; Pocket uses an isolated local preference suite.

| Input / result | Capture |
| --- | --- |
| Text with a date, opening in edit mode | [Text](01-text-flow.png) |
| Native Add followed by the Undo card | [Undo](02-undo-flow.png) |
| Screenshot OCR with a task and date | [Dated screenshot](03-screenshot-with-date-flow.png) · [Source](source-screenshot.png) |
| Image with no readable text or date, offering Pocket | [No-date image](04-image-no-date-flow.png) · [Source](source-image.png) |

The native runner also verifies that analysis does not create reminders, dismissal saves to Pocket, Pocket reopens the same item, and Undo deletes the identifiers from Add. The captured detector-mode flows finished in about 0.30 seconds for text, 0.25 seconds for the dated screenshot and 0.20 seconds for the image on this run. These are fixture measurements, not latency guarantees.

To reproduce:

```sh
./scripts/test-desktop.sh --app-only
.build/lifecycle-validation/lifecycle-validation --intake-preview .build/intake/screenshots
./scripts/preview.sh .build/preview/intake --intake
```

Drop delivery is injected through the runtime's production drop callback in this fixture. Physical external dragging, spoken VoiceOver, real EventKit authorization/save/delete and live Foundation Models extraction remain separate device acceptance checks. The screenshots do not establish those checks. Source builds retain the five-second analysis deadline, including OCR, and never add a reminder without confirmation.
