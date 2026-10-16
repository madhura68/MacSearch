# Review record: IDEA-263 plan (PLANS/idea-263-plan)

- **Phase:** plan.
- **Idea:** `cmvayvfkl01k6sy7rrbr23gjs`; `idea_phase` PLAN.
- **Reviewers:** two dispatch jobs per round, CODEX and CLAUDE.
- **Spec basis:** SPECS/idea-263-spec r8 (`cmvb4dg2g004qer17taiks5af`, sha256 `f85e46e3…c640d`). The spec has GO in its own review record.
- **Plan doc:** `cmvb51b4p005der171wq8754f`.

## Round 1: revision 1 (`cmvb51b5m005eer17ku2jde22`, sha256 `b2b15d595a39455fbcfcd01e6ed8440d1ae959e36855e12118279462c4b7bd8e`)

| Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|
| CODEX | ced58cf7-a2b2-42a7-a3b4-4685bfa29edc | 7924ab76-6082-4775-9ac0-a7f2e9cf7d59 | 2dcb615d-9c8c-486c-b311-e828ee2ff0e3 | linked | **NO-GO**: 0 B / 6 M / 2 m |
| CLAUDE | 3338527a-51dd-49c0-9f4e-021caed2f8b6 | 95d5bc9b-e742-413f-9771-226aab245400 | 33424730-ab09-447a-8f4a-0228078f3036 | linked | **NO-GO**: 0 B / 7 M / 7 m |

**Round-1 triage.** Every finding is accepted, and all were verified against the plan text.

| # | Finding | Remedy in r2 |
|---|---|---|
| C-M1 | Hostless test target cannot see app code; the smoke test hides this | Hosted tests (`TEST_HOST`/`BUNDLE_LOADER`); `AppEnvironment.isRunningTests` guard; the smoke test references app code |
| X-M1 / C-M2 | Scanner cancel is not wired to the detached producer | `onTermination` cancels the producer task; a test with an `onItem` counter |
| C-M3 | No owner for `RENAME_EXCL` per run; no mkdir in `FileOps` | `TransferBatch` step 4 determines it once per run; `FileOps.createDirectories`; a counter test |
| X-M5 / C-M4 | Valid-bit and `getattrlist`-failure cases are untestable | Pure `renameExclusiveAllowed` plus an injectable `capabilityQuery`, with tests |
| X-M2 / C-M5 | `AppModel` interface incomplete | init with `StartupState`; selection mutators, `history`, `containment`, `message`, `setField`/`confirmFormChange` |
| X-M3 / C-M6 | No negative tests for F25/F26/F13; F0b transitions untested | Task 3 tests for `sourceMissing`/`destinationUnusable`; task 12 `canConfirm` matrix, live F26 check, transitions |
| X-M4 / C-M7 | No test that the batch continues after `failed`; identical-at-start not tested | Task 10 continuation tests (unreadable file, `ENOSPC`); task 8 identical-at-start in A/B/C |
| X-M6 | Shared retry budget and route B reuse not pinned | Task 8: mixed budget, budget across `EXDEV`, call counters |
| X-m1 | Review Focus 3 promises change detection | Narrowed to missing or unreadable sources |
| X-m2 | External skill and record referenced as mandatory | Made optional and non-normative |
| C-m1 | `FileIdentity: Sendable` will not compile | `@unchecked Sendable` plus an init from the enumerator resource value |
| C-m2 | `now` non-escaping; `run` concurrency | `@escaping @Sendable`, `@concurrent`, `NonisolatedNonsending` off |
| C-m3 | Suite names; zero-test PASS | A `@Suite` per file; PASS only with a positive test count |
| C-m4 | `StoreWriteFailed` semantics | `fileProcessed` plus `outcome`; early-failure tests check one record |
| C-m5 | Weak schema tests | CHECK, index, cascade and `finished_at` tests |
| C-m6 | Source not stated as symlink-resolved | Stated, with tests in tasks 3 and 4 |
| C-m7 | Runbook and scaffold details | `git branch -M main`, `hdiutil` attach/detach, a warning grep, date tolerance |

