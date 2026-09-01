#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · counties.R
##
## Build the FSA county composite as vector tiles, one PMTiles per boundary
## vintage, in either output space — sfsa-albers-usa/1, the dummy composite the
## LFP Explorer renders, or sfsa-geographic/1, true EPSG:4326 for any standard
## map. SPACE picks; see the configuration block.
##
## This is the same composite the boundary archives publish as TopoJSON, with
## one deliberate difference: NO ms_simplify(). The archives simplify at
## keep = 0.008 because they ship a single file that has to be small enough to
## fetch on page load; tiles do their own zoom-appropriate simplification, so
## the maxzoom level can carry the source's full detail. That is the whole point
## of this repo.
##
## Everything else follows the archives step for step — the same territory
## filter, the same cb-5m clip mask, the same AlbersUSA layout — so the two
## register. Verified: with the clip applied, centroid agreement with the
## published composite is 6 m median for Alaska, 1 m for Hawaii and 175 m for
## Puerto Rico, the residual being the archives' own simplification amplified by
## Puerto Rico's 2.5x inset scale.
##
##   Rscript counties.R                           # both vintages, publish
##   VINTAGES=dd22 PUBLISH=0 Rscript counties.R   # one vintage, local only
##   SPACE=geo PUBLISH=0 Rscript counties.R       # the geographic family
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
MAXZOOM <- 15L      # where full source detail lands
DETAIL  <- 13L      # tile extent 2^13 = 8192, MapLibre's own internal EXTENT
SIMPLIFY <- 0.5     # half tippecanoe's default tolerance at the low zooms

## DETAIL APPLIES AT EVERY ZOOM, via --full-detail. An earlier version used
## --extra-detail, which lifts the extent to 8192 at MAXZOOM ONLY and leaves
## every lower zoom at the 4096 default. Tippecanoe then simplifies each of
## those to about one tile unit — which is ~0.125 CSS px, but ~0.25 px on a 2x
## display, and every modern screen is 2x. The result was visible faceting from
## z6 to z14 while maxzoom was perfect, which reads exactly like "the tiles are
## low resolution". Measured on the densest county (Somerset, ME; 28,381 source
## vertices), --full-detail=13 with SIMPLIFY 0.5 carries 1.4-1.5x more vertices
## at every intermediate zoom for ~7% more bytes.

## Territories the archives drop: AS, VI, and the four Pacific FIPS.
DROP_STATES <- c("60", "78", "14", "52", "69", "66")

## The clip mask year is PINNED. The archives leave tigris::counties() without a
## year=, so their coastline floats with the tigris release — in archives whose
## whole point is a frozen vintage. Ours does not float.
##
## THE CLIP IS NOT PER SPACE. Both families are cut at the same cb 500k 2024
## waterline, because the reason for it is the source and not the projection:
## the FSA composite's own extent reaches into open water. The mask carries all
## thirteen territory counties, so it is not what decides whether they survive.
MASK_YEAR <- 2024L

## ── The output space ─────────────────────────────────────────────────────────
## SPACE picks which family this invocation builds, and one invocation builds
## exactly one. The two share the source, the clip, the flag block and the
## sidecar schema and nothing else: sfsa-albers-usa/1 is a frozen inset
## composite in a 10-degree dummy box, sfsa-geographic/1 is st_transform(4326).
## Every artifact name goes through space_suffix(), which is what keeps the two
## families from colliding on a filename. An unrecognised value stops there
## rather than falling through to dummy, which would rebuild the published
## family under a geo run's flags.
SPACE  <- Sys.getenv("SPACE", unset = "dummy")
SUFFIX <- space_suffix(SPACE)

## The values that differ between the two, stated here rather than at each use
## so the writers, the sidecar and the tippecanoe block stay single copies.
##
## COORDINATE_PRECISION is explicit because GDAL's GeoJSON driver defaults to 7
## and neither space should inherit a default. 9 dp of DUMMY degrees is 0.5 mm
## (the driver's own 7 would be 5 cm — fine here, but by luck); 7 dp of real
## degrees is 1.1 cm, finer than the source and two digits per ordinate cheaper
## across a ~190 MB intermediate. RFC7946=NO in both: dummy degrees are not
## lng/lat and must not be normalised as such, and the geo family's
## antimeridian wrap is settled in to_geo() — RFC 7946 mode would re-split it
## on the way out.
WRITER_OPTS <- c("COORDINATE_PRECISION=9", "RFC7946=NO")
DESCRIPTION <- sprintf("%s - AlbersUSA composite in a 10-degree dummy box. NOT a geographic CRS. See js/projection.js in lfp-explorer.", SFSA_SPACE)
CLIP        <- "--clip-bounding-box=-5.02,-3.06,5.02,3.06"

