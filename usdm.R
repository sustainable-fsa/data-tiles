#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · usdm.R
##
## The weekly US Drought Monitor, pre-projected into sfsa-albers-usa/1 and
## published as one TopoJSON per week, at full source resolution.
##
## NOT PMTILES, AND THAT IS THE INTERESTING PART. Tiling won for the counties
## because the source is ~7.6 M vertices: no single file could be both full
## resolution and fetchable, so zoom-appropriate simplification was the only way
## to have both. A USDM week is FIVE features and 100-266 K vertices of
## ~1:2,000,000 data. There is nothing to simplify, so tiling only pays the
## overhead of replicating boundary geometry into every tile it crosses at every
## zoom. Measured on the worst week in the archive (2025-09-16, 265,891
## vertices), everything through this same transform:
##
##   PMTiles z0-15   10.02 MB      GeoJSON 9 dp    2.43 MB gz
##   FlatGeobuf       3.39 MB gz   GeoJSON 6 dp    1.59 MB gz
##   TopoJSON 1e6     0.61 MB gz
##
## FlatGeobuf loses because float64 coordinates are high-entropy — gzip takes
## 17% off it against 68% off text — and its spatial index is dead weight when
## every request wants the whole national extent. TopoJSON wins because
## quantising to integers and delta-encoding is exactly what gzip likes.
##
## Decode cost decides whether scrubbing janks, and it is a wash: JSON.parse
## 30.5 ms for GeoJSON against JSON.parse + topojson.feature() 31.1 ms, because
## the ~1.4 ms of arc stitching is offset by parsing less text. The app already
## ships a TopoJSON decoder for the boundary archives.
##
## PUBLISHED UNCLIPPED. The USDM's own coastline is ~1:2,000,000 and overhangs
## into water past any county set, but the app switches between four county
## authorities and a baked-in coastline would mismatch three of them. The
## overspill is masked client-side by drawing the inverse of whichever
## -outline-dummy.geojson is active. This repo does the projection, not the
## editing.
##
##   DATES=2025-09-16 PUBLISH=0 Rscript usdm.R    # one week
##   FORCE=1 WORKERS=4 Rscript usdm.R             # rebuild everything
## =============================================================================

suppressPackageStartupMessages({
  library(sf); library(dplyr); library(jsonlite); library(mirai)
})
source("R/dummy-space.R")
source("R/publish.R")
source("R/s3-archive.R")
sf::sf_use_s2(FALSE)

## 4.6 x 3.1 m on the ground, which retains 99.75% of source vertices — lossless
## against a 1:2M product. 1e5 (46 m, 92.1%) and 1e4 (461 m, 50.1%) are
## simplification wearing an encoding's clothes, so they are not options here.
QUANTIZATION <- "1e6"

## Topology building is LEFT ON, having been measured rather than assumed:
## mapshaper snaps coincident vertices on GeoJSON import, and that snap is what
## broke census-counties. On this data it costs nothing — round-tripped vertices
## are identical with and without it (265,222 both ways, the 669 lost to
## quantisation either way) — and it is 5% smaller (0.609 vs 0.641 MB gz),
## because deduplicating shared arc endpoints is worth more than the five nested
## classes share. `-i no-topology` is the alternative if that ever changes.

## The floor on vertices surviving the TopoJSON round trip, per week.
##
## MEASURED, AND THE FIRST ATTEMPT WAS WRONG. Gating on the arcs' own point
## count looked cheap — no decode — but the deficit against the source scales
## with RING COUNT, not vertices, because TopoJSON drops each ring's closing
## point and deduplicates shared arc endpoints. Across seven weeks spanning the
## archive that ratio swings 0.938-0.976 with ring density, so no floor
## distinguishes a dense week from a broken one; a 0.95 floor rejected
## 2013-03-05, which is perfect. Decoding back is the only honest measure:
##
##   week         src_v   arc/src   round-trip/src
##   2000-01-04  46,921     0.941        1.000
##   2013-03-05 103,245     0.949        1.000
##   2021-02-09  92,131     0.938        0.995
##   2025-09-16 266,575     0.970        0.995
##
## 0.995 is the observed floor and the residue is quantisation collapsing
## coincident points, which is the encoding working. census-counties' failure
## mode lost whole rings and would land nowhere near 0.99.
MIN_VERTEX_RETENTION <- 0.99