**Scope delta r1 → r2.** No tasks were added or removed. Interfaces and tests grew where the reviewers found gaps; the plan went from 503 to 595 lines. The first usable result and the practical proof (task 14) are unchanged.

## Round 2: revision 2 (`cmvb5fz96005yer17l4vrwve7`, sha256 `517304875dd9d5bd2b9279e465b43b86436222788296a0067746cdc8a028e0a4`)

| Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|
| CODEX | 30fd82b2-4dad-4eff-8c86-55522fb0985f | eede5b55-bba9-4646-9fa6-599cc0d6f574 | 1b0ac987-528b-4e62-983d-9e3eeec1e93e | linked | **NO-GO**: 0 B / 5 M / 0 m |
| CLAUDE | 9c4860be-610b-4322-aae4-8510b7f9ee6c | 23107efd-a4d2-483f-8b01-ab8408c73a87 | 983f97d3-7e74-4c58-9a84-84ba68e51515 | linked | **NO-GO**: 0 B / 2 M / 8 m |

**Round-2 triage.** Every finding is accepted.

| # | Finding | Remedy in r3 |
|---|---|---|
| X-M1 | A failed run insert had two incompatible transitions | `runId == nil` → `reviewing`; `runId != nil` → `done`; both tested |
| X-M2 | `AppModel` did I/O on the main actor | History comes from `StartupState` and an async `loadHistory`; `destinationOK` is refreshed by an async `checkDestination`; NF1 test with a delay |
| X-M3 / C-M1 | History click in `reviewing` had no flow (a regression from r1) | `requestHistory` → Bool plus `confirmHistory`; `done` → `idle`; tests |
| X-M4 | Scan UI lacked Annuleren and progress | Task 13 adds an Annuleren control and a found/scanned counter; task 12 adds a controlled-stream test |
| X-M5 | No equal-size different-content fixture | Added in tasks 7 and 8 (`ABC`/`XYZ`) |
| C-M2 | Capability result never tested as route choice | Task 10 route-choice tests (forced false, query `EIO`, forced true); task 8 passes the Bool directly |
| C-m1 | Schema tests had no DB access | Internal `dbQueue`; tests may `import GRDB` |
| C-m2 | `AppModel` init vs detached startup | `AppModel?` with a loading screen; no model under tests |
| C-m3 | Scheme and signing | Scheme `testTargets`; Sign to Run Locally |
| C-m4 | Flaky cancel test | Blocking `onItem` hook at item 500, assert ≤ 502 |
| C-m5 | `canSearch` undefined; untested model links | Defined; tests for `acknowledgeLeftover`, re-search, the counts handed to the batch |
| C-m6 | "never pending" not observable | `RecordingStore` call log plus a `createExclusive` counter of 0 |
| C-m7 | `ContentHasher` bypassed `FileOps` | `sha256(path:ops:)` |
| C-m8 | Odds and ends | `.fileSizeKey`; `SystemUUIDSource`; Opruimen moved to task 8; `volumeID` override; message and counts tests; a `scanned` test; one place for the history refresh; `checkDestination` renamed |

**Scope delta r2 → r3.** No tasks were added. Interfaces and tests grew; the plan went from 595 to 648 lines. The first usable result is unchanged.

**Scope check before round 4.** The findings are now integration contracts between tasks (`AppModel`/UI, batch/route), not design flaws, and the MAJOR count is falling (13 → 7). No smaller alternative applies yet. If round 3 still has MAJORs, assess merging tasks 12 and 13 or moving UI behaviour checks into the manual smoke test.

## Round 3: revision 3 (`cmvb5sqv3006ier17ihb8pe9s`, sha256 `6fbdd47bb1db507d8abfb04383c0c4c956b7c8cc8ce1390284dc69fdb5a75ff2`)

| Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|
| CODEX | 751ca354-efbe-4529-9edb-77faeac3c6dd | af262a4f-7772-4213-b5a6-35845e85f1ed | 41d3227c-d427-42a5-aea1-312c3a3ac8b4 | linked | **NO-GO**: 0 B / 2 M / 2 m |
| CLAUDE | 61994858-b11c-4b5b-a0b3-a8a023d5fbfc | f66781e8-9412-416c-94ed-7cf42a9a6881 | ddd008bc-6936-41f0-a0d3-813c5b52adb8 | linked | **NO-GO**: 0 B / 3 M / 8 m |