if (SPACE == "geo") {
  ## Ground resolution, not zoom number: Web Mercator at z13 with
  ## --full-detail=13 quantises to 0.597 m at the equator, the worst case
  ## anywhere this archive reaches, against dummy z15's 0.720 m of CONUS
  ## ground. R/geo-space.R marks GEO_MAXZOOM a hypothesis until the calibration
  ## run measures it, so it is read from there rather than restated here — a
  ## number that may move must not have two homes.
  MAXZOOM <- GEO_MAXZOOM

  ## THE GEO FAMILY DROPS NOTHING, and the six FIPS above are not evidence that
  ## it should. Dummy-Albers has nowhere to put Guam or American Samoa; true
  ## EPSG:4326 has exactly where. Note that two of those codes never matched
  ## anything even in the dummy build: this composite's territory rows carry
  ## real FIPSST 60/66/69/78, but their ids are LEGACY — Guam 14001, the USVI
  ## 52001/52003/52005, the Marianas 69085/69100/69110/69120, and five American
  ## Samoa rows sharing 60001 that the dissolve by id makes one feature. The
  ## filter reads stfips, where "14" and "52" are dead entries. The ids are what
  ## the sidecar publishes, so they are what a coverage gate has to expect.
  DROP_STATES <- character(0)

  WRITER_OPTS <- c("COORDINATE_PRECISION=7", "RFC7946=NO")
  DESCRIPTION <- sprintf("%s - true-position EPSG:4326, antimeridian-wrapped. Renders on standard maps including globe.", GEO_SPACE)

  ## No clip box. The dummy one is belt and braces against a mis-shift, framed
  ## on a layout this space does not have; the guard here is
  ## assert_geo_envelope() inside to_geo(), which stops the build rather than
  ## quietly cutting geometry off the edge of a box. A geo box would have to be
  ## the whole world anyway, because Guam and American Samoa are in.
  CLIP <- character(0)
}

s3_bucket <- Sys.getenv("S3_BUCKET", unset = "sustainable-fsa")
s3_prefix <- Sys.getenv("S3_PREFIX", unset = "data-tiles")
publish   <- Sys.getenv("PUBLISH", unset = "1") == "1"
vintages  <- strsplit(Sys.getenv("VINTAGES", unset = "dd17,dd22"), "[, ]+")[[1]]

SOURCE <- function(v) {
  Sys.getenv(paste0(toupper(v), "_PARQUET"),
             sprintf("https://sustainable-fsa.com/fsa-counties-%s/fsa-counties-%s.parquet", v, v))
}

dir.create("build", showWarnings = FALSE)
dir.create("tiles", showWarnings = FALSE)

## ── The clip mask, built once ────────────────────────────────────────────────
message("clip mask: cb 5m counties, year ", MASK_YEAR)
## tigris returns NAD83 (EPSG:4269); the boundary parquet is WGS84. Align them
## explicitly rather than relying on either default.
mask <- tigris::counties(cb = TRUE, resolution = "500k", year = MASK_YEAR,
                         progress_bar = FALSE) |>
  sf::st_transform(4326) |>
  sf::st_union() |>
  sf::st_make_valid()

