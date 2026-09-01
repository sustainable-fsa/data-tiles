## =============================================================================
## sustainable-fsa/data-tiles · R/geo-space.R
##
## THE ONLY COPY of the sfsa-geographic/1 transform.
##
## The parallel family: everything this repo publishes, a second time, in true
## EPSG:4326. R/dummy-space.R's output renders correctly in exactly one
## application — lfp-explorer, which owns the matching js/projection.js —
## because it is an AlbersUSA composite wearing a lng/lat label. This space is
## the honest one. Real degrees, real positions, so a stock MapLibre style, a
## globe projection, QGIS, or anything else that reads GeoJSON puts the counties
## where they actually are.
##
## WHY A SEPARATE FILE RATHER THAN A MODE IN dummy-space.R. The two transforms
## share no arithmetic — one is a frozen inset layout plus a Gudermannian shear,
## the other is st_transform() — and the dummy family is already published and
## has to keep building byte-identically, which a flag threaded through the file
## tools/check-registration.R gates to 1e-9 does not help with. What they share
## is the SHAPE of the contract, and that is worth mirroring: one space token,
## one frozen camera box, one bounds gate that stops the build rather than
## warning.
##
## A `space` VALUE IS NOT A CRS. "sfsa-geographic/1" names a versioned contract
## — EPSG:4326 plus the wrapped-bbox semantics below plus the frame bounds — and
## the sidecar carries `crs: "EPSG:4326"` separately for anyone who only wants
## the projection. An app that reads the CRS and assumes the bbox convention
## would get the Aleutians wrong.
##
## WHAT IS ACTUALLY HARD HERE IS THE ANTIMERIDIAN, AND NOT IN THE GEOMETRY.
## Measured on the 2020 clipped vintage: exactly one county straddles, Aleutians
## West (02016), and its 67 polygon parts each sit wholly on one side — 14 east
## of the line, 53 west, no ring crossing it. So st_wrap_dateline() has nothing
## to do and is kept as a no-op detector (see to_geo()).
##
## The hazard is BBOX SEMANTICS. 02016's plain st_bbox() is
## [-179.1467, 179.7785]: arithmetically right, and it describes a box wrapped
## the wrong way round the planet — 359 degrees wide instead of 21. Every
## consumer of the index sidecar (fitBounds, hit-testing, "zoom to county")
## reads that as the whole Pacific. So geo sidecars publish WRAPPED bboxes via
## wrapped_bboxes(): the east-hemisphere parts are counted at lon - 360, x0
## comes back at -187.54, and MapLibre takes that happily. A geo sidecar's x0
## may therefore be less than -180, which is the convention, not a bug.
## =============================================================================

GEO_SPACE <- "sfsa-geographic/1"   # stamp this into every geo artifact

## ── The camera box, frozen ───────────────────────────────────────────────────
## NOT the extent of the data, deliberately. A geo sidecar's `bounds` is
## measured from the artifact's own geometry, which is honest and — the moment
## Guam and American Samoa are in it, which in the geo family they are — nearly
## world-wide and useless to frame a map on: fitBounds() on it opens over the
## Pacific. So publish both, and let the app pick: `bounds` for extent, this for
## the camera.
##
## Frozen for dummy-space's reason. The app's ?lng/?lat/?zoom is expressed
## against this and has to mean the same thing every session, so it is stated
## here rather than re-derived from whatever geometry a run happened to load.
GEO_FRAME <- c(xmin = -125.0, ymin = 24.0, xmax = -66.5, ymax = 49.6)

## ── The sanity envelope, for the build-side gate ─────────────────────────────
## Measured on the 2020 clipped vintage: American Samoa reaches 14.5487 S, the
## southern limit of anything the archive carries, and Alaska reaches 71.3878 N.
## Padded to 15.5 S / 72.6 N so a vintage that gains an offshore rock does not
## fail a gate that exists to catch a transform that went wrong by degrees.
##
## LONGITUDE IS THE FULL [-180, 180] AND CANNOT BE NARROWED. Guam sits at
## 144.62 E and the western Aleutians reach 179.78 E while other islands of the
## same county sit at 179.15 W, so both hemispheres are genuinely in use and any
## narrower box would be a lie that fired on correct data. The split is what
## wrapped_bboxes() is for; this gate only asks whether the numbers are degrees.
GEO_ENVELOPE <- c(xmin = -180, ymin = -15.5, xmax = 180, ymax = 72.6)

## ── Calibration constants — HYPOTHESES, not measurements ─────────────────────
## Both of these are stated from arithmetic and are confirmed or replaced by a
## measurement step (WP5) before any batch build. Nothing else in this repo is
## allowed to carry a number nobody measured; these two are marked so they get
## revisited rather than inherited.
##
## GEO_MAXZOOM: the bar is ground resolution, not zoom number. Dummy z15 at
## --full-detail=13 quantises to 0.720 m of CONUS ground. Web Mercator at z13,
## same detail, is 0.597 m at the equator — the worst case anywhere this archive
## reaches (Guam 0.581, Puerto Rico 0.568, Alaska 0.30). z12 is 1.16 m at Guam,
## which fails a 1 m bar, so 13 is the first zoom that clears it.
GEO_MAXZOOM <- 13L

