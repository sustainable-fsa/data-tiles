# data-tiles

Vector tiles (PMTiles) for the Sustainable FSA maps, in **two coordinate
spaces**. `sfsa-albers-usa/1` is the dummy-Albers space the LFP Explorer renders
in; `sfsa-geographic/1` is true EPSG:4326, for any standard map including
`globe`. Each transform lives in exactly one place — `R/dummy-space.R` and
`R/geo-space.R` — because two implementations that drift misregister layers by
up to 765 m with nothing on screen to show it.

```
counties.R            FSA county tiles (dd17/dd22) + composite
census.R              vintage-matched Census county tiles, 18 vintages
census-aiannh.R       Census Native Areas (AIANNH), PMTiles + TopoJSON
fsa-lfp-counties.R    the NDMC/FSA LFP determination boundaries
usdm.R                the weekly USDM, 1,390 weeks of TopoJSON
R/dummy-space.R       the AlbersUSA shift and dummy-space transform
R/geo-space.R         the ONLY copy of the sfsa-geographic/1 transform
R/outline.R           the dissolved national outline and its pinhole guard
R/publish.R           the artifact classes and the ONLY copy of the cache policy
R/s3-archive.R        vendored shared S3 helpers
tools/                the gates, all of them space-aware or space-agnostic
build/  tiles/        intermediates and PMTiles output
```

`SPACE=geo VINTAGES=2020 PUBLISH=0 Rscript census.R` narrows a run. `SPACE`
picks the family, default `dummy`, one per invocation — see **The geographic
family** below.

## The toolchain decides the bytes: sf must be built from source

Every number in this file was measured against **sf built from source** —
`pak::pak("sf?source")` — over Homebrew GDAL 3.13.3 / GEOS 3.14.1 / PROJ 9.8.1.
**The CRAN macOS binary reproduces nothing here byte-identically.** It bundles
GDAL 3.8.5 and PROJ 9.5.1 with no datum grids and no Parquet driver, and both
absences are silent:

- **No grids means no datum shift.** Every transform in this repo crosses NAD83
  and WGS84 — `R/dummy-space.R:233` runs `st_transform("ESRI:102003")` on a
  WGS84 source, `census.R` reads EPSG:4269 — and PROJ picks its operation *per
  coordinate*. With the grids present it picks an `hgridshift`: (−96, 29.5)
  moves 0.612 m through `us_noaa_ethpgn.tif`, Honolulu 1.57 m, San Juan 1.01 m,
  and Anchorage, Guam and Pago Pago 0 m because there the best available
  candidate genuinely is a null transform. Without them all of it becomes
  `+proj=noop` — 4 m of declared accuracy sold as an answer — and there is no
  error and no warning.
- **No Parquet driver means `usdm.R` cannot read a week.** `usdm.R:215` goes
  through `sf::read_sf()` on the source parquet. The three county scripts use
  `arrow::read_parquet()` and would not notice.

So the symptom of the wrong stack is not a failure. It is a byte-identity check
that fails on every artifact with no line of code to blame, and geometry 0.6–2.3
m from where the published family already sits.

**CI is not the CRAN binary either, but it is not local-equivalent by
construction.** `setup-geospatial@v1` builds one conda-forge env — `r-base`,
`r-sf`, `gdal`, `geos`, `proj`, `libgdal-arrow-parquet`, all unpinned — so sf
links conda-forge GDAL/GEOS/PROJ and the Parquet driver is there. But
conda-forge ships `proj` **without** `proj-data`, and its activation script sets
`PROJ_NETWORK=ON` in its place: the grids stream from `cdn.proj.org` per run and
are *not* in the action's env cache. A CDN outage therefore degrades the whole
build to `noop` and publishes it. The workflow's **Gate the R geospatial stack**
step is the only thing standing between that and the bucket — GDAL floor,
Parquet driver, and (−96, 29.5) asserted to move at all. Verified by pointing
`PROJ_DATA` at a directory holding only `proj.db`: 0.0000 m, exit 1.

One more version-shaped trap: **GDAL 3.13 writes compact GeoJSONSeq**, so any
grep of a `build/*.geojsonl` intermediate needs `"id": ?"…"` rather than the
padded form older drivers emitted.

## Three county authorities, and why they are not interchangeable

The archives disagree about where counties are, and the disagreement is the
point: each dataset's statistics were computed against its own polygons, so a
choropleth has to be drawn on the polygons its numbers came from.

