# Review record: IDEA-263 MacSearch spec (SPECS/idea-263-spec)

- Product: MacSearch `cmvayn6jl01jesy7r4mucpvgn`
- Idea: IDEA-263 `cmvayvfkl01k6sy7rrbr23gjs`, phase SPEC
- Document: ProductDoc `cmvb0lj1r000per173xpccuxf`. It exists only in the database; there is no repository yet.

## Round 1 (before the loop): single SPEC_REVIEW
- Job `cmvb0mdl60019er17bdtg1qqo` on revision 1 (`cmvb0lj1z000qer17a1xx1kpw`). It was not linked to the idea.
- Verdict: CHANGES_REQUESTED, 3 errors and 1 warning.
  1. F8 vs F27: unclear which folder is excluded. **Accepted.** Fix: F8 rewritten, F27 adjusted, AC4a added.
  2. No fixed command context during scan and processing. **Accepted.** Fix: new §4.0 (F0a–F0d) and F13.
  3. No failure path for storage errors. **Accepted.** Fix: F19–F19c, schema `status`/`scan_complete`/`finished_at`/`pending`, AC4 fault injection.
  4. NF4 crash safety untested (warning). **Accepted.** Fix: NF4/F15/F17 tightened, AC3a and AC7 added.
- Scope delta: context, state handling and storage-failure handling added. No new features. The first usable result is unchanged (increment 1, now including F0 and F19a–c).

## Round 2: revision 2 (`cmvb1ena3001ber1774binnpl`, sha256 `ef3241b1a56667a464e7fe0569c9332d77742535d889630cb7349a14fcefe2de`)
- Pin: `product_doc`. No `repository` pin, because there is no code yet.
- Dispatch history: the first codex attempt (idempotency `07f3b028-…`) got DISPATCH_NOT_FOUND (404) twice. JP then fixed the dispatch configuration and the same key was resubmitted.

| Slot | Request id | root_message_id | Idempotency key | idea_link | Job id | Verdict |
|---|---|---|---|---|---|---|
| CODEX | 80538a37-26b7-4900-873f-3551f0b72356 | 9ecd5aba-bbf0-42bd-b6ea-29b5c23d008a | 07f3b028-7ecd-4047-a79d-a97fff349787 | linked | 3a75afae-92a2-420e-b152-897eb6499b3c | **NO-GO**: 0 B / 1 M / 2 m |
| CLAUDE | 9fcba6d7-5a23-4f5c-8468-c1daf9d1a5cb | 26f66f70-72f0-464e-96cd-c2a4c9bed44d | 11bce212-95b2-4534-b13e-5d3a9310cf45 | linked | 59c88d58-2ce3-4f6f-a70c-52f984e95605 | **GO**: 0 B / 0 M / 9 m |

**Round-1 fixes.**
- Codex: held / held / held (minor test gap) / partially held (temp-file ownership).
- Claude: held / partially held (F0b failure exits) / held / held.

**Triage.** All findings were verified against revision 2. Every one is accepted unless noted.