## Per-region area ratio after the shift, from the frozen inset scales: CONUS
## unscaled, AK 0.5, HI 1.5, PR 2.5. Nominal rather than exact — AK (EPSG:3338)
## and HI (ESRI:102007) are equal-area but PR (EPSG:32161) is Lambert Conformal
## and does not preserve area — hence the loose tolerance. This is a gate on
## gross loss, and in particular on albers_usa_shift()'s unpadded Hawaii clip
## quietly eating more than the 0.85 km2 of ocean-drape D0 it is known to.
AREA_RATIO <- c("00" = 1, "02" = 0.25, "15" = 2.25, "72" = 6.25)
AREA_TOL   <- 0.01

USDM_ARCHIVE <- Sys.getenv("USDM_ARCHIVE",
                           unset = "https://data.sustainable-fsa.com/usdm")

s3_bucket <- Sys.getenv("S3_BUCKET", unset = "sustainable-fsa")
s3_prefix <- Sys.getenv("S3_PREFIX", unset = "data-tiles")
publish   <- Sys.getenv("PUBLISH", unset = "1") == "1"
force     <- Sys.getenv("FORCE", unset = "0") == "1"
workers   <- as.integer(Sys.getenv("WORKERS",
                unset = max(1L, parallel::detectCores() - 2L)))

dir.create("build", showWarnings = FALSE)
dir.create(file.path("build", "usdm"), showWarnings = FALSE, recursive = TRUE)
dir.create("usdm", showWarnings = FALSE)

## ── Which weeks exist ────────────────────────────────────────────────────────
## From the source archive's own manifest: one request, authoritative, and no
## 1,390 HEAD probes to discover what a single file already lists.
## USDM_2010-08-10.topojson -> 2010-08-10. Two subs, not one alternation:
## sub("^USDM_|\\.topojson$", "", x) replaces only the FIRST match, so it strips
## the prefix and leaves the extension. That silently corrupted every date on
## the incremental path.
date_of <- function(f) sub("\\.topojson$", "", sub("^USDM_", "", basename(f)))

archive_dates <- function() {
  m <- readLines(file.path(USDM_ARCHIVE, "_manifest.txt"), warn = FALSE)
  m <- grep("/data/parquet/USDM_[0-9]{4}-[0-9]{2}-[0-9]{2}\\.parquet$", m, value = TRUE)
  sort(unique(sub("^.*/USDM_([0-9-]{10})\\.parquet$", "\\1", m)))
}

dates <- Sys.getenv("DATES", unset = "")
dates <- if (nzchar(dates)) strsplit(dates, "[, ]+")[[1]] else archive_dates()
message(length(dates), " week(s) in scope")

## ── What to build, and separately what to publish ────────────────────────────
## These are two different questions and conflating them was a bug: deciding
## what to BUILD from the S3 listing means a machine that already holds all 1,390
## weeks rebuilds every one of them just to upload. Build what is missing on
## disk; publish what is missing in the bucket. A fresh CI runner has nothing
## locally, so it does both, which is the case the S3-listing rule was written
## for — usdm.R in the source archive is the model ("membership in the S3
## LISTING decides it"), and it is right about publishing.
f_for <- function(d) file.path("usdm", sprintf("USDM_%s.topojson", d))

## What the bucket already holds, read once and used twice: to decide what still
## needs uploading, and to build an index that names the ARCHIVE rather than
## this disk.
published <- if (publish) {
  grep("^USDM_.*\\.topojson$",
       basename(s3_list_keys(s3_bucket, paste0(s3_prefix, "/usdm"))$Key),
       value = TRUE)
} else character(0)