**Round-3 triage.** Every finding is accepted.

| # | Finding | Remedy in r4 |
|---|---|---|
| X-M1 | The date was taken after the async destination check, not at OK | `confirm()` captures `confirmedAt = now()` before any await; `TransferBatch.run(confirmedAt:)` derives the folder and `created_at` from it; midnight tests in tasks 10 and 12 |
| X-M2 | F10 had no test for an unreadable file | Task 4: `isReadableKey` in the key list, a `chmod 000` file test with `skipped == 1` |
| C-M1 | `confirm()` was not atomic (double click, mode change after OK) | `confirm()` is synchronous: guard, `confirmedAt`, snapshot, `phase = .processing`, then a `Task`; "atomic OK" test |
| C-M2 | F18 progress had no source | `TransferBatch.run(progress:)` after each file; `AppModel.processed/total`; tests in tasks 10 and 12; progress bar plus smoke test in task 13 |
| C-M3 | Synchronous I/O in `search()` and `acknowledgeLeftover` | Injected async `makeContext`, `checkDestination`, `loadHistory`; `acknowledgeLeftover` async; NF1 constraint extended; injection-contract test; production wiring in task 13 |
| minors | Smoke test without GRDB; warning grep counted packages; cancel test race; `.progress` only at the end; move-only qualifiers in task 9; `setField`/`requestHistory` result as Bool; `canSearch` in `done`; empty-reviewing transitions; F27 message text; batch spy instead of DB row | `grdbIsVisible`; grep filtered on `/MacSearch/`; second "reached" semaphore; `.progress` after each flush; qualifiers fixed; `ChangeResult`; `canSearch` only `idle`/`reviewing`; transition tests; exact message test; `search_run` row assertions |

**Scope delta r3 → r4.** No tasks were added. The batch now checks the destination itself (step 0), which removes the async gap in `confirm()` instead of adding locking. The plan went from 648 to about 691 lines. The first usable result and practical proof are unchanged.

**Scope check before round 4 (required).** Smaller alternative chosen: a synchronous `confirm()` plus the destination check inside the batch, instead of extra state guards in `AppModel`. MAJOR counts fall (13 → 7 → 5) and are confined to `AppModel`/UI contracts. If round 4 still has MAJORs: merge tasks 12 and 13 or move UI behaviour checks into the manual smoke test, and report to JP.

## Round 4: revision 4 (`cmvb667vu0072er17m2hb2b9k`, sha256 `718c828baefe8dc27dc983c57329629d13290464ed1b6143d22c5588e8738697`)


Pins: `plan` r4, `prev` r3 (`cmvb5sqv3006ier17ihb8pe9s`), `spec` r8 (`cmvb4dg2g004qer17taiks5af`). The server content hash differs from the local file because the server adds `last_updated` to the frontmatter.

| Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|
| CODEX | 3e550920-7c2b-433c-97d5-1cee00e7b5b4 | ba6c7e97-52f1-4352-b680-72c5d65b3372 | ccd10199-cf10-443e-b561-7657f194c675 | linked | **NO-GO**: 0 B / 2 M / 2 m |
| CLAUDE | b380b64c-87a6-4d12-9b9e-3987840a57f0 | c8e3526a-ddab-4f97-9605-d3b8d0d878d4 | ec9ee17a-92b8-4007-a0d4-c1a134395c9a | linked | **NO-GO**: 0 B / 1 M / 7 m |

**Round-4 triage.** Every finding is accepted.

