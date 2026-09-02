#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · census-aiannh.R
##
## Census American Indian / Alaska Native / Native Hawaiian areas (AIANNH) as
## vector tiles AND TopoJSON, in both spaces. The only script here that emits
## both encodings: at ~891 K vertices the dataset is small enough that a single
## national TopoJSON is fetchable and large enough that tiles are worth having,
## so it gets census.R's PMTiles stage and usdm.R's TopoJSON stage, verbatim
## where they can be.
##
## THE SOURCE IS TIGER/LINE, NOT THE CARTOGRAPHIC BOUNDARY FILE, and that is a
## finding, not a preference: cb_<y>_us_aiannh_500k pre-dissolves each area's
## reservation and off-reservation trust land into one feature (704 features,
## no COMPTYP — checked on cb 2020, 2022 and 2024), so the cb form cannot
## distinguish trust lands at all. tl_2025_us_aiannh carries them separately —
## 867 records = 617 reservation/statistical-area components ("R") + 250
## off-reservation trust land components ("T") over 704 AIANNHCE codes, GEOID
## the 4-digit code plus the component letter.
##
## ONE TILESET, NOT A WITH/WITHOUT PAIR. Components stay separate features and
## `comptyp` travels as a property, so an app shows the full universe or filters
## `comptyp == "R"` to hide trust lands. That was the user's call (2026-09-01),
## and it is also what keeps the artifact count at three per space.
##
## `comptyp == "R"` HIDES THE HAWAIIAN HOME LANDS TOO. All 74 of them carry
## COMPTYP "T" — Census codes them as trust land, which is what they legally
## are — so the filter is "reservations and statistical areas", not "everything
## but the ORTLs". An app that wants the home lands visible without the ORTLs
## has to split on the name or the 5xxx code range, and should know it is
## drawing a distinction the source deliberately does not.
##
## CLIPPED HERE, AT cb 2025 500k. TIGER is the legal boundary and does not stop
## at water; every county tileset this repo publishes is cut at a cb 500k
## waterline, and an unclipped overlay would run past all of them. The mask is
## the dissolved cb 2025 county coastline — the same year as the source, pinned
## — built with the counties.R idiom (st_union + st_make_valid; NEVER
## ms_explode + ms_dissolve, see CLAUDE.md for the measurement).
##
## NO OUTLINE ARTIFACT, deliberately: the outline class exists so the app can
## clip the USDM to the active COUNTY authority, and AIANNH is never that
## authority. NO INNERLINES LAYER either: AIANNH areas are not a partition of
## the plane, so there is no shared-border mesh to precompute.
##
## `name` IS NAMELSAD, VERBATIM. Same reasoning as fsa-lfp-counties'
## CountyName: "Fort Peck Indian Reservation" and "Salt River Reservation
## Off-Reservation Trust Land" are the labels the source carries, and a
## suffix-stripping rule would mangle the statistical-area names.
##
## NOT SCHEDULED. TIGER vintages are annual and frozen once published; adding
## one is `VINTAGES=2025,2026` plus a look at MASK_YEAR below, run by hand —
## the counties.R convention, not the census.R one.
##
##   PUBLISH=0 Rscript census-aiannh.R
##   SPACE=geo PUBLISH=0 Rscript census-aiannh.R
## =============================================================================

suppressPackageStartupMessages({
  library(sf); library(dplyr); library(jsonlite)
})
source("R/dummy-space.R")
source("R/geo-space.R")
source("R/s3-archive.R")
source("R/publish.R")
sf::sf_use_s2(FALSE)

## space_suffix() hard errors on anything but "dummy" or "geo": a typo that fell
## through to the empty suffix would rebuild and republish the dummy family
## under a geo run's flags.
SPACE  <- Sys.getenv("SPACE", unset = "dummy")
SUFFIX <- space_suffix(SPACE)
message("space: ", SPACE)

## The PMTiles knobs are census.R's, including the reasoning: the bar on maxzoom
## is ground resolution, not zoom number, and the geo value lives in
## R/geo-space.R so this script does not carry a second copy of it.
MAXZOOM  <- if (SPACE == "geo") GEO_MAXZOOM else 15L
DETAIL   <- 13L
SIMPLIFY <- 0.5
LAYER_OPTS <- c(sprintf("COORDINATE_PRECISION=%d", if (SPACE == "geo") 7L else 9L),
                "RFC7946=NO")

