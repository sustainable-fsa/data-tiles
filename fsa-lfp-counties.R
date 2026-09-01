#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · fsa-lfp-counties.R
##
## The county boundaries FSA and the NDMC actually use to determine Livestock
## Forage Program eligibility, as vector tiles in either output space —
## sfsa-albers-usa/1, the dummy composite the LFP Explorer renders, or
## sfsa-geographic/1, true EPSG:4326 for any standard map. Source:
## sustainable-fsa/fsa-lfp-counties, the geodatabase released under FOIA
## 2025-FSA-08431-F — one layer, 3,221 counties, no vintages.
##
## This is a THIRD county authority, alongside the FSA composite (counties.R,
## dd17/dd22) and vintage-matched Census (census.R). They disagree, and that
## disagreement is the point: usdm-counties-fsa-lfp aggregates the USDM against
## THESE polygons, so a choropleth of those statistics has to be drawn on these
## polygons and not on a near-neighbour that happens to be handy.
##
## NO COASTLINE CLIP, and that is deliberate. counties.R clips because the FSA
## composite's own extent reaches into open water; census.R's source arrives
## clipped from upstream. This one already stops at the water: measured against
## a dissolved cb 2024 500k mask, intersecting would remove 0.109% of total area
## (9,323,313 -> 9,313,178 km2), lose no county, and touch more than 1% of only
## 99 of 3,221 — all of it bay and estuary detail where two cartographies
## disagree, not overhang. Michigan, Wisconsin and Minnesota sum to 514,338 km2
## against 492,935 km2 of Census land area, so the Great Lakes are already cut.
## Clipping anyway would draw the determination on a shape whose statistics were
## computed against a different one.
##
## IT IS ALSO NOT EDGE-MATCHED. Unioning the 3,221 counties leaves 491 pinhole
## gaps where neighbours fail to meet. They are in the record and they stay in
## the counties layer; the published outline drops them, for the reason given
## where it is built.
##
##   Rscript fsa-lfp-counties.R                   # build and publish
##   PUBLISH=0 Rscript fsa-lfp-counties.R         # local only
##   SPACE=geo PUBLISH=0 Rscript fsa-lfp-counties.R   # the geographic family
## =============================================================================

suppressPackageStartupMessages({
  library(sf); library(arrow); library(dplyr); library(tigris)
  library(rmapshaper); library(jsonlite)
})
source("R/dummy-space.R")
source("R/geo-space.R")
source("R/outline.R")
source("R/s3-archive.R")
source("R/publish.R")
sf::sf_use_s2(FALSE)
options(tigris_use_cache = TRUE)

## ── Configuration ────────────────────────────────────────────────────────────
## Identical to counties.R; see its note on why --full-detail and not
## --extra-detail, and why the lossless flags are not negotiable.
MAXZOOM  <- 15L
DETAIL   <- 13L
SIMPLIFY <- 0.5

## Kept as a guard, not as a filter: this dataset carries 50 states, DC and
## Puerto Rico and no other territory, so it currently drops nothing. If a
## future release adds Guam, dummy-Albers has nowhere to put it and the count
## gate below is what would notice.
DROP_STATES <- c("60", "78", "14", "52", "69", "66")

## As delivered. A change here is a change in the record, so it is a gate.
N_EXPECTED <- 3221L

## State names only — a lookup table, no geometry. Pinned for the same reason
## counties.R pins its mask year: nothing in this repo floats with a release.
STATE_NAME_YEAR <- 2024L

## ── The output space ─────────────────────────────────────────────────────────
## SPACE picks which family this invocation builds, and one invocation builds
## exactly one. The two share the source, the flag block and the sidecar schema
## and nothing else: sfsa-albers-usa/1 is a frozen inset composite in a
## 10-degree dummy box, sfsa-geographic/1 is st_transform(4326). Every artifact
## name goes through space_suffix(), which is what keeps the two families from
## colliding on a filename. An unrecognised value stops there rather than
## falling through to dummy, which would rebuild the published family under a
## geo run's flags.
SPACE  <- Sys.getenv("SPACE", unset = "dummy")
SUFFIX <- space_suffix(SPACE)