## ── One vintage ──────────────────────────────────────────────────────────────
build_vintage <- function(v) {
  message("\n=== ", v, " ===")
  p <- arrow::read_parquet(SOURCE(v))
  g <- sf::st_as_sfc(structure(p$geometry, class = "WKB"))
  sf::st_crs(g) <- 4326

  x <- sf::st_sf(
    id      = as.character(p$FSA_STCOU),
    state   = as.character(p$STATENAME),
    county  = as.character(p$COUNTYNAME),
    stfips  = as.character(p$FIPSST),
    geometry = g
  ) |>
    dplyr::filter(!stfips %in% DROP_STATES) |>
    sf::st_make_valid()
  message("  features in: ", nrow(x))

  ## Clip to the same coastline the archives use. Without this the composite's
  ## edge is the FSA boundary file's own extent, which reaches into open water
  ## and would not register with the published TopoJSON.
  x <- suppressWarnings(sf::st_intersection(x, mask)) |> sf::st_make_valid()

  ## One feature per FSA county. Group by id ALONE — grouping by the name columns
  ## too leaves a county split whenever its state/county strings differ between
  ## source rows, which they do for 125 of them, and the index then carries
  ## duplicate ids. The archives dissolve by id for the same reason, which is why
  ## their composite has 3,106 features and the raw file has 3,232.
  x <- x |>
    dplyr::group_by(id) |>
    dplyr::summarise(state  = dplyr::first(state),
                     county = dplyr::first(county),
                     stfips = dplyr::first(stfips),
                     .groups = "drop") |>
    sf::st_make_valid()
  stopifnot(!anyDuplicated(x$id))
  message("  counties: ", nrow(x))

  ## ── Into the output space ─────────────────────────────────────────────────
  if (SPACE == "geo") {
    ## One call, and deliberately not the dummy pipeline with a flag: there is
    ## no inset layout to classify into, no shear, nothing to relabel
    ## afterwards. The source is already true-position EPSG:4326, so to_geo()
    ## reduces to the antimeridian wrap, the equal-area assert across it and the
    ## envelope gate. It returns MULTIPOLYGON throughout — do not add a cast or
    ## an st_make_valid() here, both already ran in there.
    x <- to_geo(x)
    bb <- sf::st_bbox(x)
    message(sprintf("  geo bbox: %.6f %.6f %.6f %.6f", bb$xmin, bb$ymin, bb$xmax, bb$ymax))
  } else {
    ## AlbersUSA layout, then into the dummy space. Classified by state FIPS, which
    ## is deterministic — see albers_usa_shift()'s note on why geometric
    ## classification needs exploded POLYGONs.
    x <- albers_usa_shift(x, state_fips = x$stfips) |> sf::st_make_valid()
    x <- to_dummy(as_5070(x))
    assert_dummy_bounds(x)
    ## Label the dummy degrees EPSG:4326 for the writers. They are not lng/lat and
    ## the space is not geographic — but every downstream consumer treats them as
    ## if they were: GDAL's GeoJSON driver refuses to write a layer it cannot
    ## relate to WGS84, tippecanoe reads lng/lat, and MapLibre renders them through
    ## Mercator. The lie stops at this boundary; nothing reprojects them.
    sf::st_crs(x) <- 4326
    bb <- sf::st_bbox(x)
    message(sprintf("  dummy bbox: %.6f %.6f %.6f %.6f", bb$xmin, bb$ymin, bb$xmax, bb$ymax))
  }

  ## ── Layer 1: the counties ─────────────────────────────────────────────────
  ## WRITER_OPTS is per space; the configuration block carries why the precision
  ## is stated rather than inherited from the driver.
  f_counties <- file.path("build", sprintf("%s%s-counties.geojsonl", v, SUFFIX))
  x |>
    dplyr::select(id, state, county) |>
    sf::st_write(f_counties, driver = "GeoJSONSeq", delete_dsn = TRUE, quiet = TRUE,
                 layer_options = WRITER_OPTS)

  ## ── Layer 2: the state mesh ───────────────────────────────────────────────
  ## The kit currently derives this client-side with topojson.mesh(), which has
  ## no MVT equivalent — there is no mesh operation in a tile. So precompute the
  ## interior lines. ms_innerlines() on 50-odd dissolved states is cheap even at
  ## full resolution.
  f_states <- file.path("build", sprintf("%s%s-states.geojsonl", v, SUFFIX))
  states <- x |>
    dplyr::mutate(st = substr(id, 1, 2)) |>
    dplyr::group_by(st) |>
    dplyr::summarise(.groups = "drop") |>
    sf::st_make_valid()
  rmapshaper::ms_innerlines(states) |>
    sf::st_write(f_states, driver = "GeoJSONSeq", delete_dsn = TRUE, quiet = TRUE,
                 layer_options = WRITER_OPTS)

  ## ── The national outline ──────────────────────────────────────────────────
  ## Published because the USDM pipeline clips against it: the NDMC's own
  ## coastline is ~1:2,000,000 and would spill past the counties otherwise.
  ##
  ## The two paths differ by more than a filename, and the dummy one is the odd
  ## one out: a bare st_union() with no pinhole guard, which agrees with
  ## dissolve_outline() only because dd17/dd22 happen to carry no pinholes. That
  ## is luck, not construction — the open thread says adopt the helper the next
  ## time these are rebuilt, and rebuilding them is a 1.4 GB republish, so it
  ## stays deferred. The geo path is new and starts on the helper, with the
  ## square-metre measure its space needs: the default reads planar deg2 and
  ## scales by DUMMY$deg_m, which on real degrees would call a ring at 60 N the
  ## same size as one at the equator.
  if (SPACE == "geo") {
    f_outline <- file.path("tiles", sprintf("fsa-counties-%s-geo-outline.geojson", v))
    write_outline(dissolve_outline(x, ring_m2 = geo_ring_m2), f_outline)
  } else {
    f_outline <- file.path("tiles", sprintf("fsa-counties-%s-outline-dummy.geojson", v))
    sf::st_union(x) |>
      sf::st_sf(geometry = _) |>
      sf::st_write(f_outline, driver = "GeoJSON", delete_dsn = TRUE, quiet = TRUE,
                   layer_options = c("COORDINATE_PRECISION=9", "RFC7946=NO"))
  }

  ## ── The index sidecar ─────────────────────────────────────────────────────
  ## Vector tiles cannot supply counties.index, counties.names or
  ## countyCentroid(): queryRenderedFeatures returns only what is rendered,
  ## clipped and simplified for the zoom. The bbox midpoint here is exactly what
  ## the kit's countyCentroid() computes today, so behaviour is preserved.
  if (SPACE == "geo") {
    ## WRAPPED bboxes, and the difference is not cosmetic. Aleutians West has
    ## parts on both sides of the antimeridian, so its plain st_bbox() is
    ## [-179.15, 179.78] — arithmetically right, and 359 degrees wide instead of
    ## 21, which every fitBounds() reads as the whole Pacific. wrapped_bboxes()
    ## counts the east-hemisphere parts at lon - 360 instead, so an x0 below
    ## -180 is this space's convention rather than a bug. R/geo-space.R's header
    ## is the full account.
    bxs <- wrapped_bboxes(x)
    idx <- list(
      schema  = jsonlite::unbox("sfsa-county-index/1"),
      space   = jsonlite::unbox(GEO_SPACE),
      ## Additive, and not a restatement of `space`: the space token names a
      ## versioned contract — this CRS plus the wrapped-bbox convention plus the
      ## frame below — and an app that read only the CRS would get the Aleutians
      ## wrong.
      crs     = jsonlite::unbox("EPSG:4326"),
      vintage = jsonlite::unbox(v),
      n       = jsonlite::unbox(nrow(x)),
      ## MEASURED, and from the same wrapped measure the x0/x1 columns publish,
      ## so it contains every county box by construction. st_bbox() of the whole
      ## set would be the full [-180, 180] and say nothing. It is near-world
      ## once Guam and American Samoa are in — which in this space they are — so
      ## it is the extent and not the camera: frame_bounds is the camera, frozen
      ## so a ?lng/?lat/?zoom means the same thing every session.
      bounds  = round(c(min(bxs$x0), min(bxs$y0), max(bxs$x1), max(bxs$y1)), 6),
      frame_bounds = as.numeric(GEO_FRAME[c("xmin", "ymin", "xmax", "ymax")]),
      tiles   = list(
        url      = jsonlite::unbox(sprintf("fsa-counties-%s%s.pmtiles", v, SUFFIX)),
        minzoom  = jsonlite::unbox(0L),
        maxzoom  = jsonlite::unbox(MAXZOOM),
        extent   = jsonlite::unbox(8192L),
        layers   = list(counties = jsonlite::unbox("counties"),
                        states   = jsonlite::unbox("states"))
      ),
      counties     = x$id,
      county_names = x$county,
      state_names  = x$state,
      ## Index-aligned bbox columns, 6 dp — 11 cm of real degrees.
      x0 = round(bxs$x0, 6), y0 = round(bxs$y0, 6),
      x1 = round(bxs$x1, 6), y1 = round(bxs$y1, 6)
    )
  } else {
    bxs <- do.call(rbind, lapply(sf::st_geometry(x), function(gi) as.numeric(sf::st_bbox(gi))))
    idx <- list(
      schema  = jsonlite::unbox("sfsa-county-index/1"),
      space   = jsonlite::unbox(SFSA_SPACE),
      vintage = jsonlite::unbox(v),
      n       = jsonlite::unbox(nrow(x)),
      bounds  = as.numeric(DUMMY$bounds[c("xmin", "ymin", "xmax", "ymax")]),
      tiles   = list(
        url      = jsonlite::unbox(sprintf("fsa-counties-%s.pmtiles", v)),
        minzoom  = jsonlite::unbox(0L),
        maxzoom  = jsonlite::unbox(MAXZOOM),
        extent   = jsonlite::unbox(8192L),
        layers   = list(counties = jsonlite::unbox("counties"),
                        states   = jsonlite::unbox("states"))
      ),
      counties     = x$id,
      county_names = x$county,
      state_names  = x$state,
      ## Index-aligned bbox columns, 6 dp (0.54 m). Parallel arrays rather than
      ## objects, matching the house payload convention.
      x0 = round(bxs[, 1], 6), y0 = round(bxs[, 2], 6),
      x1 = round(bxs[, 3], 6), y1 = round(bxs[, 4], 6)
    )
  }
  f_index <- file.path("tiles", sprintf("fsa-counties-%s%s-index.json", v, SUFFIX))
  jsonlite::write_json(idx, f_index, auto_unbox = FALSE, digits = NA)
  message("  index: ", nrow(x), " counties, ",
          round(file.size(f_index) / 1024), " KB")

  ## ── Tiles ─────────────────────────────────────────────────────────────────
  ## Flag rationale, in one place:
  ##   --full-detail=13             extent 8192 at EVERY zoom, not just maxzoom
  ##   --simplification=0.5         half the default tolerance below maxzoom
  ##   --simplify-only-low-zooms    THE lossless flag: no simplification at maxzoom
  ##   --no-simplification-of-shared-nodes  or adjacent counties crack apart at low zoom
  ##   --no-tiny-polygon-reduction  or sub-pixel islands become area-equivalent squares
  ##   --no-tile-size-limit/--no-feature-limit  a dropped county is a silent hole
  ##   --clip-bounding-box          belt and braces against a mis-shift; DUMMY
  ##                                ONLY, CLIP being empty in geo
  ## ONE BLOCK FOR BOTH SPACES, not a copy each: only the maxzoom, the
  ## description and the clip box differ, and those come from the configuration
  ## block. NEVER --use-attribute-for-id / -ai / -aI: MVT feature ids are
  ## uint64, so "01001" would become 1001. The id stays a STRING PROPERTY;
  ## promoteId lifts it and filters read ['get','id'].
  f_pmtiles <- file.path("tiles", sprintf("fsa-counties-%s%s.pmtiles", v, SUFFIX))
  args <- c(
    sprintf("--output=%s", f_pmtiles), "--force",
    sprintf("--name=FSA counties %s%s", v, SUFFIX),
    sprintf("--description=%s", DESCRIPTION),
    "--attribution=USDA Farm Service Agency; Sustainable FSA archive",
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
  ## shQuote every argument: system2() builds a shell command line, so an
  ## unquoted --name=FSA counties dd22 splits into three words and tippecanoe
  ## dies with "counties: No such file or directory".
  st <- system2("tippecanoe", shQuote(args))
  if (st != 0) stop("tippecanoe failed for ", v, " (exit ", st, ")", call. = FALSE)
  message(sprintf("  %s: %.1f MB", basename(f_pmtiles), file.size(f_pmtiles) / 1048576))

  list(pmtiles = f_pmtiles, index = f_index, outline = f_outline, n = nrow(x))
}

out <- lapply(vintages, build_vintage)

## ── Publish ──────────────────────────────────────────────────────────────────
## PMTiles are served with Content-Type application/octet-stream and NEVER a
## Content-Encoding: the header records tile_compression = gzip and the client
## shim decompresses, while a Content-Encoding would break Range semantics.
if (publish) {
  for (o in out) {
    put_artifact(s3_bucket, s3_prefix, o$pmtiles)
    put_artifact(s3_bucket, s3_prefix, o$index)
    put_artifact(s3_bucket, s3_prefix, o$outline)
  }

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
  message("\npublished ", length(out), " vintage(s) to s3://", s3_bucket, "/", s3_prefix)
} else {
  message("\nPUBLISH=0 — built locally, nothing uploaded")
}
