# Fallakte: Teltow / B-Plan / Grundstücksfläche / hohe GFZ

Stand: 2026-08-09

## Ziel

Später weiterverfolgen: Grundstücke im Berliner Umland finden, bevorzugt etwa 800–1.200 m², mit Bebauungsplan-Festsetzung GFZ > 1,0. Parallel prüfen: amtliche Grundstücksfläche (ALKIS), konkrete B-Plan-Zuordnung, GRZ/GFZ, planungsrechtliche Teilfläche und möglicher Eigentümerzugang über amtliche Nachweise.

## Wichtige Grundregel für SIS

Nicht aus einer Adresse oder bloßen Nähe zum B-Plan auf GRZ/GFZ schließen. Immer räumlich prüfen:

1. Adresse exakt geokodieren.
2. Adresse einem ALKIS-Flurstück zuordnen.
3. Amtliche Grundstücksfläche aus ALKIS lesen.
4. B-Plan-Geometrie/WFS mit dem Flurstück schneiden.
5. Nur die tatsächlich überlagernde Festsetzungsfläche auswerten.
6. GRZ/GFZ nicht auf das Gesamtflurstück anwenden, wenn nur eine Teilfläche betroffen ist.

## Testfall Mahlower Straße 150, 14513 Teltow

Amtliche Adress-/ALKIS-Zuordnung:

- Adresse: Mahlower Straße 150, 14513 Teltow
- Koordinate: ca. 13.2837683292 / 52.3947655210
- Gemarkung: Teltow
- Flur: 012
- Flurstück: 6
- Flurstückskennzeichen: 12386201200006______
- amtliche Fläche: 9.013 m²

Die Fläche wurde zusätzlich durch Orthofoto/Geometrie auf Plausibilität geprüft. Die rechtlich maßgebliche Fläche bleibt der ALKIS-Wert.

B-Plan B-27a "Komponistenviertel":

- WFS/WMS: https://www.geoportal-teltow.de/isk/telt_bp23
- WFS 1.1.0
- `ms:bp_baugebietsteilflaeche`
- In der Nähe existiert WA1 mit GRZ 0,20 / GFZ 0,45.
- Frühere Annahme "Mahlower Straße 150 = WA1" wurde korrigiert: Die abgefragte WA1-Geometrie überschneidet das 9.013-m²-Flurstück nicht.
- Daher für Flurstück 6 GRZ 0,20 / GFZ 0,45 NICHT als bestätigt behandeln.
- Wahrscheinlich ist eine andere Festsetzungsart relevant (z. B. Gemeinbedarf/kirchliche Nutzung). Bei Wiederaufnahme alle B-Plan-Featuretypen prüfen, nicht nur `BP_BaugebietsTeilFlaeche`.

## Suche nach ca. 1.000 m² und GFZ > 1

Untersuchter Kandidat: Teltow B-Plan 8 / Dienst `telt_bp61`.

Gefundene hoch verdichtete Teilfläche:

- GFZ: 1,2
- GRZ: 0,4
- ungefähre BBox: 13.255886, 52.401955 bis 13.256484, 52.402471

ALKIS-Flurstücke in dieser BBox:

| Fläche | Lage | Flurstück | Flur |
|---:|---|---|---|
| 108 m² | Potsdamer Straße 38 D | 182 | 018 |
| 350 m² | Striewitzweg | 59/4 | 018 |
| 406 m² | Striewitzweg | 55/3 | 018 |
| 477 m² | Potsdamer Straße 38 E | 183 | 018 |
| 523 m² | Potsdamer Straße 38 D | 187 | 018 |
| 704 m² | Potsdamer Straße 44 | 52 | 018 |
| 1.639 m² | Potsdamer Straße 42 | 53 | 018 |
| 1.691 m² | Striewitzweg 1 E | 54/5 | 018 |
| 5.222 m² | Alte Potsdamer Straße / Potsdamer Straße | 89 | 018 |

Im Bereich gab es keinen Treffer zwischen 800 und 1.200 m². Nächste interessante Kandidaten:

- Potsdamer Straße 44 / Flurstück 52 / 704 m²
- Potsdamer Straße 42 / Flurstück 53 / 1.639 m²
- Striewitzweg 1 E / Flurstück 54/5 / 1.691 m²

WICHTIG: Diese neun Flurstücke wurden zunächst über die Bounding Box der GFZ-1,2-Fläche gefunden. Vor einer belastbaren Aussage pro Grundstück muss die exakte Polygonüberschneidung zwischen ALKIS-Flurstück und GFZ-1,2-Festsetzungsfläche berechnet werden.

## Eigentümerdaten

Eigentümernamen sind nicht Bestandteil der frei zugänglichen offenen ALKIS-Schnittstelle/BrandenburgViewer-Ausgabe.

Offizieller Weg in Brandenburg:

- Flurstücks- und Eigentümernachweis bei der zuständigen Katasterbehörde, hier Landkreis Potsdam-Mittelmark.
- Alternativ Bestellung über DAKAPO der LGB Brandenburg.
- Für Eigentümerdaten ist ein berechtigtes Interesse darzulegen; die Behörde entscheidet über die Herausgabe.
- Grundbuchauszug ist ebenfalls möglich, aber für die Einsicht gilt § 12 GBO und ebenfalls ein berechtigtes Interesse.

SIS sollte daher Eigentümernamen nicht automatisiert aus offenen Karten ableiten. Sinnvoll automatisierbar sind dagegen:

- Flurstückskennzeichen
- Gemarkung / Flur / Flurstück
- Grundstücksfläche
- B-Plan / Festsetzungsfläche / GRZ / GFZ
- vorbereitete Antragsdaten für einen amtlichen Eigentümernachweis

## Bereits angelegte technische Arbeit

Repository: `sisplatformautomation-commits/sis-platform`

Branch: `feature/brandenburg-bplan`

PR: #1 "Add BrandenburgVIEWER B-Plan connector with GRZ/GFZ extraction"

Relevante Dateien/Workflows:

- `src/brandenburg/teltow-b27a.js`
- `.github/workflows/live-parcel-lookup.yml`
- `.github/workflows/bplan-intersection.yml`
- `.github/workflows/scan-high-gfz-parcels.yml`
- `.github/workflows/list-bplan8-parcel-areas.yml`

## Nächste Schritte bei Wiederaufnahme

1. Für die 704-m²-, 1.639-m²- und 1.691-m²-Kandidaten exakte Polygon-Intersection mit der GFZ-1,2-Fläche berechnen.
2. Weitere Teltower Pläne mit GFZ > 1 scannen, insbesondere B-Plan 1A.
3. Danach Kleinmachnow und Potsdam mit gleichem Filter durchsuchen.
4. Filter nicht starr 800–1.200 m² lassen; zusätzlich z. B. 600–1.800 m² priorisieren und nach Nähe zu 1.000 m² sortieren.
5. Pro Treffer Adresse, ALKIS-Fläche, B-Plan-Teilfläche, GRZ, GFZ, Vollgeschosse und Nutzungsart zusammenführen.
6. Für besonders interessante Grundstücke amtlichen Eigentümernachweis vorbereiten, aber Eigentümerdaten nicht aus offenen Quellen erfinden oder ableiten.

## Wiederaufnahme-Stichwort

Wenn das Thema später wieder aufgenommen wird: **"Teltow GFZ > 1 Grundstückssuche"**.