## The values that differ between the two, stated here rather than at each use
## so the writers, the sidecar and the tippecanoe block stay single copies.
##
## COORDINATE_PRECISION is explicit because GDAL's GeoJSON driver defaults to 7
## and neither space should inherit a default. 9 dp of DUMMY degrees is 0.5 mm
## (the driver's own 7 would be 5 cm — fine here, but by luck); 7 dp of real
## degrees is 1.1 cm, finer than the source and two digits per ordinate cheaper
## across the intermediate. RFC7946=NO in both: dummy degrees are not lng/lat
## and must not be normalised as such, and the geo family's antimeridian wrap
## is settled in to_geo() — RFC 7946 mode would re-split it on the way out.
WRITER_OPTS <- c("COORDINATE_PRECISION=9", "RFC7946=NO")
DESCRIPTION <- sprintf("%s - the NDMC/FSA LFP determination boundaries, AlbersUSA composite in a 10-degree dummy box. Unclipped, as delivered under FOIA 2025-FSA-08431-F. NOT a geographic CRS. See js/projection.js in lfp-explorer.", SFSA_SPACE)
CLIP        <- "--clip-bounding-box=-5.02,-3.06,5.02,3.06"

if (SPACE == "geo") {
  ## Ground resolution, not zoom number: Web Mercator at z13 with
  ## --full-detail=13 quantises to 0.597 m at the equator, the worst case
  ## anywhere this archive reaches, against dummy z15's 0.720 m of CONUS
  ## ground. R/geo-space.R marks GEO_MAXZOOM a hypothesis until the calibration
  ## run measures it, so it is read from there rather than restated here — a
  ## number that may move must not have two homes.
  MAXZOOM <- GEO_MAXZOOM

  ## The geo family drops nothing anywhere, and here that is a distinction
  ## without a difference: this release carries 50 states, DC and Puerto Rico
  ## and no other territory, so both spaces see the same 3,221 counties and
  ## N_EXPECTED gates both. Stated anyway, because the guard above reads as a
  ## dummy-space limitation and only one of the two spaces has it.
  DROP_STATES <- character(0)

  WRITER_OPTS <- c("COORDINATE_PRECISION=7", "RFC7946=NO")
  DESCRIPTION <- sprintf("%s - true-position EPSG:4326, antimeridian-wrapped. The NDMC/FSA LFP determination boundaries, unclipped, as delivered under FOIA 2025-FSA-08431-F. Renders on standard maps including globe.", GEO_SPACE)

  ## No clip box. The dummy one is belt and braces against a mis-shift, framed
  ## on a layout this space does not have; the guard here is
  ## assert_geo_envelope() inside to_geo(), which stops the build rather than
  ## quietly cutting geometry off the edge of a box.
  CLIP <- character(0)
}

s3_bucket <- Sys.getenv("S3_BUCKET", unset = "sustainable-fsa")
s3_prefix <- Sys.getenv("S3_PREFIX", unset = "data-tiles")
publish   <- Sys.getenv("PUBLISH", unset = "1") == "1"

SOURCE <- Sys.getenv(
  "FSA_LFP_COUNTIES_PARQUET",
  unset = "https://data.sustainable-fsa.com/fsa-lfp-counties/fsa-lfp-counties.parquet")

dir.create("build", showWarnings = FALSE)
dir.create("tiles", showWarnings = FALSE)

states <- tigris::states(cb = TRUE, year = STATE_NAME_YEAR,
                         progress_bar = FALSE) |>
  sf::st_drop_geometry() |>
  dplyr::select(stfips = STATEFP, state = NAME) |>
  dplyr::arrange(stfips)

## ── Read ─────────────────────────────────────────────────────────────────────
## ALREADY IN ESRI:102003, true position — the NDMC ships it in USA Contiguous
## Albers with Alaska, Hawaii and Puerto Rico where they really are, which is
## exactly what albers_usa_shift() wants as input. Label the WKB with that CRS
## rather than transforming into it: st_transform() to the CRS a geometry is
## already in is a no-op in sf, but only if the two CRS objects compare equal,
## and constructing it here makes them equal by definition.
message("reading ", SOURCE)
p <- arrow::read_parquet(SOURCE)
g <- sf::st_as_sfc(structure(p$geometry, class = "WKB"))
sf::st_crs(g) <- "ESRI:102003"