| # | Finding | Decision and remedy |
|---|---|---|
| X-M1 | Temp-file ownership and collision (MAJOR) | Accepted. NF4 now uses a unique `.macsearch-<UUID>.tmp` created exclusively (`O_EXCL`), then the pending record with `temp_path`, then `fcopyfile`. Crash cleanup only removes recorded `temp_path` files. The residual risk (an empty file after a crash between create and insert) is accepted. AC3a gains collision, failed-insert and cleanup-preservation cases. |
| X-m2 / C-m3 | Pending insert vs result update conflated | Accepted. F19b steps split; AC4 split into three cases plus the case where the `aborted` write also fails. |
| X-m3 | Provenance artifacts not supplied | Accepted. The binding grill decisions are now in §1a of the spec. The grill doc is not pinned. |
| C-m1 | Destination not required at Zoeken | Accepted. F25 now requires a destination. |
| C-m2 | F0b has no failure exits; history click undefined | Accepted. Transitions added for scanner error, failed run insert and history click. The `done` state is kept. |
| C-m4 | Path comparison undefined | Accepted. Comparison is by `fileResourceIdentifierKey` and the ancestor chain. AC4a gains symlink/case and sibling-prefix cases. |
| C-m5 | F8 history clause brittle (SCHRAP) | Accepted as SCHRAP. Destination equal to source is now **blocked** (F27). Allowing it with a warning was the spec's own wording in revision 1, not a grill decision. Reported to JP as reversible. |
| C-m6 | Cross-volume move details | Accepted. Volume detected via `volumeIdentifierKey`, size checked before the source is deleted, NF3 reworded, fixed-length temp name. The cleanup limit is resolved by the new cleanup rule. |
| C-m7 | F16 `(n)` duplicates | Accepted. Existing `(n)` candidates are tested for identity; AC3 case added. |
| C-m8 | Scanner gaps | Accepted. `errorHandler`, a `nextObject()` helper, `skipped_count` with incomplete marking, a TCC note in AC5, `.fileSizeKey` removed. |
| C-m9 | Test and increment inconsistencies | Accepted. F5 non-overlap case, AC4a F0d case, pending log stays SQLite-only, F22 drop target moved to increment 2, F14 leading dot and POSIX date. NF2 is now a non-binding target with no verification step. |
| extra | Advisor: temp ordering and metadata | Order is create → record → copy. Metadata is preserved (`COPYFILE_ALL` plus the creation date). The per-revision change lists were moved out of the spec into this record. |

**Scope delta r2→r3.** Removed: the F8 history clause; dest = source is now blocked. Added: precision and tests for temp ownership, path identity, failure exits and log-write splitting. No new features. The spec grew from 215 to 269 lines. The first usable result is unchanged.

## Round 3: revision 3 (`cmvb2uayp001ver17eys60adi`, sha256 `56191f94065d9e50891ad159df488650c213be659c9eda7a50faf117434cd826`)
- Pin: `product_doc`, without a repository pin.

| Slot | Request id | root_message_id | Idempotency key | idea_link | Job id | Verdict |
|---|---|---|---|---|---|---|
| CODEX | fabf583d-8293-4d7a-9195-05ba8ab94a00 | d99f35c7-de93-475c-9832-481971c1d9d0 | 7772430d-ca11-42e7-a0f4-134a82d38ad1 | linked | (via dispatch) | **NO-GO**: 0 B / 1 M / 3 m |
| CLAUDE | 657c386f-2082-4f1e-9101-da6de897000e | 0b5304eb-6d96-449e-9244-a7c20a86f4b3 | 8b60a44c-6288-49bf-b1ca-507feafa6b4a | linked | (via dispatch) | **GO**: 0 B / 0 M / 8 m |

**Round-2 fixes.**
- Codex: 1 and 3–11 held; 2 partially held, because the precedence case was untested. Codex accepted the F27 block of destination equal to source.
- Claude: held 1, 3, 4, 5, 7, 8 and 11; partially held 2, 6, 9 and 10. Claude also accepted the F27 block.

**Triage.** All findings are accepted.

| # | Finding | Decision and remedy |
|---|---|---|
| X-M1 / C-m3b | A plain `rename` can overwrite a destination file created after the F16 check (MAJOR) | Accepted. NF4 step 7 publishes with `renamex_np(RENAME_EXCL)`; on `EEXIST` it returns to F16. `ENOTSUP` falls back to `link`+`unlink`; without that, the race is an accepted residual risk. `RENAME_EXCL`/`EEXIST`/`ENOTSUP` were checked in `man renamex_np`. AC3a gains a final-name collision case. |
| X-m2 / C-m4 | Stop plus failed write untested | Accepted. AC4 case added. |
| X-m3 | Historical references outside the evidence | Accepted. The header marks them non-normative; §1a is the authority. |
| X-m4 / C-m8 | Scope trims | Accepted. Filmstrip and cache deferred to increment 2, NF2 removed (SCHRAP), F9 warning at 5,000 results removed. |
| C-m1 | `skipped_count` not written in F19a | Accepted. Added to F19a, with an AC4 case. |
| C-m2 | Symlinks resolved before the identity read | Accepted. F0a updated, with an AC4a symlink-dest-inside case. |
| C-m3 | Sequence after the temp file not fixed | Accepted. NF4 now gives a numbered per-file order of 8 steps; the creation date is set on the temp file before publication, and its failure is a warning. |
| C-m5 | Tests need the real FS and a UUID sequence | Accepted. AC3a updated. |
| C-m6 | F16 gap ambiguity | Accepted. Candidates are checked in order up to the first free name. |
| C-m7 | F25 dead logic; folder edge cases | Accepted. The dead sentence is removed (SCHRAP). Folder names over 255 bytes are blocked, and a failed folder creation gives `aborted`. |