all_dates <- dates
to_build  <- if (force) all_dates else all_dates[!file.exists(f_for(all_dates))]
if (length(to_build) < length(all_dates))
  message("  ", length(all_dates) - length(to_build),
          " already built locally, skipping (FORCE=1 to rebuild)")

## ── One week ─────────────────────────────────────────────────────────────────
build_week <- function(d) {
  f_geo <- file.path("build", "usdm", sprintf("USDM_%s.geojson", d))
  f_out <- file.path("usdm", sprintf("USDM_%s.topojson", d))

  x <- sf::read_sf(sprintf("%s/data/parquet/USDM_%s.parquet", USDM_ARCHIVE, d))
  nv_src <- nrow(sf::st_coordinates(x))

  ## EXPLODE FIRST. albers_usa_shift() classifies per FEATURE by bbox, so a
  ## continental MULTIPOLYGON matches Alaska first and the entire country lands
  ## in the AK inset. R/dummy-space.R says so; this is the caller it means.
  p <- x |>
    sf::st_cast("MULTIPOLYGON", warn = FALSE) |>
    sf::st_cast("POLYGON", warn = FALSE) |>
    sf::st_transform("ESRI:102003")

  ## Region labels travel with the rows so the area gate can find them again:
  ## albers_usa_shift() rbinds CONUS, AK, HI and PR back together in that order,
  ## not the order they arrived in.
  p$region <- classify_regions(p)
  a_before <- tapply(as.numeric(sf::st_area(p)), p$region, sum)
  n_before <- table(p$region)

  s <- albers_usa_shift(p) |> sf::st_make_valid()
  a_after <- tapply(as.numeric(sf::st_area(s)), s$region, sum)
  n_after <- table(s$region)

  for (r in names(a_before)) {
    got <- if (is.na(a_after[r])) 0 else a_after[r] / a_before[r]
    if (abs(got / AREA_RATIO[[r]] - 1) > AREA_TOL)
      stop(sprintf(paste0("USDM %s: region %s changed area by %.3f%% more than the ",
                          "inset scale explains (ratio %.4f, expected %.4f).\n",
                          "  %d polygons in, %d out — the Hawaii bbox clip is the ",
                          "usual cause."),
                   d, r, 100 * abs(got / AREA_RATIO[[r]] - 1), got, AREA_RATIO[[r]],
                   n_before[[r]], if (is.na(n_after[r])) 0L else n_after[[r]]),
           call. = FALSE)
  }

  g <- s |>
    dplyr::group_by(date, usdm_class) |>
    dplyr::summarise(.groups = "drop") |>
    sf::st_cast("MULTIPOLYGON", warn = FALSE)

  g <- to_dummy(as_5070(g))
  assert_dummy_bounds(g)
  ## Label the dummy degrees EPSG:4326 for the writers; see counties.R for why
  ## the lie stops at this boundary.
  sf::st_crs(g) <- 4326

  ## nv_dummy, not nv_src: the dissolve legitimately drops a few hundred vertices
  ## where exploded polygons met, and the gate below is about what MAPSHAPER did,
  ## not about the dissolve.
  nv_dummy <- nrow(sf::st_coordinates(g))
  sf::st_write(g, f_geo, driver = "GeoJSON", delete_dsn = TRUE, quiet = TRUE,
               layer_options = c("COORDINATE_PRECISION=9", "RFC7946=NO"))

  ## Built under a temporary name and renamed only once every gate has passed.
  ## A rejected week that left its file behind would be treated as done by the
  ## incremental skip on the next run — a bad artifact, published, silently.
  f_tmp <- paste0(f_out, ".partial")
  f_rt  <- file.path("build", "usdm", sprintf("USDM_%s-roundtrip.geojson", d))
  on.exit(unlink(c(f_geo, f_tmp, f_rt)), add = TRUE)

  ## Flags match fsa-counties-dd17/dd22's own TopoJSON step
  ## (fsa-counties-dd22.R:156-166), which is the house precedent and lands on the
  ## same quantization independently. fix-geometry is theirs and is not
  ## decorative: quantization is a coordinate snap, and a snap can push a ring
  ## into itself — mapshaper ships that flag precisely because its own
  ## quantization introduces intersections. id-field is theirs alone; there is no
  ## id here. -rename-layers pins the object name to `usdm` rather than letting
  ## it follow the filename, and bbox lets the client frame without decoding.
  args <- c(shQuote(f_geo), "-rename-layers", "usdm",
            "-o", "format=topojson", paste0("quantization=", QUANTIZATION),
            "fix-geometry", "bbox", "force", shQuote(f_tmp))
  if (system2("mapshaper", args, stdout = FALSE, stderr = FALSE) != 0)
    stop("mapshaper failed for USDM ", d, call. = FALSE)

  ## Decode back and count. mapshaper snaps coincident vertices on GeoJSON
  ## import — the mechanism that broke census-counties — so this is a measured
  ## claim per week rather than one calibration generalised to 1,390.
  if (system2("mapshaper", c(shQuote(f_tmp), "-o", "format=geojson", "force",
                             shQuote(f_rt)), stdout = FALSE, stderr = FALSE) != 0)
    stop("mapshaper could not decode its own output for USDM ", d, call. = FALSE)
  nv_rt <- nrow(sf::st_coordinates(sf::read_sf(f_rt)))
  if (nv_rt < MIN_VERTEX_RETENTION * nv_dummy)
    stop(sprintf(paste0("USDM %s: %s of %s vertices survived the TopoJSON round ",
                        "trip (%.3f%%, floor %.1f%%).\n  mapshaper snaps on ",
                        "import; this is what that looks like when it goes wrong."),
                 d, format(nv_rt, big.mark = ","), format(nv_dummy, big.mark = ","),
                 100 * nv_rt / nv_dummy, 100 * MIN_VERTEX_RETENTION), call. = FALSE)

  topo <- jsonlite::fromJSON(f_tmp, simplifyVector = FALSE)
  if (!identical(names(topo$objects), "usdm"))
    stop("USDM ", d, ": TopoJSON object is '", paste(names(topo$objects), collapse = ","),
         "', expected 'usdm'", call. = FALSE)
  if (!file.rename(f_tmp, f_out))
    stop("could not place ", f_out, call. = FALSE)

  list(date = d, classes = sort(unique(g$usdm_class)), vertices = nv_dummy,
       retained = nv_rt / nv_dummy, arcs = length(topo$arcs),
       bytes = file.size(f_out), file = f_out)
}