## `CountyName` is the LSAD form — "Autauga County", "Bethel Census Area",
## "Adjuntas Municipio". Carried verbatim, unlike the bare names in the dd17/
## dd22 and Census tilesets, because it is the label the determination records
## themselves carry and because stripping the suffix by rule turns "Carson City"
## into "Carson" and "District of Columbia" into "District of".
x <- sf::st_sf(
  id       = as.character(p$CountyFIPS),
  stfips   = as.character(p$StateFIPS),
  county   = as.character(p$CountyName),
  geometry = g
) |>
  dplyr::filter(!stfips %in% DROP_STATES) |>
  dplyr::left_join(states, by = dplyr::join_by(stfips))
message("  counties: ", nrow(x))

if (nrow(x) != N_EXPECTED)
  stop("expected ", N_EXPECTED, " counties, got ", nrow(x),
       " — the FOIA release changed", call. = FALSE)
if (anyNA(x$state))
  stop("no state name for FIPS ",
       paste(sort(unique(x$stfips[is.na(x$state)])), collapse = ", "),
       " — tigris ", STATE_NAME_YEAR, " does not carry it", call. = FALSE)
stopifnot(!anyDuplicated(x$id), all(sf::st_is_valid(x)))

## ── Into the output space ────────────────────────────────────────────────────
if (SPACE == "geo") {
  ## One call, and deliberately not the dummy pipeline with a flag: there is no
  ## inset layout to classify into, no shear, nothing to relabel afterwards.
  ## ESRI:102003 in, true EPSG:4326 out, with the antimeridian wrap, the
  ## equal-area assert across it and the envelope gate all inside. to_geo()
  ## returns MULTIPOLYGON throughout — do not add a cast or an st_make_valid()
  ## here, both already ran in there.
  x <- to_geo(x)
  bb <- sf::st_bbox(x)
  message(sprintf("  geo bbox: %.6f %.6f %.6f %.6f", bb$xmin, bb$ymin, bb$xmax, bb$ymax))
} else {
  ## Classified by state FIPS, which the data carries — see albers_usa_shift()'s
  ## note on why geometric classification needs exploded POLYGONs. The cast is
  ## load-bearing: the Hawaii bbox clip inside the shift drops some counties to
  ## POLYGON while the rest stay MULTIPOLYGON, and a mixed column is an
  ## sfc_GEOMETRY that st_coordinates() has no method for.
  x <- albers_usa_shift(x, state_fips = x$stfips) |>
    sf::st_make_valid() |>
    sf::st_cast("MULTIPOLYGON")
  x <- to_dummy(as_5070(x))
  assert_dummy_bounds(x)
  ## Label the dummy degrees EPSG:4326 for the writers. They are not lng/lat; see
  ## counties.R for why the lie stops at this boundary.
  sf::st_crs(x) <- 4326
  bb <- sf::st_bbox(x)
  message(sprintf("  dummy bbox: %.6f %.6f %.6f %.6f", bb$xmin, bb$ymin, bb$xmax, bb$ymax))
}

## ── Layer 1: the counties ────────────────────────────────────────────────────
## WRITER_OPTS is per space; the configuration block carries why the precision
## is stated rather than inherited from the driver.
f_counties <- file.path("build", sprintf("fsa-lfp-counties%s.geojsonl", SUFFIX))
x |>
  dplyr::select(id, state, county) |>
  sf::st_write(f_counties, driver = "GeoJSONSeq", delete_dsn = TRUE, quiet = TRUE,
               layer_options = WRITER_OPTS)
nv <- nrow(sf::st_coordinates(x))
message(sprintf("  vertices: %s   geojsonl %.0f MB", format(nv, big.mark = ","),
                file.size(f_counties) / 1048576))

## ── Layer 2: the state mesh ──────────────────────────────────────────────────
## Precomputed, because there is no mesh operation in a vector tile — the kit
## derives this client-side with topojson.mesh() today and MVT has no
## equivalent.
f_states <- file.path("build", sprintf("fsa-lfp-states%s.geojsonl", SUFFIX))
states_g <- x |>
  dplyr::group_by(stfips) |>
  dplyr::summarise(.groups = "drop") |>
  sf::st_make_valid()