**Scope delta r3→r4.** Removed or deferred: filmstrip and cache, NF2, the 5,000-result warning, the F25 dead sentence. Added: no-overwrite publication and test cases. The spec grew from 269 to 281 lines. The first usable result is unchanged.

## Round 4: revision 4 (`cmvb347z2002fer17er8fb5fm`, sha256 `7ceb3d329b2b4f2735a9ba172a5ce00ba0b9a85fe2aa118a4b4959376d9e4f7b`)

| Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|
| CODEX | a72a8725-35a8-4260-b016-c0cf36f81863 | 8d1603e4-8a16-489a-a883-a0db5516d336 | 6b5affa5-6b15-44cd-a7bf-05f96396c613 | linked | **NO-GO**: 0 B / 2 M / 2 m |
| CLAUDE | f508242c-e519-4a92-8cc3-436a00e66d11 | 0fbd220f-5c50-469d-9845-d5f7a2d2d2ed | debf9bfc-0066-45ab-8442-74a94f5899c5 | linked | **GO**: 0 B / 0 M / 6 m |

**Round-4 findings.**
- Codex M1: the plain-rename fallback on `ENOTSUP` keeps the overwrite race.
- Codex M2: an `EEXIST` retry that ends in identical content leaves the pending record inconsistent.
- Codex minors: the metadata warning case; historical references.
- Claude minors:
  - retry bookkeeping (overlaps codex M2);
  - same-volume `moveItem` is not exclusive;
  - folder-creation order;
  - mtime;
  - the `link` tier is dead code;
  - AC3a gaps.

**JP gate.** What to do on volumes without `RENAME_EXCL` (exFAT/SMB) is a product decision; it was put to JP on 2026-10-16.
**JP decision (2026-10-16).** On volumes without `RENAME_EXCL`, write directly and exclusively (route C).

**Round-4 triage.** All findings are accepted.

| # | Finding | Decision and remedy |
|---|---|---|
| X-M1 | Plain-rename fallback keeps the overwrite race | Accepted, per JP's decision. The `link` tier and the plain-rename fallback are removed. Route C writes the destination itself with `O_EXCL` and records it as `temp_path`. A half file under the destination name after a crash is accepted (JP) and cleaned up at the next start. |
| X-M2 / C-m1 | Retry bookkeeping | Accepted. One attempt counter and always the existing record. On a retry, steps 2–4 are not repeated. Retry-to-identical deletes the own file and updates the record. AC3a gains cases for exactly one record, no pending record left, and three `EEXIST`s. |
| X-m1 | Metadata warning case | Accepted. AC3a splits metadata into a success case and a failure case. |
| X-m2 | Historical references | No change; they remain non-normative. |
| C-m2 | `moveItem` not exclusive | Accepted. Route A uses `renamex_np(RENAME_EXCL)`; without that capability, a move goes via route C. |
| C-m3 | Folder-creation order | Accepted. F14 creates the folder after the `search_run` insert; AC4 case added. |
| C-m4 | mtime | Accepted. Both dates are set explicitly; F15 states preservation as a requirement. |
| C-m5 | `link` tier dead code | Accepted (SCHRAP). |
| C-m6 | AC3a gaps | Accepted. Two final-name collision cases, three `EEXIST`s, a route A collision, route C cases. |

