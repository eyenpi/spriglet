# Intake extraction validation

Run `swift test --package-path tools/IntakeExtraction -Xswiftc -warnings-as-errors`,
which is also part of `scripts/test.sh`. The source symlinks compile the same
Environment files as the app; there is no second implementation of extraction.
Core remains independent of Vision, Foundation Models and data detectors.

`Tests/Fixtures/corpus.json` contains 40 synthetic, realistic plain-text and OCR
transcripts, each with its own ISO reference timestamp and expected title, local
date, time and all-day flag. Cases cover emails, calendar invites, flights,
bookings, chats, invoice due dates, English/German relative phrases, EU formats,
OCR digit errors, midnight/noon, a DST boundary, month/year rollover, a past
explicit date and a source with no date. Fifteen screenshot transcripts also
render to temporary rasters and run through real Vision OCR. No private mail,
bookings, screenshots or desktop recordings are stored in the corpus.

The mock supplies only source-derived titles and source phrases. It never supplies
the fixture's expected date or time. Production resolution, reconciliation and
confidence logic run unchanged. Separate tests inject model/date disagreements,
abstention, ungrounded phrases and missing source times. Date/time accuracy
compares Europe/Berlin calendar components; overall also requires the expected
title, a timed rather than all-day draft, and exactly the expected reminder count.
The suite prints all failures and aggregate accuracy and requires at least 90%
for date, time and overall on both transcripts and synthetic screenshot OCR.
This measures the fixed corpus and mocked model contract, not live Foundation
Models accuracy or arbitrary real-world screenshot accuracy.

The date policy is deterministic:

- Europe/Berlin is the default zone. A date without a time means **09:00**, never
  all-day. The card displays `09:00 default`; this flag survives Pocket storage.
- `receivedAt` anchors relative dates. Weekdays mean the next occurrence (the
  following week if today); a yearless month/day uses the upcoming year when
  already past. Explicit past dates remain past.
- Bare hours such as `tomorrow at 5` mean 05:00 and require review. Use `5 PM` or
  `17:00` for an unambiguous afternoon time.
- Numeric dates are EU day-first. Date/time-shaped OCR tokens receive O/0,
  l/1, I/1 and S/5 repair. Soft line wraps and `at14:30` spacing are normalized;
  task words remain intact. Payment-due, departure and check-in labels take
  priority over issue, arrival and check-out metadata.
- NSDataDetector runs on expressions anchored to explicit dates first. Its
  public API does not accept a reference date. The resolver therefore supplies
  that context through normalization rather than relying on the system clock
  or private APIs. Detector and guided-model disagreement require review;
  the model cannot overwrite an explicit source time or erase a local result.
- Fast OCR publishes readable content before model work or accurate OCR. If no
  usable date is found, accurate English/German OCR retries. Accurate OCR can
  cold-start beyond the runtime's five-second deadline; the deadline preserves
  fast text and local detection, and stale progress/results cannot reopen a card.

Known limits include vague times (`after lunch`), spelled-out colloquial times,
complex recurrence, unsupported languages, arbitrary layout/reading order, and
several independent tasks sharing one date. Every suggestion remains reviewable.
Cross-zone travel should be checked manually; this corpus covers local Berlin
reminders rather than travel-time-zone conversion.

Swift Testing prints a separate subtotal for each package test target. For the
pre-existing CompanionKit suite, 19 rendering plus 119 core tests means 138
passing tests; a final `119` line alone is the core subtotal, not lost tests.
