# data-tiles

Vector tiles (PMTiles) for the Sustainable FSA maps. Everything here is
projected into the dummy-Albers space the LFP Explorer renders in; that
transform lives in exactly one place, `R/dummy-space.R`, because two
implementations that drift misregister layers by up to 765 m with nothing on
screen to show it.

```
counties.R            FSA county tiles (dd17/dd22) + composite
census.R              vintage-matched Census county tiles, 18 vintages
fsa-lfp-counties.R    the NDMC/FSA LFP determination boundaries
usdm.R                the weekly USDM, 1,390 weeks of TopoJSON
R/dummy-space.R       the AlbersUSA shift and dummy-space transform
R/outline.R           the dissolved national outline and its pinhole guard
R/publish.R           the artifact classes and the ONLY copy of the cache policy
R/s3-archive.R        vendored shared S3 helpers
tools/                the four gates
build/  tiles/        intermediates and PMTiles output
```

`VINTAGES=2020 PUBLISH=0 Rscript census.R` narrows a run.

## Three county authorities, and why they are not interchangeable

The archives disagree about where counties are, and the disagreement is the
point: each dataset's statistics were computed against its own polygons, so a
choropleth has to be drawn on the polygons its numbers came from.

| script | tiles | source | clipped to a waterline? |
|---|---|---|---|
| `counties.R` | `fsa-counties-dd17`, `-dd22` | FSA county composite | **here**, cb 5m/500k 2024, pinned |
| `census.R` | `census-counties-<year>` × 18 | `census-counties` `data/clipped/` | **upstream**, each vintage's own cb |
| `fsa-lfp-counties.R` | `fsa-lfp-counties` | `fsa-lfp-counties` (FOIA) | **not at all** — see below |

All three now publish the same shape: a `counties` layer and a `states`
innerlines layer inside the PMTiles, an `-index.json` sidecar and an
`-outline-dummy.geojson`. Every one lands in `sfsa-albers-usa/1`, drops the same
six territory FIPS, and carries `id` / `state` / `county` string properties.

The census sidecars carry two fields the others do not: `vintage`, the boundary
year as a string, and **`mask_year`, the coastline the geometry was actually cut
at** — not always the vintage, and the app has no other way to know it. Both are
additive to `sfsa-county-index/1`.

## census.R: repointed 2026-08-22, builds all 18 vintages

