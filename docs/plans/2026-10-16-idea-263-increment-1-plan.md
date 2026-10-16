---
title: "IDEA-263 — MacSearch: implementatieplan increment 1"
status: draft
---

# MacSearch increment 1: implementatieplan

Revisie 9: verwerkt de plan-reviews van ronde 1 tot en met 7 en delta-ronde 1.

> **Uitvoering:** taak voor taak, in volgorde; stappen gebruiken `- [ ]`. Elke taak is zelfstandig uitvoerbaar met dit plan en de spec. Een werkwijze-skill zoals superpowers:subagent-driven-development is optioneel.

**Doel:** de kernflow van MacSearch, als native macOS-app op de Mac van JP:
- zoeken op keywords in een bronmap;
- in de slider uitvinken wat niet mee moet;
- kopiëren of verplaatsen naar `<bestemming>/<keyword>/<datum>/`;
- geschiedenis en actielog in SQLite;
- crashveilige publicatie.

**Architectuur.** De kern bestaat uit pure of injecteerbare componenten zonder UI: `KeywordMatcher`, `SearchContext`, `MediaScanner`, `HistoryStore`, `FileOps`, `ConflictResolver`, `FileTransfer`, `TransferBatch` en `StartupRoutine`. Daarboven staat één `@Observable AppModel` met het toestandsmodel uit F0b, en een SwiftUI-`NavigationSplitView`. Alle I/O draait buiten de main actor.

**Techniek:**
- Swift 6 met strikte concurrency, SwiftUI, de huidige macOS (Xcode 27).
- GRDB.swift via SPM, vanaf `7.0.0`.
- Swift Testing (`@Test`, `#expect`).
- Het project wordt gegenereerd met XcodeGen (`project.yml`); het gegenereerde `.xcodeproj` staat niet in git.

**Spec:** SPECS/idea-263-spec revisie 8 (ProductDoc `cmvb0lj1r000per173xpccuxf`, revisie `cmvb4dg2g004qer17taiks5af`). Spec-ID's (F…, NF…, AC…) verwijzen daarnaar.

**Review-records** (historische context, niet normatief): `docs/reviews/2026-10-16-idea-263-spec-review-record.md` en `docs/reviews/2026-10-16-idea-263-plan-review-record.md`.

## Global Constraints
- Alleen de huidige macOS; deployment target `27.0`. Geen sandbox en geen App Store; lokaal gesigneerd (spec §2).
- Eén app-target `MacSearch` en één testtarget `MacSearchTests` (spec §2).
- Database: `~/Library/Application Support/MacSearch/macsearch.sqlite`, met de GRDB-migratie `v1` exact zoals spec §5.
- Er wordt nooit een bestand overschreven of verwijderd dat niet van de app is (NF4). Na een crash verwijdert de app niets (F19c, F19d).
- Bronbestanden worden alleen verwijderd in verplaatsmodus, na een gecontroleerde verplaatsing (NF3, F15).
- Release bouwt zonder waarschuwingen (AC6): `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` in Release.
- Bestandsoperaties in `FileTransfer` lopen uitsluitend via `FileOps` (AC3a).
- Elk testbestand `MacSearchTests/<Naam>.swift` bevat precies één `@Suite struct <Naam>` met `@testable import MacSearch`.
- Testcommando, met `<Suite>` per taak:
  `xcodebuild test -project MacSearch.xcodeproj -scheme MacSearch -destination 'platform=macOS' -only-testing:MacSearchTests/<Suite>`
  - Een PASS telt alleen als de uitvoer een positief aantal uitgevoerde tests van die suite meldt.
  - Een FAIL-stap telt alleen als hij faalt op de nieuwe test (een compileerfout of een falende assertie), niet op 0 uitgevoerde tests.
- Concurrency:
  - `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT = NO`.
  - Alle I/O draait in `Task.detached` of in een `@concurrent`-functie, nooit op de main actor (NF1). Dat geldt voor scan, batch, startup, het verversen van de geschiedenis, `SearchContext.make`, `clearTempPath` en de bestemmingscontrole.

## Review Focus
1. **Unicode NFD in bestandsnamen.** Op externe schijven of na een kopie uit Linux kan een naam als `Rene\u{301}` (e met losse accent) voorkomen. Die moet matchen zoals `René`. Test in taak 2.
2. **Zeer grote resultatensets.** 5.000 of meer treffers mogen de UI niet verstikken. De scanner levert treffers in batches van maximaal 200, met voortgang. Test in taak 4.
3. **Bron verdwijnt of wordt onleesbaar tussen scan en OK.** Dat geeft `failed` voor dat bestand en de batch loopt door. Taak 9 test het bestand, taak 10 de batch. Inhoudelijke wijzigingen van de bron sinds de scan worden niet gedetecteerd; dat vraagt de spec niet.
4. **Doelschijf vol (`ENOSPC`) tijdens het kopiëren.** Dat geeft `failed`, het eigen bestand wordt opgeruimd, de bron blijft intact en de batch loopt door. Test in taak 9.
5. **Keywordinvoer zonder bruikbare tekens**, bijvoorbeeld `...` of `--`. Zoeken wordt dan geblokkeerd met `noKeywords` en er ontstaat geen lege mapnaam. Test in taak 3.

---

### Taak 1: Repository, project en een lege app

**Files:**
- Create: `project.yml`, `.gitignore`, `MacSearch/App/MacSearchApp.swift`, `MacSearchTests/SmokeTests.swift`, `README.md`

**Interfaces:**
- Levert de targets `MacSearch` en `MacSearchTests`, met de GRDB-dependency gekoppeld aan het app-target.
- Levert `enum AppEnvironment { static var isRunningTests: Bool }`. Die is `true` als `XCTestConfigurationFilePath` in de omgeving staat of als `NSClassFromString("XCTestCase") != nil`.