| script | tiles | source | clipped to a waterline? |
|---|---|---|---|
| `counties.R` | `fsa-counties-dd17`, `-dd22` | FSA county composite | **here**, cb 5m/500k 2024, pinned |
| `census.R` | `census-counties-<year>` × 18 | `census-counties` `data/clipped/` | **upstream**, each vintage's own cb |
| `fsa-lfp-counties.R` | `fsa-lfp-counties` | `fsa-lfp-counties` (FOIA) | **not at all** — see below |

All three publish the same shape: a `counties` layer and a `states` innerlines
layer inside the PMTiles, an `-index.json` sidecar and an outline GeoJSON. Every
one lands in whichever space the run asked for and carries `id` / `state` /
`county` string properties; in `sfsa-albers-usa/1` all three drop the same six
territory FIPS, and in `sfsa-geographic/1` none of them drops anything.

The census sidecars carry two fields the others do not: `vintage`, the boundary
year as a string, and **`mask_year`, the coastline the geometry was actually cut
at** — not always the vintage, and the app has no other way to know it. Both are
additive to `sfsa-county-index/1`; so are the three fields a geo sidecar adds
(`crs`, `frame_bounds`, and for census `mask_years`).

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

The territory filter (`60, 78, 14, 52, 69, 66`) stays **in dummy**: the archive
carries those counties and dummy-Albers only places CONUS, AK, HI and PR. It is
empty in geo, where there is somewhere to put them.

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
client-side with the inverse of whichever outline GeoJSON is active —
**which is app work that does not exist yet, now in both spaces.**

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

## census-aiannh.R: the Native Areas, and the only script that emits both encodings

The Census AIANNH areas (American Indian reservations, off-reservation trust
lands, Oklahoma tribal statistical areas, Alaska Native village statistical
areas, Hawaiian home lands) as PMTiles **and** TopoJSON, both spaces. At ~891 K
source vertices the dataset sits between the counties (tiles or nothing) and a
USDM week (TopoJSON or waste), so it gets census.R's PMTiles stage and usdm.R's
TopoJSON stage. Three artifacts per space —
`census-aiannh-2025[-geo].pmtiles` / `-index.json` / `.topojson`, all in
`tiles/` — plain `space_suffix()` insertion throughout, no outline-name legacy.

**The source is TIGER/Line, not the cb file, and that is a finding.**
`cb_<y>_us_aiannh_500k` pre-dissolves each area's reservation and trust-land
components into one feature — 704 features, no `COMPTYP`, checked on cb 2020,
2022 and 2024 — so the cb form cannot distinguish trust lands at all.
`tl_2025_us_aiannh` carries 867 records: 617 reservation/statistical-area
components (`COMPTYP` "R") + 250 trust-land components ("T") over 704
`AIANNHCE` codes, `GEOID` the 4-digit code plus the letter. Cached under
`build/aiannh/`, which the gates read back.

**One tileset per space, with `comptyp` as the with/without switch.** The R and
T components stay separate features; an app filters `comptyp == "R"` to hide
trust lands. **That filter hides the 74 Hawaiian home lands too** — Census
codes every one of them "T", which is what they legally are — so it means
"reservations and statistical areas", not "everything but the ORTLs".

**Clipped here at cb 2025 500k, the source's own year, pinned** (`MASK_YEAR`),
with counties.R's `st_union() |> st_make_valid()` idiom and a direct pinned
URL rather than tigris. The clip keeps 0.9831 of source vertices (TIGER runs
past the coastline; that loss is the clip working) and **every one of the 867
components must survive it non-empty** — a component wholly seaward would be a
real disagreement between two Census products and stops the build. A future
`VINTAGES` entry needs a deliberate `MASK_YEAR` decision, not a silent reuse.

**The dummy branch is usdm.R's, not census.R's**: AIANNH carries no state FIPS
— the Navajo Nation spans three states, Alaska is full of ANVSAs — so
placement is `classify_regions()` over exploded polygons, then the per-region
`AREA_RATIO` gate, then a dissolve back by id. Nothing is dropped in either
space: AIANNH covers the 50 states only (no territories, no PR, and nothing
crosses the antimeridian — extent −174.24..−67.04). `name` is `NAMELSAD`
verbatim, the fsa-lfp lesson again.

