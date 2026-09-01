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
## TWO SPACES, ONE PER INVOCATION. SPACE=dummy (the default) builds the
## sfsa-albers-usa/1 family that is already published; SPACE=geo builds the
## parallel sfsa-geographic/1 family in true EPSG:4326. Every artifact name
## carries the space, so the two cannot collide and the incremental skip is
## per-space without being told about spaces at all.
##
##   VINTAGES=2020 PUBLISH=0 Rscript census.R
##   SPACE=geo VINTAGES=2020 PUBLISH=0 Rscript census.R
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

## space_suffix() hard errors on anything but "dummy" or "geo": a typo that fell
## through to the empty suffix would rebuild and republish the dummy family
## under a geo run's flags.
SPACE  <- Sys.getenv("SPACE", unset = "dummy")
SUFFIX <- space_suffix(SPACE)
message("space: ", SPACE)

## THE BAR ON MAXZOOM IS GROUND RESOLUTION, NOT ZOOM NUMBER. Dummy z15 at
## detail 13 quantises to 0.720 m of CONUS ground; real Web Mercator reaches
## that at z13, worst case 0.597 m at the equator. The geo value lives in
## R/geo-space.R and WP5's calibration may revise it — this script must not
## carry a second copy of it.
MAXZOOM  <- if (SPACE == "geo") GEO_MAXZOOM else 15L
DETAIL   <- 13L
SIMPLIFY <- 0.5

## GeoJSONL writer options for both layers. 9 dp was chosen against DUMMY
## degrees, where GDAL's default 7 would have been fine (5 cm) but only by luck;
## on real degrees 7 dp is 1.1 cm, finer than anything the source resolves, so
## the geo intermediates do not carry two digits tippecanoe discards. RFC7946=NO
## in both: dummy coordinates are not lng/lat and must not be normalised as
## such, and in geo it is what keeps the precision this line states rather than
## the 7 dp and ring rewinding RFC7946 would impose on its own terms.
LAYER_OPTS <- c(sprintf("COORDINATE_PRECISION=%d", if (SPACE == "geo") 7L else 9L),
                "RFC7946=NO")

## DISCOVERED, NOT HARDCODED, for the same reason census-counties discovers
## them: a hardcoded list cannot notice the year Census publishes a new vintage,
## and this script would have gone on building eighteen for as long as nobody
## edited it. One request to the upstream manifest, which is authoritative about
## what the clipped form actually contains.
archive_vintages <- function() {
  m <- readLines(file.path(CENSUS_COUNTIES, "_manifest.txt"), warn = FALSE)
  m <- grep("/data/clipped/[0-9]{4}-counties\\.parquet$", m, value = TRUE)
  v <- sort(unique(as.integer(sub("^.*/([0-9]{4})-counties\\.parquet$", "\\1", m))))
  if (!length(v))
    stop("no clipped vintages in ", CENSUS_COUNTIES, "/_manifest.txt", call. = FALSE)
  v
}

## Territories the composite cannot place: dummy-Albers lays out CONUS, AK, HI
## and PR only. The archive carries these counties, so the filter is ours.
##
## THE GEO FAMILY DROPS NOTHING. Real degrees place American Samoa, Guam, the
## Northern Marianas and the US Virgin Islands where they actually are, so the
## only reason the filter existed is gone with the composite. The codes are still
## named because the geo mask_year rule below is stated over them: these are the
## rows allowed to disagree with the rest of the vintage about which coastline
## cut them. (52 and 14 are the legacy US Virgin Islands and Guam codes the FSA
## composite uses; the Census parquets carry 60/66/69/78 only, and the set is
## shared with counties.R because a short set that is wrong in one script is
## worse than a long one that is right in both.)
TERRITORY_STATES <- c("60", "78", "14", "52", "69", "66")
DROP_STATES <- if (SPACE == "geo") character(0) else TERRITORY_STATES

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
force     <- Sys.getenv("FORCE", unset = "0") == "1"

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