## GEO_QUANTIZATION: mapshaper's -o quantization is BBOX-RELATIVE. usdm.R's
## measured table settled on q=1e6 for a dummy week, whose bbox is 10 degrees
## wide — a 4.6 x 3.1 m grid. A geo week's bbox is ~115 degrees wide, where the
## same q is a ~13 m grid, which is simplification wearing an encoding's clothes
## and is exactly what that table rejected 1e5 and 1e4 for. 1e7 restores the
## pitch.
GEO_QUANTIZATION <- "1e7"

## ── Equal-area measure ───────────────────────────────────────────────────────
## EPSG:6933 (WGS 84 / NSIDC EASE-Grid 2.0 Global). Used for the preservation
## assert in to_geo(), for the geo outline's ring measure, and — in usdm.R — for
## the per-class area gate against the source. One CRS in one place, because
## three copies of "an equal-area check" that pick different projections cannot
## be compared with each other.
##
## Planar area over straight edges in a projected CRS is not the geodesic area,
## and does not need to be: every use here is a BEFORE/AFTER comparison of the
## same measure, never a published figure.
EQUAL_AREA_CRS <- 6933L

## @param x an sf or sfc in any CRS
## @return total area in square metres, EPSG:6933, as one numeric
geo_area_m2 <- function(x) {
  sum(as.numeric(sf::st_area(sf::st_transform(sf::st_geometry(x),
                                              EQUAL_AREA_CRS))))
}

## ── True-position CRS -> sfsa-geographic/1 ───────────────────────────────────
## The whole transform. st_transform() does the work; the other three steps are
## there so that what comes out is uniform enough for the writers downstream.
##
## st_wrap_dateline() IS A NO-OP DETECTOR, AND THAT IS WHY THE AREA ASSERT SITS
## WHERE IT DOES. It is GDAL-backed, so it works with s2 switched off (this repo
## runs sf_use_s2(FALSE)) — verified on Alaska 2020: identical bbox, identical
## 6933 area to the last bit. It is kept because the USDM is hand-drawn at
## ~1:2,000,000 and nothing upstream promises its rings stop at the line.
##
## If a ring ever DOES cross, the wrap splits it — and the split changes the
## 6933 area enormously, because a ring whose lon jumps from +179 to -179
## projects to one that girdles the planet. The assert then stops the build. It
## is reporting a real repair, not a failure of the repair, and the right
## response is to look at the source rather than to loosen the tolerance: this
## file's contract is that the geometry arrives already split, and the assert is
## what keeps that a fact instead of an assumption.
##
## @param x an sf or sfc in any true-position CRS (NOT a dummy-space geometry —
##   those are labelled EPSG:4326 and reprojecting them is meaningless)
## @return the same class, EPSG:4326, MULTIPOLYGON throughout
to_geo <- function(x) {
  x <- sf::st_transform(x, 4326)
  before <- geo_area_m2(x)

  x <- sf::st_wrap_dateline(x)
  x <- sf::st_make_valid(x)

  ## st_wrap_dateline() and st_make_valid() both return the SIMPLEST type per
  ## feature, so Alaska comes back 22 MULTIPOLYGON and 8 POLYGON — a mixed
  ## column is an sfc_GEOMETRY and st_coordinates() has no method for it, which
  ## is how the dummy pipeline died once after writing a correct 192 MB
  ## GeoJSONL (see census.R). st_cast() handles that mix directly; only a
  ## GEOMETRYCOLLECTION defeats it, and then with "incorrect number of
  ## dimensions" rather than anything that names the problem. make_valid
  ## produces one when a MULTIPOLYGON carries a zero-area part: the good part
  ## stays a polygon and the degenerate one comes back a LINESTRING beside it.
  ## (A zero-width spike on an exterior ring does NOT do it — GEOS shaves that
  ## and returns POLYGON.) Extract the areal part and say so; the area assert
  ## below is downstream of this, so an extract that drops anything with area
  ## in it fails the build rather than passing quietly.
  if (any(sf::st_geometry_type(x) == "GEOMETRYCOLLECTION")) {
    message("  to_geo: st_make_valid returned GEOMETRYCOLLECTION(s); ",
            "extracting POLYGON")
    x <- sf::st_collection_extract(x, "POLYGON")
  }
  x <- sf::st_cast(x, "MULTIPOLYGON")

  after <- geo_area_m2(x)
  rel <- abs(after - before) / before
  if (!is.finite(rel) || rel > 1e-6) {
    stop(
      "to_geo: equal-area not preserved across the wrap — a dateline-crossing ",
      "ring, not a rounding error.\n",
      sprintf("  before %.6f m2 (EPSG:%d)\n", before, EQUAL_AREA_CRS),
      sprintf("  after  %.6f m2\n", after),
      sprintf("  relative %.3e, tolerance %.0e", rel, 1e-6),
      call. = FALSE
    )
  }

  assert_geo_envelope(x)
  x
}