It used to read `usdm-counties/data/census/parquet/`, which was retired when the
boundaries moved to
[`census-counties`](https://github.com/sustainable-fsa/census-counties) and now
404s. It reads `census-counties/data/clipped/<year>-counties.parquet` — already
clipped to that vintage's own `cb` 500k waterline — so the whole clip stage went
away with the URL: `MASK_FALLBACK`, `mask_for()`, the `st_intersection()`, the
`st_collection_extract()` guard, the dissolve by `id`, and the `st_make_valid()`
calls around all of it. Read, filter, project.

Four things that were load-bearing on the way, all of them now gates:

1. **There is no `State` column.** `census-counties` publishes the Census schema
   — `STATEFP, COUNTYFP, County, CountyLSAD, year, mask_year, Area`. The old
   source carried a state name only because `usdm-counties` joined one before
   republishing. Joined here from `tigris::states(cb = TRUE)`, the way
   `usdm-counties.R` and `usdm-counties-census-2020.R` do, but **pinned** to
   `STATE_NAME_YEAR` — an unpinned tigris call floats with the package release
   and nothing in this repo floats. `anyNA(state)` stops the build.
2. **`mask_year` is per county, not per vintage.** On 2009 and 2011 the clipped
   form carries two values — 3,221 rows at `cb` 2010 and 13 at `cb` 2013,
   because `cb` 2010 has no American Samoa, Guam, Northern Marianas or US Virgin
   Islands. The territory filter drops all 13, so `unique()` after filtering is
   single-valued — and that is asserted rather than assumed, because the value
   goes into the tileset description. Taken from the data, never from a fallback
   table this repo would have to keep in step with `census-counties`'.
3. **`st_cast("MULTIPOLYGON")` after the shift is not tidiness.**
   `albers_usa_shift()` clips Hawaii to the frozen inset bbox, which drops
   Hawaii and Kalawao counties to `POLYGON` while the other 3,219 stay
   `MULTIPOLYGON`, and `st_make_valid()` then returns the simplest type for
   every one of them. A mixed column is an `sfc_GEOMETRY` and
   `st_coordinates()` has no method for it — which is exactly how the first run
   after the repoint died, *after* writing a correct 192 MB GeoJSONL.
4. **CRS is EPSG:4269**, so `st_transform(4326)` stays. The clipped form is
   MULTIPOLYGON throughout and valid under both s2 and GEOS, asserted upstream.

The territory filter (`60, 78, 14, 52, 69, 66`) stays: the archive carries those
counties and dummy-Albers only places CONUS, AK, HI and PR.

**The source is cached under `build/census/`.** A clipped vintage is ~46 MB and
there are eighteen; without the cache a rebuild pulls 830 MB from the CDN every
run. `CLIPPED_<year>` overrides one vintage and is used in place if it names a
local file.

Measured, full run of all 18 (2026-08-22): 3,219–3,222 counties per vintage,
7.33–8.31 M vertices, 61.2–64.4 MB of PMTiles each, ~90 s each after the fetch;
1.2 GB in total. Counties climb 3,219 (2000) → 3,222 (2022–2025) and vertices
climb monotonically after 2012, which is TIGER getting finer, not a bug. The
mask year equals the vintage from 2013 on; 2000/2009/2010/2011 report cb 2010
and 2012 reports cb 2013, exactly the fallback table that used to live here.

**Do not edit these scripts while they are running.** `Rscript` parses lazily,
expression by expression, so a mid-run edit shifts the offsets under it: an
otherwise clean 18-vintage run ended in `unexpected ')'` inside the publish
block it had not reached yet. The tiles were unaffected — `build_vintage()` was
already parsed — and rebuilding 2020 afterwards reproduced the batch's PMTiles
byte for byte, which is how that was established rather than assumed.

## fsa-lfp-counties.R: no clip, and it is not edge-matched

The FOIA'd NDMC geodatabase — the boundaries FSA's LFP determinations are
actually computed against — arrives **already in ESRI:102003 at true position**,
which is precisely what `albers_usa_shift()` wants as input. Label the WKB with
that CRS rather than transforming into it.

**It is not clipped, deliberately.** Measured against a dissolved `cb` 2024 500k
mask: intersecting would remove 0.109% of total area (9,323,313 → 9,313,178
km²), lose no county, and touch more than 1% of only 99 of 3,221 — bay and
estuary detail where two cartographies disagree, not overhang. MI + WI + MN sum
to 514,338 km² against 492,935 km² of Census land area, so the Great Lakes are
already cut. Clipping anyway would draw the determination on a shape whose
statistics were computed against a different one.

**It is not edge-matched.** Unioning the 3,221 counties leaves 491 pinholes
where neighbours fail to meet: 0.2 km² in total, median 0.06 m², largest 0.19
km², none of them a lake. They stay in the counties layer, because they are in
the record. The published outline drops them with the guard idiom
`census-counties` uses (`fill_holes`, keep-and-announce above 1 km²), because
that file exists to clip the USDM and every pinhole in it becomes a pinhole in
the drought layer.

Two more things worth not rediscovering:

- **`CountyName` is the LSAD form** — "Autauga County", "Bethel Census Area",
  "Adjuntas Municipio" — unlike the bare `County` in the Census and FSA
  tilesets. Carried verbatim: it is the label the determination records carry,
  and stripping the suffix by rule turns "Carson City" into "Carson" and
  "District of Columbia" into "District of".
- **It is coarse where the others are fine, and fine where they are coarse.**
  919 K vertices against ~7.6 M for a Census vintage, but 2,834 coastal parts
  against dd17's 1,351, because dd17's coast is `cb` 500k and this one is the
  NDMC's own. 37.2 MB of PMTiles.

## usdm.R: TopoJSON, not PMTiles, and the measurement that decided it

Tiling won for the counties because the source is ~7.6 M vertices — no single
file could be both full resolution and fetchable. A USDM week is **five features
and 100–266 K vertices** of ~1:2,000,000 data, so there is nothing to simplify
and tiling only pays the overhead of replicating boundary geometry into every
tile it crosses at every zoom. Measured on the worst week (2025-09-16), all
through this same transform:

| format | gzipped |
|---|---|
| PMTiles z0–15 | 10.02 MB |
| FlatGeobuf | 3.39 MB |
| GeoJSON 9 dp | 2.43 MB |
| GeoJSON 6 dp | 1.59 MB |
| **TopoJSON q=1e6** | **0.61 MB** |

FlatGeobuf loses on its own terms: float64 coordinates are high-entropy so gzip
takes 17% off it against 68% off text, and its spatial index is dead weight when
every request wants the whole national extent. Decode cost — the thing that
decides whether scrubbing janks — is a wash: `JSON.parse` 30.5 ms for GeoJSON
against `JSON.parse` + `topojson.feature()` 31.1 ms, the ~1.4 ms of arc
stitching offset by parsing less text. **q=1e6** is a 4.6 × 3.1 m grid retaining
99.75% of vertices; 1e5 (46 m, 92.1%) and 1e4 (461 m, 50.1%) are simplification
wearing an encoding's clothes.

Published **unclipped**: the app switches between four county authorities and a
baked-in coastline would mismatch three of them. The overspill is masked
client-side with the inverse of whichever `-outline-dummy.geojson` is active —
**which is app work that does not exist yet.**

### The classifier bug it had to fix first

`albers_usa_shift(state_fips = NULL)` classified by strict bbox containment and
fell through to `"00"` — CONUS, unshifted. The frozen bboxes are the extent of
the **counties**, and the USDM does not stop where counties do:

- **0.85 km² north-west of Kauai, 226 m outside `hi_bbox`** (2005, 2010, 2013).
  Left at true position `x = -6.27e6`, which is dummy x ≈ −10.9.
- 13.13 km² near Point Roberts, 4,831 m above `conus_bbox` — genuinely CONUS, so
  the fall-through was right there by luck.

`classify_regions()` now pads by 25 km (the regions are 536–783 km apart, so
they stay disjoint) and **hard-errors on anything unplaceable**. The Hawaii clip
inside the shift is deliberately *not* padded — it would change four published
county tilesets — so that Kauai polygon is classified HI and then clipped away,
which is right (it is over open ocean) and is caught by the per-region area gate
rather than being silent.

### Three things that cost a cycle each

- **`parallel::mclapply` cannot be used here.** It forks, and a forked child
  that touches Objective-C runtime initialisation aborts on macOS — `sf` pulls
  in GDAL which pulls in the system frameworks. Every worker died before doing
  any work. `mirai` daemons are separate processes; they also match the rest of
  the project, and `everywhere()` has to push the libraries, the working
  directory and the config across because daemons start empty.
- **The vertex-retention gate cannot read the arcs.** Gating on the arcs' own
  point count needs no decode, but the deficit scales with RING COUNT — TopoJSON
  drops each ring's closing point and dedups shared endpoints — so across seven
  weeks the ratio swings 0.938–0.976 and a 0.95 floor rejected a perfect week.
  Round-tripping back through mapshaper is the only honest measure: 0.995–1.000.
- **`sub("^USDM_|\\.topojson$", "", x)` is an alternation and replaces only the
  FIRST match**, so it stripped the prefix and left the extension. It was in the
  incremental-skip path, where it would have corrupted every date on a
  publishing run. `date_of()` does it in two subs.

Topology building is left ON, measured rather than assumed: round-tripped
vertices are identical with and without it (the loss is quantisation either way)
and it is 5% smaller. Flags otherwise match `fsa-counties-dd22.R:156-166`,
including `fix-geometry` — quantisation is a snap, and a snap can push a ring
into itself.

## Do not build a clip mask with ms_explode + ms_dissolve

`counties.R:75` builds its `cb` 5m mask with `st_union() |> st_make_valid()`,
which is correct — leave it. The idiom to avoid is the `rmapshaper::ms_explode()
|> ms_dissolve()` one that `fsa-counties-dd17`/`dd22` use (~line 109 in each).

Measured on `cb` 2010 while fixing `census-counties`: Census publishes 3,221
features with zero s2-invalid, and mapshaper snapped 2,588 points on import and
returned an **s2-invalid** outline in 2,430 disconnected pieces (the US has
~520) carrying 1,935 degenerate holes. Clipping against it put self-intersecting
rings into 123 of 3,219 counties, including landlocked ones the clip should
never have touched.

It stays invisible here because this repo runs `sf_use_s2(FALSE)` (line 40) and
never asks s2 anything — but the spurious pieces and pinholes are real in planar
geometry too.

## Gates

```sh
Rscript tools/check-registration.R                                # G4
TILESET=fsa-lfp-counties      Rscript tools/check-coverage.R
TILESET=census-counties-2020  Rscript tools/check-coverage.R
Rscript tools/check-coverage.R                                    # dd22, default
```

`check-coverage.R` takes `TILESET` (the PMTiles basename) as well as the
original `VINTAGE`. The **source wins wherever there is a rule for it**: for
`census-counties-<year>` the gate re-derives the ids from the cached clipped
parquet and re-applies the territory filter itself, rather than reading them out
of the sidecar. A gate that trusts the build's own bookkeeping cannot catch the
build losing a county before tippecanoe ever saw it. Everything else falls back
to `tiles/<TILESET>-index.json`.

**Where both exist they are compared, and a disagreement is a failure.** That
check is the only thing standing behind the sidecars — without it, publishing an
index for a tileset that already had a source rule would silently demote this
gate from "the tiles match the archive" to "the tiles match what the build said
it wrote".

## Open threads

1. **Published 2026-08-22** to `s3://sustainable-fsa/data-tiles/tiles/`, 63
   objects / 1.39 GB, verified over the CDN: correct content types, HTTP 206 on
   a range request, and no `Content-Encoding` on the PMTiles (which would break
   Range semantics — the header records `tile_compression = gzip` and the client
   shim decompresses).

   The bytes uploaded were the audited ones, not a re-derivation. A rebuild
   reproduces them — census 2009 and 2020 were checked byte for byte — but
   nothing had gated a fresh build.

   The three scripts now end the way every sibling archive does, with
   `s3_write_manifest()` + `cf_invalidate()`. None of them did, so the first
   publish went up unlisted and `_manifest.txt` had to be written by hand. The
   invalidation uses `/<prefix>/tiles/*`, which counts as a single path.
2. **`counties.R` still inlines a bare `st_union()` for its outline** where
   `census.R` and `fsa-lfp-counties.R` now call `dissolve_outline()`. dd17/dd22
   happen to carry no pinholes, so the two agree by luck rather than by
   construction — adopt the helper the next time those are rebuilt.
3. **`setup-geospatial` already provides mapshaper and tippecanoe.** The
   workflow only re-pins mapshaper to 0.6.113, the version usdm.R's retention
   gate was calibrated against; the shared action installs it unpinned. That pin
   is what makes a CI build byte-identical to a local one — verified end to end
   by deleting a published week and letting the workflow rebuild it: same
   sha256, `4a4b96c7`.
4. **The weekly cron runs `usdm.R` and `census.R`.** Both discover their inputs
   from the upstream manifest and skip whatever the bucket already holds, so a
   quiet week costs two list calls. `census.R` only does work in the year Census
   posts a new vintage, and now notices that on its own rather than waiting for
   someone to edit a hardcoded list.

   `counties.R` and `fsa-lfp-counties.R` are **not** scheduled and still rebuild
   unconditionally; their sources are frozen archives. A push that edits
   `R/dummy-space.R` therefore does NOT re-tile them — the transform gates run,
   but re-tiling stays a manual call, which is deliberate: a 1.4 GB republish
   should not be a side effect of a commit.
5. **Nothing masks the USDM overspill yet.** It is published unclipped by
   design, so until `lfp-explorer` draws the inverse of the active outline above
   it, the overlay shows the USDM's own ~1:2M coastline running past the
   counties.
6. **The cache policy is `public, max-age=3600`, and it used to be
   `immutable`.** Fixed 2026-08-22; the reasoning lives in `R/publish.R`'s
   header. Short version: `immutable` under a filename that is stable across
   rebuilds is a contradiction, those exact keys were republished twice in one
   session, and an edge invalidation does not reach a browser that already holds
   a file it was told would never change. If real immutability is ever wanted,
   it has to be a content hash in the filename — that is the only version of the
   promise that is true.

   All 63 published objects were re-stamped in place with a server-side copy
   (`--metadata-directive REPLACE`, which drops anything not restated, so both
   headers go every time). No re-upload, sizes unchanged, Range still 206.

## Related

- Boundaries and the clipped form: `sustainable-fsa/census-counties`, concept
  DOI `10.5281/zenodo.22059330`. Its `CLAUDE.md` carries the full account of the
  mask bug and the validity log.
- The LFP determination boundaries: `sustainable-fsa/fsa-lfp-counties` (FOIA
  2025-FSA-08431-F), and the statistics computed on them,
  `sustainable-fsa/usdm-counties-fsa-lfp`.
- The determinations these tiles illustrate: `sustainable-fsa/usdm-counties`.

## Geo family (`SPACE=geo`): the calibration numbers, measured 2026-09-01

WP5's measurements, parked here for WP7 to fold into the geo-family section.
GDAL 3.13.3 / GEOS 3.14.1 / PROJ 9.8.1, mapshaper 0.6.113, every run
`PUBLISH=0`. **Both constants in `R/geo-space.R` were confirmed, not revised.**

**`GEO_MAXZOOM = 13L`.** dd22-geo and census-counties-2020-geo built at both
zooms; deviation is `tippecanoe-decode` of the maxzoom tiles over Guam, American
Samoa, a PR municipio, Pinellas FL and an Alaska borough, point-to-segment
against the build's own geojsonl in the local UTM zone, with clip artefacts (the
tile border and tippecanoe's 5/256 buffer rect) excluded.

| maxzoom | per-axis quantum | worst deviation | dd22-geo | census-2020-geo |
|---|---|---|---|---|
| 13 | 0.30–0.58 m | **0.42 m** (PR) | 83.2 MB (1.35x dummy) | 88.4 MB (1.36x) |
| 12 | 0.61–1.16 m | 0.82 m (PR) | 51.6 MB (0.84x) | 54.2 MB (0.84x) |

The measured deviation is 0.71 of the quantum at both zooms — half a grid
diagonal — so **only the per-axis quantum separates them**, and that is the
number the ≤1 m bar was written against. County ids at z4/z6/z8 are complete at
both zooms with one exception: **census-geo loses Rose Island (60030) at z4
only**, a 1 km² atoll against z4's ~300 m grid. It is back at z6. A coverage
gate that enumerates ids at z4 has to know that.

**`GEO_QUANTIZATION = "1e7"`.** Weeks 2013-03-05, 2019-08-27 and 2025-09-16 (the
archive's worst) at four values. Pitch is per file from its own
`transform.scale`; `south` is at the bbox's southern edge, where a degree of
longitude is longest and the grid is coarsest.

| q | pitch x mid / south | pitch y | worst-week gz | worst retention |
|---|---|---|---|---|
| 1e6 | 8.1–9.0 / 10.0–11.7 m | 4.8–5.9 m | 0.570 MB | 0.9925 |
| 2e6 | 4.0–4.5 / 5.0–5.9 m | 2.4–2.9 m | 0.644 MB | 0.9974 |
| 5e6 | 1.6–1.8 / 2.0–2.3 m | 1.0–1.2 m | 0.758 MB | 0.9989 |
| **1e7** | **0.8–0.9 / 1.0–1.2 m** | 0.5–0.6 m | **0.847 MB** | **0.9991** |

1e6 and 2e6 fail the ~5 m bar at the southern edge. 5e6 is the real alternative
and 1e7 buys one thing for its extra 0.089 MB: **bbox headroom**. q is
bbox-relative and geo week bboxes are 95–110° wide (48 weeks sampled at stride
29, plus the three built: max 110.5°, westernmost vertex 176.2 W, none crossing
the dateline). One drought polygon west of the line would make a week's bbox
~358° and triple its pitch — 7.6 m at 5e6, which fails; 3.8 m at 1e7, which
holds. Dummy cannot have that problem: its Aleutians are folded into a fixed
10-degree inset.