vintages <- Sys.getenv("VINTAGES", unset = "")
vintages <- if (nzchar(vintages)) {
  as.integer(strsplit(vintages, "[, ]+")[[1]])
} else {
  archive_vintages()
}
message(length(vintages), " vintage(s) in scope")

## ── What to build, and separately what to publish ────────────────────────────
## A vintage is three artifacts and is only done when all three are present. The
## rule is usdm.R's, and both halves are load-bearing: keying the BUILD off the
## S3 listing alone makes a machine that already holds everything rebuild it to
## upload, and keying it off local files alone makes a CI runner — which clones
## a repo where tiles/ is gitignored — rebuild all eighteen to add one.
##
## Without this the script rebuilt every vintage every run: half an hour and
## 1.2 GB republished to produce byte-identical output, which is why the weekly
## workflow could not afford to call it.
##
## THE SUFFIX IS WHAT MAKES ALL OF THAT PER-SPACE FOR FREE. A geo run listing a
## bucket that holds only dummy keys sees nothing of its own and builds; a dummy
## run is unaffected by however much geo is on disk. The outline is the one name
## that is not a suffix insertion — the dummy family published -outline-dummy
## before there was a second space and those keys cannot move — so it is stated
## once here rather than twice.
outline_for <- function(y) file.path("tiles", if (SPACE == "geo")
  sprintf("census-counties-%d-geo-outline.geojson", y)
  else sprintf("census-counties-%d-outline-dummy.geojson", y))

artifacts_for <- function(y) c(file.path("tiles", c(
  sprintf("census-counties-%d%s.pmtiles", y, SUFFIX),
  sprintf("census-counties-%d%s-index.json", y, SUFFIX))),
  outline_for(y))

published <- if (publish) {
  basename(s3_list_keys(s3_bucket, paste0(s3_prefix, "/tiles"))$Key)
} else character(0)

archived <- function(y) all(basename(artifacts_for(y)) %in% published)
on_disk  <- function(y) all(file.exists(artifacts_for(y)))

wanted <- if (force || !publish) {
  vintages
} else {
  vintages[!vapply(vintages, archived, logical(1))]
}
to_build <- if (force) vintages else wanted[!vapply(wanted, on_disk, logical(1))]
if (length(to_build) < length(vintages))
  message("  ", length(vintages) - length(to_build),
          " vintage(s) already archived or built, skipping (FORCE=1 to rebuild)")

