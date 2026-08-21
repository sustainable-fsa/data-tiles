#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · tools/check-registration.R
##
## GATE G4. Proves this repo's R implementation of sfsa-albers-usa/1 agrees with
## lfp-explorer's JavaScript one to 1e-9 dummy degrees (~0.5 mm).
##
## This is the most valuable test in the pipeline. The failure it catches is
## otherwise invisible: two implementations that disagree render layers that
## line up at the centre of the map and drift apart toward the edges, with
## nothing on screen to indicate it. Nobody notices until a drought polygon sits
## a few hundred metres off the county it is supposed to explain — permanently,
## in tiles that have already been published.
##
## The twelve points are the reference table in js/projection.js, which is the
## specification. They are PUBLISHED (already AlbersUSA-shifted) lng/lat in
## EPSG:4269, so the comparable R path is 4269 -> 5070 -> to_dummy(); the inset
## shift has no JavaScript counterpart and is gated separately by
## assert_dummy_bounds() and the composite-extent check below.
##
## EPSG:4269, not 4326: from 4326 PROJ inserts a WGS84->NAD83 datum shift and
## (-96, 29.5) comes back at x = 0.43 m instead of x = 0.
##
## Run from the repo root, as the sibling archives run theirs:
##
##   Rscript tools/check-registration.R
## =============================================================================

suppressPackageStartupMessages({library(sf)})
source("R/dummy-space.R")

TOL <- 1e-9

## lng, lat (EPSG:4269), then the dummy x/y js/projection.js produces.
REF <- data.frame(
  lng = c(-96, -96, -100, -80, -110, -155, -68,
          -113.9967, -125.2581512, -125.2581512, -66.9498943, -66.9498943),
  lat = c(23, 29.5, 40, 30, 45.5, 60, 42,
          46.8721, 49.3843626, 18.5921373, 49.3843626, 18.5921373),
  x   = c(0.7947477083, 0.7947477083, 0.1645913869, 3.6529679418,
          -1.2355505808, -5.5697326102, 5.0224850448, -1.7556369197,
          -3.1546051115, -5.0762148857, 4.7169014166, 6.6252771038),
  y   = c(-2.8690890227, -1.5406289019, 0.6569201213, -1.1962819573,
          1.9371708604, 6.7049406421, 1.6878038573, 2.3127478380,
          3.1978918714, -2.8423860441, 3.1892891466, -2.8551786008)
)

pts <- sf::st_as_sf(REF, coords = c("lng", "lat"), crs = 4269)
got <- sf::st_coordinates(to_dummy(sf::st_transform(pts, 5070)))

dx <- abs(got[, 1] - REF$x)
dy <- abs(got[, 2] - REF$y)

cat(sprintf("%13s %11s  %16s %16s  %10s %10s\n",
            "lng", "lat", "dummy x", "dummy y", "dx", "dy"))
for (i in seq_len(nrow(REF))) {
  cat(sprintf("%13g %11g  %16.10f %16.10f  %10.2e %10.2e%s\n",
              REF$lng[i], REF$lat[i], got[i, 1], got[i, 2], dx[i], dy[i],
              if (max(dx[i], dy[i]) > TOL) "  <-- FAIL" else ""))
}

## The reference table is rounded to 10 decimals, so the floor on agreement is
## 5e-11 per coordinate; TOL is an order of magnitude above that.
worst <- max(dx, dy)
cat(sprintf("\nworst disagreement: %.3e dummy degrees (%.4f mm on the ground)\n",
            worst, worst * DUMMY$deg_m * 1000))

## The shear correction is the half most likely to be missing, and it vanishes
## at the equator — so report the high-|y| points separately. A producer that
## skipped gudermannian() passes a centre-only test and fails here by ~765 m.
edge <- which(abs(REF$y) > 3)
cat(sprintf("high-|y| points checked: %d (max |y| = %.4f) — these are what catch a missing Gudermannian\n",
            length(edge), max(abs(REF$y))))

if (worst > TOL) {
  stop(sprintf("check-registration: worst disagreement %.3e exceeds %.0e", worst, TOL),
       call. = FALSE)
}
cat("\ncheck-registration: OK — R and JS agree to", format(TOL), "dummy degrees\n")