| # | Finding | Remedy in r5 |
|---|---|---|
| X-M1 / C-M1 (convergent) | `search()` awaited `makeContext` before any phase change, so a double Zoeken or a form edit could mix contexts (F0a) | A general rule for work-starting entry points. `search()` is now synchronous: guard, snapshot, `phase = .scanning`, clear state, `destinationOK = false`, then a stored `scanTask` handle. A cancel during `makeContext` starts no scan. Tests: a barrier on `makeContext`, a second `search()` returns `nil`, `setField` and `requestHistory` return `.refused`, the scanner runs exactly once; a cancel during `makeContext` → `idle` |
| X-M2 / C-m7 | After a step-0 refusal `destinationOK` stayed true, so OK stayed enabled. This was a regression: r3 cleared it | `BatchSummary.fatalCause` (`destinationUnusable`, `runInsertFailed`, `aborted`). `.destinationUnusable` clears `destinationOK` and re-runs the check; `.runInsertFailed` keeps OK for a retry. Both paths are tested |
| X-m1 / C-m1 (convergent) | The NF1 thread-capture test cannot fail, and `clearTempPath` has no injected closure | The test is dropped (SCHRAP). NF1 evidence is the task-13 production wiring plus the responsiveness smoke test. `acknowledgeLeftover` → `clearTempPath` in `Task.detached` is stated in task 13 |
| X-m2 | Background facts were unverifiable; the remote was assumed empty | Task 1: check with `git ls-remote origin`, and stop and report if the remote is not empty |
| C-m2 | The midnight tests pass with the defect when the date is today | A fixed past date (2001-02-03 23:59:59 local) in tasks 10 and 12; the "starts after midnight" wording is removed |
| C-m3 | The progress test only saw the final value; the hop is unordered | `processed = max(processed, p)`, and `processed = total` at the end; a hook holds file 2 so the test can assert `processed == 1` |
| C-m4 | The `confirm()` snapshot was underspecified | Files in `results` order, a `StopFlag`, `total` set synchronously; `search()` and `confirm()` return their task handle so tests can await it |
| C-m5 | Cancel and error exits could skip `checkDestination` | All three scan exits run the check; the cancel and scanner-error tests assert `canConfirm == true` |
| C-m6 | Typed-throws `makeContext` cannot be wired directly through `Task.detached` | Task 13: the detached task returns `Result<SearchContext, SearchValidationError>`, and the closure uses `try result.get()` |
| C-note | The case-variant test needs a case-insensitive volume | Task 3 checks this first and otherwise skips only that variant |

**Regression check r3 → r4.** All removed lines were diffed. The only unreplaced loss was `destinationOK = false` on a refused OK (now restored via `fatalCause`). The r3 NF1 300 ms test is intentionally not restored, because an async closure test cannot fail on main-actor I/O.

**Scope check (round 4 had MAJORs).** Both reviewers assessed whether tasks 12 and 13 could be merged or the UI checks moved into the smoke test, and both rejected it with reasons:
- Codex: the deterministic `AppModel` tests cover failures that a happy-path smoke test never reaches.
- Claude: the two tasks are verified differently.

The MAJOR count falls 13 → 7 → 5 → 2 distinct MAJORs, all in task 12 (concurrency of entry points). The one root cause is now addressed by a general rule rather than per method.

**Scope delta r4 → r5.** No tasks were added; one test was removed. The plan grew from 691 to 707 lines. The first usable result and practical proof are unchanged.

## Round 5: revision 5 (`cmvb6k9p8007mer17wq9tbn7d`, sha256 `da623a9931512d187b722b02559458a8ba473bec38c6bc2c3526a211cdcdb0d5`)

Pins: `plan` r5, `prev` r4 (`cmvb667vu0072er17m2hb2b9k`), `spec` r8. The server hash equals the local file plus the `last_updated` frontmatter line (verified).


| Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|
| CODEX | c07897a8-0490-49e6-979d-dcd36c5a2445 | 12eeb6aa-6dad-4faf-bbe6-4fffee4b16b0 | bba90ab7-9a78-4ebc-aca6-7e6e91368262 | linked | **NO-GO**: 0 B / 2 M / 1 m |
| CLAUDE | 93b63cff-31d0-4afa-a2d2-e1cdc2c45c11 | af32a3ed-3ade-4096-b994-2241cad8023e | 2059614f-6c28-4d4d-bd8a-c1842676a8f8 | linked | **GO**: 0 B / 0 M / 9 m |