rmapshaper::ms_innerlines(states_g) |>
  sf::st_write(f_states, driver = "GeoJSONSeq", delete_dsn = TRUE, quiet = TRUE,
               layer_options = WRITER_OPTS)

## ── The national outline ─────────────────────────────────────────────────────
## R/outline.R carries the rationale: these counties are not edge-matched, so
## the union leaves 491 pinholes where neighbours fail to meet, and every one
## would punch a hole through the layer this outline exists to clip.
## The pinhole threshold is in square metres, so the measure is the space's:
## the default reads planar deg2 and scales by DUMMY$deg_m, which on real
## degrees would call a ring at 60 N the same size as one at the equator.
if (SPACE == "geo") {
  f_outline <- file.path("tiles", "fsa-lfp-counties-geo-outline.geojson")
  write_outline(dissolve_outline(x, ring_m2 = geo_ring_m2), f_outline)
} else {
  f_outline <- file.path("tiles", "fsa-lfp-counties-outline-dummy.geojson")
  write_outline(dissolve_outline(x), f_outline)
}

## ── The index sidecar ────────────────────────────────────────────────────────
## Same schema as the dd17/dd22 sidecars, and a hard requirement for the same
## reason: queryRenderedFeatures() returns only what is rendered, clipped and
## simplified for the zoom, so tiles alone cannot supply counties.index,
## counties.names or countyCentroid().
if (SPACE == "geo") {
  ## WRAPPED bboxes, and the difference is not cosmetic. A feature with parts on
  ## both sides of the antimeridian has a plain st_bbox() that is arithmetically
  ## right and 359 degrees wide instead of 21, which every fitBounds() reads as
  ## the whole Pacific. wrapped_bboxes() counts the east-hemisphere parts at
  ## lon - 360 instead, so an x0 below -180 is this space's convention rather
  ## than a bug; R/geo-space.R's header is the full account. This source
  ## exercises it: Aleutians West (02016) reaches 179.788 E and 179.133 W, and
  ## its published box is x0 -187.551758 to x1 -166.035141 — 21.5 degrees wide
  ## rather than 359.
  bxs <- wrapped_bboxes(x)
  idx <- list(
    schema  = jsonlite::unbox("sfsa-county-index/1"),
    space   = jsonlite::unbox(GEO_SPACE),
    ## Additive, and not a restatement of `space`: the space token names a
    ## versioned contract — this CRS plus the wrapped-bbox convention plus the
    ## frame below — and an app that read only the CRS would get a
    ## dateline-straddling county wrong.
    crs     = jsonlite::unbox("EPSG:4326"),
    vintage = jsonlite::unbox("fsa-lfp"),
    n       = jsonlite::unbox(nrow(x)),
    ## MEASURED, and from the same wrapped measure the x0/x1 columns publish, so
    ## it contains every county box by construction. It is the extent and not
    ## the camera: frame_bounds is the camera, frozen so that a ?lng/?lat/?zoom
    ## means the same thing every session.
    bounds  = round(c(min(bxs$x0), min(bxs$y0), max(bxs$x1), max(bxs$y1)), 6),
    frame_bounds = as.numeric(GEO_FRAME[c("xmin", "ymin", "xmax", "ymax")]),
    tiles   = list(
      url      = jsonlite::unbox(sprintf("fsa-lfp-counties%s.pmtiles", SUFFIX)),
      minzoom  = jsonlite::unbox(0L),
      maxzoom  = jsonlite::unbox(MAXZOOM),
      extent   = jsonlite::unbox(8192L),
      layers   = list(counties = jsonlite::unbox("counties"),
                      states   = jsonlite::unbox("states"))
    ),
    counties     = x$id,
    county_names = x$county,
    state_names  = x$state,
    ## 6 dp of real degrees is 11 cm.
    x0 = round(bxs$x0, 6), y0 = round(bxs$y0, 6),
    x1 = round(bxs$x1, 6), y1 = round(bxs$y1, 6)
  )
} else {
  bxs <- do.call(rbind, lapply(sf::st_geometry(x), function(gi) as.numeric(sf::st_bbox(gi))))
  idx <- list(
    schema  = jsonlite::unbox("sfsa-county-index/1"),
    space   = jsonlite::unbox(SFSA_SPACE),
    vintage = jsonlite::unbox("fsa-lfp"),
    n       = jsonlite::unbox(nrow(x)),
    bounds  = as.numeric(DUMMY$bounds[c("xmin", "ymin", "xmax", "ymax")]),
    tiles   = list(
      url      = jsonlite::unbox("fsa-lfp-counties.pmtiles"),
      minzoom  = jsonlite::unbox(0L),
      maxzoom  = jsonlite::unbox(MAXZOOM),
      extent   = jsonlite::unbox(8192L),
      layers   = list(counties = jsonlite::unbox("counties"),
                      states   = jsonlite::unbox("states"))
    ),
    counties     = x$id,
    county_names = x$county,
    state_names  = x$state,
    x0 = round(bxs[, 1], 6), y0 = round(bxs[, 2], 6),
    x1 = round(bxs[, 3], 6), y1 = round(bxs[, 4], 6)
  )
}
f_index <- file.path("tiles", sprintf("fsa-lfp-counties%s-index.json", SUFFIX))
jsonlite::write_json(idx, f_index, auto_unbox = FALSE, digits = NA)
message("  index: ", nrow(x), " counties, ", round(file.size(f_index) / 1024), " KB")

