# data-tiles

Vector tiles for the [Sustainable FSA](https://sustainable-fsa.com) web maps:
the FSA county composite and the weekly US Drought Monitor, published as
[PMTiles](https://docs.protomaps.com/pmtiles/) in two coordinate spaces —
`sfsa-albers-usa/1`, pre-projected for the app, and `sfsa-geographic/1`, true
EPSG:4326 for any standard map.

**This is a presentation archive, not an archive of record.** It derives
everything it publishes from archives that *are* records, and it holds no
authoritative data of its own:

| input | from |
|---|---|
| FSA county boundaries, full resolution, true-position WGS84 | [`fsa-counties-dd17`](https://github.com/sustainable-fsa/fsa-counties-dd17), [`fsa-counties-dd22`](https://github.com/sustainable-fsa/fsa-counties-dd22) |
| vintage-matched Census counties, clipped to each year's own waterline | [`census-counties`](https://github.com/sustainable-fsa/census-counties) |
| the boundaries FSA's LFP determinations are computed against | [`fsa-lfp-counties`](https://github.com/sustainable-fsa/fsa-lfp-counties) |
| weekly USDM polygons, GeoParquet, WGS84 | [`usdm`](https://github.com/sustainable-fsa/usdm) |

Those repositories stay projection-neutral and publish real coordinates in a
real CRS. Everything app-specific — the territory filter, the coastline clip,
the AlbersUSA inset shift, the dummy rescale, the tiling — happens here. In the
geographic family only the clip and the tiling apply; the rest is what makes
that family the honest one.

The three county sets disagree with one another, and the disagreement is
load-bearing: each archive's statistics were computed against its own polygons,
so a choropleth has to be drawn on the polygons its numbers came from. They stay
three separate tilesets, and one is never substituted for another.

## The dummy space

`sfsa-albers-usa/1` is the AlbersUSA composite (CONUS with Alaska, Hawaii and
Puerto Rico scaled and repositioned as insets) rescaled into a 10-degree box
centred on (0, 0), which MapLibre renders as if it were lng/lat. It is **not a
geographic CRS**, and coordinates in it are meaningless outside this system.

It exists because MapLibre supports only Mercator-family projections, so a map
that wants to *look* like Albers has to be fed coordinates that are already
Albers. Tiles inherit their addressing from their coordinates, so the transform
has to happen before tiling — it cannot be applied in the browser.

Two consequences worth knowing before consuming these tiles:

- **A conventional basemap cannot register against them.** Real-world tiles are
  addressed in Mercator-of-true-lng/lat; these are addressed in
  Mercator-of-dummy-degrees, which lands in the Gulf of Guinea. Separately, the
  composite *moves* Alaska, Hawaii and Puerto Rico, so no real basemap could be
  correct beneath the insets in any projection.
- **The shear is corrected.** Mercator's y is the inverse Gudermannian of
  latitude, so emitting a y linear in Albers northing would render the plane
  with a 0.14% vertical stretch, accumulating to 765 m of displacement at the
  top and bottom edges — and a 0.141% area error in a projection chosen
  *because* it is equal-area. `R/dummy-space.R` emits the Gudermannian instead,
  so Mercator undoes it and the rendered plane is true Albers.

## The geographic family

Every artifact has a `-geo` sibling in `sfsa-geographic/1`: **true EPSG:4326, at
real positions**, which renders on a stock MapLibre style, on `globe`, in QGIS,
or anywhere else that reads GeoJSON. Same directories, same sidecar schema,
`-geo` in the name.

```
tiles/<tileset>-geo.pmtiles
tiles/<tileset>-geo-index.json
tiles/<tileset>-geo-outline.geojson
usdm/USDM_<date>-geo.topojson
usdm/usdm-geo-index.json
```

Four things to know before consuming them:

- **`space` is a contract, not a CRS.** `sfsa-geographic/1` means EPSG:4326 *plus*
  the bbox convention below *plus* the frame box. The sidecar also carries
  `crs: "EPSG:4326"` for anyone who only wants the projection.
- **Frame from the sidecar, never from the PMTiles header.** The header holds
  tippecanoe's plain unwrapped bbox, which for any tileset containing Aleutians
  West spans nearly the whole Pacific. The sidecar's `bounds` is the wrapped
  measure of the real extent — itself nearly world-wide whenever Guam and
  American Samoa are in the tileset, which here they are — and its
  `frame_bounds`, a frozen CONUS camera box `[-125.0, 24.0, -66.5, 49.6]`, is
  what `fitBounds()` wants.
- **Per-county bboxes are wrapped, so `x0` can be below −180.** A county with
  parts either side of the antimeridian has its eastern parts counted at
  `lon − 360`, which makes its box 21 degrees wide instead of 359. MapLibre
  accepts that; a clamp to [−180, 180] would undo it.
- **Territories are included.** Guam, the Northern Marianas, American Samoa and
  the US Virgin Islands are in the geographic family and absent from the dummy
  one, which has nowhere to put them. In the FSA composite their ids are legacy
  codes rather than modern FIPS — Guam `14001`, the USVI `52001/52003/52005`,
  the Marianas `69085/69100/69110/69120`, American Samoa `60001`.

Maxzoom is **13**, not the dummy family's 15, and that is the same ground
resolution rather than a coarser one: Web Mercator at z13 with `--full-detail=13`
quantises to 0.597 m at the equator, against dummy z15's 0.720 m of CONUS
ground, and the worst measured vertex deviation is 0.42 m. Geo county tilesets
run 83–89 MB, about 1.35x their dummy siblings. USDM weeks are quantized to 1e7
rather than 1e6, because mapshaper's quantization is bbox-relative and a
geographic week's bbox is 95–110 degrees wide where the dummy box is 10: the
pitch comes out at 0.8–1.2 m, and the worst week in the archive is 0.85 MB
gzipped.

The USDM is unclipped in this family too — mask the overspill with the inverse
of `<tileset>-geo-outline.geojson`.

## Layout

```
counties.R                   FSA county tiles (dd17/dd22)
census.R                     vintage-matched Census county tiles, 18 vintages
fsa-lfp-counties.R           the NDMC/FSA LFP determination boundaries
usdm.R                       the weekly USDM, 1,390 weeks of TopoJSON
R/dummy-space.R              the ONLY copy of the dummy transform
R/geo-space.R                the ONLY copy of the geographic transform
R/outline.R                  the dissolved outline and its pinhole guard
R/publish.R                  artifact classes and the cache policy
tools/check-registration.R   gate G4 — proves it matches the JavaScript
tools/check-coverage.R       proves no county was silently dropped
tools/check-usdm.R           proves the weekly USDM decodes and registers
```

Each build script takes `SPACE=dummy|geo` (default `dummy`) and builds one space
per invocation, and `PUBLISH=0` to build locally without uploading; `census.R`
also takes `VINTAGES=` to narrow a run.

Reproducing these bytes needs **sf built from source** — `pak::pak("sf?source")`
over Homebrew GDAL 3.13 / PROJ 9.8 — against a PROJ that has the NAD83 datum
grids and a GDAL that has the Parquet driver. The CRAN macOS binary carries
neither, and its transforms then land 0.6–2.3 m off with no error and no warning.

Neither transform file is vendored into the archive repos, the
way `R/s3-archive.R` is. Two implementations of a projection that disagree
produce a silent misregistration: layers that line up at the centre of the map
and drift apart toward the edges, with nothing on screen to say so. That file
already exists in 16 copies across 3 distinct versions in this project, which is
exactly how it happens.

## Gates

```sh
Rscript tools/check-registration.R
TILESET=fsa-lfp-counties     Rscript tools/check-coverage.R
TILESET=census-counties-2020-geo Rscript tools/check-coverage.R
SPACE=geo Rscript tools/check-usdm.R
```

`check-coverage.R` decodes the built tiles and asserts that every county in the
source is present at every zoom the app can display — the one pipeline failure
that does not look like a failure, because a choropleth with holes still renders
as a map. It takes `TILESET` (the PMTiles basename) and defaults to
`fsa-counties-dd22`, and reads the space off the name: a `-geo` tileset is
expected to carry the territories and is audited at different zooms. Where a
tileset has both an archive to check against and a published index sidecar, the
archive is the authority and the two are compared.

`check-registration.R` runs the twelve reference points from the specification
— the header of `js/projection.js` in
[`lfp-explorer`](https://github.com/sustainable-fsa/lfp-explorer) — through the
R implementation and asserts agreement to **1e-9 dummy degrees** (about half a
millimetre). Three of the twelve sit at high |y|, which is deliberate: the shear
correction vanishes at the equator, so a producer that skipped it would pass a
centre-only test and be 765 m out at the edges.

## Published artifacts

<https://data.sustainable-fsa.com/data-tiles/tiles/>, listed in
[`_manifest.txt`](https://data.sustainable-fsa.com/data-tiles/_manifest.txt):

```
tiles/census-counties-<year>.pmtiles   2000, 2009, 2010, 2011-2025
tiles/fsa-lfp-counties.pmtiles
tiles/fsa-counties-dd17.pmtiles
tiles/fsa-counties-dd22.pmtiles
usdm/USDM_<date>.topojson              1,390 weeks, 2000-01-04 onward
usdm/usdm-index.json
```

Each of those has a `-geo` sibling in `sfsa-geographic/1`, published 2026-09-01.
`_manifest.txt` lists both families.

The USDM is **TopoJSON, not tiles**, and that is a measured choice: a week is
five features and 100-266 K vertices of ~1:2,000,000 data, so there is nothing
for a tile pyramid to simplify and it would cost 16x the bytes. Quantized to
1e6 in the dummy space — a 4.6 m grid, 99.75% of vertices — each week is 0.1-0.6
MB over the wire. It is published **unclipped**; mask the overspill client-side
with the inverse of whichever outline you are drawing.

Each `.pmtiles` carries a `counties` layer and a `states` innerlines layer, and
ships with a `-index.json` sidecar and an outline GeoJSON beside it —
`-outline-dummy.geojson` in `sfsa-albers-usa/1`, `-geo-outline.geojson` in
`sfsa-geographic/1`. The sidecar is not an optimisation:
`queryRenderedFeatures` returns only what is rendered, clipped and simplified
for the zoom, so the tiles alone cannot supply a county index, county names or a
centroid.

PMTiles are served `application/octet-stream` with **no `Content-Encoding`**:
the header records `tile_compression = gzip` and the client shim decompresses,
while a `Content-Encoding` would break Range semantics.

Everything under this prefix is `public, max-age=3600`. Filenames are stable
across rebuilds, so nothing here is `immutable` — a publish invalidates the
edge, and an hour is the longest a client can hold a superseded copy.

## Updating

`.github/workflows/data-tiles.yaml` runs **Thursdays at 21:00 UTC**, behind the
whole USDM cascade (`usdm` publishes at 13:00, `usdm-counties` at 20:20). It
runs `usdm.R` and `census.R`. Both discover what exists upstream and skip
whatever the bucket already holds, so a quiet Thursday costs two list calls and
publishes nothing. `counties.R` and `fsa-lfp-counties.R` build frozen archives
and are reachable through the workflow's `scripts` input.

Each script runs once per space named in the `spaces` input, which is `dummy`
until the geographic backfill is published. A freshness precheck skips scheduled
runs when the current USDM week is already archived; pushes and manual
dispatches always proceed.

## Citation

Bocinsky, R. Kyle. *Sustainable FSA Data Tiles*. Montana Climate Office,
University of Montana. Sustainable FSA project.
<https://sustainable-fsa.com/data-tiles/>

**Acknowledgment**: This work is part of the [*Enhancing Sustainable Disaster
Relief in FSA Programs*](https://www.ars.usda.gov/research/project/?accnNo=444612)
project, supported by the USDA Office of the Chief Economist, Office of Energy
and Environmental Policy, and the USDA Climate Hubs.