- [ ] **Stap 1:** `git init` en `git branch -M main` in `/Users/janpetervisser/Development/MacSearch`, daarna `git remote add origin https://git.jp-visser.nl/janpeter/MacSearch.git`. Controleer eerst met `git ls-remote origin` of de remote leeg is; is hij dat niet, stop dan en meld het aan JP. `docs/` staat lokaal al.
- [ ] **Stap 2:** maak `project.yml` (XcodeGen) aan met:
  - app-target `MacSearch` (macOS 27.0, SwiftUI-lifecycle, `ENABLE_APP_SANDBOX = NO`, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`);
  - testtarget `MacSearchTests` als **hosted** unit tests (`TEST_HOST = $(BUILT_PRODUCTS_DIR)/MacSearch.app/Contents/MacOS/MacSearch`, `BUNDLE_LOADER = $(TEST_HOST)`), afhankelijk van het app-target. GRDB wordt alleen aan de app gelinkt; de tests zien GRDB en de app-code via de bundle loader. Tests mogen `import GRDB` gebruiken;
  - een scheme `MacSearch` met `build` en `test`, met `testTargets: [MacSearchTests]`;
  - signing "Sign to Run Locally" (`CODE_SIGN_IDENTITY = "-"`) voor beide targets;
  - package `GRDB` via `https://github.com/groue/GRDB.swift`, `from: 7.0.0`;
  - Release: warnings as errors.

  Zet `.gitignore` op `*.xcodeproj`, `build/` en `DerivedData/`.
- [ ] **Stap 3:** `MacSearchApp` met één `WindowGroup` en een placeholder-`Text("MacSearch")`.
  - Bij `AppEnvironment.isRunningTests` doet de app geen opstartwerk: geen database en geen `StartupRoutine` (taak 11 en 12 houden zich hieraan). Zo raken tests nooit de echte database.
  - `SmokeTests.swift`: `@Suite struct SmokeTests` met `@testable import MacSearch` en `import GRDB`, met `@Test func appCodeIsVisible() { #expect(AppEnvironment.isRunningTests) }` en `@Test func grdbIsVisible() throws { _ = try DatabaseQueue() }`.
  - Compileert `import GRDB` niet in het testtarget, koppel het GRDB-product dan ook aan `MacSearchTests` en noteer dat in `project.yml`.
- [ ] **Stap 4:** `xcodegen generate`, daarna het testcommando met `<Suite>` = `SmokeTests`. Verwacht: PASS met 2 uitgevoerde tests. Daarna `xcodebuild -scheme MacSearch -configuration Release build 2>&1 | tee build.log; grep 'warning:' build.log | grep -c '/MacSearch/'`. Verwacht: `BUILD SUCCEEDED` en `0` (waarschuwingen uit de eigen bronnen; die van packages tellen niet).
- [ ] **Stap 5:** commit "chore: scaffold MacSearch app with XcodeGen and GRDB" en `git push -u origin main`.

### Taak 2: KeywordMatcher (F1–F5)

**Files:** Create `MacSearch/Core/KeywordMatcher.swift`; test `MacSearchTests/KeywordMatcherTests.swift`.

**Interfaces, Produces:**
```swift
enum KeywordMatcher {
    static func norm(_ s: String) -> String
    static func keywords(from input: String) -> [String]          // F2: split op witruimte, norm, lege weg
    static func matches(fileName: String, keywords: [String]) -> Bool  // F3/F4: naam zonder extensie
}
```

- [ ] **Stap 1:** tests, als geparametriseerde `@Test(arguments:)`:
  - alle F5-matches en -non-matches met invoer `janpeter visser`;
  - `rené` matcht `Rene_2020.jpg`;
  - `janpeter janpeter` matcht `janpeter_janpeter.jpg` en niet `janpeter.jpg`;
  - **Review Focus 1:** `matches(fileName: "Rene\u{301}_2020.jpg", keywords: keywords(from: "René"))` is `true`;
  - `keywords(from: "  ...  -- ")` is `[]`.
- [ ] **Stap 2:** draai de tests. Verwacht: FAIL, want het type ontbreekt.
- [ ] **Stap 3:** implementeer.
  - `norm`: `folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)`, daarna alleen `isLetter || isNumber` behouden.
  - `matches`: zoek greedy van links, met een zoekstart na het einde van de vorige match.
- [ ] **Stap 4:** draai de tests. Verwacht: PASS.
- [ ] **Stap 5:** commit "feat: keyword matcher".

### Taak 3: SearchContext, bestandsidentiteit en validatie (F0a, F8, F14-naam, F25, F27)

**Files:** Create `MacSearch/Core/FileIdentity.swift`, `MacSearch/Core/SearchContext.swift`; test `MacSearchTests/SearchContextTests.swift`.

**Interfaces, Produces:**
```swift
struct FileIdentity: Hashable, @unchecked Sendable {   // immutable wrapper; == via isEqual, hash via NSObject.hash
    init?(url: URL)                                   // lost symlinks op, leest fileResourceIdentifierKey
    init(resourceIdentifier: any NSObjectProtocol)    // uit de vooraf opgehaalde resource-waarde van de enumerator
}
func destinationUsable(_ url: URL) -> Bool            // bestaat, is een map en access(W_OK) == 0; F25 en F26
func keywordFolderName(_ raw: String) -> String               // F14
enum SearchValidationError: Error, Equatable { case sourceMissing, destinationUnusable, sameFolder, noKeywords, folderNameTooLong }
enum Containment: Equatable { case none, destInsideSource, sourceInsideDest }
struct SearchContext: Sendable {
    let source: URL, destRoot: URL, keywordsRaw: String, keywords: [String], folderName: String   // source en destRoot symlink-opgelost
    let excluded: FileIdentity?        // alleen bij destInsideSource (F8)
    let containment: Containment       // voor de waarschuwing van F27
    static func make(source: URL, keywordsRaw: String, destRoot: URL) throws(SearchValidationError) -> SearchContext
}
```

- [ ] **Stap 1:** tests in een tijdelijke map:
  - bron gelijk aan bestemming, ook via een symlink en via een andere hoofdlettervariant → `.sameFolder`. De hoofdlettervariant vereist een hoofdletterongevoelig volume (zoals de standaard-APFS van JP); de test controleert dat eerst en slaat alleen die variant anders over met een melding;
  - bestemming strikt binnen de bron → `excluded` gelijk aan de identiteit van de bestemming;
  - een symlink-bestemming naar een submap van de bron → idem;
  - zustermappen `/x/foto` en `/x/fotos` → `excluded == nil`, `.none`;
  - een bron binnen de bestemming → `.sourceInsideDest`, `excluded == nil`;
  - `keywordFolderName(" .a/b:c?*\"<>|\\  d.. ")` → `"a-b-c------- d"`;
  - een mapnaam van meer dan 255 bytes UTF-8 → `.folderNameTooLong`;
  - **Review Focus 5:** `keywordsRaw: "..."` → `.noKeywords`;
  - een niet-bestaande bron → `.sourceMissing`;
  - een niet-bestaande bestemming → `.destinationUnusable`;
  - een bestemming met `chmod 555` → `.destinationUnusable`, en `destinationUsable` is `false` (herstel de rechten na de test);
  - een bron die een symlink is → `ctx.source` is het opgeloste pad.
- [ ] **Stap 2:** draai de tests. Verwacht: FAIL.
- [ ] **Stap 3:** implementeer.
  - "Binnen" betekent dat de identiteit van B voorkomt in de keten van ouders van A, na `resolvingSymlinksInPath()`.
  - De volgorde van F14 is: tekens vervangen, dan trimmen, dan interne witruimte samenvoegen.
- [ ] **Stap 4:** draai de tests. Verwacht: PASS.
- [ ] **Stap 5:** commit "feat: search context and validation".

### Taak 4: MediaScanner (F6, F7, F9, F10)

**Files:** Create `MacSearch/Core/MediaScanner.swift`; test `MacSearchTests/MediaScannerTests.swift`.

**Interfaces:**
- **Consumes:** `SearchContext`, `KeywordMatcher`.
- **Produces:**
```swift
struct FoundFile: Sendable, Hashable { let url: URL; let size: Int64 }
enum ScanEvent: Sendable { case found([FoundFile]); case progress(scanned: Int, skipped: Int) }
struct MediaScanner: Sendable {
    init(onItem: (@Sendable (Int) -> Void)? = nil)   // test-hook: aanroep met het volgnummer van elk door de enumerator opgeleverd item; mag blokkeren
    func scan(_ ctx: SearchContext) -> AsyncThrowingStream<ScanEvent, Error>
}
```

- [ ] **Stap 1:** tests (AC2):
  - een boom met de volgende onderdelen; alleen de twee media-treffers worden gevonden:
    - een verborgen `.x/janpeter_visser.jpg`;
    - een `.photoslibrary`-pakket;
    - een `janpeter_visser.txt`;
    - een geneste bestemmingsmap met `janpeter_visser.jpg`;
    - een matchende `.jpg` en `.mov` elders.
  - een onleesbare submap (`chmod 000`) geeft `skipped >= 1` en de scan eindigt normaal;
  - **F10, onleesbaar bestand:** een matchende `.jpg` met `chmod 000` naast een leesbare match. Alleen de leesbare wordt gevonden, `skipped` is 1 en de scan eindigt normaal. Herstel de rechten na de test;
  - annuleren van de consumerende `Task` stopt de producent, deterministisch getest:
    - een boom van 2.000 matchende bestanden;
    - de `onItem`-hook signaleert "bereikt" en blokkeert op een tweede semafoor bij item 500;
    - de test wacht op "bereikt", annuleert de consument en geeft de semafoor vrij;
    - na 200 ms is de hoogste gemelde index `<= 502`;
  - `.progress(scanned:)` geeft aan het einde het aantal opgeleverde items (een boom van 30 bestanden en 3 mappen geeft `scanned == 33`);
  - een bron die een symlink is naar een map met een treffer → die treffer wordt gevonden;
  - **Review Focus 2:** 5.000 lege matchende `.jpg`-bestanden geven in totaal 5.000 treffers, en geen enkel `found`-event bevat meer dan 200 items.
- [ ] **Stap 2:** draai de tests. Verwacht: FAIL.
- [ ] **Stap 3:** implementeer.
  - Een synchrone helper met `nextObject()`-lus op een `Task.detached`, die de stream voedt. Bewaar de task-handle en zet `continuation.onTermination = { _ in task.cancel() }`, zodat annuleren van de consument de producent stopt (F9).
  - De identiteit van een map komt uit de vooraf opgehaalde `fileResourceIdentifierKey` (`FileIdentity(resourceIdentifier:)`), zonder extra I/O per map. De sleutellijst van F6 krijgt er `.fileSizeKey` bij, voor `FoundFile.size`.
  - De `errorHandler` telt een overgeslagen item en geeft `true` terug.
  - Een matchend mediabestand waarvan `isReadableKey` `false` is (opgenomen in de sleutellijst), telt als overgeslagen en wordt niet opgeleverd (F10).
  - Bij elke flush van een `found`-batch volgt een `.progress`-event, en ook één aan het einde.
  - Bij een map waarvan `FileIdentity` gelijk is aan `ctx.excluded`: `skipDescendants()`.
  - Media is wat conformeert aan `UTType.image` of `.movie`.
  - Treffers worden in batches verzameld, maximaal 200 of maximaal 100 ms.
  - `Task.isCancelled` wordt per item gecontroleerd.
- [ ] **Stap 4:** draai de tests. Verwacht: PASS.
- [ ] **Stap 5:** commit "feat: streaming media scanner".

### Taak 5: HistoryStore (F19, F19a, F19c-statussen, §5)

**Files:** Create `MacSearch/Store/HistoryStore.swift`, `MacSearch/Store/Records.swift`; test `MacSearchTests/HistoryStoreTests.swift`.

**Interfaces, Produces:**
```swift
enum RunStatus: String { case running, completed, cancelled, aborted, interrupted }
enum ActionResult: String { case pending, copied, moved, renamed, skippedIdentical = "skipped_identical", failed }
enum TempPathChange { case keep, set(String), clear }
struct NewRun { createdAt, sourcePath, keywordsRaw, destRoot, destFolder: String; mode: TransferMode; foundCount, selectedCount: Int; scanComplete: Bool; skippedCount: Int }
enum TransferMode: String, Sendable { case copy, move }
protocol HistoryWriting: Sendable {
    func insertRun(_ run: NewRun) throws -> Int64
    func finishRun(id: Int64, status: RunStatus) throws
    func insertAction(runId: Int64, sourcePath: String, destPath: String?, tempPath: String?, result: ActionResult, error: String?) throws -> Int64
    func updateAction(id: Int64, result: ActionResult, destPath: String?, tempPath: TempPathChange, error: String?) throws
}
struct Leftover { let actionId: Int64; let path: String }
struct RunSummary { id, createdAt, keywordsRaw, sourcePath, destRoot, mode, status, processedCount, isIncomplete }
final class HistoryStore: HistoryWriting {
    init(url: URL) throws; static func inMemory() throws -> HistoryStore
    func markRunningInterrupted() throws -> Int
    func leftoverCandidates() throws -> [Leftover]      // temp_path gezet, run niet running
    func clearTempPath(actionId: Int64) throws
    func recentRuns(limit: Int) throws -> [RunSummary]
    func actions(runId: Int64) throws -> [ActionRow]    // voor tests
    let dbQueue: DatabaseQueue                          // internal; schema-tests gebruiken het via @testable en import GRDB
}
```

- [ ] **Stap 1:** tests (AC4):
  - de migratie draait op een lege database;
  - een run met twee acties wordt opgeslagen en teruggelezen;
  - `markRunningInterrupted` zet alleen `running` om naar `interrupted`;
  - `isIncomplete` is `true` voor `interrupted`, `aborted` en `cancelled`, voor `scan_complete = 0` en voor `skipped_count > 0`;
  - `leftoverCandidates` slaat `running`-runs over;
  - een kapotte database (een bestand met random bytes) → `init` gooit;
  - het schema volgt §5:
    - een insert met een ongeldige `mode` of `status` wordt geweigerd;
    - `sqlite_master` bevat `file_action_run` en `search_run_created`;
    - een run verwijderen verwijdert zijn acties (cascade, met `PRAGMA foreign_keys` aan);
    - `finished_at` is `NULL` zolang de run `running` is, en `finishRun` zet het.
- [ ] **Stap 2:** draai de tests. Verwacht: FAIL.
- [ ] **Stap 3:** implementeer met `DatabaseQueue` en de migratie `v1`, letterlijk volgens §5. `created_at` en `finished_at` zijn ISO-8601.
- [ ] **Stap 4:** draai de tests. Verwacht: PASS.
- [ ] **Stap 5:** commit "feat: history store with v1 migration".

### Taak 6: FileOps en volumecapaciteit (F15, de basis van AC3a)

**Files:** Create `MacSearch/Transfer/FileOps.swift`, `MacSearch/Transfer/PosixFileOps.swift`; test `MacSearchTests/PosixFileOpsTests.swift`, `MacSearchTests/Support/FaultyFileOps.swift`.

**Interfaces, Produces:**
```swift
struct POSIXFailure: Error, Equatable { let errno: Int32 }
struct Inode: Equatable { let dev: UInt64; let ino: UInt64 }
protocol FileOps: Sendable {
    func openRead(_ path: String) throws(POSIXFailure) -> Int32
    func createExclusive(_ path: String) throws(POSIXFailure) -> Int32          // O_CREAT|O_EXCL|O_WRONLY
    func fstatInode(_ fd: Int32) throws(POSIXFailure) -> Inode
    func lstatInode(_ path: String) throws(POSIXFailure) -> Inode
    func unlink(_ path: String) throws(POSIXFailure)
    func renameExclusive(_ from: String, _ to: String) throws(POSIXFailure)     // renamex_np RENAME_EXCL
    func copyData(from: Int32, to: Int32) throws(POSIXFailure)                  // fcopyfile COPYFILE_DATA
    func copyXattrs(from: Int32, to: Int32) throws(POSIXFailure)                // fcopyfile COPYFILE_XATTR
    func setDates(_ fd: Int32, modified: Date, created: Date) throws(POSIXFailure) // futimens + fsetattrlist ATTR_CMN_CRTIME
    func fullFsync(_ fd: Int32) throws(POSIXFailure)                            // fcntl F_FULLFSYNC
    func size(fd: Int32) throws(POSIXFailure) -> Int64
    func dates(path: String) throws(POSIXFailure) -> (modified: Date, created: Date)
    func exists(_ path: String) -> Bool
    func close(_ fd: Int32)
    func createDirectories(_ path: String) throws(POSIXFailure)                  // mkdir -p
    func supportsRenameExclusive(volumeOf dir: String) -> Bool                  // getattrlist; valid-bit vereist; fout → false
    func volumeID(_ path: String) -> AnyHashable?
}
protocol UUIDSource: Sendable { func next() -> UUID }
struct SystemUUIDSource: UUIDSource { func next() -> UUID { UUID() } }
struct VolumeCapabilities { let capabilities: UInt32; let valid: UInt32 }   // het VOL_CAPABILITIES_INTERFACES-woord
func renameExclusiveAllowed(_ caps: VolumeCapabilities) -> Bool            // puur: bit in capabilities én in valid
final class PosixFileOps: FileOps {
    init(capabilityQuery: @escaping @Sendable (String) throws(POSIXFailure) -> VolumeCapabilities = PosixFileOps.getattrlistQuery)
}
```
`FaultyFileOps` (alleen in tests) wikkelt `PosixFileOps` met:
- per methode een te injecteren `POSIXFailure`, eventueel alleen bij de n-de aanroep;
- `before`-hooks per methode;
- een geforceerde uitkomst van `supportsRenameExclusive` (`Bool?`), gebruikt in de batch-tests van taak 10;
- een override van `volumeID` (`[String: AnyHashable]`, op padprefix), zodat route B bij verplaatsen ("ander volume") zonder tweede schijf testbaar is;
- tellers per methode.

- [ ] **Stap 1:** tests op echte bestanden in een tijdelijke map:
  - `createExclusive` op een bestaand pad → `errno == EEXIST`;
  - `renameExclusive` naar een bestaand doel → `EEXIST`, en het doel is byte-voor-byte ongewijzigd;
  - `supportsRenameExclusive` op `NSTemporaryDirectory()` is `true`;
  - `renameExclusiveAllowed`, voor vier combinaties:

    | capability-bit | valid-bit | uitkomst |
    |---|---|---|
    | gezet | gezet | `true` |
    | gezet | niet gezet | `false` |
    | niet gezet | gezet | `false` |
    | niet gezet | niet gezet | `false` |
  - `PosixFileOps(capabilityQuery:)` met een query die `POSIXFailure(errno: EIO)` gooit → `supportsRenameExclusive` is `false`;
  - `createDirectories` op een pad onder een gewoon bestand → `ENOTDIR`;
  - `setDates` en daarna `dates`: de verschillen zijn kleiner dan 1 ms.
- [ ] **Stap 2:** draai de tests. Verwacht: FAIL.
- [ ] **Stap 3:** implementeer de syscalls zoals in de commentaren hierboven. `supportsRenameExclusive` vereist `VOL_CAP_INT_RENAME_EXCL` in zowel `capabilities` als `valid`.
- [ ] **Stap 4:** draai de tests. Verwacht: PASS.
- [ ] **Stap 5:** commit "feat: FileOps abstraction over POSIX".

### Taak 7: ConflictResolver (F16)

**Files:** Create `MacSearch/Transfer/ConflictResolver.swift`; test `MacSearchTests/ConflictResolverTests.swift`.

**Interfaces:**
- **Consumes:** `FileOps`.
- **Produces:**
```swift
enum Resolution: Equatable { case free(String); case identical(String) }
struct ConflictResolver: Sendable {
    let ops: FileOps
    func resolve(sourcePath: String, sourceSize: Int64, desiredPath: String) throws -> Resolution
}
enum ContentHasher { static func sha256(path: String, ops: FileOps) throws -> Data }   // streaming via ops.openRead, CryptoKit
```

- [ ] **Stap 1:** tests (AC3):
  - het doel bestaat niet → `.free(desired)`;
  - het doel is identiek → `.identical(desired)`;
  - het doel heeft een andere grootte → `.free("naam (2).jpg")`;
  - `naam (2)` is identiek → `.identical("…(2)…")`;
  - `naam` en `naam (2)` zijn anders → `.free("naam (3).jpg")`;
  - **gelijke grootte, andere inhoud:** de bron bevat `ABC`, het doel `XYZ` → `.free("naam (2).jpg")`;
  - zonder extensie: `naam` → `naam (2)`.
- [ ] **Stap 2:** draai de tests. Verwacht: FAIL.
- [ ] **Stap 3:** implementeer. Toets de kandidaten op volgorde, tot en met de eerste vrije naam. Gelijke grootte gaat via SHA-256, met blokken van 1 MiB.
- [ ] **Stap 4:** draai de tests. Verwacht: PASS.
- [ ] **Stap 5:** commit "feat: Finder-style conflict resolution".

### Taak 8: FileTransfer, publicatieroutes A/B/C en herpogingen (F15, F17, NF4)

**Files:** Create `MacSearch/Transfer/FileTransfer.swift`; test `MacSearchTests/FileTransferRoutesTests.swift`, `MacSearchTests/Support/RecordingStore.swift`.

**Interfaces:**
- **Consumes:** `FileOps`, `HistoryWriting`, `ConflictResolver`, `UUIDSource`.
- **Produces:**
```swift
struct TransferOutcome: Equatable { let result: ActionResult; let destPath: String?; let warning: String? }
struct StoreWriteFailed: Error {                                     // F19b: batch moet stoppen
    let fileProcessed: Bool              // false: pending-insert faalde (bestand niet verwerkt); true: resultaat-update faalde
    let outcome: TransferOutcome?        // gezet als fileProcessed
}
final class FileTransfer: Sendable {
    init(ops: FileOps, store: HistoryWriting, uuids: UUIDSource, renameExclusive: Bool)
    func transfer(_ file: FoundFile, runId: Int64, destFolder: String, mode: TransferMode) throws(StoreWriteFailed) -> TransferOutcome
}
```

Kies de route volgens F15:
- **Route A:** verplaatsen, zelfde `volumeID` en `renameExclusive`;
- **Route B:** wel `renameExclusive`, maar kopiëren of een ander volume, of A met `EXDEV`;
- **Route C:** geen `renameExclusive`.

De stappen per route en de regel "precies één record" staan letterlijk in NF4. Eén pogingenteller per bestand, maximaal 3 keer `EEXIST`.

- [ ] **Stap 1:** tests op de echte `PosixFileOps`, met `FaultyFileOps` alleen voor hooks en capaciteit. Het gaat om deze AC3a-gevallen:
  - kopiëren en verplaatsen in route A, B en C;
  - collision op de tijdelijke naam (UUID-reeks);
  - collision op de definitieve naam, met andere en met identieke inhoud (hook vóór de publicatie), in B en in C;
  - drie keer `EEXIST`, in B en in C;
  - een collision in route A;
  - route A met `EXDEV`: precies één record;
  - record vóór de eerste byte (hook op `copyData`), in B en in C;
  - een geslaagde transfer laat `temp_path` op `NULL` achter;
  - metadata geslaagd: datums plus het xattr `com.macsearch.test`;
  - `renameExclusive: false` → route C: geen `renameExclusive`-aanroep en geen `.macsearch-*.tmp`;
  - verplaatsen naar een ander volume (via de `volumeID`-override) → route B;
  - **gelijke grootte, andere inhoud** (bron `ABC`, doel `XYZ`), in B en in C → `renamed` naar `(2)`. Het bestaande doel is ongewijzigd en `(2)` bevat `ABC`;
  - **identiek vanaf het begin**, in A, B en C, kopiëren en verplaatsen:
    - het doel bestaat al met identieke inhoud → `skipped_identical`;
    - de bron staat er nog;
    - de `createExclusive`-teller is 0;
    - het aanroeplog van de store toont precies één `insertAction` met `skipped_identical` en nul `updateAction`;
  - **gedeeld pogingenbudget, route B:** eerst één collision op de tijdelijke naam, daarna twee publicatie-collisions → `failed` bij de derde botsing, het eigen bestand is weg, de bron is intact en er is precies één record;
  - **budget over `EXDEV` heen:** één collision in route A, daarna `EXDEV`, daarna twee publicatie-collisions in route B → `failed` bij de derde;
  - **hergebruik in route B:** bij twee publicatie-collisions gevolgd door succes worden `createExclusive` en `copyData` precies één keer aangeroepen (tellers in `FaultyFileOps`).

  Elke test controleert de doelinhoud, de bron, het resultaat en de records via `store.actions(runId:)`. De store is een `HistoryStore.inMemory()`, gewikkeld in een `RecordingStore` (`MacSearchTests/Support/RecordingStore.swift`) die aanroepen logt en fouten kan injecteren. Taak 10 gebruikt dezelfde `RecordingStore`.
- [ ] **Stap 2:** draai de tests. Verwacht: FAIL.
- [ ] **Stap 3:** implementeer de routes, de herpogingen en Opruimen.
  - Houd de eigen fd open tot de publicatie of het opruimen.
  - Na een geslaagde publicatie wordt `temp_path` gewist in de write van het eindresultaat (F19b stap 2).
  - Opruimen volgt NF4: vergelijk `fstatInode(fd)` met `lstatInode(pad)`; alleen bij gelijkheid volgt `unlink` en daarna `.clear`, anders blijft het `.keep`. Opruimen hoort in deze taak, omdat de herpoging naar identiek en drie keer `EEXIST` het nodig hebben.
- [ ] **Stap 4:** draai de tests. Verwacht: PASS.
- [ ] **Stap 5:** commit "feat: crash-safe publication routes".

### Taak 9: FileTransfer, foutpaden en opruimen (NF4 Opruimen, F15, F17)

**Files:** Modify `MacSearch/Transfer/FileTransfer.swift`; test `MacSearchTests/FileTransferFailureTests.swift`.

Deze taak gebruikt Opruimen uit taak 8 en voegt de foutpaden toe. Tests die al slagen op Opruimen alleen (vervangen bestand, `unlink` faalt, `ENOENT`) mogen bij stap 2 al PASS geven. Dat is hier toegestaan; de andere gevallen moeten FAIL geven.

**Interfaces:**
- **Consumes:** taak 8.
- **Produces:** geen nieuwe interfaces.

- [ ] **Stap 1:** tests, telkens met de beschreven verwachting (AC3a):
  - **Kopie breekt halverwege af:** een `copyData`-hook schrijft eerst een bekend, niet-leeg deel (4 KiB van het begin van de bron) naar de doel-fd en gooit dan `EIO`. Vóór het gooien legt de hook de grootte (`fstat` op de doel-fd) en de inhoud vast. Omdat de doel-fd `O_WRONLY` is, opent de hook daarvoor apart het pad read-only; dat pad legt `FaultyFileOps` vast bij `createExclusive`. De hook controleert dat device en inode van beide fd's gelijk zijn en leest dan de 4 KiB terug. Het opruimen verwijdert het bestand voordat de test weer aan de beurt is. De test controleert daarom eerst dat vastgelegde record (4 KiB, gelijk aan het begin van de bron), en daarna: `failed`, geen eigen bestand, geen publicatie, de bron intact en precies één record.
  - **Publiceren faalt met `EIO`:** `failed`.
  - **Bron verwijderen faalt na een kopie tussen volumes, bij verplaatsen:** `copied` met een waarschuwing.
  - **Grootte wijkt af, bij verplaatsen:** `failed`.
  - **Vervangen bestand, in B en in C:** een hook vervangt het eigen bestand → het vreemde bestand is ongewijzigd, `failed`, en `temp_path` is na het eindresultaat nog gezet.
  - **`unlink` faalt:** idem.
  - **`lstat` geeft `ENOENT`:** `failed`, en `temp_path` is nog gezet.
  - **Flush faalt bij verplaatsen, in B en in C:** het bestand staat onder de definitieve naam, de bron bestaat nog, `copied` met een waarschuwing, en `temp_path` is `NULL`.
  - **XATTR of datums falen, elk apart:** `copied` met een waarschuwing.
  - **`COPYFILE_DATA` faalt:** `failed`.
  - **`pending`-insert faalt na de exclusieve aanmaak, in B en in C:** gooit `StoreWriteFailed`, het eigen lege bestand is weg en er is geen transfer.
  - **Route C, de `temp_path = NULL`-update faalt bij verplaatsen:** gooit `StoreWriteFailed` en de bron bestaat nog.
  - **Review Focus 3:** de bron is verwijderd na de scan → `failed`, er volgt geen throw en er is precies één record (`failed`, nooit `pending`).
  - **Review Focus 4:** `copyData` faalt met `ENOSPC` → `failed`, geen eigen bestand, de bron is intact en er is precies één record (`failed`).
  - **Fout vóór een eigen bestand** (`createExclusive` geeft `ENOSPC` in route C, of `openRead` faalt in de hash van F16 via `FaultyFileOps`) → het aanroeplog toont precies één `insertAction` met `failed` en nul `updateAction`.
- [ ] **Stap 2:** draai de tests. Verwacht: FAIL.
- [ ] **Stap 3:** implementeer de foutpaden van F15 en F17:
  - grootte-afwijking;
  - flush, met de bron die blijft staan en een waarschuwing;
  - metadata-waarschuwingen;
  - het faalpad van het verwijderen van de bron (het slagende pad zit in taak 8);
  - `StoreWriteFailed` met `fileProcessed`.
- [ ] **Stap 4:** draai de tests. Verwacht: PASS, ook voor de suite van taak 8.
- [ ] **Stap 5:** commit "feat: transfer failure paths and safe cleanup".

### Taak 10: TransferBatch (F14-map, F17, F19a, F19b, F19c, F0d-stop)

**Files:** Create `MacSearch/Transfer/TransferBatch.swift`; test `MacSearchTests/TransferBatchTests.swift` (gebruikt `RecordingStore` uit taak 8).

**Interfaces:**
- **Consumes:** `SearchContext`, `HistoryWriting`, `FileTransfer`, `FileOps`.
- **Produces:**
```swift
enum FatalCause: Sendable, Equatable { case destinationUnusable, runInsertFailed, aborted }
struct BatchSummary { let runId: Int64?; let status: RunStatus?; let counts: [ActionResult: Int]; let warnings: [String]; let fatalError: String?; let fatalCause: FatalCause?; let destFolder: String }
final class StopFlag: Sendable { func stop(); var isStopped: Bool { get } }   // atomic
struct TransferBatch: Sendable {
    init(store: HistoryWriting, ops: FileOps, uuids: UUIDSource, isUsable: @escaping @Sendable (URL) -> Bool = destinationUsable)
    @concurrent func run(context: SearchContext, files: [FoundFile], mode: TransferMode, confirmedAt: Date,
             foundCount: Int, scanComplete: Bool, skippedCount: Int,
             stop: StopFlag, progress: @escaping @Sendable (_ processed: Int, _ total: Int) -> Void) async -> BatchSummary
}
```
De volgorde is:
0. `isUsable(context.destRoot)` controleren (F26). Bij `false`: `fatalError` met `runId == nil` en `fatalCause == .destinationUnusable`, zonder insert of transfer;
1. de datum en de doelmap afleiden uit `confirmedAt`, het moment van OK (`yyyy-MM-dd`, `en_US_POSIX`, Gregoriaans, lokale tijdzone, F0d en F14). `created_at` is ook `confirmedAt`;
2. `insertRun`, en bij een fout `fatalError` met `runId == nil` en `fatalCause == .runInsertFailed`;
3. de mappen aanmaken met `ops.createDirectories`, en bij een fout `aborted` (`fatalCause == .aborted`);
4. **één keer per run** `ops.supportsRenameExclusive(volumeOf: destFolder)` bepalen en daarmee `FileTransfer` maken (F15);
5. de bestanden verwerken;
6. `finishRun`.

Een gewone `failed`-uitkomst stopt de batch niet (F17). `StoreWriteFailed` stopt de batch wel en zet de status op `aborted` (`fatalCause == .aborted`), ook als Stop is ingedrukt.

De foutmelding noemt het laatst verwerkte bestand:
- bij `fileProcessed == true` is dat het huidige bestand;
- anders het vorige;
- als er geen vorig bestand is: "geen bestand verwerkt".

`progress(processed, total)` wordt na elk bestand aangeroepen.

Een meegegeven `outcome` telt mee in `counts`.

- [ ] **Stap 1:** tests (AC4, F0d):
  - een `search_run`-insert faalt → nul transfers, `runId == nil`, `fatalError != nil` en `fatalCause == .runInsertFailed`;
  - de bestemming is onbruikbaar (`isUsable` geeft `false`) → geen insert, nul transfers, `runId == nil`, `fatalError != nil` en `fatalCause == .destinationUnusable`;
  - `confirmedAt` is de vaste datum 2001-02-03 23:59:59 in de lokale tijdzone → de doelmap eindigt op `2001-02-03` en `created_at` is de ISO-8601-vorm van dat moment. Omdat die datum nooit vandaag is, faalt een `run` die zelf de klok leest altijd;
  - `progress` wordt bij 3 bestanden aangeroepen met `(1,3)`, `(2,3)` en `(3,3)`;
  - de `pending`-insert van bestand 1 faalt → nul transfers, `aborted`, `fatalCause == .aborted` en `runId != nil`;
  - de resultaat-update van bestand 1 van 3 faalt → precies één transfer, het `pending`-record blijft en de status is `aborted`;
  - idem terwijl ook de `aborted`-write faalt → de status blijft `running`, en na `markRunningInterrupted` is hij `interrupted`;
  - Stop tijdens bestand 1 plus een mislukte update → `aborted`;
  - Stop na bestand 1 van 3 → `cancelled`, en de bestanden 2 en 3 zijn onaangeroerd;
  - de doelmap aanmaken faalt → `aborted`, `fatalCause == .aborted`, nul transfers;
  - de write van de eindstatus faalt → de status blijft `running`;
  - **batch loopt door na een fout (AC3):** drie bestanden, waarvan bestand 1 onleesbaar is (`chmod 000`) → records `failed`, `copied`, `copied`; de bestanden 2 en 3 staan in de doelmap, bestand 1 is intact en de status is `completed`;
  - idem met `ENOSPC` op `copyData` van bestand 1;
  - `supportsRenameExclusive` wordt per run precies één keer aangeroepen (teller), ook bij drie bestanden;
  - **de capaciteit stuurt de route (F15, AC3a):**
    - met een geforceerde `false` via `FaultyFileOps`, en apart met `PosixFileOps(capabilityQuery:)` die `EIO` gooit, volgt de batch route C: de `renameExclusive`-teller is 0, er wordt geen `.macsearch-*.tmp` aangemaakt en het bestand staat compleet onder de definitieve naam;
    - met een geforceerde `true` en kopiëren is de `renameExclusive`-teller ≥ 1;
  - een `StoreWriteFailed` met `fileProcessed == true` bij bestand 2 → `fatalError` noemt bestand 2, en `counts` bevat de uitkomst van bestand 2;
  - met `fileProcessed == false` bij bestand 2 → `fatalError` noemt bestand 1.
- [ ] **Stap 2:** draai de tests. Verwacht: FAIL.
- [ ] **Stap 3:** implementeer. De datum komt uitsluitend uit `confirmedAt`; `run` leest zelf geen klok.
- [ ] **Stap 4:** draai de tests. Verwacht: PASS.
- [ ] **Stap 5:** commit "feat: transfer batch with run bookkeeping".

### Taak 11: StartupRoutine (F19, F19c, F19d)

**Files:** Create `MacSearch/Store/StartupRoutine.swift`; test `MacSearchTests/StartupRoutineTests.swift`.

**Interfaces, Produces:**
```swift
enum StartupState { case ready(store: HistoryStore, leftovers: [Leftover], history: [RunSummary]); case failed(path: String, message: String) }
enum StartupRoutine { static func run(databaseURL: URL, ops: FileOps) -> StartupState }
```
Dit doet de routine:
- de database openen en migreren, met de `Application Support`-map erbij;
- `markRunningInterrupted`;
- voor elke kandidaat waarvan het pad niet bestaat: `clearTempPath`;
- de rest teruggeven als `leftovers`, samen met `recentRuns(limit: 50)` als `history`;
- nooit iets verwijderen.

`StartupRoutine.run` is synchroon en wordt door de app aangeroepen in `Task.detached` (NF1).
- Tot de routine klaar is, toont `MacSearchApp` een laadscherm en houdt het `AppModel?` op `nil`.
- Onder `AppEnvironment.isRunningTests` draait de routine niet en wordt er geen `AppModel` gemaakt; het venster toont alleen de placeholder.

- [ ] **Stap 1:** tests met een geseede database en bestanden (AC3a, crash):
  - **route C, halve kopie:** gemeld, niets verwijderd, en een vreemd bestand ernaast is ongewijzigd;
  - **route C, door de gebruiker verwijderd:** `temp_path` wordt `NULL`, geen melding;
  - **route C, crash na NULL:** geen melding, en doel en bron bestaan nog;
  - **route B, crash tussen stap 5 en 7:** `NULL`, geen melding;
  - **melding na een crash:** gemeld bij elke start; na `clearTempPath` volgt de volgende start zonder melding;
  - **een run die op `running` staat:** wordt `interrupted`;
  - **een database die niet te openen is:** `.failed` met het pad.
- [ ] **Stap 2:** draai de tests. Verwacht: FAIL.
- [ ] **Stap 3:** implementeer.
- [ ] **Stap 4:** draai de tests. Verwacht: PASS.
- [ ] **Stap 5:** commit "feat: startup routine and leftover report data".

### Taak 12: AppModel, het toestandsmodel (F0b–F0d, F13, F20-gating, F26)

**Files:** Create `MacSearch/App/AppModel.swift`; test `MacSearchTests/AppModelTests.swift`.

**Interfaces:**
- **Consumes:** taken 3, 4, 5, 10 en 11.
- **Produces:**
```swift
enum Phase: Equatable { case idle, scanning, reviewing(incomplete: Bool), processing, done }
enum FormField { case source, destination, keywords }
enum ChangeResult { case applied, needsConfirmation, refused }
@MainActor @Observable final class AppModel {
    init(startup: StartupState,
         scanner: @escaping @Sendable (SearchContext) -> AsyncThrowingStream<ScanEvent, Error>,
         batch: @escaping @Sendable (HistoryStore) -> TransferBatch,
         checkDestination: @escaping @Sendable (URL) async -> Bool,          // productie: Task.detached { destinationUsable(url) }
         makeContext: @escaping @Sendable (URL, String, URL) async throws(SearchValidationError) -> SearchContext,   // productie: detached SearchContext.make
         loadHistory: @escaping @Sendable (HistoryStore) async -> [RunSummary]?,  // productie: detached try? recentRuns(limit: 50); nil = lezen mislukt
         now: @escaping @Sendable () -> Date = Date.init)
    private(set) var sourcePath: String?, destPath: String?, keywordsRaw: String
    private(set) var mode: TransferMode         // alleen via setMode
    private(set) var phase: Phase, results: [FoundFile], selected: Set<URL>, scanned: Int, skipped: Int
    private(set) var summary: BatchSummary?, startupError: (path: String, message: String)?, leftovers: [Leftover]
    private(set) var history: [RunSummary]      // uit StartupState; ververst als laatste stap van de batch-task, nog in processing
    private(set) var destinationOK: Bool        // false bij de start van een scan en na fatalCause == .destinationUnusable; gezet door checkDestination
    private(set) var processed: Int, total: Int // voortgang van de lopende batch (F18), via de progress-callback naar de main actor
    private(set) var containment: Containment   // van de laatste SearchContext (F27-waarschuwing)
    private(set) var message: String?           // validatiefout, scannerfout, fatalError van de batch of mislukte geschiedenis-verversing
    var canSearch: Bool { get }; var canConfirm: Bool { get }; var formEditable: Bool { get }; var modeEditable: Bool { get }
    func setField(_ field: FormField, _ value: String) -> ChangeResult   // zie de regels hieronder
    func confirmFormChange(_ field: FormField, _ value: String)  // na bevestiging: discardResults en dan wijzigen
    func setMode(_ mode: TransferMode)          // genegeerd als !modeEditable
    func toggle(_ url: URL); func selectAll(); func selectNone()
    @discardableResult func search() -> Task<Void, Never>?    // synchroon: guard, generatie, snapshot en scanning vóór elke await; nil als geweigerd
    @discardableResult func confirm() -> Task<Void, Never>?   // synchroon: guard, generatie, snapshot en processing vóór elke await; nil als geweigerd
    func cancelScan(); func stop()
    func discardResults()                       // reviewing → idle
    func requestHistory(_ run: RunSummary) -> ChangeResult
    func confirmHistory(_ run: RunSummary)           // na bevestiging: discardResults, formulier vullen, idle
    func acknowledgeLeftover(_ l: Leftover) async    // clearTempPath detached; daarna uit leftovers
    func closeSummary(); func dismissMessage()
}
```
`AppModel` krijgt de scanner, de batch-factory, `makeContext`, `checkDestination` en `loadHistory` geïnjecteerd, zodat het testbaar is. Tests wachten op de teruggegeven task-handles (`await task?.value`) in plaats van te pollen.

**Regel voor elke ingang die werk start (`search`, `confirm`):** de guard, de fase-overgang en de snapshot gebeuren synchroon, vóór de eerste `await`. De ingang bewaart de task-handle (`scanTask` of `batchTask`, gewist als de task eindigt) en geeft hem terug.

**Generatie:** `AppModel` houdt een teller `generation: Int` bij. `search()`, `confirm()`, `discardResults()`, `confirmFormChange`, `confirmHistory` en elke `.applied`-wijziging van `setField` of `requestHistory` verhogen hem. Elk async vervolg (de scan-task, de batch-task en de hercontrole van de bestemming) legt bij zijn start de generatie vast en schrijft na elke `await` alleen state als die nog gelijk is. Annuleren verhoogt de generatie niet, zodat een geannuleerde scan zijn gedeeltelijke resultaten nog afrondt (F0c).
- Niet aan de generatie gebonden zijn `history` (gedeelde databasestaat) en het resultaat van `acknowledgeLeftover`.
- Een progress-sprong schrijft `processed` alleen zolang `phase == .processing`.
- `setField` en `requestHistory` geven:
  - `.applied` in `idle`, in `done` (de fase wordt dan `idle` en `summary` vervalt) en in `reviewing` zonder resultaten (de fase wordt `idle`);
  - `.needsConfirmation` in `reviewing` met resultaten, zonder iets te wijzigen;
  - `.refused` in `scanning` en `processing`.
- `canSearch` is `startupError == nil`, `sourcePath` en `destPath` zijn gezet, en de fase is `idle` of `reviewing` ("Opnieuw zoeken" met een nieuwe context, F0b). In `done` gaat een wijziging eerst naar `idle`. Lege keywords geven via `makeContext` `.noKeywords`.
- `search()` is synchroon en doet, vóór enige `await`:
  1. de guard `canSearch`; anders `nil`;
  2. een snapshot van bron, keywords en bestemming;
  3. `phase = .scanning`, en `results`, `selected`, `scanned`, `skipped` en `message` leeg; `destinationOK = false`;
  4. een `Task` starten en de handle als `scanTask` bewaren; `cancelScan()` annuleert die.

  In de task:
  - wacht op `makeContext` met de snapshot. Een validatiefout wordt `message` en de fase wordt `idle`. Is de task intussen geannuleerd, dan start er geen scan en wordt de fase `idle`. Deze overgang `scanning → idle` is een bewuste aanvulling op de tabel van F0b: de validatie van F25 en F27 blokkeert Zoeken, alsof het niet gestart was;
  - streamt de scan;
  - alle drie de uitgangen van de scan (afgerond, geannuleerd, scannerfout) wachten op `checkDestination` en zetten daarna `reviewing(incomplete:)`. Zo blijft OK ook na Annuleren of een scannerfout bruikbaar (F0c);
  - `incomplete` en `scanComplete` volgen uit hoe de lus over de stream eindigde, niet uit `Task.isCancelled` op het eind. Omdat `next()` na annuleren gewoon `nil` geeft, zet `cancelScan()` een vlag `cancelRequested`, maar alleen zolang de lus nog loopt; de lus zet `streamFinished` bij het verlaten. Dan geldt `incomplete = cancelRequested || scannerfout`. Na `streamFinished` doet `cancelScan()` niets.
- Gestreamde treffers zijn standaard geselecteerd (F12).
- `canConfirm` is `phase == .reviewing`, `!selected.isEmpty` en `destinationOK` (F13, F26). De getter doet geen I/O.
- `confirm()` is synchroon en doet, vóór enige `await`:
  1. de guard `canConfirm`; anders `nil`;
  2. `confirmedAt = now()`;
  3. een snapshot: `mode`, `files = results.filter { selected.contains($0.url) }` (de volgorde van `results`), `results.count`, `scanComplete` en `skipped`; `scanComplete` is het gegeven dat de scan bewaarde (zie hierboven);
  4. een nieuwe `StopFlag`, die `stop()` gebruikt; `processed = 0` en `total = files.count`;
  5. `phase = .processing`.

  Daarna start het een `Task` die de batch draait met die snapshot, en bewaart de handle als `batchTask`. De batch controleert de bestemming zelf (taak 10 stap 0). Een tweede klik is daardoor onmogelijk, en wijzigingen na OK raken de run niet (F0d).
- De progress-callback springt naar de main actor en zet `processed = max(processed, p)`, zodat een late sprong de balk niet terugzet. Bij het publiceren van `done` zet de batch-task `processed` gezaghebbend op het aantal verwerkte bestanden: de som van `summary.counts`. Bij `completed` is dat `total`; na Stop of een afbreking is het kleiner. Een progress-sprong die pas daarna aankomt, wordt door de `processing`-guard genegeerd. Zo hangt de eindwaarde niet af van de volgorde waarin de sprongen worden afgeleverd.
- `fatalCause == .destinationUnusable` (taak 10 stap 0) → terug naar `reviewing(incomplete: !snapshot.scanComplete)` met de resultaten en selectie intact, `message` gezet en `destinationOK = false`; daarna opnieuw `checkDestination`, dat `destinationOK` alleen bijwerkt als de generatie nog gelijk is.
- `fatalCause == .runInsertFailed` (F19a) → terug naar `reviewing(incomplete: !snapshot.scanComplete)` met de resultaten en selectie intact en `message`; `destinationOK` blijft staan, zodat opnieuw OK kan.
- `fatalError` met `runId != nil` → `done` met `summary` en `message`.
- **Einde van de batch-task:** wanneer de batch `runId != nil` heeft, wacht de task nog in `processing` op `loadHistory`. Daarna publiceert hij `history`, `summary` en `done` samen, zonder `await` ertussen. Een formulierwijziging kan zo nooit de verversing van de net afgeronde run wegwerken. Geeft `loadHistory` `nil` (lezen mislukt), dan blijft de vorige `history` staan, krijgt `message` de waarschuwing "De geschiedenis kon niet worden ververst" (achter een eventuele `fatalError`-melding), en volgen `summary` en `done` gewoon.

- [ ] **Stap 1:** tests (AC4a):
  - `canConfirm` is `false` tijdens `scanning`;
  - een geannuleerde scan met ten minste één treffer en een bruikbare bestemming → `.reviewing(incomplete: true)` en `canConfirm` is `true`; de run krijgt `scanComplete == false`;
  - **atomair Zoeken:** een `makeContext` die op een barrière wacht. Intussen geeft een tweede `search()` `nil`, en geven `setField` en `requestHistory` `.refused`. Na het vrijgeven wordt de scanner-closure precies één keer aangeroepen (teller);
  - Annuleren terwijl `makeContext` wacht (de test wacht eerst op een signaal "makeContext bereikt") → de scanner-closure wordt niet aangeroepen en de fase is `idle`;
  - **late Annuleren:** de stream is normaal afgerond en `checkDestination` wacht op een barrière; `cancelScan()` dan → `.reviewing(incomplete: false)` en de run krijgt `scanComplete == true`;
  - **verlopen hercontrole:** OK geeft `.destinationUnusable` en de hercontrole van A wacht op een barrière met uitkomst `true`. Intussen wijzigt de gebruiker de bestemming en zoekt B, en `checkDestination` van B geeft `false`. Na het vrijgeven van A zijn `destinationOK` en `canConfirm` van B nog steeds `false`;
  - `discardResults` in `reviewing` → `idle` met lege resultaten;
  - `setMode` tijdens `processing` → `modeEditable == false` en `mode` is ongewijzigd;
  - `requestHistory` tijdens `scanning` of `processing` → `.refused` en niets gewijzigd;
  - `requestHistory` in `idle` → `.applied`: het vult bron, keywords, bestemming en modus en start niets. In `done` gebeurt hetzelfde: de fase wordt `idle` en `summary` is `nil`;
  - `requestHistory` in `reviewing` met resultaten → `.needsConfirmation`, en resultaten, selectie en formulier zijn ongewijzigd. Daarna `confirmHistory` → `idle`, lege resultaten en een gevuld formulier;
  - `requestHistory` en `setField` in `reviewing` zonder resultaten → `.applied` en `idle`;
  - `setField` in `done` → `.applied` en `idle`;
  - een `startupError` → `canSearch` en `canConfirm` zijn `false`;
  - `canConfirm` is `false` in `reviewing` met nul geselecteerde bestanden, en wordt `true` na `toggle`;
  - de bestemming wordt na de scan onbruikbaar → de batch geeft `fatalCause == .destinationUnusable` → `reviewing`, met resultaten en selectie intact en `message` gezet, en `canConfirm` is `false` zolang `checkDestination` `false` geeft. Er is geen `search_run`-rij;
  - `checkDestination` geeft `false` na de scan → `canConfirm` is `false`;
  - **atomair OK:** `confirm()` twee keer direct na elkaar → de tweede geeft `nil` en er is precies één `search_run`-rij;
  - **datum bij OK:** `now` geeft de vaste datum 2001-02-03 23:59:59 lokaal → de `dest_folder` van de rij eindigt op `2001-02-03`;
  - **voortgang (F18):** een batch met 3 bestanden waarvan een `FaultyFileOps`-hook bestand 2 vasthoudt. De test leest `processed` opnieuw op de main actor na elke `await Task.yield()`, tot `processed == 1` of een deadline van 2 s (dan faalt hij), en controleert `total == 3`; daarna geeft hij bestand 2 vrij. Na `done` is `processed == 3`;
  - `selectAll`, `selectNone` en `toggle` → `selected.count` klopt;
  - een scanner die gooit na één treffer → `.reviewing(incomplete: true)`, `message` is gezet en `canConfirm` is `true`;
  - **streaming (F9):** een gecontroleerde stream die open blijft na `found([a, b])` en `progress(scanned: 10, skipped: 1)`:
    - vóór het einde zijn `results.count == 2`, `selected.count == 2`, `scanned == 10` en `skipped == 1`, en `canConfirm` is `false`;
    - na `cancelScan()` → `.reviewing(incomplete: true)` met de 2 resultaten behouden;
  - opnieuw zoeken in `reviewing` → `scanning` met een nieuwe context, en de oude resultaten zijn weg;
  - `await acknowledgeLeftover` → de `temp_path` van het record is `NULL` (in een `HistoryStore.inMemory()`) en het item staat niet meer in `leftovers`;
  - `confirm()` → de `search_run`-rij in een `HistoryStore.inMemory()` bevat `found_count`, `selected_count`, `scan_complete` en `skipped_count` van de snapshot, en de `file_action`-rijen horen precies bij de geselecteerde bestanden;
  - een validatiefout `.sameFolder` → `message == "Kies een andere bestemming of een submap"` en de fase blijft `idle`;
  - `setField` in `reviewing` met resultaten → `.needsConfirmation` en geen wijziging; `confirmFormChange` → `idle`, lege resultaten en het veld gewijzigd;
  - `formEditable` is `false` tijdens `scanning` en `processing`;
  - een batch die eindigt → `done` met `summary`, en `history` is ververst via `loadHistory`;
  - **geschiedenis na de batch:** `loadHistory` signaleert "loadHistory bereikt" en wacht dan op een barrière. De test wacht eerst op dat signaal; daarna is de fase nog `processing` en geeft `setField` `.refused`. Na het vrijgeven is de fase `done` en bevat `history` de nieuwe run. Een `setField` direct daarna (`.applied`, `idle`) laat `history` ongemoeid;
  - **verversing mislukt:** `loadHistory` geeft `nil` → de fase is `done`, `summary` is gezet, `history` is gelijk aan de vorige lijst en `message` bevat "De geschiedenis kon niet worden ververst";
  - **voortgang na Stop:** een `FaultyFileOps`-hook houdt bestand 1 vast en signaleert dat. De test roept dan op de main actor `stop()` aan en geeft bestand 1 vrij, zonder op de UI-teller te wachten; de batch controleert Stop vóór bestand 2. Na `await task?.value` is de fase `done`, `processed == 1`, gelijk aan de som van `summary.counts`, en `total == 3`. Idem voor een afbreking: de resultaat-update van bestand 2 faalt → `processed` is gelijk aan de som van `summary.counts`;
  - een batch met `fatalError` en `runId != nil` → `done` en `message`;
  - een `search_run`-insert die faalt (`fatalCause == .runInsertFailed`) bij een bruikbare bestemming → `reviewing` met resultaten en selectie intact, `message`, en `canConfirm` blijft `true`. Variant na een geannuleerde scan: de fase is `.reviewing(incomplete: true)` en een tweede OK schrijft `scan_complete = 0`;
  - `canSearch` is `false` zolang bron of bestemming niet gezet is;
  - `closeSummary` → `idle`;
  - `containment` wordt `.destInsideSource` na een zoekactie met een bestemming binnen de bron.
- [ ] **Stap 2:** draai de tests. Verwacht: FAIL.
- [ ] **Stap 3:** implementeer volgens de tabel van F0b.
- [ ] **Stap 4:** draai de tests. Verwacht: PASS.
- [ ] **Stap 5:** commit "feat: app state model".

### Taak 13: UI voor de kernflow (F11–F13, F18–F22, F19d-melding)

**Files:**
- Create `MacSearch/UI/SidebarView.swift` (formulier en geschiedenis), `MacSearch/UI/ResultsSliderView.swift`, `MacSearch/UI/ProcessingView.swift`, `MacSearch/UI/LeftoversSheet.swift`.
- Modify `MacSearch/App/MacSearchApp.swift`.

**Interfaces:**
- **Consumes:** `AppModel`.
- **Produces:** geen.

Dit zijn de verplichte onderdelen:
- `NavigationSplitView`. Links staan bron en bestemming (via `NSOpenPanel`), het keywordveld, de toggle Kopiëren/Verplaatsen, Zoeken en de geschiedenislijst. Een onvolledige run is gemarkeerd.
- Rechts staat in increment 1 alleen de slider.
- De slider toont één item groot (`QLThumbnailGenerator`), met pijltjes links/rechts, een vinkje en "alles aan"/"alles uit". Bij een video staat er een knop **Afspelen** die het huidige item in Quick Look opent, zodat de video daar speelt (F11). Gebruik de SwiftUI-modifier `.quickLookPreview($previewURL)` op de slider, met `previewURL: URL?` als view-state die de knop zet. De spatiebalk-bediening van F24 blijft voor increment 2. De teller toont `geselecteerd / gevonden`. Bij een onvolledige scan staat er een banner. OK is actief volgens `canConfirm`.
- `ProcessingView` toont een voortgangsbalk op `processed / total` en Stop. De samenvatting toont de aantallen per resultaat en de waarschuwingen, met de knop "Toon in Finder" (`NSWorkspace.activateFileViewerSelecting`).
- Een blokkerende foutmelding met het databasepad, als `startupError` gezet is.
- `LeftoversSheet` opent één keer automatisch na de start als `leftovers` niet leeg is (F19d). Dat gebeurt via een vlag in de view-state, die niet van `leftovers` wordt afgeleid. De sheet heeft een knop **Sluiten** die niets afhandelt; de melding komt bij de volgende start terug. Wordt `leftovers` leeg (het laatste item is afgehandeld), dan sluit de sheet zichzelf. Per pad toont de sheet:
  - selecteerbare tekst;
  - de knop "Kopieer pad";
  - de knop "Toon in Finder";
  - de knop "Afgehandeld";
  - de tekst "Verborgen bestanden toont Finder pas na Cmd+Shift+.".
- Velden wijzigen via `setField`, en een geschiedenisklik gaat via `requestHistory`. Bij `.needsConfirmation` toont de UI een bevestigingsdialoog en roept bij Ja `confirmFormChange` of `confirmHistory` aan. Bij `.refused` gebeurt er niets.
- Tijdens `scanning`:
  - de teller `gevonden / doorzocht` en de resultaten, die al tijdens de scan in de slider verschijnen;
  - de knop **Annuleren**, gekoppeld aan `cancelScan`.
- De views gebruiken alleen de API van `AppModel`, en hebben geen eigen selectie- of geschiedenisstaat.
- `message` verschijnt als melding. Bij F27 is dat "Kies een andere bestemming of een submap".
- Een niet-blokkerende waarschuwing als `containment != .none` (F27).
- Het aantal overgeslagen items na de scan (F10).
- **Productiewiring in `MacSearchApp`:**
  - een laadscherm zolang `StartupRoutine.run` in `Task.detached` draait;
  - daarna `AppModel(startup:scanner:batch:checkDestination:makeContext:loadHistory:)` met:
    - `MediaScanner().scan`;
    - `{ store in TransferBatch(store: store, ops: PosixFileOps(), uuids: SystemUUIDSource()) }`;
    - en voor `checkDestination`, `makeContext` en `loadHistory` elk een closure die het werk in `Task.detached` doet. Voor `makeContext` geeft de detached task een expliciet getypeerde `Result` terug: `let r: Result<SearchContext, SearchValidationError> = await Task.detached { Result { () throws(SearchValidationError) in try SearchContext.make(...) } }.value`, en de closure doet `try r.get()`; zo blijft de typed throw behouden.
  - `loadHistory` doet in `Task.detached` `try? store.recentRuns(limit: 50)`; een leesfout wordt `nil`.
  - `acknowledgeLeftover` roept `clearTempPath` aan in `Task.detached`.
  - NF1 wordt in de app bewezen door deze wiring en de rooktest hieronder: het venster blijft reageren tijdens scan en batch.

- [ ] **Stap 1:** bouw de views.
- [ ] **Stap 2:** `xcodebuild -scheme MacSearch build`. Verwacht: `BUILD SUCCEEDED`.
- [ ] **Stap 3:** handmatige rooktest:
  - de app starten, een tijdelijke map met drie matchende JPG's doorzoeken, één bestand uitvinken en kopiëren. De samenvatting toont 2× `copied`, en de geschiedenis toont de run;
  - een map met duizenden bestanden doorzoeken en halverwege Annuleren. De teller liep op tijdens de scan, en de slider toont de gedeeltelijke resultaten met de banner "onvolledig";
  - een batch van 50 bestanden kopiëren. De voortgangsbalk loopt zichtbaar op, en het venster blijft reageren;
  - een echte `.mov` vinden en in de slider op **Afspelen** klikken. Quick Look opent en speelt de video;
  - de app stoppen, met `sqlite3` een run met status `interrupted` en een `file_action` toevoegen waarvan `temp_path` naar een bestaand bestand wijst, en de app starten. De melding opent automatisch. Na **Sluiten** en een herstart verschijnt hij opnieuw; na "Afgehandeld" sluit de sheet zichzelf, en na een herstart blijft hij weg.
- [ ] **Stap 4:** commit "feat: core UI flow".

### Taak 14: Proeven op de echte Mac (AC5, AC6, AC7)

**Files:** Create `docs/runbooks/increment-1-handmatige-proef.md`, met de resultaten.

- [ ] **Stap 1:** AC6: `xcodebuild -scheme MacSearch -configuration Release clean build 2>&1 | tee release.log; grep 'warning:' release.log | grep -c '/MacSearch/'`. Verwacht: `BUILD SUCCEEDED` en `0`.
- [ ] **Stap 2:** AC5 met een bron onder `~/Desktop` of `~/Documents`. De TCC-vraag verschijnt en JP verleent die. Zoek op `janpeter visser`, vink twee bestanden uit en kopieer. Controleer de doelmap, de geschiedenis en dat een klik het formulier vult. Een geweigerde toestemming geeft een run die als onvolledig is gemarkeerd.
- [ ] **Stap 3:** AC7 met `hdiutil create -size 200m -fs APFS -volname MSAPFS apfs.dmg` en `hdiutil create -size 200m -fs ExFAT -volname MSEXFAT exfat.dmg`. Koppel ze met `hdiutil attach` en ontkoppel ze na afloop met `hdiutil detach`.
  - Verplaats één bestand naar elk volume.
  - Op exFAT gebruik je het keyword `test?map`, wat de map `test-map` geeft.
  - Controleer per volume: het doel is compleet, de bron is weg, er staan geen `.macsearch-*.tmp`-bestanden, de status is `completed` en de volgende start toont geen melding.
  - Noteer of er `._*`-bestanden ontstaan.
- [ ] **Stap 4:** commit het runbook met de resultaten en push.

---

## Increment 2 (alleen de richting; wordt pas na increment 1 gedetailleerd)
- Het rechterpaneel met de weergaven Bron, Bestemming en Resultaten (F23), met breadcrumb-navigatie.
- Quick Look met de spatiebalk en openen met een dubbelklik (F24).
- Drag-and-drop van mappen (F22).
- Een filmstrip met thumbnailcache (F11).
- De markering van ontbrekende mappen in de geschiedenis (F21).