## The TopoJSON stage is usdm.R's, but the dummy QUANTIZATION is NOT — the
## USDM's 1e6 was calibrated on ~1:2,000,000 hand-drawn polygons with no
## sub-5 m detail, and TIGER has plenty: at 1e6 (a 4.6 x 3.1 m grid over the
## dummy box) this dataset retains only 0.9880 of its vertices and fails the
## floor. Measured on the 2025 vintage (2026-09-01): 2e6 -> 0.9975 / 1.75 MB
## gz, 5e6 -> 0.9994 / 2.11 MB, 1e7 -> 0.9994 / 2.38 MB. 5e6 is a 0.92 x
## 0.62 m grid — the same resolution class as the tile family's z15 quantum
## (0.720 m of CONUS ground) — and 1e7 buys no retention at all for its extra
## 0.27 MB, so 5e6 it is. The geo family keeps GEO_QUANTIZATION: 1e7 over its
## ~107-degree box is 0.8-1.2 m, the same pitch class, plus the bbox headroom
## R/geo-space.R:99-123 documents.
QUANTIZATION <- if (SPACE == "geo") GEO_QUANTIZATION else "5e6"
MIN_VERTEX_RETENTION <- 0.99

## Per-region area ratio after the shift, from the frozen inset scales — the
## usdm.R gate, kept whole (PR included) even though no AIANNH area is in
## Puerto Rico: a "72" row appearing would be data news, and the gate should
## measure it rather than crash on a missing name.
AREA_RATIO <- c("00" = 1, "02" = 0.25, "15" = 2.25, "72" = 6.25)
AREA_TOL   <- 0.01

## THE CLIP MASK YEAR IS PINNED, and it is the source's own year. Unlike
## counties.R's composite (a frozen archive cut at a coastline chosen once),
## this source is a dated TIGER vintage, so the census-counties rule applies:
## cut each vintage at its own cb waterline. A future VINTAGES entry needs a
## deliberate decision here, not a silent reuse of 2025's coastline.
MASK_YEAR <- 2025L

## Direct pinned URLs, not tigris: an unpinned package call floats with the
## release and nothing in this repo floats. AIANNH_<year> may name a local zip,
## used where it sits.
AIANNH_URL <- function(y) Sys.getenv(
  paste0("AIANNH_", y),
  sprintf("https://www2.census.gov/geo/tiger/TIGER%d/AIANNH/tl_%d_us_aiannh.zip", y, y))
MASK_URL <- sprintf(
  "https://www2.census.gov/geo/tiger/GENZ%d/shp/cb_%d_us_county_500k.zip",
  MASK_YEAR, MASK_YEAR)

s3_bucket <- Sys.getenv("S3_BUCKET", unset = "sustainable-fsa")
s3_prefix <- Sys.getenv("S3_PREFIX", unset = "data-tiles")
publish   <- Sys.getenv("PUBLISH", unset = "1") == "1"
force     <- Sys.getenv("FORCE", unset = "0") == "1"

dir.create("build", showWarnings = FALSE)
dir.create(file.path("build", "aiannh"), showWarnings = FALSE, recursive = TRUE)
dir.create("tiles", showWarnings = FALSE)