## ── Tiles ────────────────────────────────────────────────────────────────────
## Flags are counties.R's, verbatim; its comment block is the rationale. ONE
## block for both spaces, not a copy each: only the maxzoom, the description and
## the clip box differ, and those come from the configuration block. NEVER
## --use-attribute-for-id: MVT feature ids are uint64 and "01001" would become
## 1001. The id stays a STRING PROPERTY and promoteId lifts it.
f_pmtiles <- file.path("tiles", sprintf("fsa-lfp-counties%s.pmtiles", SUFFIX))
args <- c(
  sprintf("--output=%s", f_pmtiles), "--force",
  sprintf("--name=FSA LFP counties%s", SUFFIX),
  sprintf("--description=%s", DESCRIPTION),
  "--attribution=USDA Farm Service Agency (FOIA 2025-FSA-08431-F); National Drought Mitigation Center; Sustainable FSA archive",
  sprintf("--named-layer=counties:%s", f_counties),
  sprintf("--named-layer=states:%s", f_states),
  "--minimum-zoom=0", sprintf("--maximum-zoom=%d", MAXZOOM),
  sprintf("--full-detail=%d", DETAIL),
  sprintf("--simplification=%s", format(SIMPLIFY)),
  "--simplify-only-low-zooms", "--no-simplification-of-shared-nodes",
  "--no-tiny-polygon-reduction", "--no-tile-size-limit", "--no-feature-limit",
  "--include=id", "--include=state", "--include=county",
  CLIP,
  "--no-tile-stats", "--read-parallel"
)
message("  tippecanoe -> ", f_pmtiles)
st <- system2("tippecanoe", shQuote(args))
if (st != 0) stop("tippecanoe failed (exit ", st, ")", call. = FALSE)
message(sprintf("  %s: %.1f MB", basename(f_pmtiles), file.size(f_pmtiles) / 1048576))

## ── Publish ──────────────────────────────────────────────────────────────────
if (publish) {
  put_artifact(s3_bucket, s3_prefix, f_pmtiles)
  put_artifact(s3_bucket, s3_prefix, f_index)
  put_artifact(s3_bucket, s3_prefix, f_outline)

  ## Every sibling archive ends here, and none of this repo's scripts did.
  ## _manifest.txt is what puts a prefix in the CDN listing: without it these
  ## tiles are published but undiscoverable. It lists the whole prefix, so
  ## whichever script runs last leaves a complete one.
  s3_write_manifest(bucket = s3_bucket, prefix = s3_prefix)
  ## Filenames are stable across rebuilds, so an invalidation is what makes a
  ## republish visible now rather than after R/publish.R's max-age. The wildcard
  ## counts as one invalidation path, against 54 for a per-file list.
  cf_invalidate(c(paste0("/", s3_prefix, "/tiles/*"),
                  paste0("/", s3_prefix, "/_manifest.txt")))
  message("\npublished to s3://", s3_bucket, "/", s3_prefix)
} else {
  message("\nPUBLISH=0 — built locally, nothing uploaded")
}