**Dummy TopoJSON quantization is 5e6, not the USDM's 1e6**, and the ladder is
the reason (measured 2026-09-01, dummy space): 1e6 — a 4.6 × 3.1 m grid —
retains 0.9880 of this TIGER-resolution geometry and fails the 0.99 floor that
the ~1:2M USDM sails through; 2e6 → 0.9975 / 1.75 MB gz; **5e6 → 0.9994 /
2.11 MB**; 1e7 → 0.9994 / 2.38 MB. 5e6 is a 0.92 × 0.62 m grid, the same
resolution class as the tile family's z15 quantum, and 1e7 buys zero retention
for +0.27 MB. Geo keeps `GEO_QUANTIZATION = 1e7` (0.8–1.2 m over its box,
retained 0.9994). Both spaces: mapshaper with topology ON, `id-field=id` (the
dd22 usage — these features have ids), `fix-geometry`, `bbox`, the `.partial`
rename, and the ≥0.99 round-trip gate against the post-transform count.

**Swinomish 4075T is this family's Rose Island, three orders down**: 304 m² of
land, so the completeness floors sit high. Measured on the 2025 build: dummy
carries 274 of 867 at z0, misses only 4075T at z8–z9 and is **complete from
z10**; geo misses three T parcels (1400T, 4075T, 5196T) at z5 and is **complete
from z6**. Dummy's floor is above geo's because the composite compresses CONUS
into 10 degrees. So `check-coverage.R` audits 10/12/14 (dummy) and 6/8/10
(geo), and **the AIANNH family takes the streamed one-decode-per-zoom path in
both spaces** — z12 is 8,000 per-tile subprocesses and z14 is 127,000, the
regime the streamed decoder was written for — with the dummy composite box as
its single range. The county tilesets' per-tile dummy path is textually intact.

Measured, full build (2026-09-01): dummy 875,839 vertices post-clip, 8.5 MB
PMTiles, 6.87 MB TopoJSON; geo 875,849 / 12.3 MB / 6.83 MB; net TopoJSON
retention vs the source zip 0.9826 in both spaces (clip 0.9831 × round trip
0.9994), which is what `tools/check-aiannh.R`'s 0.97 floor was written
against.

The sidecar schema is **`sfsa-aiannh-index/1`**: the county shape with the
arrays renamed (`areas`, `area_names`, plus `aiannhce` and `comptyp`) and an
additive `topojson {url, object, quantization}` block pointing at the sibling
encoding. `check-coverage.R` reads whichever array pair a sidecar carries and
re-derives the expected set from the cached TIGER zip; `check-aiannh.R` is the
TopoJSON's independent gate, retention measured against the source. **No
outline artifact** (AIANNH is never the county authority the USDM is clipped
to) and **no innerlines layer** (the areas are not a partition of the plane).
**Not scheduled**: TIGER vintages are annual and frozen; adding one is a
`VINTAGES` edit and a manual run, like counties.R.

**Published 2026-09-01** (both spaces, six objects to
`s3://sustainable-fsa/data-tiles/tiles/`), verified over the CDN the same day:
correct content types, `public, max-age=3600`, HTTP 206 on a ranged PMTiles
GET with no `Content-Encoding`, all six in `_manifest.txt`, and
`check-aiannh.R` run in remote mode against the published bytes in both
spaces. The bytes uploaded were the gated ones, not a re-derivation.

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

## The geographic family

Everything this repo publishes, a second time, in true EPSG:4326:
`sfsa-geographic/1`. The dummy family renders correctly in exactly one
application — `lfp-explorer`, which owns the matching `js/projection.js` —
because it is an AlbersUSA composite wearing a lng/lat label. This one renders
in QGIS, on a stock MapLibre style, and on `globe`. **Purely additive**: the
dummy family keeps building byte-identically, and that constraint shaped every
decision below.

`SPACE=dummy|geo` (default `dummy`), **one space per invocation**, with an
explicit `if (SPACE == "geo") {…} else {existing code verbatim}` at each branch
point. One space per run is not a limitation waiting to be fixed: it is what
keeps the dummy hot path textually intact, which is what makes byte-identity
provable at all, and it keeps the `Rscript` lazy-parse hazard down to one family
per process.

Every artifact name goes through `space_suffix()`, which returns `"-geo"` or
`""` and **hard-errors on anything else** — a typo falling through to `""` would
rebuild and republish the dummy family under a geo run's flags. That one
function is also what makes the incremental skip per-space for free: the two
families cannot collide on a filename, so a geo run listing the bucket sees only
geo objects and a dummy run is unaffected by however much geo is on disk.

