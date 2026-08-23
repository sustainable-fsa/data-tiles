#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · census.R
##
## Vintage-matched Census county boundaries as vector tiles, so a reader can see
## the actual boundaries the USDM county determinations were computed against.
##
## THE CLIP HAPPENS UPSTREAM NOW. sustainable-fsa/census-counties publishes two
## forms of every vintage: data/parquet/ is TIGER/Line as published — the legal
## boundary, and the analytical truth the determinations are computed against —
## and data/clipped/ is that same geometry cut at the SAME VINTAGE's cb 500k
## waterline, for display. This repo reads the clipped form and does nothing to
## it but project.
##
## tl does not stop at water: coastal counties and the Great Lakes states extend
## far offshore, correct as a legal boundary and wrong as a picture. Cutting it
## with a coastline from a different year produces a boundary belonging to
## neither, which is why the vintage match matters and why census-counties owns
## it — including the four years Census never published a cb file for (2000,
## 2009, 2011, 2012), which fall back to the nearest available one. That
## substitution arrives as a per-county `mask_year` column; it is read from the
## data here, never re-derived.
##
## WHAT THIS SCRIPT DELIBERATELY NO LONGER DOES: build a per-vintage mask,
## st_intersection() against it, st_collection_extract() the areal part back
## out, dissolve by id, or st_make_valid() around any of that. All of it is done
## upstream, where the clipped form is asserted valid under both s2 and GEOS at
## build time. Read, filter, project. That is the whole job.
##
##   VINTAGES=2020 PUBLISH=0 Rscript census.R
## =============================================================================

suppressPackageStartupMessages({
  library(sf); library(arrow); library(dplyr); library(tigris); library(jsonlite)
})
source("R/dummy-space.R")
source("R/s3-archive.R")
sf::sf_use_s2(FALSE)
options(tigris_use_cache = TRUE)

MAXZOOM  <- 15L
DETAIL   <- 13L
SIMPLIFY <- 0.5

## The vintages usdm-counties archives, and therefore the vintages a week of
## USDM data can be matched to. census-counties discovers these rather than
## hardcoding them; here they are the list to build, and a vintage that has not
## been published yet fails loudly on the fetch.
ALL_VINTAGES <- c(2000, 2009, 2010, 2011:2025)

## Territories the composite cannot place: dummy-Albers lays out CONUS, AK, HI
## and PR only. The archive carries these counties, so the filter is ours.
DROP_STATES <- c("60", "78", "14", "52", "69", "66")

## State NAMES only — no geometry — so this is a lookup table, not a boundary.
## Pinned anyway, for the same reason counties.R pins its mask year: an unpinned
## tigris call floats with the package release, and nothing in this repo should.
STATE_NAME_YEAR <- 2024L

CENSUS_COUNTIES <- Sys.getenv(
  "CENSUS_COUNTIES_URL",
  unset = "https://data.sustainable-fsa.com/census-counties")

CLIPPED <- function(y) Sys.getenv(
  paste0("CLIPPED_", y),
  sprintf("%s/data/clipped/%d-counties.parquet", CENSUS_COUNTIES, y))

s3_bucket <- Sys.getenv("S3_BUCKET", unset = "sustainable-fsa")
s3_prefix <- Sys.getenv("S3_PREFIX", unset = "data-tiles")
publish   <- Sys.getenv("PUBLISH", unset = "1") == "1"
vintages  <- as.integer(strsplit(Sys.getenv("VINTAGES",
                paste(ALL_VINTAGES, collapse = ",")), "[, ]+")[[1]])

dir.create("build", showWarnings = FALSE)
dir.create(file.path("build", "census"), showWarnings = FALSE, recursive = TRUE)
dir.create("tiles", showWarnings = FALSE)

## ── The source, cached ───────────────────────────────────────────────────────
## A clipped vintage is ~46 MB and there are eighteen of them; a full rebuild
## would pull 830 MB from the CDN every run. Cache under build/, which is
## gitignored and derived. CLIPPED_<year> may name a local file, in which case
## it is used where it sits.
source_for <- function(y) {
  u <- CLIPPED(y)
  if (file.exists(u)) return(u)
  f <- file.path("build", "census", sprintf("%d-counties.parquet", y))
  if (!file.exists(f)) {
    message("  fetching ", u)
    ok <- utils::download.file(u, f, mode = "wb", quiet = TRUE)
    if (!identical(ok, 0L) || !file.exists(f)) {
      unlink(f)
      stop("could not fetch ", u, call. = FALSE)
    }
  }
  f
}

