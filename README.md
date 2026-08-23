# data-tiles

Vector tiles for the [Sustainable FSA](https://sustainable-fsa.com) web maps:
the FSA county composite and the weekly US Drought Monitor, published as
[PMTiles](https://docs.protomaps.com/pmtiles/) and pre-projected into the
`sfsa-albers-usa/1` coordinate space.

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
the AlbersUSA inset shift, the dummy rescale, the tiling — happens here.

The three county sets disagree with one another, and the disagreement is
load-bearing: each archive's statistics were computed against its own polygons,
so a choropleth has to be drawn on the polygons its numbers came from. They stay
three separate tilesets, and one is never substituted for another.

## The coordinate space

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

## Layout

```
counties.R                   FSA county tiles (dd17/dd22)
census.R                     vintage-matched Census county tiles, 18 vintages
fsa-lfp-counties.R           the NDMC/FSA LFP determination boundaries
usdm.R                       the weekly USDM, 1,390 weeks of TopoJSON
R/dummy-space.R              the ONLY copy of the transform
R/outline.R                  the dissolved outline and its pinhole guard
R/publish.R                  artifact classes and the cache policy
tools/check-registration.R   gate G4 — proves it matches the JavaScript
tools/check-coverage.R       proves no county was silently dropped
tools/check-usdm.R           proves the weekly USDM decodes and registers
```

Each build script takes `PUBLISH=0` to build locally without uploading;
`census.R` also takes `VINTAGES=` to narrow a run.

`R/dummy-space.R` is deliberately **not** vendored into the archive repos, the
way `R/s3-archive.R` is. Two implementations of a projection that disagree
produce a silent misregistration: layers that line up at the centre of the map
and drift apart toward the edges, with nothing on screen to say so. That file
already exists in 16 copies across 3 distinct versions in this project, which is
exactly how it happens.

## Gates

```sh
Rscript tools/check-registration.R
TILESET=fsa-lfp-counties Rscript tools/check-coverage.R
```

`check-coverage.R` decodes the built tiles and asserts that every county in the
source is present at every zoom the app can display — the one pipeline failure
that does not look like a failure, because a choropleth with holes still renders
as a map. It takes `TILESET` (the PMTiles basename) and defaults to
`fsa-counties-dd22`. Where a tileset has both an archive to check against and a
published index sidecar, the archive is the authority and the two are compared.

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

The USDM is **TopoJSON, not tiles**, and that is a measured choice: a week is
five features and 100-266 K vertices of ~1:2,000,000 data, so there is nothing
for a tile pyramid to simplify and it would cost 16x the bytes. Quantized to
1e6 — a 4.6 m grid, 99.75% of vertices — each week is 0.1-0.6 MB over the wire.
It is published **unclipped**; mask the overspill client-side with the inverse
of whichever `-outline-dummy.geojson` you are drawing.

Each `.pmtiles` carries a `counties` layer and a `states` innerlines layer, and
ships with a `-index.json` sidecar and a `-outline-dummy.geojson` beside it. The
sidecar is not an optimisation: `queryRenderedFeatures` returns only what is
rendered, clipped and simplified for the zoom, so the tiles alone cannot supply
a county index, county names or a centroid.

PMTiles are served `application/octet-stream` with **no `Content-Encoding`**:
the header records `tile_compression = gzip` and the client shim decompresses,
while a `Content-Encoding` would break Range semantics.

Everything under this prefix is `public, max-age=3600`. Filenames are stable
across rebuilds, so nothing here is `immutable` — a publish invalidates the
edge, and an hour is the longest a client can hold a superseded copy.

## Citation

Bocinsky, R. Kyle. *Sustainable FSA Data Tiles*. Montana Climate Office,
University of Montana. Sustainable FSA project.
<https://sustainable-fsa.com/data-tiles/>

**Acknowledgment**: This work is part of the [*Enhancing Sustainable Disaster
Relief in FSA Programs*](https://www.ars.usda.gov/research/project/?accnNo=444612)
project, supported by the USDA Office of the Chief Economist, Office of Energy
and Environmental Policy, and the USDA Climate Hubs.