## ── Build ────────────────────────────────────────────────────────────────────
## mirai, matching the rest of the project. It is also the only option that
## works here: parallel::mclapply FORKS, and a forked child that touches
## Objective-C runtime initialisation aborts outright on macOS —
##   "+[NSNumber initialize] may have been in progress in another thread when
##    fork() was called ... Crashing instead."
## sf pulls in GDAL, which pulls in the system frameworks that trip it, so every
## worker died before doing any work. mirai daemons are separate processes, so
## there is no fork to be unsafe.
##
## Daemons start empty: nothing from this session is visible to them, so the
## libraries, the working directory (every path here is repo-relative), the
## transform and the configuration all have to be pushed across once with
## everywhere() rather than relied upon.
message("building ", length(to_build), " week(s) on ", workers, " daemon(s)")
run_all <- function(ds) {
  if (workers <= 1L)
    return(lapply(ds, function(d) tryCatch(build_week(d), error = identity)))
  mirai::daemons(workers)
  on.exit(mirai::daemons(0), add = TRUE)
  mirai::everywhere(
    {
      suppressPackageStartupMessages({library(sf); library(dplyr); library(jsonlite)})
      setwd(wd)
      source("R/dummy-space.R")
      sf::sf_use_s2(FALSE)
    },
    wd = getwd(),
    USDM_ARCHIVE = USDM_ARCHIVE, QUANTIZATION = QUANTIZATION,
    MIN_VERTEX_RETENTION = MIN_VERTEX_RETENTION,
    AREA_RATIO = AREA_RATIO, AREA_TOL = AREA_TOL
  )
  mirai::mirai_map(ds, build_week)[.progress]
}
out <- if (length(to_build)) run_all(to_build) else list()