## ── State names ──────────────────────────────────────────────────────────────
## census-counties publishes the Census schema — STATEFP, COUNTYFP, County,
## CountyLSAD, year, mask_year, Area — and no state name. The old source carried
## one only because usdm-counties joined it before republishing. Join it the
## same way usdm-counties.R and usdm-counties-census-2020.R do.
## Fetched only when there is something to build — a no-op run should not pull
## a Census shapefile it will not look at.
states <- if (length(to_build)) {
  tigris::states(cb = TRUE, year = STATE_NAME_YEAR, progress_bar = FALSE) |>
    sf::st_drop_geometry() |>
    dplyr::select(stfips = STATEFP, state = NAME) |>
    dplyr::arrange(stfips)
} else NULL

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
  ##
  ## THE GEO FAMILY KEEPS THOSE 13 COUNTIES, so single-valued is no longer a
  ## fact to assert — on 2009 and 2011 the vintage genuinely carries two mask
  ## years. The rule that replaces it is the same statement in the only form
  ## still true: every row that is NOT a territory shares one mask year, that
  ## value is the scalar the sidecar and the tileset description carry, and a
  ## second value is tolerated only on territory rows. Anything else is the clip
  ## mask composition changing upstream, which is the failure the assert exists
  ## for, and it stops the build in both spaces. The full set goes out as
  ## `mask_years` so the scalar hides nothing.
  if (SPACE == "geo") {
    mask_years <- sort(unique(x$mask_year))
    core <- unique(x$mask_year[!x$stfips %in% TERRITORY_STATES])
    if (length(core) != 1L)
      stop("mask_year is not single-valued across the states and DC: ",
           paste(sort(core), collapse = ", "),
           " — the clip mask composition changed upstream", call. = FALSE)
    mask_year <- core
    if (length(mask_years) > 1L)
      message("  mask years: ", paste(mask_years, collapse = ", "),
              " — cb ", mask_year, " everywhere but the territories")
  } else {
    mask_year <- unique(x$mask_year)
    if (length(mask_year) != 1L)
      stop("mask_year is not single-valued after the territory filter: ",
           paste(sort(mask_year), collapse = ", "),
           " — the clip mask composition changed upstream", call. = FALSE)
  }
  if (mask_year != y) message("  cb ", y, " does not exist; clipped with cb ", mask_year)

  ## st_cast, and not for tidiness: albers_usa_shift() clips Hawaii to the
  ## frozen inset bbox, which drops Hawaii and Kalawao counties to POLYGON while
  ## the other 3,219 stay MULTIPOLYGON, and st_make_valid() then returns the
  ## simplest type it can for every one of them. A mixed column is an
  ## sfc_GEOMETRY, and st_coordinates() below has no method for it. The cast
  ## also fails loudly if the bbox clip ever yields a GEOMETRYCOLLECTION, which
  ## is the behaviour to want.
  ##
  ## The geo branch is st_transform and nothing else: no shift, no 5070 hop, no
  ## bbox clip, and no CRS relabel because the label is true. No cast either —
  ## to_geo() returns MULTIPOLYGON throughout, having dealt with the same mixed
  ## column on its own side of the wrap.
  if (SPACE == "geo") {
    x <- to_geo(x)
  } else {
    x <- albers_usa_shift(x, state_fips = x$stfips) |>
      sf::st_make_valid() |>
      sf::st_cast("MULTIPOLYGON")
    x <- to_dummy(as_5070(x))
    assert_dummy_bounds(x)
    sf::st_crs(x) <- 4326                  # writer-boundary label; see counties.R
  }
  x$year <- y

  ## ── Layer 1: the counties ─────────────────────────────────────────────────
  ## The writer options are per-space and stated once at the top; neither
  ## precision is GDAL's default, deliberately.
  f_counties <- file.path("build", sprintf("census-%d%s-counties.geojsonl", y, SUFFIX))
  x |> dplyr::select(id, state, county, year) |>
    sf::st_write(f_counties, driver = "GeoJSONSeq", delete_dsn = TRUE, quiet = TRUE,
                 layer_options = LAYER_OPTS)
  nv <- nrow(sf::st_coordinates(x))
  message(sprintf("  vertices: %s   geojsonl %.0f MB", format(nv, big.mark = ","),
                  file.size(f_counties) / 1048576))

  ## ── Layer 2: the state mesh ───────────────────────────────────────────────
  ## Precomputed because there is no mesh operation in a vector tile: the kit
  ## derives this client-side with topojson.mesh() and MVT has no equivalent.
  ## Dissolved by the state FIPS the data carries, not by substr(id) — same
  ## answer here, but the column is the honest source.
  f_states <- file.path("build", sprintf("census-%d%s-states.geojsonl", y, SUFFIX))
  states_g <- x |>
    dplyr::group_by(stfips) |>
    dplyr::summarise(.groups = "drop") |>
    sf::st_make_valid()
  rmapshaper::ms_innerlines(states_g) |>
    sf::st_write(f_states, driver = "GeoJSONSeq", delete_dsn = TRUE, quiet = TRUE,
                 layer_options = LAYER_OPTS)
  message("  states: ", nrow(states_g), " dissolved")

  ## ── The national outline ──────────────────────────────────────────────────
  ## Vintage-matched like everything else here: the USDM week that clips against
  ## this one has to clip against the coastline of its own year.
  ##
  ## The pinhole guard measures rings in square metres, so the measure is the
  ## caller's to supply: the dummy one is planar deg2 scaled by DUMMY$deg_m and
  ## on real degrees it is not merely imprecise but wrong by a factor of two
  ## between the equator and 60 N.
  f_outline <- outline_for(y)
  if (SPACE == "geo") {
    write_outline(dissolve_outline(x, ring_m2 = geo_ring_m2), f_outline)
  } else {
    write_outline(dissolve_outline(x), f_outline)
  }

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
  ##
  ## Three more in the geo family, all additive again. `crs` because a space
  ## token names a versioned contract — wrapping and bbox convention and frame
  ## bounds — and not a projection, so an app that wants only the projection
  ## should not have to know the contract. `frame_bounds` because a `bounds`
  ## measured off geometry that includes Guam and American Samoa is honest and
  ## nearly world-wide, and fitBounds() on it opens over the Pacific.
  ## `mask_years` because the scalar now describes everything but the
  ## territories and they are entitled to disagree with it.
  bxs <- if (SPACE == "geo") {
    ## WRAPPED, not plain. Aleutians West (02016) has parts on both sides of the
    ## antimeridian; its plain st_bbox() is arithmetically right and 359 degrees
    ## wide, which every consumer of this file reads as the whole Pacific. See
    ## R/geo-space.R — x0 comes back below -180 and that is the convention.
    wrapped_bboxes(x)
  } else {
    do.call(rbind, lapply(sf::st_geometry(x), function(gi) as.numeric(sf::st_bbox(gi))))
  }
  geo_extra <- if (SPACE == "geo") list(
    crs          = jsonlite::unbox("EPSG:4326"),
    frame_bounds = as.numeric(GEO_FRAME[c("xmin", "ymin", "xmax", "ymax")]),
    mask_years   = as.integer(mask_years)
  ) else list()
  idx <- c(
    list(
      schema    = jsonlite::unbox("sfsa-county-index/1"),
      space     = jsonlite::unbox(if (SPACE == "geo") GEO_SPACE else SFSA_SPACE),
      vintage   = jsonlite::unbox(as.character(y)),
      mask_year = jsonlite::unbox(mask_year),
      n         = jsonlite::unbox(nrow(x)),
      ## Measured for geo, frozen for dummy: the composite's box is the frame
      ## the app's ?lng/?lat is expressed against, and the geo family states
      ## that separately as frame_bounds. Taken from the rows rather than from
      ## st_bbox(x) so the file is internally consistent — the aggregate is the
      ## union of the wrapped boxes it publishes, which st_bbox() of the whole
      ## set is not.
      bounds    = if (SPACE == "geo")
        round(c(min(bxs[, 1]), min(bxs[, 2]), max(bxs[, 3]), max(bxs[, 4])), 6)
      else as.numeric(DUMMY$bounds[c("xmin", "ymin", "xmax", "ymax")]),
      tiles     = list(
        url      = jsonlite::unbox(sprintf("census-counties-%d%s.pmtiles", y, SUFFIX)),
        minzoom  = jsonlite::unbox(0L),
        maxzoom  = jsonlite::unbox(MAXZOOM),
        extent   = jsonlite::unbox(8192L),
        layers   = list(counties = jsonlite::unbox("counties"),
                        states   = jsonlite::unbox("states"))
      )
    ),
    geo_extra,
    list(
      counties     = x$id,
      county_names = x$county,
      state_names  = x$state,
      ## Index-aligned bbox columns, 6 dp (0.54 m dummy, 11 cm real). Parallel
      ## arrays rather than objects, matching the house payload convention.
      x0 = round(bxs[, 1], 6), y0 = round(bxs[, 2], 6),
      x1 = round(bxs[, 3], 6), y1 = round(bxs[, 4], 6)
    )
  )
  f_index <- file.path("tiles", sprintf("census-counties-%d%s-index.json", y, SUFFIX))
  jsonlite::write_json(idx, f_index, auto_unbox = FALSE, digits = NA)
  message("  index: ", nrow(x), " counties, ", round(file.size(f_index) / 1024), " KB")

  f_pm <- file.path("tiles", sprintf("census-counties-%d%s.pmtiles", y, SUFFIX))
  desc <- if (SPACE == "geo") sprintf(
    paste("%s - tl_%d geometry clipped to the cb %d 500k waterline,",
          "true-position EPSG:4326, antimeridian-wrapped.",
          "Renders on standard maps including globe."),
    GEO_SPACE, y, mask_year) else sprintf(
    "%s - tl_%d geometry clipped to the cb %d 500k waterline. NOT a geographic CRS.",
    SFSA_SPACE, y, mask_year)
  args <- c(
    sprintf("--output=%s", f_pm), "--force",
    sprintf("--name=Census counties %d%s", y, SUFFIX),
    sprintf("--description=%s", desc),
    "--attribution=U.S. Census Bureau TIGER/Line; Sustainable FSA archive",
    sprintf("--named-layer=counties:%s", f_counties),
    sprintf("--named-layer=states:%s", f_states),
    "--minimum-zoom=0", sprintf("--maximum-zoom=%d", MAXZOOM),
    sprintf("--full-detail=%d", DETAIL),
    sprintf("--simplification=%s", format(SIMPLIFY)),
    "--simplify-only-low-zooms", "--no-simplification-of-shared-nodes",
    "--no-tiny-polygon-reduction", "--no-tile-size-limit", "--no-feature-limit",
    "--include=id", "--include=state", "--include=county", "--include=year",
    "--attribute-type=year:int",
    ## No clip box in the geo family: the dummy one is the frozen composite
    ## frame, and there is no geographic equivalent — the extent is the world
    ## once Guam and American Samoa are in it, so any box would cut them off.
    if (SPACE == "geo") character(0) else "--clip-bounding-box=-5.02,-3.06,5.02,3.06",
    "--no-tile-stats", "--read-parallel"
  )
  if (system2("tippecanoe", shQuote(args)) != 0)
    stop("tippecanoe failed for census ", y, call. = FALSE)
  message(sprintf("  %s: %.1f MB", basename(f_pm), file.size(f_pm) / 1048576))

  list(year = y, mask_year = mask_year, n = nrow(x), vertices = nv,
       pmtiles = f_pm, index = f_index, outline = f_outline,
       bytes = file.size(f_pm))
}

