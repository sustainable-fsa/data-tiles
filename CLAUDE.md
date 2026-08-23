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
R/dummy-space.R       the AlbersUSA shift and dummy-space transform
R/outline.R           the dissolved national outline and its pinhole guard
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
   nothing had gated a fresh build, and publishing is effectively one-way:
   `s3_put` writes the PMTiles `immutable` with a one-year max-age, so a
   correction under the same filename is invisible to anyone holding a copy.
   **A real correction needs a new filename, not an invalidation.**

   The three scripts now end the way every sibling archive does, with
   `s3_write_manifest()` + `cf_invalidate()`. None of them did, so the first
   publish went up unlisted and `_manifest.txt` had to be written by hand. The
   invalidation uses `/<prefix>/tiles/*`, which counts as a single path.
2. **`counties.R` still inlines a bare `st_union()` for its outline** where
   `census.R` and `fsa-lfp-counties.R` now call `dissolve_outline()`. dd17/dd22
   happen to carry no pinholes, so the two agree by luck rather than by
   construction — adopt the helper the next time those are rebuilt.
3. **`immutable` is the wrong cache policy for a filename that gets revised.**
   Twice now the census PMTiles have been republished under the same names, and
   only because nothing consumes them yet. `max-age=31536000, immutable` means
   an edge invalidation does not reach a browser that already holds the file. If
   these tilesets are still in flux, either shorten the max-age or put a content
   hash in the filename before anyone starts consuming them.

## Related

- Boundaries and the clipped form: `sustainable-fsa/census-counties`, concept
  DOI `10.5281/zenodo.22059330`. Its `CLAUDE.md` carries the full account of the
  mask bug and the validity log.
- The LFP determination boundaries: `sustainable-fsa/fsa-lfp-counties` (FOIA
  2025-FSA-08431-F), and the statistics computed on them,
  `sustainable-fsa/usdm-counties-fsa-lfp`.
- The determinations these tiles illustrate: `sustainable-fsa/usdm-counties`.
