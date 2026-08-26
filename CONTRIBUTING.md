# Contributing

## Commit messages

This repo uses plain-English commits, not Conventional Commits. The log is
the documentation of why the code is the way it is; write for the person
reading it in two years.

- **Subject**: imperative, capitalized, ≤ 72 characters, no trailing period,
  no `feat:`/`fix:` prefixes. Say what the change does, in English:
  `Name herdr pots by rename, then live title`.
- **Body**: one blank line after the subject, wrapped at 80 columns. Explain
  *why* — what was observed, what was considered, what the change trades
  away. The diff already says what changed.
- If a claim in the message was verified (measured, captured, reproduced),
  say how. Unverified claims read the same as verified ones otherwise.

Enable the local check once per clone:

```bash
git config core.hooksPath .githooks
```

CI runs the same check on every push, so the hook only saves you a round
trip.

## Tests

```bash
./test/run-tests
```

No framework; bash and python3. New behavior gets a test in the matching
group, and a fix for a bug that the suite missed gets a test that would have
caught it.