## A failed week comes back as a value, not a stop(), so it would otherwise
## vanish into a list that merely looks shorter than it should.
bad <- vapply(out, function(z) mirai::is_mirai_error(z) || inherits(z, "error"),
              logical(1))
if (any(bad)) {
  for (i in which(bad)) message("FAILED ", to_build[i], ": ", conditionMessage(out[[i]]))
  stop(sum(bad), " of ", length(to_build), " week(s) failed", call. = FALSE)
}
if (length(out))
  message(sprintf("built %d week(s), %.1f MB, median %.2f MB",
                  length(out), sum(vapply(out, `[[`, 0, "bytes")) / 1048576,
                  stats::median(vapply(out, `[[`, 0, "bytes")) / 1048576))

## ── The index ────────────────────────────────────────────────────────────────
## Dates only, deliberately. Per-week drought classes would be redundant: the
## app reads the week it is displaying, and usdm-counties already publishes the
## weekly class statistics a timeline would need.
##
## IT NAMES EVERY WEEK IN THE ARCHIVE, NOT EVERY WEEK ON THIS DISK. A CI runner
## builds one week and holds one file, so taking the list from the filesystem
## alone would publish an index naming a single date and erase 1,390 — the
## weekly cron quietly destroying the thing it exists to maintain. The bucket is
## the authority; local files cover the PUBLISH=0 case, where there is no bucket
## to ask.
built <- sort(unique(c(
  date_of(published),
  date_of(list.files("usdm", pattern = "\\.topojson$")),
  vapply(out, `[[`, "", "date"))))
idx <- list(
  schema       = jsonlite::unbox("sfsa-usdm-index/1"),
  space        = jsonlite::unbox(SFSA_SPACE),
  quantization = jsonlite::unbox(as.numeric(QUANTIZATION)),
  bounds       = as.numeric(DUMMY$bounds[c("xmin", "ymin", "xmax", "ymax")]),
  url          = jsonlite::unbox("USDM_{date}.topojson"),
  object       = jsonlite::unbox("usdm"),
  n            = jsonlite::unbox(length(built)),
  dates        = built
)
f_index <- file.path("usdm", "usdm-index.json")
jsonlite::write_json(idx, f_index, auto_unbox = FALSE, digits = NA)
message("index: ", length(built), " week(s), ", round(file.size(f_index) / 1024), " KB")

## ── Publish ──────────────────────────────────────────────────────────────────
if (publish) {
  to_pub <- if (force) all_dates
            else all_dates[!basename(f_for(all_dates)) %in% published]
  message("publishing ", length(to_pub), " of ", length(all_dates), " week(s)",
          if (length(to_pub) < length(all_dates))
            sprintf(" (%d already in the bucket)", length(all_dates) - length(to_pub)) else "")
  for (f in f_for(to_pub)) put_artifact(s3_bucket, s3_prefix, f, subdir = "usdm")
  ## The index always goes: it names every week, so it is stale the moment one
  ## is added.
  put_artifact(s3_bucket, s3_prefix, f_index, subdir = "usdm")
  s3_write_manifest(bucket = s3_bucket, prefix = s3_prefix)
  cf_invalidate(c(paste0("/", s3_prefix, "/usdm/*"),
                  paste0("/", s3_prefix, "/_manifest.txt")))
  message("\npublished ", length(to_pub), " week(s) to s3://", s3_bucket, "/", s3_prefix, "/usdm")
} else {
  message("\nPUBLISH=0 — built locally, nothing uploaded")
}
