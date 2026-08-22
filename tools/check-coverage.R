#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · tools/check-coverage.R
##
## Gate: every county in a tileset's source is present in the tiles at every
## zoom the app can actually display.
##
## This is the gate for the worst pipeline failure, because it is the one that
## does not look like a failure: a choropleth with silent holes still renders as
## a map. Any tippecanoe flag that drops features to meet a size budget
## (--drop-densest-as-needed, --coalesce, a tile-size limit) produces exactly
## that, and nothing else in the stack would notice.
##
## Z0 IS EXPECTED TO BE INCOMPLETE, and that is not a defect. At z0 the whole
## composite spans roughly seven pixels, so sub-pixel counties — San Francisco,
## Broomfield, Gilpin — cannot survive quantization at any setting. Measured:
## 3,045 of 3,106 at z0, complete from z4 up. The app's zoom floor sits near
## display zoom 6.5, so it never requests a zoom that is short.
##
## WHERE THE EXPECTED IDS COME FROM, in order:
##   1. tiles/<TILESET>-index.json, for the tilesets that publish a sidecar
##      (fsa-counties-dd17/dd22, fsa-lfp-counties).
##   2. for census-counties-<year>, the cached clipped parquet the build read,
##      re-filtered here. Deriving them again from the source rather than from
##      anything census.R wrote is the point: a gate that trusts the build's own
##      bookkeeping cannot catch the build losing a county before tippecanoe
##      ever saw it.
##
##   Rscript tools/check-coverage.R                                  # dd22
##   TILESET=fsa-lfp-counties Rscript tools/check-coverage.R
##   TILESET=census-counties-2020 ZOOMS=4,6 Rscript tools/check-coverage.R
## =============================================================================

suppressPackageStartupMessages({library(jsonlite)})

## VINTAGE is kept for the original call shape, TILESET generalises it.
VINTAGE <- Sys.getenv("VINTAGE", "")
TILESET <- Sys.getenv("TILESET", "")
if (!nzchar(TILESET))
  TILESET <- sprintf("fsa-counties-%s", if (nzchar(VINTAGE)) VINTAGE else "dd22")

ZOOMS   <- as.integer(strsplit(Sys.getenv("ZOOMS", "4,6,8"), "[, ]+")[[1]])
PMTILES <- file.path("tiles", paste0(TILESET, ".pmtiles"))
INDEX   <- file.path("tiles", paste0(TILESET, "-index.json"))
stopifnot(file.exists(PMTILES))

## Territories dummy-Albers cannot place. Duplicated from the build scripts on
## purpose: a gate that imports the value it is checking checks nothing.
DROP_STATES <- c("60", "78", "14", "52", "69", "66")

## Expected ids, and a name per id for the failure message.
expected_from_index <- function() {
  idx <- jsonlite::fromJSON(INDEX)
  if (length(unique(idx$counties)) != idx$n)
    stop("check-coverage: the index carries DUPLICATE ids (", idx$n, " rows, ",
         length(unique(idx$counties)), " distinct). Dissolve by id alone.",
         call. = FALSE)
  stats::setNames(idx$counties, idx$county_names)
}

expected_from_census <- function(year) {
  f <- file.path("build", "census", sprintf("%s-counties.parquet", year))
  if (!file.exists(f))
    stop("check-coverage: ", f, " is not cached — run\n",
         "  VINTAGES=", year, " PUBLISH=0 Rscript census.R\n",
         "first, or point CLIPPED_", year, " at a local copy.", call. = FALSE)
  p <- arrow::read_parquet(f, col_select = c("STATEFP", "COUNTYFP", "County"))
  p <- p[!as.character(p$STATEFP) %in% DROP_STATES, ]
  stats::setNames(paste0(as.character(p$STATEFP), as.character(p$COUNTYFP)),
                  as.character(p$County))
}

expected <-
  if (file.exists(INDEX)) {
    expected_from_index()
  } else if (grepl("^census-counties-[0-9]{4}$", TILESET)) {
    suppressPackageStartupMessages(library(arrow))
    expected_from_census(sub("^census-counties-", "", TILESET))
  } else {
    stop("check-coverage: no index sidecar at ", INDEX,
         " and no source rule for tileset '", TILESET, "'.", call. = FALSE)
  }

total <- unique(unname(expected))
cat(sprintf("%s: %d counties expected\n", TILESET, length(total)))
if (length(total) != length(expected))
  stop("check-coverage: the source carries DUPLICATE ids (", length(expected),
       " rows, ", length(total), " distinct). Dissolve by id alone.", call. = FALSE)

## Tile range covering the frozen bounds, with a tile of slack.
tiles_for <- function(z) {
  n <- 2^z
  xt <- function(lon) as.integer((lon + 180) / 360 * n)
  yt <- function(lat) as.integer((1 - asinh(tan(lat * pi / 180)) / pi) / 2 * n)
  expand.grid(z = z, x = seq(xt(-5.02), xt(5.02)), y = seq(yt(3.04), yt(-3.04)))
}

ids_at <- function(z) {
  tl <- tiles_for(z)
  seen <- character(0)
  for (i in seq_len(nrow(tl))) {
    out <- suppressWarnings(system2("tippecanoe-decode",
      c(shQuote(PMTILES), tl$z[i], tl$x[i], tl$y[i]), stdout = TRUE, stderr = FALSE))
    if (!length(out)) next
    d <- try(jsonlite::fromJSON(paste(out, collapse = "\n"), simplifyVector = FALSE), silent = TRUE)
    if (inherits(d, "try-error")) next
    for (lay in d$features) {
      if (!identical(lay$properties$layer, "counties")) next
      for (f in lay$features) {
        id <- f$properties$id
        if (!is.null(id)) seen <- c(seen, id)
      }
    }
  }
  list(ids = unique(seen), ntiles = nrow(tl))
}

bad <- integer(0)
for (z in ZOOMS) {
  r <- ids_at(z)
  miss <- setdiff(total, r$ids)
  cat(sprintf("  z%-2d %4d tiles   present %5d   missing %4d%s\n",
              z, r$ntiles, length(r$ids), length(miss),
              if (length(miss)) "   <-- FAIL" else ""))
  if (length(miss)) {
    nmz <- names(expected)[match(head(sort(miss), 5), unname(expected))]
    cat("      e.g. ", paste(nmz, collapse = ", "), "\n", sep = "")
    bad <- c(bad, z)
  }
}

if (length(bad)) {
  stop("check-coverage: counties missing at zoom(s) ", paste(bad, collapse = ", "),
       ".\n  A choropleth with holes still looks like a map — this is the failure\n",
       "  that hides. Check for --drop-*, --coalesce-*, or a tile-size limit.",
       call. = FALSE)
}
cat("\ncheck-coverage: OK — every county present at every audited zoom\n")
