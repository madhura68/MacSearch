# Increment 1: handmatige proef op de echte Mac (AC5, AC6, AC7)

Taak 14 van PLANS/idea-263-plan r9. Spec: SPECS/idea-263-spec r8, §7.

| AC | Status | Uitgevoerd door |
|---|---|---|
| AC6 Release zonder waarschuwingen | PASS (2026-10-16) | agent |
| AC7 verplaatsen naar APFS- en exFAT-dmg | PASS (2026-10-16) | agent |
| AC5 echte Mac, inclusief TCC | PASS met afwijking (2026-10-16), zie hieronder | JP |

## AC6: Release bouwt zonder waarschuwingen

```bash
xcodegen generate
xcodebuild -scheme MacSearch -configuration Release clean build 2>&1 | tee release.log
grep 'warning:' release.log | grep -c '/MacSearch/'
```

Resultaat: `BUILD SUCCEEDED` en `0`. De enige `warning:`-regel in de log komt van Xcode's
`appintentsmetadataprocessor` ("Metadata extraction skipped, no AppIntents.framework dependency
found") en niet uit de code van MacSearch.

## AC7: verplaatsen naar een APFS- en een exFAT-dmg

```bash
hdiutil create -size 200m -fs APFS -volname MSAPFS apfs.dmg
hdiutil create -size 200m -fs ExFAT -volname MSEXFAT exfat.dmg
hdiutil attach apfs.dmg -nobrowse
hdiutil attach exfat.dmg -nobrowse
# na afloop
hdiutil detach /Volumes/MSAPFS
hdiutil detach /Volumes/MSEXFAT
```

Opzet:
- De Debug-build van commit 9a3418b, met een losse database via `CFFIXED_USER_HOME`.
- Per volume één bronbestand van 3 MB op de interne schijf: `jan apfs.jpg` (keyword `jan`) en
  `test map foto.jpg` (keyword `test?map`).
- Bron en bestemming kwamen uit een geseede geschiedenisrij: de agent bedient het NSOpenPanel
  niet. Vanaf de klik op de rij liep alles door de app: Zoeken, OK verplaatsen, samenvatting.

Resultaat per volume:

| Controle | MSAPFS | MSEXFAT |
|---|---|---|
| Doelmap | `jan/2026-10-16/` | `test-map/2026-10-16/` (`?` werd `-`) |
| Doel compleet (sha256 gelijk aan de bron) | ja | ja |
| Bron weg | ja | ja |
| `.macsearch-*.tmp` op het volume | geen | geen |
| `file_action` | `moved`, `temp_path` NULL | `moved`, `temp_path` NULL |
| Run-status | `completed` | `completed` |
| Volgende start | geen restantenmelding | geen restantenmelding |
| `._*`-bestanden | geen | ja: `._test-map`, `._2026-10-16`, `._test map foto.jpg` |

De `._*`-bestanden op exFAT zijn AppleDouble-bestanden van macOS zelf: exFAT kent geen
extended attributes, en het bestand draagt `com.apple.provenance`. MacSearch maakt ze niet aan.

## AC5: proef van JP op de echte Mac

### Resultaat (2026-10-16)

JP draaide de app op de echte Mac met de echte database. Daarin staat één run (run 1):
- een bron op het netwerkvolume `/Volumes/Public` en een bestemming op hetzelfde volume, allebei
  gekozen met **Kies…**. Zonder eerdere geschiedenis kan een map alleen via het NSOpenPanel in
  het formulier komen;
- een eigen keyword van JP; modus kopiëren;
- 2 gevonden, 2 geselecteerd, `scan_complete = 1`;
- 2× `copied` in `<bestemming>/<keyword>/2026-10-16/`, `temp_path` leeg, status `completed`.

**Afwijking, door JP besloten op 2026-10-16:** deze netwerkvolume-run telt als AC5. Wat het
protocol hieronder anders vraagt:

| Protocol | Uitgevoerd | Gevolg |
|---|---|---|
| Bron onder `~/Desktop` of `~/Documents`, met de TCC-vraag | Bron op het netwerkvolume | TCC voor Desktop/Documents valt buiten AC5 |
| Geweigerde toestemming geeft een run die als onvolledig is gemarkeerd | Niet uitgevoerd | Valt buiten AC5 |
| Keyword `janpeter visser` | Een eigen keyword van JP | Geen |
| Twee bestanden uitvinken | 2 van 2 geselecteerd | Uitvinken is bewezen in de rooktest van taak 13 |
| Een klik op de geschiedenisrij vult het formulier | Niet apart gemeld | Bewezen in de rooktest van taak 13 en bij AC7 |

Volgens JP zijn ook Quick Look-playback, **Kopieer pad** en **Toon in Finder** geprobeerd. Een
uitkomst per knop is niet doorgegeven en staat dus niet in dit runbook.

### Protocol uit het plan

Start de Release-build zelf vanuit Finder of met `open`, zodat MacSearch zelf de TCC-vraag stelt:

```bash
xcodebuild -scheme MacSearch -configuration Release -derivedDataPath build build
open build/Build/Products/Release/MacSearch.app
```

De app gebruikt dan de echte database:
`~/Library/Application Support/MacSearch/macsearch.sqlite`.

Stappen (plan, taak 14, stap 2):
1. Kies met **Kies…** een bron onder `~/Desktop` of `~/Documents` met bestanden waarvan de naam
   `janpeter visser` bevat. De TCC-vraag verschijnt; verleen toegang.
2. Kies met **Kies…** een bestemming, zoek op `janpeter visser`, vink twee bestanden uit en
   kopieer.
3. Controleer de doelmap `<bestemming>/janpeter visser/<datum>/`, de nieuwe geschiedenisrij, en dat
   een klik op die rij het formulier vult.
4. Geweigerde toestemming: zet de toestemming terug met
   `tccutil reset SystemPolicyDesktopFolder nl.jp-visser.MacSearch` (of `...DocumentsFolder`),
   start de app opnieuw, weiger de vraag en zoek opnieuw. De run hoort als onvolledig gemarkeerd
   te zijn.

Wat de agent niet kon bedienen (graag meenemen in dezelfde proef):
- **Kies…** opent het NSOpenPanel, en de gekozen map komt in het formulier.
- **Afspelen** bij een `.mov`: het Quick Look-paneel opende in de rooktest; of de video afspeelt,
  is niet waargenomen.
- In de restantenmelding: **Kopieer pad** zet het pad op het klembord, en **Toon in Finder**
  selecteert het bestand. Sluiten en Afgehandeld zijn al wel getest.

## Rooktest van taak 13 (ter referentie)

Geslaagd in de Debug-build met een losse database:
- 3 JPG's, 1 uitgevinkt → 2× `copied` en een nieuwe geschiedenisrij;
- Annuleren halverwege een grote map → gedeeltelijke resultaten en de banner "Onvolledig";
- 50 × 60 MB kopiëren → zichtbare voortgang, en het venster bleef reageren;
- een geseed restant → de melding opent zelf. Sluiten laat hem bij de volgende start terugkomen.
  Afgehandeld sluit de sheet, het `.tmp`-bestand blijft staan, en na een herstart blijft de
  melding weg;
- de bevestigingsdialoog bij een geschiedenisklik tijdens het beoordelen: Annuleren behoudt de
  resultaten, Verwerpen laadt de run.