## ── Wrapped per-feature bboxes ───────────────────────────────────────────────
## The sidecar's x0/y0/x1/y1 columns. See the header: a feature with parts on
## both sides of the antimeridian has a plain st_bbox() 359 degrees wide, which
## every consumer reads as the whole Pacific. Count the east-hemisphere parts at
## lon - 360 instead and the box is contiguous and 21 degrees wide, with x0
## below -180.
##
## THE THRESHOLD IS PER VERTEX AND THAT IS SAFE ONLY BECAUSE to_geo() RAN. No
## ring crosses the line after the wrap, so no ring has vertices in both halves,
## so shifting every vertex above +90 can never tear one apart. Applied to
## unwrapped input it could.
##
## 90 rather than 0: a feature spanning +145 (Guam) and -170 (American Samoa)
## would be a genuine near-world extent rather than a dateline artefact, and no
## county is both. The straddle test is on the plain bbox, so the expensive path
## runs for the one feature in 3,234 that needs it and the rest are untouched —
## an ordinary CONUS county's row is st_bbox() exactly.
WRAP_SPLIT_DEG <- 90

## @param x an sf or sfc already through to_geo()
## @return a data.frame of x0, y0, x1, y1 in feature order, unrounded (callers
##   round to 6 dp, which is 11 cm)
wrapped_bboxes <- function(x) {
  g <- sf::st_geometry(x)
  bx <- do.call(rbind, lapply(g, function(gi) as.numeric(sf::st_bbox(gi))))
  straddle <- which(bx[, 1] < -WRAP_SPLIT_DEG & bx[, 3] > WRAP_SPLIT_DEG)
  for (i in straddle) {
    cc  <- sf::st_coordinates(g[[i]])
    lon <- cc[, 1]
    east <- lon > WRAP_SPLIT_DEG
    lon[east] <- lon[east] - 360
    bx[i, ] <- c(min(lon), min(cc[, 2]), max(lon), max(cc[, 2]))
  }
  data.frame(x0 = bx[, 1], y0 = bx[, 2], x1 = bx[, 3], y1 = bx[, 4])
}

## Ring area in square metres for a geo outline, the argument R/outline.R's
## dissolve_outline() takes as `ring_m2`. Its default is the dummy measure —
## planar deg2 scaled by DUMMY$deg_m — which is not merely imprecise on real
## degrees but wrong by a factor: a 1 x 1 degree box is 12,308 km2 at the
## equator and 6,123 km2 at 60 N, and the dummy measure calls both 288,363.
## Lives here so a caller does not re-derive it and pick a different projection
## than geo_area_m2() does.
##
## @param r a closed coordinate matrix, lng/lat
## @return area in square metres, EPSG:6933
geo_ring_m2 <- function(r) {
  abs(as.numeric(
    sf::st_sfc(sf::st_polygon(list(r)), crs = 4326) |>
      sf::st_transform(EQUAL_AREA_CRS) |>
      sf::st_area()
  ))
}

## ── Artifact naming ──────────────────────────────────────────────────────────
## The dummy family's names are already published and cannot gain a suffix, so
## the geo family takes one and dummy keeps the empty string. Every artifact
## name in every script goes through this, which is what makes the incremental
## skip per-space for free: the two spaces simply cannot collide on a filename.
##
## Hard error on anything else. SPACE comes from the environment, and a typo
## that fell through to "" would rebuild and republish the dummy family under a
## geo run's flags.
space_suffix <- function(space) {
  switch(space,
         dummy = "",
         geo   = "-geo",
         stop("unknown space '", space, "' — expected 'dummy' or 'geo'",
              call. = FALSE))
}

## ── The bounds gate ──────────────────────────────────────────────────────────
## Mirrors assert_dummy_bounds(). A vertex outside the envelope means the
## transform went wrong by degrees — an unprojected metre coordinate, a dummy
## geometry fed in by mistake, a datum that never got applied. This stops the
## build; it must never warn.
##
## @param x an sf/sfc already in EPSG:4326
## @param tol_deg slack around the envelope (0.02 deg = ~2.2 km)
assert_geo_envelope <- function(x, tol_deg = 0.02) {
  bb <- sf::st_bbox(x)
  b  <- GEO_ENVELOPE
  if (bb[["xmin"]] < b[["xmin"]] - tol_deg ||
      bb[["ymin"]] < b[["ymin"]] - tol_deg ||
      bb[["xmax"]] > b[["xmax"]] + tol_deg ||
      bb[["ymax"]] > b[["ymax"]] + tol_deg) {
    stop(
      "sfsa-geographic bounds violated — not a rounding error.\n",
      sprintf("  got      %.10f %.10f %.10f %.10f\n",
              bb[["xmin"]], bb[["ymin"]], bb[["xmax"]], bb[["ymax"]]),
      sprintf("  envelope %.10f %.10f %.10f %.10f  (+/- %g)",
              b[["xmin"]], b[["ymin"]], b[["xmax"]], b[["ymax"]], tol_deg),
      call. = FALSE
    )
  }
  invisible(x)
}