## ── State names ──────────────────────────────────────────────────────────────
## census-counties publishes the Census schema — STATEFP, COUNTYFP, County,
## CountyLSAD, year, mask_year, Area — and no state name. The old source carried
## one only because usdm-counties joined it before republishing. Join it the
## same way usdm-counties.R and usdm-counties-census-2020.R do.
states <- tigris::states(cb = TRUE, year = STATE_NAME_YEAR,
                         progress_bar = FALSE) |>
  sf::st_drop_geometry() |>
  dplyr::select(stfips = STATEFP, state = NAME) |>
  dplyr::arrange(stfips)

build_vintage <- function(y) {
  message("\n=== census ", y, " ===")

  p <- arrow::read_parquet(source_for(y))
  g <- sf::st_as_sfc(structure(p$geometry, class = "WKB"))
  sf::st_crs(g) <- 4269                    # TIGER is NAD83, not WGS84

  x <- sf::st_sf(
    id        = paste0(as.character(p$STATEFP), as.character(p$COUNTYFP)),
    stfips    = as.character(p$STATEFP),
    county    = as.character(p$County),
    mask_year = as.integer(p$mask_year),
    geometry  = g
  ) |>
    dplyr::filter(!stfips %in% DROP_STATES) |>
    sf::st_transform(4326) |>
    dplyr::left_join(states, by = dplyr::join_by(stfips))
  message("  counties: ", nrow(x))

  ## Two gates on the schema change; the third, on mask_year, is below. The
  ## year check is on the fetch, not the schema: build/census/ is a cache keyed
  ## by filename, so a truncated or misnamed download is otherwise silent.
  stopifnot(all(as.integer(p$year) == y))
  if (anyNA(x$state))
    stop("no state name for FIPS ",
         paste(sort(unique(x$stfips[is.na(x$state)])), collapse = ", "),
         " — tigris ", STATE_NAME_YEAR, " does not carry it", call. = FALSE)
  stopifnot(!anyDuplicated(x$id))

  ## mask_year is per COUNTY, not per vintage: 2009 and 2011 fall back to cb
  ## 2010, which has no American Samoa, Guam, Northern Marianas or US Virgin
  ## Islands, so those 13 counties carry cb 2013 instead. The territory filter
  ## above has already dropped all 13, so one value survives — but take it from
  ## the data rather than from a fallback table this repo would have to maintain
  ## in parallel with census-counties'.
  mask_year <- unique(x$mask_year)
  if (length(mask_year) != 1L)
    stop("mask_year is not single-valued after the territory filter: ",
         paste(sort(mask_year), collapse = ", "),
         " — the clip mask composition changed upstream", call. = FALSE)
  if (mask_year != y) message("  cb ", y, " does not exist; clipped with cb ", mask_year)

  ## st_cast, and not for tidiness: albers_usa_shift() clips Hawaii to the
  ## frozen inset bbox, which drops Hawaii and Kalawao counties to POLYGON while
  ## the other 3,219 stay MULTIPOLYGON, and st_make_valid() then returns the
  ## simplest type it can for every one of them. A mixed column is an
  ## sfc_GEOMETRY, and st_coordinates() below has no method for it. The cast
  ## also fails loudly if the bbox clip ever yields a GEOMETRYCOLLECTION, which
  ## is the behaviour to want.
  x <- albers_usa_shift(x, state_fips = x$stfips) |>
    sf::st_make_valid() |>
    sf::st_cast("MULTIPOLYGON")
  x <- to_dummy(as_5070(x))
  assert_dummy_bounds(x)
  sf::st_crs(x) <- 4326                    # writer-boundary label; see counties.R
  x$year <- y

  f_geo <- file.path("build", sprintf("census-%d.geojsonl", y))
  x |> dplyr::select(id, state, county, year) |>
    sf::st_write(f_geo, driver = "GeoJSONSeq", delete_dsn = TRUE, quiet = TRUE,
                 layer_options = c("COORDINATE_PRECISION=9", "RFC7946=NO"))
  nv <- nrow(sf::st_coordinates(x))
  message(sprintf("  vertices: %s   geojsonl %.0f MB", format(nv, big.mark = ","),
                  file.size(f_geo) / 1048576))

  ## ── The index sidecar ─────────────────────────────────────────────────────
  ## Same schema as the dd17/dd22 and fsa-lfp-counties sidecars, and a hard
  ## requirement for the same reason: queryRenderedFeatures() returns only what
  ## is rendered, clipped and simplified for the zoom, so tiles alone cannot
  ## supply counties.index, counties.names or countyCentroid().
  ##
  ## Two fields the other sidecars do not carry. `vintage` is the boundary year
  ## as a string, where dd17/dd22 use their archive's name. `mask_year` is the
  ## coastline the geometry was cut at, which is NOT always the vintage — 2000,
  ## 2009 and 2011 are cut at cb 2010 and 2012 at cb 2013 — and the app has no
  ## other way to know it. Additive: a reader of sfsa-county-index/1 that does
  ## not know either key is unaffected.
  bxs <- do.call(rbind, lapply(sf::st_geometry(x), function(gi) as.numeric(sf::st_bbox(gi))))
  idx <- list(
    schema    = jsonlite::unbox("sfsa-county-index/1"),
    space     = jsonlite::unbox(SFSA_SPACE),
    vintage   = jsonlite::unbox(as.character(y)),
    mask_year = jsonlite::unbox(mask_year),
    n         = jsonlite::unbox(nrow(x)),
    bounds    = as.numeric(DUMMY$bounds[c("xmin", "ymin", "xmax", "ymax")]),
    tiles     = list(
      url      = jsonlite::unbox(sprintf("census-counties-%d.pmtiles", y)),
      minzoom  = jsonlite::unbox(0L),
      maxzoom  = jsonlite::unbox(MAXZOOM),
      extent   = jsonlite::unbox(8192L),
      ## One layer, unlike dd17/dd22 and fsa-lfp-counties: these vintages carry
      ## no precomputed state mesh.
      layers   = list(counties = jsonlite::unbox("counties"))
    ),
    counties     = x$id,
    county_names = x$county,
    state_names  = x$state,
    ## Index-aligned bbox columns, 6 dp (0.54 m). Parallel arrays rather than
    ## objects, matching the house payload convention.
    x0 = round(bxs[, 1], 6), y0 = round(bxs[, 2], 6),
    x1 = round(bxs[, 3], 6), y1 = round(bxs[, 4], 6)
  )
  f_index <- file.path("tiles", sprintf("census-counties-%d-index.json", y))
  jsonlite::write_json(idx, f_index, auto_unbox = FALSE, digits = NA)
  message("  index: ", nrow(x), " counties, ", round(file.size(f_index) / 1024), " KB")

  f_pm <- file.path("tiles", sprintf("census-counties-%d.pmtiles", y))
  args <- c(
    sprintf("--output=%s", f_pm), "--force",
    sprintf("--name=Census counties %d", y),
    sprintf("--description=%s - tl_%d geometry clipped to the cb %d 500k waterline. NOT a geographic CRS.",
            SFSA_SPACE, y, mask_year),
    "--attribution=U.S. Census Bureau TIGER/Line; Sustainable FSA archive",
    sprintf("--layer=counties"), f_geo,
    "--minimum-zoom=0", sprintf("--maximum-zoom=%d", MAXZOOM),
    sprintf("--full-detail=%d", DETAIL),
    sprintf("--simplification=%s", format(SIMPLIFY)),
    "--simplify-only-low-zooms", "--no-simplification-of-shared-nodes",
    "--no-tiny-polygon-reduction", "--no-tile-size-limit", "--no-feature-limit",
    "--include=id", "--include=state", "--include=county", "--include=year",
    "--attribute-type=year:int",
    "--clip-bounding-box=-5.02,-3.06,5.02,3.06",
    "--no-tile-stats", "--read-parallel"
  )
  if (system2("tippecanoe", shQuote(args)) != 0)
    stop("tippecanoe failed for census ", y, call. = FALSE)
  message(sprintf("  %s: %.1f MB", basename(f_pm), file.size(f_pm) / 1048576))

  list(year = y, mask_year = mask_year, n = nrow(x), vertices = nv,
       pmtiles = f_pm, index = f_index, bytes = file.size(f_pm))
}

out <- lapply(vintages, build_vintage)

message("\n", strrep("-", 64))
for (o in out) message(sprintf("  %d  counties %5d  vertices %10s  %6.1f MB  (mask cb %d)",
  o$year, o$n, format(o$vertices, big.mark = ","), o$bytes / 1048576, o$mask_year))

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
  }

  ## Every sibling archive ends here, and none of this repo's scripts did.
  ## _manifest.txt is what puts a prefix in the CDN listing: without it these
  ## tiles are published but undiscoverable. It lists the whole prefix, so
  ## whichever script runs last leaves a complete one.
  s3_write_manifest(bucket = s3_bucket, prefix = s3_prefix)
  ## The PMTiles go up immutable with a one-year max-age, so a REPUBLISH under
  ## the same filename would sit behind the edge cache until 2027. The wildcard
  ## counts as one invalidation path. It does NOT reach a browser that already
  ## holds the file — for that the filename has to change.
  cf_invalidate(c(paste0("/", s3_prefix, "/tiles/*"),
                  paste0("/", s3_prefix, "/_manifest.txt")))
  message("\npublished ", length(out), " vintage(s)")
} else {
  message("\nPUBLISH=0 — built locally, nothing uploaded")
}