| dummy | geo |
|---|---|
| `tiles/<t>.pmtiles` | `tiles/<t>-geo.pmtiles` |
| `tiles/<t>-index.json` | `tiles/<t>-geo-index.json` |
| `tiles/<t>-outline-dummy.geojson` | `tiles/<t>-geo-outline.geojson` |
| `usdm/USDM_<date>.topojson` | `usdm/USDM_<date>-geo.topojson` |
| `usdm/usdm-index.json` | `usdm/usdm-geo-index.json` |

The outline is the one name that is not a single pattern: the dummy form was
already published and could not move, so the space word sits after `outline`
there and before it in geo. Everything else is `<name><SUFFIX><rest>`, and the
manifest and invalidation wildcards already covered suffixed names.

**A `space` value is a contract, not a CRS.** `sfsa-geographic/1` names
EPSG:4326 *plus* the wrapped-bbox convention below *plus* the frame box, and the
sidecar carries `crs: "EPSG:4326"` separately for anyone who only wants the
projection. An app that read the CRS and assumed the bbox convention would get
the Aleutians wrong.

**`bounds` is honest and useless for framing; `frame_bounds` is the camera.** A
geo sidecar's `bounds` is measured off the artifact's own geometry — which, with
Guam at 144.6 E and American Samoa at 14.5 S in the same tileset, is nearly
world-wide, and `fitBounds()` on it opens over the Pacific. So publish both: the
additive `frame_bounds` is the frozen `GEO_FRAME = (−125.0, 24.0, −66.5, 49.6)`,
a CONUS camera box, frozen for dummy-space's reason — the app's
`?lng/?lat/?zoom` is expressed against it and has to mean the same thing every
session. The geo USDM index carries `frame_bounds` and *no* `bounds`, because no
week's extent is the frame and each week's own extent is in its TopoJSON bbox.

**Never frame from the PMTiles header.** tippecanoe writes the plain, unwrapped
bbox into the v3 header, so a tileset containing Aleutians West reports a header
spanning nearly the whole Pacific. That is the number a library hands you by
default and it is neither of the two useful ones — frame from the sidecar's
`frame_bounds`, take extent from its `bounds`.

**Wrapped per-county bboxes, and `x0` below −180 is the convention.** Measured on
the 2020 clipped vintage, exactly one county straddles the antimeridian —
Aleutians West, `02016` — and its 67 polygon parts each sit wholly on one side,
14 east and 53 west, no ring crossing. So `st_wrap_dateline()` has nothing to
split and is kept as a no-op detector. The hazard is arithmetic, not geometry:
`02016`'s plain `st_bbox()` is [−179.15, 179.78], which is right and describes a
box wrapped the wrong way round the planet, 359° wide instead of 21, and every
consumer of the sidecar reads it as the whole Pacific. `wrapped_bboxes()` counts
the east-hemisphere parts at `lon − 360`, so `x0` comes back at −187.54 and
MapLibre takes it happily. The threshold is per vertex and is safe only because
`to_geo()` ran first; the straddle test is on the plain bbox, so the expensive
path runs for one feature in 3,234 and an ordinary CONUS county's row is
`st_bbox()` exactly.

**The geo family drops nothing, and the six dummy FIPS were never the whole
story.** Dummy-Albers has nowhere to put Guam or American Samoa and true
EPSG:4326 has exactly where. Two of the six codes never matched anything even in
the dummy build: the FSA composite's territory rows carry real `FIPSST`
60/66/69/78, but their **ids are legacy** — Guam `14001`, the USVI
`52001/52003/52005`, the Marianas `69085/69100/69110/69120`, and five American
Samoa rows sharing `60001` that the dissolve by id makes one feature. The filter
reads `stfips`, where `"14"` and `"52"` are dead entries. The ids are what the
sidecar publishes, so they are what a coverage gate has to expect: **dd22-geo is
3,115 features** against dummy's 3,106, and a census vintage gains the territory
counties the Census parquet carries under real 60/66/69/78 — 13 of them in the
two measured, 2009-geo and 2020-geo, both 3,234 against 3,221.
`fsa-lfp-counties-geo` stays 3,221 and a USDM week stays five features, because
neither source carries a territory at all.

