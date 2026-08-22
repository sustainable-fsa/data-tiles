#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · tools/check-coverage.R
##
## Gate: every county in the index is present in the tiles at every zoom the app
## can actually display.
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
##   Rscript tools/check-coverage.R
## =============================================================================

suppressPackageStartupMessages({library(jsonlite)})

VINTAGE  <- Sys.getenv("VINTAGE", "dd22")
ZOOMS    <- as.integer(strsplit(Sys.getenv("ZOOMS", "4,6,8"), "[, ]+")[[1]])
PMTILES  <- file.path("tiles", sprintf("fsa-counties-%s.pmtiles", VINTAGE))
INDEX    <- file.path("tiles", sprintf("fsa-counties-%s-index.json", VINTAGE))
stopifnot(file.exists(PMTILES), file.exists(INDEX))

idx   <- jsonlite::fromJSON(INDEX)
total <- unique(idx$counties)
cat(sprintf("index: %d counties (%d distinct)\n", idx$n, length(total)))
if (length(total) != idx$n) {
  stop("check-coverage: the index carries DUPLICATE ids (", idx$n, " rows, ",
       length(total), " distinct). Dissolve by id alone.", call. = FALSE)
}

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
    nmz <- idx$county_names[match(head(sort(miss), 5), idx$counties)]
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
