## =============================================================================
## sustainable-fsa/data-tiles · R/outline.R
##
## The national outline, dissolved from a county set already in dummy degrees.
##
## Published because the USDM pipeline clips against it: the NDMC's own
## coastline is ~1:2,000,000 and would spill past the counties otherwise.
##
## AN ENCLOSED RING IN A DISSOLVED COUNTY SET IS ALMOST NEVER WATER. Where a
## boundary file is not edge-matched, unioning it leaves a pinhole everywhere
## neighbours fail to meet, and every one of those punches a hole through the
## layer this outline exists to clip. Measured on fsa-lfp-counties: 491 of them,
## 0.2 km2 in total against 9,323,313, median 0.06 m2, largest 0.19 km2, and not
## one a lake.
##
## So drop them — but as a GUARD, not a blanket fill, which is the shape
## census-counties' fill_holes() settled on for the same problem: a ring big
## enough to be real water is kept and announced, so the day one appears it is
## visible rather than silently swallowed.
##
## THIS IS SHARED BECAUSE TWO COPIES DRIFT. counties.R still inlines a bare
## st_union() and should adopt this the next time dd17/dd22 are rebuilt; its
## outline happens to carry no holes today, so the two agree by luck rather
## than by construction.
## =============================================================================

## Dissolve `x` to a single outline, dropping pinholes below `max_hole_m2`.
##
## @param x an sf in dummy degrees, LABELLED EPSG:4326 (see counties.R on why
##   the label is a lie that stops at the writer boundary)
## @param max_hole_m2 keep-and-announce threshold; rings above it survive
## @param quiet suppress the per-call message
## @return an sfc of one MULTIPOLYGON, crs 4326
dissolve_outline <- function(x, max_hole_m2 = 1e6, quiet = FALSE) {
  ## Ring area via a CRS-less st_polygon, deliberately: x is LABELLED EPSG:4326
  ## and st_area() would read that label and return geodesic metres off dummy
  ## degrees, which are not degrees. Planar deg2 scaled by deg_m is the only
  ## honest reading.
  ring_m2 <- function(r) {
    abs(as.numeric(sf::st_area(sf::st_polygon(list(r))))) * DUMMY$deg_m^2
  }

  dropped <- 0L
  kept    <- numeric(0)
  parts <- lapply(sf::st_cast(sf::st_union(x), "MULTIPOLYGON")[[1]], function(pp) {
    if (length(pp) == 1L) return(pp)
    a   <- vapply(pp[-1], ring_m2, numeric(1))
    big <- a > max_hole_m2
    dropped <<- dropped + sum(!big)
    kept    <<- c(kept, a[big])
    pp[c(TRUE, big)]
  })

  if (!quiet) {
    message(sprintf("  outline: %d parts, %d pinholes dropped, %d rings kept",
                    length(parts), dropped, length(kept)))
    if (length(kept))
      message(sprintf("    kept ring > %.0f km2: %s", max_hole_m2 / 1e6,
                      paste(sprintf("%.2f km2", kept / 1e6), collapse = ", ")))
  }
  sf::st_sfc(sf::st_multipolygon(parts), crs = 4326)
}

## Write one to disk, with the writer options every artifact in this repo uses.
write_outline <- function(g, path) {
  g |>
    sf::st_sf(geometry = _) |>
    sf::st_write(path, driver = "GeoJSON", delete_dsn = TRUE, quiet = TRUE,
                 layer_options = c("COORDINATE_PRECISION=9", "RFC7946=NO"))
  invisible(path)
}
