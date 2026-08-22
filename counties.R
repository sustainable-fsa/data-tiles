#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · counties.R
##
## Build the FSA county composite as vector tiles, one PMTiles per boundary
## vintage, in the sfsa-albers-usa/1 dummy space.
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
##   Rscript counties.R                  # both vintages, publish
##   VINTAGES=dd22 PUBLISH=0 Rscript counties.R   # one vintage, local only
## =============================================================================

suppressPackageStartupMessages({
  library(sf); library(arrow); library(dplyr); library(tigris)
  library(rmapshaper); library(jsonlite)
})
source("R/dummy-space.R")
source("R/s3-archive.R")
sf::sf_use_s2(FALSE)
options(tigris_use_cache = TRUE)

## ── Configuration ────────────────────────────────────────────────────────────
MAXZOOM <- 15L      # 0.72 m at extra-detail 13; pixel-exact to display zoom 19
DETAIL  <- 13L      # MapLibre's internal EXTENT is 8192; above this is rounded away

## Territories the archives drop: AS, VI, and the four Pacific FIPS.
DROP_STATES <- c("60", "78", "14", "52", "69", "66")

## The clip mask year is PINNED. The archives leave tigris::counties() without a
## year=, so their coastline floats with the tigris release — in archives whose
## whole point is a frozen vintage. Ours does not float.
MASK_YEAR <- 2024L

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
mask <- tigris::counties(cb = TRUE, resolution = "5m", year = MASK_YEAR,
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

  ## ── Layer 1: the counties ─────────────────────────────────────────────────
  ## COORDINATE_PRECISION=9 is explicit: GDAL's GeoJSON writer defaults to 7,
  ## which happens to be fine here (1e-7 dummy degrees is 5 cm) but only by
  ## luck. RFC7946=NO because these are not real lng/lat and must not be
  ## normalised as such.
  f_counties <- file.path("build", sprintf("%s-counties.geojsonl", v))
  x |>
    dplyr::select(id, state, county) |>
    sf::st_write(f_counties, driver = "GeoJSONSeq", delete_dsn = TRUE, quiet = TRUE,
                 layer_options = c("COORDINATE_PRECISION=9", "RFC7946=NO"))

  ## ── Layer 2: the state mesh ───────────────────────────────────────────────
  ## The kit currently derives this client-side with topojson.mesh(), which has
  ## no MVT equivalent — there is no mesh operation in a tile. So precompute the
  ## interior lines. ms_innerlines() on 50-odd dissolved states is cheap even at
  ## full resolution.
  f_states <- file.path("build", sprintf("%s-states.geojsonl", v))
  states <- x |>
    dplyr::mutate(st = substr(id, 1, 2)) |>
    dplyr::group_by(st) |>
    dplyr::summarise(.groups = "drop") |>
    sf::st_make_valid()
  rmapshaper::ms_innerlines(states) |>
    sf::st_write(f_states, driver = "GeoJSONSeq", delete_dsn = TRUE, quiet = TRUE,
                 layer_options = c("COORDINATE_PRECISION=9", "RFC7946=NO"))

  ## ── The national outline ──────────────────────────────────────────────────
  ## Published because the USDM pipeline clips against it: the NDMC's own
  ## coastline is ~1:2,000,000 and would spill past the counties otherwise.
  f_outline <- file.path("tiles", sprintf("fsa-counties-%s-outline-dummy.geojson", v))
  sf::st_union(x) |>
    sf::st_sf(geometry = _) |>
    sf::st_write(f_outline, driver = "GeoJSON", delete_dsn = TRUE, quiet = TRUE,
                 layer_options = c("COORDINATE_PRECISION=9", "RFC7946=NO"))

  ## ── The index sidecar ─────────────────────────────────────────────────────
  ## Vector tiles cannot supply counties.index, counties.names or
  ## countyCentroid(): queryRenderedFeatures returns only what is rendered,
  ## clipped and simplified for the zoom. The bbox midpoint here is exactly what
  ## the kit's countyCentroid() computes today, so behaviour is preserved.
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
  f_index <- file.path("tiles", sprintf("fsa-counties-%s-index.json", v))
  jsonlite::write_json(idx, f_index, auto_unbox = FALSE, digits = NA)
  message("  index: ", nrow(x), " counties, ",
          round(file.size(f_index) / 1024), " KB")

  ## ── Tiles ─────────────────────────────────────────────────────────────────
  ## Flag rationale, in one place:
  ##   --extra-detail=13            extent 8192 at maxzoom; MapLibre rounds above
  ##   --simplify-only-low-zooms    THE lossless flag: no simplification at maxzoom
  ##   --no-simplification-of-shared-nodes  or adjacent counties crack apart at low zoom
  ##   --no-tiny-polygon-reduction  or sub-pixel islands become area-equivalent squares
  ##   --no-tile-size-limit/--no-feature-limit  a dropped county is a silent hole
  ##   --clip-bounding-box          belt and braces against a mis-shift
  ## NEVER --use-attribute-for-id / -ai / -aI: MVT feature ids are uint64, so
  ## "01001" would become 1001. The id stays a STRING PROPERTY; promoteId lifts
  ## it and filters read ['get','id'].
  f_pmtiles <- file.path("tiles", sprintf("fsa-counties-%s.pmtiles", v))
  args <- c(
    sprintf("--output=%s", f_pmtiles), "--force",
    sprintf("--name=FSA counties %s", v),
    sprintf("--description=%s - AlbersUSA composite in a 10-degree dummy box. NOT a geographic CRS. See js/projection.js in lfp-explorer.", SFSA_SPACE),
    "--attribution=USDA Farm Service Agency; Sustainable FSA archive",
    sprintf("--named-layer=counties:%s", f_counties),
    sprintf("--named-layer=states:%s", f_states),
    "--minimum-zoom=0", sprintf("--maximum-zoom=%d", MAXZOOM),
    sprintf("--extra-detail=%d", DETAIL),
    "--simplify-only-low-zooms", "--no-simplification-of-shared-nodes",
    "--no-tiny-polygon-reduction", "--no-tile-size-limit", "--no-feature-limit",
    "--include=id", "--include=state", "--include=county",
    "--clip-bounding-box=-5.02,-3.06,5.02,3.06",
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
    s3_put(bucket = s3_bucket,
           key = paste0(s3_prefix, "/tiles/", basename(o$pmtiles)),
           file = o$pmtiles,
           content_type = "application/octet-stream",
           cache_control = "public, max-age=31536000, immutable")
    s3_put(bucket = s3_bucket,
           key = paste0(s3_prefix, "/tiles/", basename(o$index)),
           file = o$index,
           content_type = "application/json",
           cache_control = "max-age=3600")
    s3_put(bucket = s3_bucket,
           key = paste0(s3_prefix, "/tiles/", basename(o$outline)),
           file = o$outline,
           content_type = "application/geo+json",
           cache_control = "max-age=3600")
  }
  message("\npublished ", length(out), " vintage(s) to s3://", s3_bucket, "/", s3_prefix)
} else {
  message("\nPUBLISH=0 — built locally, nothing uploaded")
}