**Round-5 triage.** Every finding was verified against the plan and spec r8, and every finding is accepted.

| # | Finding | Remedy in r6 |
|---|---|---|
| X-M1 + C-m1 | A refused-OK destination recheck could overwrite a later search's `destinationOK`. The handle rule was inert, because a task cannot hold its own handle | The handle rule is replaced by a `generation` counter, bumped by `search`, `confirm`, discard, confirmations and applied form/history changes. Async continuations (scan, batch, recheck) write only while their generation is current; cancel does not bump the counter (F0c). New test: stale recheck |
| X-M2 | F11 requires video playback via Quick Look in increment 1, and there was no task for it | Task 13: an **Afspelen** button opens `QLPreviewPanel` for the current video; the spacebar (F24) stays in increment 2. Smoke step with a real `.mov` |
| X-m1 | The progress hook does not synchronize the main-actor update | Bounded wait (2 s, `withObservationTracking`) for `processed == 1` before the hook is released |
| C-m2 | A refused OK could lose the incomplete flag | `reviewing(incomplete: !snapshot.scanComplete)`; added a variant test for an incomplete scan |
| C-m3 | A late Annuleren could mark a finished scan incomplete | Incompleteness is decided by how the stream ended; `cancelScan` is a no-op once the stream has finished. New test: late cancel |
| C-m4 | `scanning → idle` was not in F0b; the cancel test did not exercise "during" | Declared as an intentional addition to F0b; the test waits for a "makeContext reached" signal |
| C-m5 | Typed-throws wiring needs an explicit type | An explicit `Result<SearchContext, SearchValidationError>` annotation with a typed-throws closure |
| C-m6 | `FatalCause.aborted` was never set for a directory-creation failure, and never asserted | Set in step 3 and asserted in both aborted tests |
| C-m7 | `canSearch` ignored nil paths | `canSearch` requires the source and destination paths; test added |
| C-m8 | `var mode` was guarded only by a flag | `private(set)` plus `setMode`, which ignores writes when not editable; the test asserts `mode` is unchanged |
| C-m9 | Nothing triggered the leftover sheet | The sheet opens automatically when `leftovers` is non-empty; smoke step with a `sqlite3`-seeded record |

**Scope delta r5 → r6.** No tasks were added. Task 13 gets one button and two smoke steps; task 12 gets a generation rule and three tests. The plan went from 707 to 716 lines. The first usable result is unchanged.

**Trend.** The MAJOR count is now 2 distinct (Codex only). Claude gave GO in round 5.

## Round 6: revision 6 (`cmvb6wmgs0086er17fcrnvc8j`, sha256 `1ff5a5b1a117f124951fb9e3045aa254be0d715e4410e6ac473337c604ae9d62`)

Pins: `plan` r6, `prev` r5 (`cmvb6k9p8007mer17wq9tbn7d`, sha256 `da623a99…db0d5`), `spec` r8. The hash was verified as the local file plus `last_updated`.


| Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|
| CODEX | e0e91fd8-5592-4ab7-ab34-d5e8530539e0 | d78f0bb0-6ff1-4750-a171-e94b22fef920 | cd6e1695-4ecf-42c5-9e25-ec988f127790 | linked | **NO-GO**: 0 B / 1 M / 1 m |
| CLAUDE | f33656f9-9d54-4616-9545-3d937363d2a2 | e1d52d98-315d-4172-a57d-d2cc44e60dd3 | 639ea56a-661f-4a73-b58a-5803556bb0a2 | linked | **GO**: 0 B / 0 M / 6 m |

**Round-6 triage.** Every finding is accepted.