**`mask_year` becomes a scalar plus an array.** In dummy the territory filter
made `unique(mask_year)` single-valued and that was asserted. Geo keeps those 13
counties, so on 2009 and 2011 a vintage genuinely carries two values and
single-valued is no longer a fact. The rule that replaces the assert is the same
statement in the only form still true: **every non-territory row shares one mask
year**, that value stays the scalar the sidecar and the tileset description
carry, and a second value is tolerated only on territory rows. Anything else is
the upstream clip mask composition changing, which is what the assert exists
for, and it stops the build in both spaces. The full set goes out as an additive
`mask_years`; only 2009 and 2011 are `[2010, 2013]`.

**Precision and flags.** Geo intermediates are written
`COORDINATE_PRECISION=7` — 1.1 cm of real degrees, finer than any source here,
where the dummy 9 dp was calibrated to dummy degrees and would be two wasted
digits per ordinate across a ~190 MB file. `RFC7946=NO` in both spaces: dummy
degrees are not lng/lat and must not be normalised as such, and RFC 7946 mode
would re-split the antimeridian wrap `to_geo()` already settled. The tippecanoe
block is **one block for both spaces** — only the maxzoom, the description and
`--clip-bounding-box` differ, and the clip box is dummy-only, being belt and
braces against a mis-shift in a layout this space does not have. The geo guard
is `assert_geo_envelope()` inside `to_geo()`, which stops the build rather than
quietly cutting geometry off the edge of a box; a geo box would have to be the
whole world anyway.

### The calibration, measured 2026-09-01

Both constants in `R/geo-space.R` arrived as arithmetic and were built and
decoded back. **Neither moved.** GDAL 3.13.3 / GEOS 3.14.1 / PROJ 9.8.1,
mapshaper 0.6.113, every run `PUBLISH=0`.