out <- lapply(to_build, build_vintage)

if (length(out)) {
  message("\n", strrep("-", 64))
  for (o in out) message(sprintf("  %d  counties %5d  vertices %10s  %6.1f MB  (mask cb %d)",
    o$year, o$n, format(o$vertices, big.mark = ","), o$bytes / 1048576, o$mask_year))
}

if (publish) {
  ## Publish what the bucket lacks, not what this run happened to build: a
  ## vintage can be complete on disk from an earlier local run and still be
  ## missing upstream.
  to_pub <- if (force) vintages else vintages[!vapply(vintages, archived, logical(1))]
  message("publishing ", length(to_pub), " of ", length(vintages), " vintage(s)")
  ## unlist(list()) is NULL, not character(0), and file.exists(NULL) is an
  ## error rather than logical(0) — so the nothing-to-publish case, which is
  ## every quiet week, needs the empty vector spelled out.
  files <- if (length(to_pub)) unlist(lapply(to_pub, artifacts_for)) else character(0)
  ## to_build covered exactly the not-archived-and-not-local vintages, so every
  ## file here exists by now. Assert it rather than discovering a gap mid-upload.
  stopifnot(all(file.exists(files)))
  for (f in files) put_artifact(s3_bucket, s3_prefix, f)

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
  message("\npublished ", length(to_pub), " vintage(s)")
} else {
  message("\nPUBLISH=0 — built locally, nothing uploaded")
}