| # | Finding | Remedy in r7 |
|---|---|---|
| X-M1 / C-m1 (convergent) | The generation gate could drop the history refresh after a form edit in `done`. Progress hops were not covered either | `history` and the leftover acknowledgement are exempt from the generation gate. The batch task awaits `loadHistory` while still `processing`, then publishes `history`, `summary` and `done` together with no await in between. Progress writes only while `processing`. Barrier test: `loadHistory` held, `setField` refused, history then contains the run, and a subsequent edit leaves it untouched |
| X-m1 | The halfway-copy test did not require a partial write | The hook writes a known 4 KiB prefix, then throws `EIO`; the bytes are asserted before cleanup |
| C-m2 | The `QLPreviewPanel` wiring from SwiftUI was unstated | `.quickLookPreview($previewURL)` with view-state `previewURL` |
| C-m3 | Detecting how the stream ended is ambiguous for `AsyncThrowingStream` | `cancelRequested` (set only while the loop runs) and `streamFinished`; `incomplete = cancelRequested \|\| scanner error` |
| C-m4 | The leftover sheet had no dismissal | A **Sluiten** button; a one-shot view-state flag, not derived from `leftovers`. Smoke step: the sheet reappears after Sluiten plus restart |
| C-m5 | `withObservationTracking` fires in willSet | Re-read after each `Task.yield()` until a 2 s deadline |
| C-m6 | `setMode` after `confirm()` cannot detect a missing snapshot | The sentence is dropped |

**Scope delta r6 → r7.** No tasks were added. One rule paragraph and one barrier test were added, and one sentence was removed. The plan grew from 716 to 720 lines.

## Round 7: revision 7 (`cmvb7663t008qer17cfdsusid`, sha256 `c2d192321632365c030c139f34e7ed9e971da38a32b4368cced82bc2ae0585fc`)

Pins: `plan` r7, `prev` r6 (`cmvb6wmgs0086er17fcrnvc8j`, sha256 `1ff5a5b1…9d62`), `spec` r8. The hash was verified as the local file plus `last_updated`.


| Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|
| CODEX | 6efb18cf-0503-45c9-b126-de0cb2a8f1df | 402eccce-4d5c-4855-af86-f01d20631dbe | b7e25d7b-6815-41e1-8e28-8ff87448a2bd | linked | **GO**: 0 B / 0 M / 1 m |
| CLAUDE | c6870718-0875-48b4-8302-c9266ac7b4b5 | b64fc3e4-5350-44df-a186-55bf6ce185b5 | 6a18d86d-18b2-40e0-a2cc-a490adaa8247 | linked | **GO**: 0 B / 0 M / 4 m |

## Outcome: plan phase GO at revision 7 (round 7)

Both reviewers gave GO on PLANS/idea-263-plan r7 (`cmvb7663t008qer17cfdsusid`). A technical GO does not authorize ceremony or implementation; JP's gate comes next.

**Open minors (not applied):**

| # | Source | Minor |
|---|---|---|
| 1 | Codex m1 and Claude M1 (convergent) | `loadHistory` has no failure semantics. The proposal: on a read failure keep the previous `history`, show a warning, and still publish `summary` and `done`. Add one test |
| 2 | Claude M2 | The `loadHistory` barrier test needs a "loadHistory reached" signal. In the halfway-copy test the hook must record the destination fd's size and content itself, because cleanup runs before the test regains control |
| 3 | Claude M3 | `processed = total` at the end is wrong after Stop or abort. Fix: only on `completed`, or drop it |
| 4 | Claude M4 | `LeftoversSheet` should close itself when `leftovers` becomes empty |

**Loop summary:**
- MAJOR counts per round (Codex/Claude): 6/7, 5/2, 2/3, 2/1, 2/0, 1/0, 0/0.
- The plan went from 503 to 720 lines, with 14 tasks throughout. The first usable result and the practical proof (task 14) are unchanged.


## Delta loop: revision 8 (`cmvb7i0l0000190173062n7sa`, sha256 `b763b8b1ff92072362c2114a3bb9edcf5733cb5797960f2e0698d8f0d5f9ac14`)

JP (2026-10-16) asked for the four open minors to go into revision 8, followed by a delta review and then the ceremony.

The edits were written by Claude, so the reviewer is a single cross-model one: `runtime: CODEX`. The delta loop is capped at 5 rounds.

