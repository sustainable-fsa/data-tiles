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

## ── The AlbersUSA inset placement ────────────────────────────────────────────
## A frozen replication of tigris::shift_geometry(position = "below",
## preserve_area = FALSE) — the defaults the boundary archives call it with.
##
## WHY FROZEN RATHER THAN CALLED. shift_geometry() derives its placement from a
## LIVE download of cb_2020_us_state_20m every run: the CONUS bbox sets the
## targets, and the three state centroids set the scaling origins. If that file
## or tigris' pinned year ever changes, the composite moves — and every tileset
## already published silently misregisters against every new one. The constants
## below were reproduced from that file digit for digit (see
## tools/check-constants.R) and are now ours.
##
## The placement, from tigris' own place_geometry_wilke():
##   (geometry - centroid) * scale + target
## i.e. the region's centroid lands exactly on `target`. Targets are
## xmin + {0.08, 0.35, 0.65} * width and ymin + {0.07, 0, 0} * height of the
## CONUS bbox, which is why they are stated as absolutes here.
AUSA <- list(
  conus_bbox = c(xmin = -2356113.74289801, ymin = -1338125.39538785,
                 xmax =  2258154.44089948, ymax =  1558935.38955247),
  ## State bboxes in ESRI:102003, for classifying features and clipping Hawaii.
  ## Pairwise disjoint from the CONUS bbox, so once features are exploded to
  ## POLYGON the classification cannot misfire.
  ak_bbox = c(xmin = -5440929.96067486, ymin =  2322903.16005841,
              xmax = -2202062.97194359, ymax =  4591568.43850457),
  hi_bbox = c(xmin = -6293423.07766197, ymin =   -75047.09982280,
              xmax = -5977299.56434244, ymax =   483191.00172252),
  pr_bbox = c(xmin =  3041730.62298520, ymin = -1686301.53708693,
              xmax =  3320182.26939249, ymax = -1567207.11273847),
  ak = list(crs = 3338,          scale = 0.5,
            centroid = c( 81494.8750232504, 1538488.2508510202),
            target   = c(-1986972.28819421, -1135331.14044203)),
  hi = list(crs = "ESRI:102007", scale = 1.5,
            centroid = c( 68668.365457044,   803703.899762258),
            target   = c(-741119.878568889, -1338125.395387850)),
  pr = list(crs = 32161,         scale = 2.5,
            centroid = c(197517.918898814,   242967.470173348),
            target   = c(643160.576570359, -1338125.395387850))
)

## Place one inset: reproject to its own CRS, scale about the frozen centroid,
## land that centroid on the frozen target, then RELABEL as ESRI:102003 without
## transforming — which is what tigris does, and why the result must never be
## st_transform()ed afterwards (see to_dummy()).
place_inset <- function(x, spec) {
  g <- sf::st_transform(sf::st_geometry(x), spec$crs)
  g <- (g - spec$centroid) * spec$scale + sf::st_sfc(sf::st_point(spec$target))
  g <- sf::st_set_crs(g, "ESRI:102003")
  sf::st_geometry(x) <- g
  x
}

## ── Region classification, for data with no state FIPS ───────────────────────
## THE FROZEN BBOXES ARE THE EXTENT OF THE COUNTIES, and nothing says another
## dataset stops where counties do. The USDM is drawn at ~1:2,000,000 and drapes
## over water, so its polygons sit slightly outside the region they plainly
## belong to. Measured across the archive: an 0.85 km2 D0 polygon north-west of
## Kauai lands 226 m outside hi_bbox — in 2005, 2010 and 2013 — and 13.13 km2
## near Point Roberts lands 4,831 m above conus_bbox.
##
## This used to fall through to "00", CONUS, which is unshifted. Correct by luck
## for Point Roberts. Silently wrong for Kauai, which stays at x = -6.27e6 and
## lands at dummy x = -10.9 — caught by assert_dummy_bounds, but only as a build
## that dies partway through 1,390 weeks with nothing saying why.
##
## So pad for CLASSIFICATION ONLY, and make an unplaceable feature a hard error
## rather than a fall-through. The regions are 536-783 km apart at their closest
## (AK/HI 536, AK/CONUS 764, PR/CONUS 783), so 25 km keeps them pairwise
## disjoint by a factor of twenty.
##
## THE HAWAII CLIP IN albers_usa_shift() IS DELIBERATELY NOT PADDED. It exists to
## drop the far north-western Hawaiian islands the way tigris does, and widening
## it would change four already-published county tilesets. The Kauai polygon is
## therefore classified as Hawaii and then clipped away — right, because it is
## over open ocean, but callers should MEASURE that loss rather than assume it.
CLASSIFY_PAD_M <- 25000

