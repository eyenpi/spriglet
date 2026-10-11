# Drop to Mallow screenshot set

These captures use synthetic content, production native card views, the production drop callback and the production Mallow renderer on a clean simulated backdrop. They contain no personal desktop content. The runner exercises real fast Vision OCR and the production data-detector fallback, with Foundation Models disabled to make this reduced-mode evidence reproducible. An isolated fake Reminders writer verifies Add and Undo without changing personal Apple Reminders; Pocket uses an isolated local preference suite.

| Input / result | Capture |
| --- | --- |
| Text with a date, compact by default | [Text](01-text-flow.png) |
| Native Add followed by the Undo card | [Undo](02-undo-flow.png) |
| Screenshot OCR with a task and date | [Dated screenshot](03-screenshot-with-date-flow.png) · [Source](source-screenshot.png) |
| Inline Edit with highlighted uncertain fields | [Edit](05-expanded-edit-flow.png) |
| Image with no readable text or date, offering Pocket | [No-date image](04-image-no-date-flow.png) · [Source](source-image.png) |

The lavender postcard is 320 pt wide with a vector tail aimed at Mallow. The default view shows a one-line task, a date in words, Add, Edit and labeled icon alternatives. Edit expands native fields inline; Done preserves edits and collapses them. The native runner checks compact dimensions, initial Edit focus for medium confidence, Escape to Pocket, Pocket reopen, native Add and Command-Z Undo. The amber title/date treatment and spoken “needs review” labels remain in both modes. Appearance adapts to light/dark mode; system Reduce Motion removes unfolding and tucking transitions.

To reproduce:

```sh
./scripts/test-desktop.sh --app-only
.build/lifecycle-validation/lifecycle-validation --intake-preview .build/intake/screenshots
./scripts/preview.sh .build/preview/intake --intake
```

Drop delivery is injected through the runtime's production drop callback in this fixture. Physical external dragging, spoken VoiceOver, real EventKit authorization/save/delete and live Foundation Models extraction remain separate device acceptance checks. The screenshots do not establish those checks. Source builds retain the five-second analysis deadline, including OCR, and never add a reminder without confirmation.