## ── The sources, cached ──────────────────────────────────────────────────────
## The census.R idiom: cache under build/, which is gitignored and derived, and
## treat a failed download as a failure rather than a zero-byte cache entry.
## tools/check-aiannh.R and the check-coverage.R source rule read the SAME
## cached zip, which is the whole point of caching it under a stable name.
fetch_cached <- function(u, f) {
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

source_for <- function(y) {
  u <- AIANNH_URL(y)
  if (file.exists(u)) return(u)
  fetch_cached(u, file.path("build", "aiannh", sprintf("tl_%d_us_aiannh.zip", y)))
}

vintages <- Sys.getenv("VINTAGES", unset = "2025")
vintages <- as.integer(strsplit(vintages, "[, ]+")[[1]])
message(length(vintages), " vintage(s) in scope")

## ── What to build, and separately what to publish ────────────────────────────
## census.R's two-key rule, and both halves are load-bearing there and here:
## keying the BUILD off the S3 listing alone makes a machine that already holds
## everything rebuild it to upload, and keying it off local files alone makes a
## CI runner rebuild everything to add one vintage. A vintage is three artifacts
## — tiles, index, TopoJSON — and is only done when all three are present. Every
## name is a plain space_suffix() insertion; this family has no published-name
## legacy to work around, so there is no outline_for() asymmetry.
artifacts_for <- function(y) file.path("tiles", c(
  sprintf("census-aiannh-%d%s.pmtiles", y, SUFFIX),
  sprintf("census-aiannh-%d%s-index.json", y, SUFFIX),
  sprintf("census-aiannh-%d%s.topojson", y, SUFFIX)))

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

## ── The clip mask, built once ────────────────────────────────────────────────
## Only when there is something to build — a no-op run should not pull a Census
## shapefile it will not look at. THE CLIP IS NOT PER SPACE, for counties.R's
## reason: the cut exists because the source reaches into open water, which is a
## fact about the source and not about the projection.
mask <- if (length(to_build)) {
  message("clip mask: cb ", MASK_YEAR, " 500k counties, dissolved")
  fetch_cached(MASK_URL, file.path("build", "aiannh", basename(MASK_URL)))
  sf::read_sf(paste0("/vsizip/", file.path("build", "aiannh", basename(MASK_URL)))) |>
    sf::st_transform(4326) |>
    sf::st_union() |>
    sf::st_make_valid()
} else NULL

build_vintage <- function(y) {
  message("\n=== aiannh ", y, " ===")

  src <- source_for(y)
  x <- sf::read_sf(if (grepl("\\.zip$", src)) paste0("/vsizip/", src) else src)
  stopifnot(sf::st_crs(x) == sf::st_crs(4269))   # TIGER is NAD83, not WGS84

  x <- sf::st_sf(
    id       = as.character(x$GEOID),            # AIANNHCE + component letter
    aiannhce = as.character(x$AIANNHCE),
    name     = as.character(x$NAMELSAD),         # verbatim; see header
    comptyp  = as.character(x$COMPTYP),
    geometry = sf::st_geometry(x)
  ) |>
    sf::st_transform(4326) |>
    sf::st_make_valid()
  stopifnot(!anyDuplicated(x$id))
  if (!all(x$comptyp %in% c("R", "T")))
    stop("aiannh ", y, ": COMPTYP carries ",
         paste(setdiff(unique(x$comptyp), c("R", "T")), collapse = ", "),
         " — the R/T reading of this file no longer holds", call. = FALSE)
  message(sprintf("  features: %d (%d R, %d T; %d areas)", nrow(x),
                  sum(x$comptyp == "R"), sum(x$comptyp == "T"),
                  length(unique(x$aiannhce))))

  ## ── The clip ───────────────────────────────────────────────────────────────
  ## st_collection_extract() because a tangency can hand back a point or a line
  ## inside a collection; the areal part is the feature. EVERY id must survive
  ## non-empty: a component wholly seaward of the county coastline would be a
  ## real disagreement between two Census products, and it should stop the build
  ## and be looked at, not vanish from the sidecar.
  ids_in <- x$id
  x <- suppressWarnings(sf::st_intersection(x, mask)) |> sf::st_make_valid()
  if (any(sf::st_geometry_type(x) == "GEOMETRYCOLLECTION"))
    x <- sf::st_collection_extract(x, "POLYGON")
  gone <- setdiff(ids_in, x$id[!sf::st_is_empty(x)])
  if (length(gone))
    stop("aiannh ", y, ": ", length(gone),
         " component(s) did not survive the cb ", MASK_YEAR, " clip — e.g. ",
         paste(head(gone, 5), collapse = ", "), call. = FALSE)

  ## ── Into the output space ──────────────────────────────────────────────────
  ## The dummy branch is usdm.R's, not census.R's, because AIANNH carries no
  ## state FIPS — the Navajo Nation spans three states and Alaska is full of
  ## ANVSAs — so placement has to come from classify_regions() over EXPLODED
  ## polygons (albers_usa_shift() classifies per feature by bbox, and a
  ## multi-part feature with an Alaska part would drag the rest into the AK
  ## inset). The per-region area gate then holds the shift to the frozen inset
  ## scales, which is what catches the unpadded Hawaii clip eating geometry —
  ## the Hawaiian home lands all sit inside hi_bbox, so the expected loss there
  ## is zero.
  if (SPACE == "geo") {
    x <- to_geo(x)
  } else {
    p <- x |>
      sf::st_cast("MULTIPOLYGON", warn = FALSE) |>
      sf::st_cast("POLYGON", warn = FALSE) |>
      sf::st_transform("ESRI:102003")
    p$region <- classify_regions(p)
    a_before <- tapply(as.numeric(sf::st_area(p)), p$region, sum)

    s <- albers_usa_shift(p) |> sf::st_make_valid()
    a_after <- tapply(as.numeric(sf::st_area(s)), s$region, sum)
    for (r in names(a_before)) {
      got <- if (is.na(a_after[r])) 0 else a_after[r] / a_before[r]
      if (abs(got / AREA_RATIO[[r]] - 1) > AREA_TOL)
        stop(sprintf(paste0("aiannh %d: region %s changed area by %.3f%% more ",
                            "than the inset scale explains (ratio %.4f, ",
                            "expected %.4f).\n  The Hawaii bbox clip is the ",
                            "usual cause."),
                     y, r, 100 * abs(got / AREA_RATIO[[r]] - 1), got,
                     AREA_RATIO[[r]]), call. = FALSE)
    }

    ## Dissolve the explode back to one feature per component. By id ALONE, the
    ## counties.R lesson; the other columns are constant within an id by
    ## construction. st_cast for census.R's reason: the Hawaii bbox clip and
    ## st_make_valid() can leave a mixed POLYGON/MULTIPOLYGON column, which is
    ## an sfc_GEOMETRY, and st_coordinates() has no method for it.
    x <- s |>
      dplyr::group_by(id) |>
      dplyr::summarise(aiannhce = dplyr::first(aiannhce),
                       name     = dplyr::first(name),
                       comptyp  = dplyr::first(comptyp),
                       .groups  = "drop") |>
      sf::st_make_valid() |>
      sf::st_cast("MULTIPOLYGON")
    stopifnot(!anyDuplicated(x$id))
    x <- to_dummy(as_5070(x))
    assert_dummy_bounds(x)
    sf::st_crs(x) <- 4326                # writer-boundary label; see counties.R
  }
  x$year <- y
  x <- x |> dplyr::select(id, aiannhce, name, comptyp, year)

  nv <- nrow(sf::st_coordinates(x))
  message(sprintf("  features out: %d   vertices: %s", nrow(x),
                  format(nv, big.mark = ",")))

  ## ── The one tile layer ─────────────────────────────────────────────────────
  f_lyr <- file.path("build", sprintf("aiannh-%d%s.geojsonl", y, SUFFIX))
  sf::st_write(x, f_lyr, driver = "GeoJSONSeq", delete_dsn = TRUE, quiet = TRUE,
               layer_options = LAYER_OPTS)

  ## ── The index sidecar ──────────────────────────────────────────────────────
  ## A new schema token — the arrays are areas, not counties — but the same
  ## shape as sfsa-county-index/1 for the same reason: queryRenderedFeatures()
  ## returns only what is rendered, so the tiles alone cannot supply the id
  ## list, the labels or a bbox to fly to. `topojson` is additive and points at
  ## the sibling encoding, so a client that wants the whole dataset in one fetch
  ## does not have to guess the filename convention.
  bxs <- if (SPACE == "geo") {
    wrapped_bboxes(x)                    # no straddler in 2025; the convention stands
  } else {
    do.call(rbind, lapply(sf::st_geometry(x), function(gi) as.numeric(sf::st_bbox(gi))))
  }
  geo_extra <- if (SPACE == "geo") list(
    crs          = jsonlite::unbox("EPSG:4326"),
    frame_bounds = as.numeric(GEO_FRAME[c("xmin", "ymin", "xmax", "ymax")])
  ) else list()
  idx <- c(
    list(
      schema    = jsonlite::unbox("sfsa-aiannh-index/1"),
      space     = jsonlite::unbox(if (SPACE == "geo") GEO_SPACE else SFSA_SPACE),
      vintage   = jsonlite::unbox(as.character(y)),
      mask_year = jsonlite::unbox(MASK_YEAR),
      n         = jsonlite::unbox(nrow(x)),
      bounds    = if (SPACE == "geo")
        round(c(min(bxs[, 1]), min(bxs[, 2]), max(bxs[, 3]), max(bxs[, 4])), 6)
      else as.numeric(DUMMY$bounds[c("xmin", "ymin", "xmax", "ymax")]),
      tiles     = list(
        url      = jsonlite::unbox(sprintf("census-aiannh-%d%s.pmtiles", y, SUFFIX)),
        minzoom  = jsonlite::unbox(0L),
        maxzoom  = jsonlite::unbox(MAXZOOM),
        extent   = jsonlite::unbox(8192L),
        layers   = list(aiannh = jsonlite::unbox("aiannh"))
      ),
      topojson  = list(
        url          = jsonlite::unbox(sprintf("census-aiannh-%d%s.topojson", y, SUFFIX)),
        object       = jsonlite::unbox("aiannh"),
        quantization = jsonlite::unbox(as.numeric(QUANTIZATION))
      )
    ),
    geo_extra,
    list(
      areas      = x$id,
      area_names = x$name,
      aiannhce   = x$aiannhce,
      comptyp    = x$comptyp,
      x0 = round(bxs[, 1], 6), y0 = round(bxs[, 2], 6),
      x1 = round(bxs[, 3], 6), y1 = round(bxs[, 4], 6)
    )
  )
  f_index <- file.path("tiles", sprintf("census-aiannh-%d%s-index.json", y, SUFFIX))
  jsonlite::write_json(idx, f_index, auto_unbox = FALSE, digits = NA)
  message("  index: ", nrow(x), " components, ", round(file.size(f_index) / 1024), " KB")

  ## ── PMTiles ────────────────────────────────────────────────────────────────
  ## The flag block is census.R's; only the layer and the attribute list differ.
  ## Never --use-attribute-for-id: MVT feature ids are uint64 and "0010R" is not
  ## a number at all — the id stays a string property and the app promotes it.
  f_pm <- file.path("tiles", sprintf("census-aiannh-%d%s.pmtiles", y, SUFFIX))
  desc <- if (SPACE == "geo") sprintf(
    paste("%s - tl_%d AIANNH areas (R and T components separate) clipped to",
          "the cb %d 500k waterline, true-position EPSG:4326.",
          "Renders on standard maps including globe."),
    GEO_SPACE, y, MASK_YEAR) else sprintf(
    paste("%s - tl_%d AIANNH areas (R and T components separate) clipped to",
          "the cb %d 500k waterline. NOT a geographic CRS."),
    SFSA_SPACE, y, MASK_YEAR)
  args <- c(
    sprintf("--output=%s", f_pm), "--force",
    sprintf("--name=Census AIANNH %d%s", y, SUFFIX),
    sprintf("--description=%s", desc),
    "--attribution=U.S. Census Bureau TIGER/Line; Sustainable FSA archive",
    sprintf("--named-layer=aiannh:%s", f_lyr),
    "--minimum-zoom=0", sprintf("--maximum-zoom=%d", MAXZOOM),
    sprintf("--full-detail=%d", DETAIL),
    sprintf("--simplification=%s", format(SIMPLIFY)),
    "--simplify-only-low-zooms", "--no-simplification-of-shared-nodes",
    "--no-tiny-polygon-reduction", "--no-tile-size-limit", "--no-feature-limit",
    "--include=id", "--include=aiannhce", "--include=name", "--include=comptyp",
    "--include=year", "--attribute-type=year:int",
    if (SPACE == "geo") character(0) else "--clip-bounding-box=-5.02,-3.06,5.02,3.06",
    "--no-tile-stats", "--read-parallel"
  )
  if (system2("tippecanoe", shQuote(args)) != 0)
    stop("tippecanoe failed for aiannh ", y, call. = FALSE)
  message(sprintf("  %s: %.1f MB", basename(f_pm), file.size(f_pm) / 1048576))

  ## ── TopoJSON ───────────────────────────────────────────────────────────────
  ## usdm.R's stage: a single-document GeoJSON (mapshaper wants one document,
  ## not the line-delimited form tippecanoe wants), built under a .partial name
  ## and renamed only once every gate has passed — a rejected build that left
  ## its file behind would be treated as done by the incremental skip.
  ## id-field is the dd22 usage: unlike a USDM week, these features have ids.
  f_doc <- file.path("build", sprintf("aiannh-%d%s.geojson", y, SUFFIX))
  f_out <- file.path("tiles", sprintf("census-aiannh-%d%s.topojson", y, SUFFIX))
  f_tmp <- paste0(f_out, ".partial")
  f_rt  <- file.path("build", sprintf("aiannh-%d%s-roundtrip.geojson", y, SUFFIX))
  on.exit(unlink(c(f_doc, f_tmp, f_rt)), add = TRUE)

  sf::st_write(x, f_doc, driver = "GeoJSON", delete_dsn = TRUE, quiet = TRUE,
               layer_options = LAYER_OPTS)

  args <- c(shQuote(f_doc), "-rename-layers", "aiannh",
            "-o", "format=topojson", paste0("quantization=", QUANTIZATION),
            "id-field=id", "fix-geometry", "bbox", "force", shQuote(f_tmp))
  if (system2("mapshaper", args, stdout = FALSE, stderr = FALSE) != 0)
    stop("mapshaper failed for aiannh ", y, call. = FALSE)

  ## Decode back and count — mapshaper snaps coincident vertices on GeoJSON
  ## import, the mechanism that broke census-counties, so the retention is a
  ## measured claim per build rather than a calibration taken on faith.
  if (system2("mapshaper", c(shQuote(f_tmp), "-o", "format=geojson", "force",
                             shQuote(f_rt)), stdout = FALSE, stderr = FALSE) != 0)
    stop("mapshaper could not decode its own output for aiannh ", y, call. = FALSE)
  nv_rt <- nrow(sf::st_coordinates(sf::read_sf(f_rt)))
  if (nv_rt < MIN_VERTEX_RETENTION * nv)
    stop(sprintf(paste0("aiannh %d: %s of %s vertices survived the TopoJSON ",
                        "round trip (%.3f%%, floor %.1f%%)."),
                 y, format(nv_rt, big.mark = ","), format(nv, big.mark = ","),
                 100 * nv_rt / nv, 100 * MIN_VERTEX_RETENTION), call. = FALSE)

  topo <- jsonlite::fromJSON(f_tmp, simplifyVector = FALSE)
  if (!identical(names(topo$objects), "aiannh"))
    stop("aiannh ", y, ": TopoJSON object is '",
         paste(names(topo$objects), collapse = ","), "', expected 'aiannh'",
         call. = FALSE)
  if (length(topo$objects$aiannh$geometries) != nrow(x))
    stop("aiannh ", y, ": TopoJSON carries ",
         length(topo$objects$aiannh$geometries), " features, expected ",
         nrow(x), call. = FALSE)
  if (!file.rename(f_tmp, f_out))
    stop("could not place ", f_out, call. = FALSE)
  message(sprintf("  %s: %.2f MB, retained %.4f", basename(f_out),
                  file.size(f_out) / 1048576, nv_rt / nv))

  list(year = y, n = nrow(x), vertices = nv, retained = nv_rt / nv,
       pmtiles = f_pm, index = f_index, topojson = f_out,
       bytes = file.size(f_pm))
}

out <- lapply(to_build, build_vintage)

if (length(out)) {
  message("\n", strrep("-", 64))
  for (o in out) message(sprintf(
    "  %d  components %4d  vertices %9s  tiles %5.1f MB  topojson %.2f MB",
    o$year, o$n, format(o$vertices, big.mark = ","), o$bytes / 1048576,
    file.size(o$topojson) / 1048576))
}

if (publish) {
  ## Publish what the bucket lacks, not what this run happened to build; see
  ## census.R for both this and the explicit character(0).
  to_pub <- if (force) vintages else vintages[!vapply(vintages, archived, logical(1))]
  message("publishing ", length(to_pub), " of ", length(vintages), " vintage(s)")
  files <- if (length(to_pub)) unlist(lapply(to_pub, artifacts_for)) else character(0)
  stopifnot(all(file.exists(files)))
  for (f in files) put_artifact(s3_bucket, s3_prefix, f)

  s3_write_manifest(bucket = s3_bucket, prefix = s3_prefix)
  cf_invalidate(c(paste0("/", s3_prefix, "/tiles/*"),
                  paste0("/", s3_prefix, "/_manifest.txt")))
  message("\npublished ", length(to_pub), " vintage(s)")
} else {
  message("\nPUBLISH=0 — built locally, nothing uploaded")
}
