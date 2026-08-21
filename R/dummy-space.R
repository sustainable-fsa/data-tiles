## =============================================================================
## sustainable-fsa/data-tiles · R/dummy-space.R
##
## THE ONLY COPY of the sfsa-albers-usa/1 transform.
##
## Every tileset this repo publishes is pre-projected into a "dummy" coordinate
## space: the AlbersUSA composite, rescaled into a 10-degree box centred on
## (0, 0), which MapLibre then renders as if it were lng/lat. The consuming app
## (sustainable-fsa/lfp-explorer, js/projection.js) implements the same
## transform in JavaScript and frames its camera on the same bounds.
##
## WHY THIS IS NOT VENDORED INTO THE ARCHIVE REPOS. Two implementations that
## disagree produce a silent misregistration — layers that line up at the centre
## of the map and drift apart toward the edges, with nothing on screen to say
## so. `R/s3-archive.R` exists in 16 copies across 3 distinct versions in this
## workspace, which is exactly how that happens. This repo owns the transform;
## the archives stay projection-neutral and publish true-position WGS84.
## tools/check-registration.R is the gate.
##
## THE SPECIFICATION is the header of js/projection.js in lfp-explorer, which
## carries twelve reference points in both Albers metres and dummy degrees.
## Agreement to 1e-9 dummy degrees (about half a millimetre) is the contract.
## The constants below are deliberately the SAME NUMBERS as that file's
## CENTER_X_M / CENTER_Y_M / M_TO_DEG, so the two can be compared by eye.
## =============================================================================

SFSA_SPACE <- "sfsa-albers-usa/1"   # stamp this into every artifact

DUMMY <- list(
  ## Identical to js/projection.js. Measured from the composite's own extent and
  ## FROZEN — never re-derived from whatever geometry happens to be loaded. The
  ## app's ?lng/?lat/?zoom camera is expressed in this space and has to mean the
  ## same thing every session, and both boundary vintages have to land in the
  ## same space or crossing 2015 would shift the map under a camera that never
  ## moved.
  center_x_5070 = -426775.2855,
  center_y_5070 =  1541329.8055,
  m_to_deg      =  1.86221586701e-06,
  deg_m         =  536994.6727,

  ## ESRI:102003 -> EPSG:5070 is a pure northing offset: x is identical in both,
  ## and y_5070 = y_102003 + 1606786.26058 m exactly (measured against PROJ at
  ## widely spread points). tigris::shift_geometry() lays the composite out in
  ## 102003, so the pipeline adds this before calling to_dummy().
  y_102003_to_5070 = 1606786.26058,

  ## The composite's extent in dummy degrees, shear-corrected. Frozen; compare
  ## against it, never recompute it.
  bounds = c(xmin = -5, ymin = -3.0362967564608283,
             xmax =  5, ymax =  3.0362967564608283)
)

## ── The shear correction ─────────────────────────────────────────────────────
## MapLibre runs Web Mercator over these fake degrees, and Mercator's y IS the
## inverse Gudermannian of latitude. A dummy latitude left LINEAR in Albers
## northing therefore renders stretched by 1/cos(lat) — 1.000152 at dummy lat 1,
## 1.001407 at the box edge — accumulating to 765 m of displacement from a true
## Albers plane at the top and bottom edges. Albers is used BECAUSE it is
## equal-area, so that stretch is also a 0.141% area error.
##
## Emit the Gudermannian of the linear value and Mercator undoes it exactly.
## Edge: linear 3.0377188926 -> 3.0362967564 (0.0014221362 deg, 764 m).
##
## A producer that skips this matches at the centre of the map and is 765 m out
## at the edges, so any registration test MUST include a high-|y| point.
gudermannian <- function(deg) {
  (360 / pi) * atan(exp(pi * deg / 180)) - 90
}

## ── EPSG:5070 metres -> dummy degrees ────────────────────────────────────────
## Pure arithmetic. NEVER st_transform() a shifted geometry on the way in:
## tigris::shift_geometry() relabels the Alaska and Hawaii insets as ESRI:102003
## without transforming them, so those coordinates are not really in that CRS
## and reprojecting them is meaningless. Add y_102003_to_5070 instead.
##
## @param x an sf or sfc in EPSG:5070 metres (or 102003 + the offset)
## @return the same class, coordinates in dummy degrees, CRS dropped
to_dummy <- function(x) {
  f <- function(m) {
    m[, 1] <- (m[, 1] - DUMMY$center_x_5070) * DUMMY$m_to_deg
    m[, 2] <- gudermannian((m[, 2] - DUMMY$center_y_5070) * DUMMY$m_to_deg)
    m
  }
  g <- sf::st_geometry(x)
  out <- sf::st_sfc(lapply(g, map_sfg, f = f))   # CRS deliberately absent
  if (inherits(x, "sf")) {
    sf::st_geometry(x) <- out
    x
  } else {
    out
  }
}

## Apply `f` to every coordinate matrix in one sfg, preserving its class. An
## sfg is a matrix (LINESTRING), a list of matrices (POLYGON), a list of lists
## (MULTIPOLYGON), or a bare numeric (POINT) — one recursion covers all four.
map_sfg <- function(g, f) {
  walk <- function(z) {
    if (is.matrix(z)) return(f(z))
    if (is.numeric(z)) return(as.numeric(f(matrix(z, nrow = 1))))
    lapply(z, walk)
  }
  out <- walk(unclass(g))
  class(out) <- class(g)
  out
}

## Shift an ESRI:102003-labelled geometry into EPSG:5070 numbers. Arithmetic
## only, for the reason in to_dummy()'s note.
as_5070 <- function(x) {
  g <- sf::st_geometry(x)
  g <- sf::st_set_crs(g, NA)
  out <- g + c(0, DUMMY$y_102003_to_5070)
  if (inherits(x, "sf")) {
    sf::st_geometry(x) <- out
    x
  } else {
    out
  }
}

## ── The bounds gate ──────────────────────────────────────────────────────────
## A vertex outside the frozen box means a mis-shift, and a mis-shift silently
## multiplies the tileset extent. This stops the build; it must never warn.
##
## @param x an sf/sfc already in dummy degrees
## @param tol_deg slack around the frozen box (0.02 deg = ~10.7 km)
assert_dummy_bounds <- function(x, tol_deg = 0.02) {
  bb <- sf::st_bbox(x)
  b  <- DUMMY$bounds
  if (bb[["xmin"]] < b[["xmin"]] - tol_deg ||
      bb[["ymin"]] < b[["ymin"]] - tol_deg ||
      bb[["xmax"]] > b[["xmax"]] + tol_deg ||
      bb[["ymax"]] > b[["ymax"]] + tol_deg) {
    stop(
      "dummy-space bounds violated — a mis-shift, not a rounding error.\n",
      sprintf("  got      %.10f %.10f %.10f %.10f\n",
              bb[["xmin"]], bb[["ymin"]], bb[["xmax"]], bb[["ymax"]]),
      sprintf("  expected %.10f %.10f %.10f %.10f  (+/- %g)",
              b[["xmin"]], b[["ymin"]], b[["xmax"]], b[["ymax"]], tol_deg),
      call. = FALSE
    )
  }
  invisible(x)
}