classify_regions <- function(x) {
  cc <- suppressWarnings(sf::st_coordinates(sf::st_centroid(sf::st_geometry(x))))
  inside <- function(bb) {
    cc[, 1] >= bb[["xmin"]] - CLASSIFY_PAD_M & cc[, 1] <= bb[["xmax"]] + CLASSIFY_PAD_M &
      cc[, 2] >= bb[["ymin"]] - CLASSIFY_PAD_M & cc[, 2] <= bb[["ymax"]] + CLASSIFY_PAD_M
  }
  ak <- inside(AUSA$ak_bbox); hi <- inside(AUSA$hi_bbox)
  pr <- inside(AUSA$pr_bbox); us <- inside(AUSA$conus_bbox)

  orphan <- !(ak | hi | pr | us)
  if (any(orphan)) {
    i <- which(orphan)[1]
    stop(sprintf(paste0(
      "albers_usa_shift: %d feature(s) fall outside every AlbersUSA region, ",
      "even padded by %g km.\n  first at ESRI:102003 (%.0f, %.0f)\n",
      "  dummy-Albers places CONUS, AK, HI and PR only. An unplaced feature ",
      "would be left at true position and misregister silently."),
      sum(orphan), CLASSIFY_PAD_M / 1000, cc[i, 1], cc[i, 2]), call. = FALSE)
  }
  ## Same precedence as before: AK, then HI, then PR, then CONUS.
  ifelse(ak, "02", ifelse(hi, "15", ifelse(pr, "72", "00")))
}

## Lay a true-position dataset out as the AlbersUSA composite.
##
## @param x an sf in any CRS, EXPLODED TO POLYGON if `state_fips` is NULL.
##   Classification is per FEATURE by bbox, so a continental MULTIPOLYGON
##   matches Alaska first and the whole country lands in the AK inset. Counties
##   should pass `state_fips`; the USDM must explode first and is then placed by
##   classify_regions() above.
## @param state_fips optional 2-character state FIPS per feature. Deterministic,
##   and the right choice whenever the data carries it.
## @return an sf labelled ESRI:102003, insets in place
albers_usa_shift <- function(x, state_fips = NULL) {
  x <- sf::st_transform(x, "ESRI:102003")
  if (is.null(state_fips)) state_fips <- classify_regions(x)
  state_fips <- substr(as.character(state_fips), 1, 2)

  parts <- list(x[!state_fips %in% c("02", "15", "72"), ])
  if (any(state_fips == "02")) {
    parts <- c(parts, list(place_inset(x[state_fips == "02", ], AUSA$ak)))
  }
  if (any(state_fips == "15")) {
    ## tigris clips Hawaii to its own bbox first, dropping the far
    ## north-western islands that would otherwise stretch the inset.
    hi <- suppressWarnings(
      sf::st_intersection(x[state_fips == "15", ],
                          sf::st_as_sfc(sf::st_bbox(AUSA$hi_bbox, crs = sf::st_crs("ESRI:102003")))))
    parts <- c(parts, list(place_inset(hi, AUSA$hi)))
  }
  if (any(state_fips == "72")) {
    parts <- c(parts, list(place_inset(x[state_fips == "72", ], AUSA$pr)))
  }
  do.call(rbind, parts)
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