**Scope delta r4→r5.** Removed: the `link` tier and the plain-rename fallback. Added: route C, retry rules, tests. The spec grew from 281 to 308 lines. The first usable result is unchanged.

## Round 5: revision 5 (`cmvb3ea2a002zer17g4p8x98x`, sha256 `7d5e35872c417a5656ef53794aff95675f3ac0716f6e3c46951d509f029fadaf`)

| Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|
| CODEX | 0146a24f-df5e-4c08-868b-02d5e7387b6f | f27d5e91-9278-41e3-9e41-a5e634880699 | 697b2e1c-3eea-40e7-b29a-8fb43bfa0a83 | linked | **NO-GO**: 0 B / 2 M / 2 m |
| CLAUDE | 23cf03c9-3443-4dd1-a640-e38a1539e294 | 416a9b15-2795-46bb-a632-9f0891eb081e | 96fa3412-8dc5-40c9-bfa9-8b08445f2c21 | linked | **NO-GO**: 0 B / 1 M / 6 m |

**Round-5 findings.**
- Codex M1 and Claude M1, which converge: crash cleanup deletes by path alone and runs only once, so a foreign file at the same path can be deleted and a half file can stay behind.
- Codex M2 and Claude m3: route C retries happen before any record exists.
- Minors:
  - repeatable startup cleanup;
  - a failed `temp_path = NULL` update;
  - crash tests run through the error path;
  - capability valid bit and `EXDEV`;
  - AppleDouble sidecars;
  - F15 date wording.

**Scope check before round 6.** Every MAJOR since round 2 sits in NF4 publication and cleanup, and the spec has grown from 215 to 308 lines. A smaller alternative was put to JP: no automatic deletion at startup, only reporting. That removes the M1 class of findings entirely.

**JP decision (2026-10-16).** After a crash the app deletes nothing automatically on any volume; leftovers are only reported (F19d). An intermediate choice, automatic cleanup, was withdrawn once it turned out to be APFS-only.

**Round-5 triage.**

| # | Finding | Decision and remedy |
|---|---|---|
| X-M1 / C-M1 | Path-only, one-shot crash cleanup | Accepted, resolved by JP's report-only decision. Startup cleanup is removed. New F19d reports every record with `temp_path` set, at every start, with "Afgehandeld". In-run cleanup compares `fstat(fd)` with `lstat(pad)` before `unlink`; the microsecond window is an accepted residual risk. |
| X-M2 / C-m3 | Route C retries before a record exists | Accepted. NF4 rule "exactly one record per file": route C before step 3 touches no record and inserts once (pending, or directly `skipped_identical`/`failed`). Retry wording says "indien aanwezig". |
| C-m2 | Repeatable startup handling | Accepted; F19d runs at every start. |
| minor | Failed `temp_path = NULL` update | Accepted. The source is not deleted, F19b applies, the file is reported via F19d. AC3a case. |
| minor | Crash tests go through the error path | Accepted. Crash cases are seeded and run through the startup routine. |
| minor | Capability valid bit and `EXDEV` | Accepted. The `valid` bit is required, `getattrlist` failure means route C, `EXDEV` in route A means route B. Measurements: APFS RENAME_EXCL=1, exFAT 0. |
| minor | AppleDouble `._*` | Accepted as an AC7 observation, not a failure criterion. |
| minor | F15 date wording | Accepted: "bij kopiëren en bij verplaatsen via een kopie". |
| — | Multiple instances | Added to §2 as not supported. |

**Scope delta r5→r6.** Removed: automatic startup cleanup. Added: the F19d report, the `fstat`/`lstat` check, a record rule, AC3a cases. Spec 308 → 329 lines. The first usable result is unchanged; F19–F19d move into increment 1.

## Round 6: revision 6 (`cmvb3ts0a003ler172naxoxvs`, sha256 `e5df09d0fca8a601e2e8808731a5b767c51c05bea95d128a2f9b74cc1b08e782`)

| Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|
| CODEX | dc96a857-0af4-48e4-a401-bc017a58156d | 938e538f-6ede-4a1f-8aea-2f53ae89b273 | 1f6b8c44-d11e-488e-85ef-f23c04894ec2 | linked | **GO**: 0 B / 0 M / 3 m |
| CLAUDE | c35ae6f7-6ea2-46ba-b6f6-403376761f77 | ea7644e7-914b-4da5-a57c-413d9a5d6d61 | 0a157e48-568d-472d-baeb-ac9ede7de3a1 | linked | **GO**: 0 B / 0 M / 7 m |

**Round-6 minors (both GO, so they do not block).**
- Codex m1 / Claude m1, convergent: route B never clears `temp_path` after publication, so F19d would report phantom files after every successful cross-volume transfer.
- Codex m2 / Claude m3, convergent: on an EXDEV hand-off from A to B, route B step 3 says "insert" although the record already exists.
- Codex m3: history and measurement evidence are not pinned.
- Claude m2: there is no writer-side test that `temp_path` is set before the first byte; no capability or unlink/ENOENT variants.
- Claude m4: no `F_FULLFSYNC` before the source delete when moving across volumes.
- Claude m5: "Toon in Finder" on a hidden `.tmp`.
- Claude m6: fd-based date setting; `COPYFILE_ALL` ACL/owner errors on exFAT/SMB.
- Claude m7: exFAT-illegal characters in the keyword folder; F19a wording.

**Spec phase: GO from both reviewers in round 6.** Whether to apply the minors (as revision 7 with a delta round) is JP's call. The idea stays DRAFT.

## Delta loop (r6 → r8): minors applied at JP's request (2026-10-16)

The delta loop has a single reviewer: Codex, cross-model to the Claude author. Pins are `product_doc` revisions.

**Revision 7** (`cmvb46tc50046er17xqj82qw5`, sha256 `96086f6c…f0c25`) applies:
- the two convergent round-6 minors: route B `temp_path` clearing and the EXDEV record;
- Claude m2, m4, m5, m6 and m7.

Codex m3 (no pins for history and measurement) is not applied, because those references are non-normative.

### Delta round 1: r6 → r7

| Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|
| CODEX | b93736fb-24a6-4216-82fe-57836c6112dc | ee9f1268-e3d1-4253-930f-ab290a89e6b7 | 8b43bf7a-f25a-4609-89db-613e092db608 | linked | **NO-GO**: 0 B / 1 M / 3 m |

Findings:
- **MAJOR:** the final-result write clears `temp_path` unconditionally, which discards unresolved cleanup. This regression came from my r7 fix; accepted.
- **Minors, all accepted:**
  - the flush-failure continuation in each route;
  - the crash fixture needs an existence precondition;
  - XATTR coverage.

**Revision 8** (`cmvb4dg2g004qer17taiks5af`, sha256 `f85e46e3…c640d`) fixes all four.

### Delta round 2: r7 → r8

| Slot | Request id | root_message_id | Idempotency key | idea_link | Verdict |
|---|---|---|---|---|---|
| CODEX | ab3cb8ed-4912-4e6e-9234-8639bf77fdf0 | c9e1a4e9-44c1-4623-bcfb-5cb0c3ef607e | 87a955bc-0564-4b35-a3c8-462ae550aad8 | linked | **GO**: 0 B / 0 M / 0 m |

**Scope delta r6 → r8.** Added:
- `F_FULLFSYNC` before deleting the source on a move;
- fd-based dates;
- splitting `COPYFILE_DATA` from `COPYFILE_XATTR` (ACL and owner are no longer copied);
- exFAT-safe folder names;
- automatic NULL in F19d for missing paths;
- about 10 AC3a cases.

The spec went from 329 to 342 lines. The first usable result is unchanged.

**Status:** the spec phase is closed with GO on revision 8. The idea stays DRAFT, and starting the plan phase needs JP.