| Minor | Change in r8 |
|---|---|
| 1. `loadHistory` failure | `loadHistory` now returns `[RunSummary]?`, where `nil` means the read failed. The production wiring uses `try?`. On `nil` the previous `history` is kept, `message` gets the warning "De geschiedenis kon niet worden ververst", and `summary` and `done` are still published. A test covers this |
| 2. Test strength | The `loadHistory` barrier test waits for a "loadHistory reached" signal. The halfway-copy hook records the fd's size and content itself, and the test asserts that record |
| 3. `processed = total` | Set only for `completed`. A new test checks that after a Stop at 1 of 3, `processed == 1` |
| 4. `LeftoversSheet` | The sheet closes itself when `leftovers` becomes empty; the smoke step was updated |

**Scope delta r7 → r8.** No tasks were added. Three tests were added (task 12). The plan grew from 720 to 723 lines.

Pins: `plan` r8, `prev` r7 (`cmvb7663t008qer17cfdsusid`, the GO revision, sha256 `c2d19232…85fc`), `spec` r8. The hash was verified as the local file plus `last_updated`.

| Delta round | Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|---|
| 1 | CODEX | d2c3b413-7da6-484f-af68-faa164e7e27d | f16c2aed-1861-4cd5-b5d5-bfb3ff3be044 | 04bd3727-f3c9-4889-9fca-47ad25a1b187 | linked | NO-GO (0 B / 1 M / 1 m) |

### Delta round 1: triage

Codex rated two of the four changes as held (history refresh failure, `LeftoversSheet`) and two as partially held (test strength, progress after Stop). Both findings were verified against the plan text and accepted.

| Finding | Severity | Decision | Remedy in r9 |
|---|---|---|---|
| Stop completion can discard the last progress update | MAJOR | Accepted. The progress callback is synchronous while its UI write hops to the main actor; nothing orders that hop before `done`, and the `processing` guard then drops it. r7 hid this by forcing `processed = total` | Task 12: when publishing `done`, the batch task sets `processed` authoritatively to the sum of `summary.counts` (equal to `total` for `completed`, smaller after Stop or an abort). Progress hops use `max`, and a late hop is ignored by the guard. The Stop test no longer waits for the UI counter: the hook holds file 1, the test calls `stop()` on the main actor and releases. An abort variant was added |
| The copy test needs a readable descriptor | MINOR | Accepted. The destination fd is `O_WRONLY`, so it cannot be read back | Task 9: the hook opens the path read-only (captured by `FaultyFileOps` at `createExclusive`), checks that device and inode match the destination fd, and reads the 4 KiB back |

**Scope delta r8 → r9.** No tasks were added. One test was strengthened and one variant added (task 12); the plan stays at 723 lines. No effect on the first usable result or the practical proof.

## Delta revision 9 (`cmvb7pm50000l9017pq7racnd`, sha256 `20d659b9ab9562b0ad3b30ba8a22e6afba00fd99e171330da4e4176b339b24ea`)

Pins for delta round 2: `plan` r9, `prev` r8 (`cmvb7i0l0000190173062n7sa`, sha256 `b763b8b1…ac14`), `spec` r8. The hash was verified as the local file plus `last_updated`.

| Delta round | Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|---|
| 2 | CODEX | d7cfd4d8-bf5a-46dd-8fac-e197d37d8ba8 | eab0e565-e37b-44c2-97e2-f331e02eb508 | c2f16d43-7930-4795-b155-cf6e36c9624a | linked | GO (0 B / 0 M / 2 m) |

### Delta round 2: triage

Codex verified both r9 fixes against the r8 baseline. The production progress rule held, and so did the readable-descriptor fix. The Stop/abort test strengthening partially held. Codex also traced the sum of `summary.counts` through every path that publishes `done` (Stop, abort with `fileProcessed` true and false, folder-creation failure, failed final-status write) and found it correct.

| Finding | Severity | Decision | Reason |
|---|---|---|---|
| The Stop/abort regression test does not force a late progress hop, so it can pass with the original race present | MINOR | Deferred | Test-strength polish. The authoritative assignment at `done` (task 12 progress rule) is specified independently and Codex confirmed it is correct. The implementer of task 12 may add an injectable delivery barrier for the last progress hop |
| "Smaller after Stop or an abort" is not always true: if the last file was processed, the sum equals `total` | MINOR | Deferred; corrected in the ceremony text | The explanatory clause is wrong, but the assignment itself is correct. JP's scope for this delta was only the four r7 minors; another revision would need delta round 3. The task-12 text in Scrum4Me says "at most `total`; smaller only when selected files were left unprocessed" and points back to this finding |