**`GEO_MAXZOOM = 13L`.** dd22-geo and census-counties-2020-geo built at both
zooms; deviation is `tippecanoe-decode` of the maxzoom tiles over Guam, American
Samoa, a PR municipio, Pinellas FL and an Alaska borough, point-to-segment
against the build's own geojsonl in the local UTM zone, with the clip artefacts
(tile border, tippecanoe's 5/256 buffer rect) excluded.

| maxzoom | per-axis quantum | worst deviation | dd22-geo | census-2020-geo |
|---|---|---|---|---|
| 13 | 0.30–0.58 m | **0.42 m** (PR) | 83.2 MB (1.35× dummy) | 88.4 MB (1.36×) |
| 12 | 0.61–1.16 m | 0.82 m (PR) | 51.6 MB (0.84×) | 54.2 MB (0.84×) |

The measured deviation is 0.71 of the quantum at both zooms — half a grid
diagonal, which is exactly what rounding to a grid does — so **empirical
deviation clears 1 m at both zooms and only the per-axis quantum separates
them**. That is the number the ≤1 m bar was written against; reading the
diagonal instead would sell a 1.16 m grid as a sub-metre one. The 38% size
premium is the price of not being coarser in the honest space than in the
deliberate lie.

**`GEO_QUANTIZATION = "1e7"`.** mapshaper's `-o quantization` is
**bbox-relative**, and that is the whole reason the two spaces cannot share the
number: `q=1e6` over a 10-degree dummy box is a 4.6 × 3.1 m grid and over a geo
week's 95–110° box it is 8–12 m, which is simplification wearing an encoding's
clothes and is exactly what usdm.R's own table rejected 1e5 for. Weeks
2013-03-05, 2019-08-27 and 2025-09-16 (the archive's worst) at four values;
pitch is per file from its own `transform.scale`, read at the bbox's southern
edge where a degree of longitude is longest.

| q | pitch x mid / south | pitch y | worst-week gz | worst retention |
|---|---|---|---|---|
| 1e6 | 8.1–9.0 / 10.0–11.7 m | 4.8–5.9 m | 0.570 MB | 0.9925 |
| 2e6 | 4.0–4.5 / 5.0–5.9 m | 2.4–2.9 m | 0.644 MB | 0.9974 |
| 5e6 | 1.6–1.8 / 2.0–2.3 m | 1.0–1.2 m | 0.758 MB | 0.9989 |
| **1e7** | **0.8–0.9 / 1.0–1.2 m** | 0.5–0.6 m | **0.847 MB** | **0.9991** |

1e6 and 2e6 fail the ~5 m bar at the southern edge. **5e6 is the real
alternative**, and 1e7 buys one thing for its extra 0.089 MB: **bbox headroom**.
One drought polygon west of the dateline would make a week's bbox ~358° and
triple its pitch — 7.6 m at 5e6, which fails; 3.8 m at 1e7, which holds. Dummy
cannot have that problem, its Aleutians being folded into a fixed 10-degree
inset.

### The USDM in geo: different gates, for a different reason

**No region classifier and no `AREA_RATIO` gate.** There are no insets, so there
is nothing to classify and nothing to clip away — both are replaced by a
**per-class total-area comparison against the source in EPSG:6933 at 1e-4**,
plus `assert_geo_envelope()`. Retention (≥0.99 round-trip through mapshaper),
the D0–D4 class-set check, the object name and the `.partial` machinery are
verbatim.

**No week in this archive crosses the antimeridian.** 51 weeks sampled across it
— 48 at stride 29 plus the three built — max bbox 110.5° wide, westernmost
vertex 176.2 W, none crossing. `st_wrap_dateline()` is therefore a no-op here
too, kept because the USDM is hand-drawn at ~1:2,000,000 and nothing upstream
promises its rings stop at the line. `to_geo()`'s equal-area assert is what turns
a future crossing into a stopped build: a split ring whose lon jumps ±179
projects to one that girdles the planet, so the 6933 area moves enormously and
the assert reports a real repair rather than a failure of the repair. The right
response is to look at the source, not to loosen the tolerance.

**The anchored listing regex was a dummy-path bug waiting for a geo file to
exist.** `usdm.R` and `tools/check-usdm.R` both listed `^USDM_.*\.topojson$`,
and `date_of()` would have read `USDM_2020-01-07-geo.topojson` as the week
`"2020-01-07-geo"` — into the dummy index and into the skip decision. One geo
object in the bucket was enough to corrupt both. Both listings are now
`sprintf("^USDM_[0-9]{4}-[0-9]{2}-[0-9]{2}%s\\.topojson$", SUFFIX)` and
`date_of()` is three subs rather than one alternation. It landed **before any
geo file existed**, which is the only order in which it is a fix rather than a
repair.

### Rose Island, and why the geo coverage gate audits z5

`60030` is 0.0998 km² of American Samoa by the archive's own `Area` column. A z4
tile's 4,096-unit extent quantises to a ~610 m cell, 0.37 km², so the atoll has
a quarter of one cell and no area left to encode: **3,233 of 3,234 in the
census-geo vintages at z4**, complete from z5. Nothing dropped it — the geo
builds pass `--no-tiny-polygon-reduction`, `--no-tile-size-limit` and
`--no-feature-limit`, read back out of the tileset's own `generator_options` —
so it is sub-pixel arithmetic, and it is a fact about the tiles rather than
about the gate. Unlike dummy's z0 floor **this one is reachable**: a stock map
framed on `GEO_FRAME` sits near z4, and genuinely lacks Rose Island there. The
geo gate audits 5, 6, 8; dummy stays 4, 6, 8.

## Gates

```sh
Rscript tools/check-registration.R                                  # G4, dummy only
TILESET=fsa-lfp-counties          Rscript tools/check-coverage.R
TILESET=census-counties-2020      Rscript tools/check-coverage.R
TILESET=census-counties-2020-geo  Rscript tools/check-coverage.R
Rscript tools/check-coverage.R                                      # dd22, default
TILESET=census-aiannh-2025        Rscript tools/check-coverage.R
TILESET=census-aiannh-2025-geo    Rscript tools/check-coverage.R
Rscript tools/check-usdm.R                                          # dummy
SPACE=geo SAMPLE=6 Rscript tools/check-usdm.R
Rscript tools/check-aiannh.R                                        # dummy
SPACE=geo Rscript tools/check-aiannh.R
```

`check-coverage.R` takes `TILESET` (the PMTiles basename) as well as the
original `VINTAGE`. The **source wins wherever there is a rule for it**: for
`census-counties-<year>` — and for `census-counties-<year>-geo` — the gate
re-derives the ids from the cached clipped parquet and re-applies the space's own
territory filter itself, rather than reading them out of the sidecar. A gate that
trusts the build's own bookkeeping cannot catch the build losing a county before
tippecanoe ever saw it. Everything else falls back to
`tiles/<TILESET>-index.json`.

**Where both exist they are compared, and a disagreement is a failure.** That
check is the only thing standing behind the sidecars — without it, publishing an
index for a tileset that already had a source rule would silently demote this
gate from "the tiles match the archive" to "the tiles match what the build said
it wrote".

**The space is derived from the name, not passed.** `TILESET` already carries the
`-geo` suffix, so the gate reads it, and four things change with it: the drop set
(dummy's six FIPS, geo's empty), the census source-rule regex, the audited zooms
(4/6/8 against 5/6/8 — see Rose Island above), and the decode strategy. That
last one is not cosmetic: the geo audit boxes are ~5,400 tiles at z8 where
dummy's frozen box is 48, so geo runs one `tippecanoe-decode` per zoom and reads
it as a line stream. The dummy per-tile path is textually intact.

`check-usdm.R` takes `SPACE`, one space per invocation for the same reason
`usdm.R` does: different names, a different index, a different bounds box.

**Nothing in either gate is imported from `R/`.** The drop sets and the four
geographic envelope numbers are typed again there on purpose; the zoom ceiling
comes out of the PMTiles v3 header, the tileset itself being the only party to
that question that cannot be wrong about it.

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
2. **The geo family was backfilled 2026-09-01**, in the order that let the
   cheap runs prove the machinery before the long one started:
   `SPACE=geo Rscript counties.R` (6 files) → `fsa-lfp-counties.R` (3) →
   `census.R` (54, where the incremental skip proved itself) →
   `SPACE=geo WORKERS=6 Rscript usdm.R` (1,391 weeks and an index; ~40 min on
   6 daemons). Verified over the CDN the same day: correct content types
   including the new `-geo-outline.geojson` class, HTTP 206 on a ranged GET,
   no `Content-Encoding` on PMTiles, `SPACE=geo SAMPLE=20 check-usdm.R` in
   remote mode, and the dummy `usdm-index.json` untouched by any of it (its
   only delta that day was `2026-08-25`, added by the cron itself). The
   existing wildcard invalidations covered the suffixed names.
3. **The workflow's `SPACES` flipped to `dummy geo`** in its own commit once
   the backfill was in the bucket — earlier, the first scheduled `SPACE=geo`
   run would have tried to build the whole USDM archive inside a 350-minute
   timeout. A quiet Thursday now costs four list calls instead of two.
4. **`counties.R` still inlines a bare `st_union()` for its dummy outline** where
   `census.R` and `fsa-lfp-counties.R` call `dissolve_outline()`. dd17/dd22
   happen to carry no pinholes, so the two agree by luck rather than by
   construction. Its **geo** path uses the helper, so this is now the only
   remaining caller — adopt it the next time the dummy pair is rebuilt.
5. **`setup-geospatial` already provides mapshaper and tippecanoe.** The
   workflow only re-pins mapshaper to 0.6.113, the version usdm.R's retention
   gate was calibrated against; the shared action installs it unpinned. That pin
   is what makes a CI build byte-identical to a local one — verified end to end
   by deleting a published week and letting the workflow rebuild it: same
   sha256, `4a4b96c7`. Note what that verification did *not* cover: it is a
   `usdm.R` week, which is the one script whose source needs no Parquet driver
   read at a datum boundary. See **The toolchain decides the bytes** — nothing
   has yet proven a CI `census.R` build byte-identical.
6. **The weekly cron runs `usdm.R` and `census.R`, now under a `SPACES` loop.**
   Both discover their inputs from the upstream manifest and skip whatever the
   bucket already holds, so a quiet week costs one list call per script per
   space. `census.R` only does work in the year Census posts a new vintage, and
   notices that on its own rather than waiting for someone to edit a hardcoded
   list.

   `counties.R` and `fsa-lfp-counties.R` are **not** scheduled and still rebuild
   unconditionally; their sources are frozen archives. A push that edits
   `R/dummy-space.R` or `R/geo-space.R` therefore does NOT re-tile them — the
   transform gates run, but re-tiling stays a manual call, which is deliberate:
   a 1.4 GB republish should not be a side effect of a commit.
7. **The app side of the geographic family does not exist.** Two pieces:
   `lfp-explorer` has to draw the inverse of the active outline above the USDM,
   which is unpublished by design in both spaces, or the overlay shows the
   USDM's own ~1:2M coastline running past the counties; and it has to frame
   from the sidecar's `frame_bounds` rather than from the PMTiles header, which
   for any geo tileset containing Aleutians West spans nearly the whole Pacific.
   Neither is written.
8. **The cache policy is `public, max-age=3600`, and it used to be
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