**Scope delta.** None. Both minors were deferred, and the plan stays at revision 9.

**Outcome: delta GO at revision 9** (`cmvb7pm50000l9017pq7racnd`, sha256 `20d659b9ab9562b0ad3b30ba8a22e6afba00fd99e171330da4e4176b339b24ea`). The GO does not authorize implementation.

## Ceremony (2026-10-16)

JP approved adding the `Scrum4Me-product` block to the repo's `CLAUDE.md` (product MacSearch, `cmvayn6jl01jesy7r4mucpvgn`). The ceremony then ran on plan revision 9.

| Object | id | Code | idea_link.outcome |
|---|---|---|---|
| Sprint | `cmvb7yo8f00169017vlqjmzza` | S-2026-10-16-1 | `set` (build_sprint_id) |
| PBI | `cmvb7yuy6001790174zzl2h84` | PBI-1, source_doc PLAN r9 | `set` (pbi_id) |
| Story | `cmvb7z4ta00199017vd1v7fzl` | ST-001 | — |

`get_estimate_history` returned 0 tasks; the estimates rest on section size and test count.

Tasks (all `TO_DO`, in plan order, each with its estimate):

| Task | id | Minutes | USD |
|---|---|---|---|
| T-1 scaffold | `cmvb80fmh001a90175ifz20nh` | 30 | 6 |
| T-2 KeywordMatcher | `cmvb80uqn001b9017iudzgosz` | 20 | 3 |
| T-3 SearchContext | `cmvb81elq001c90177ykr2a0z` | 40 | 7 |
| T-4 MediaScanner | `cmvb81yny001d9017k89l0s7v` | 50 | 9 |
| T-5 HistoryStore | `cmvb82p7v001e9017eezeo9hc` | 45 | 8 |
| T-6 FileOps | `cmvb83dyk001f9017ljy25fpg` | 50 | 9 |
| T-7 ConflictResolver | `cmvb83tpl001g9017lfwhzlkc` | 25 | 4 |
| T-8 FileTransfer routes | `cmvb8550f001h9017h5vfre75` | 90 | 18 |
| T-9 FileTransfer failures | `cmvb85rfs001i9017020laj5v` | 75 | 15 |
| T-10 TransferBatch | `cmvb86ikw001j90173hknplc3` | 75 | 15 |
| T-11 StartupRoutine | `cmvb871jx001k9017d8d3eedk` | 40 | 7 |
| T-12 AppModel | `cmvb8bge7001l9017nlexpuss` | 120 | 25 |
| T-13 UI | `cmvb8c88s001m9017xyo36277` | 90 | 18 |
| T-14 Mac trials | `cmvb8cp64001n9017icbgt1mk` | 30 | 5 |
| **Total** | | **780** | **149** |

**Transcription choices.**
- Tasks 1–11, 13 and 14 carry their plan section verbatim in `implementation_plan`, together with the full Global Constraints.
- Two tasks add small notes to their section. Task 1 step 5 adds "also include `docs/` and `CLAUDE.md`". Task 6 notes that `FaultyFileOps` may already record the `createExclusive` path, and its bit table is written as a list.
- Task 5 also carries the §5 migration SQL. Task 8's description carries a summary of NF4; the spec stays binding.
- Task 12 exceeds the field limits (4,000 + 8,000 characters), so it is condensed. The interfaces are verbatim and the rules lightly shortened, the 29 tests are in the description, and only the Global Constraints that bind it are copied.
- In task 12 the progress clause reads "at most `total`; smaller only when selected files were left unprocessed". This corrects the deferred delta-round-2 minor. The optional delivery barrier for the last progress hop is mentioned as a possible strengthening of the test.

**Hardstop.** Nothing was started: no task status was changed and nothing was dispatched. The idea stays `DRAFT`, as JP asked.
