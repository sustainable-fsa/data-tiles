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
## IN THE GEO FAMILY THAT FLOOR IS Z5, and unlike dummy's it is reachable: a
## stock map framed on GEO_FRAME sits near z4, where Rose Island — 0.0998 km2 of
## American Samoa, a quarter of one z4 quantisation cell — has no area left to
## encode and is not in the tiles. Sub-pixel arithmetic, not a dropped feature:
## the geo builds pass --no-tiny-polygon-reduction, --no-tile-size-limit and
## --no-feature-limit, checked in the tileset's own generator_options. The audited
## zooms say so (see ZOOMS below).
##
## WHERE THE EXPECTED IDS COME FROM. The source wins wherever there is a rule
## for it — for census-counties-<year>, the cached clipped parquet the build
## read, re-filtered here. Deriving them again from the source rather than from
## anything census.R wrote is the point: a gate that trusts the build's own
## bookkeeping cannot catch the build losing a county before tippecanoe ever
## saw it. Otherwise they come from tiles/<TILESET>-index.json.
##
## WHERE BOTH EXIST, THEY ARE COMPARED, and a disagreement is a failure. That
## check is the only thing standing behind the sidecars: without it, publishing
## an index for a tileset that already had a source rule would silently demote
## this gate from "the tiles match the archive" to "the tiles match what the
## build said it wrote".
##
## TWO SPACES, DERIVED FROM THE NAME. A `-geo` tileset is in sfsa-geographic/1 —
## real degrees, real positions, territories included — and everything spatial
## here changes with it: which counties are expected, and which tiles have to be
## asked. The suffix is the only signal, and it is read rather than passed
## because TILESET already carries it.
##
## NOTHING IN THIS FILE IS IMPORTED FROM R/. Not the drop sets, not the audit
## boxes, not the zoom ceiling. Two of those are stated twice in this repo on
## purpose, and the third is read out of the PMTiles header — the tileset itself,
## which is the only party to the question that cannot be wrong about it.
##
##   Rscript tools/check-coverage.R                                  # dd22
##   TILESET=fsa-lfp-counties Rscript tools/check-coverage.R
##   TILESET=census-counties-2020 ZOOMS=4,6 Rscript tools/check-coverage.R
##   TILESET=census-counties-2020-geo Rscript tools/check-coverage.R
## =============================================================================

suppressPackageStartupMessages({library(jsonlite)})

## VINTAGE is kept for the original call shape, TILESET generalises it.
VINTAGE <- Sys.getenv("VINTAGE", "")
TILESET <- Sys.getenv("TILESET", "")
if (!nzchar(TILESET))
  TILESET <- sprintf("fsa-counties-%s", if (nzchar(VINTAGE)) VINTAGE else "dd22")

SPACE   <- if (grepl("-geo$", TILESET)) "geo" else "dummy"

## THE AUDITED ZOOMS ARE PER SPACE, AND THE GEO FLOOR IS Z5. Same physics as z0
## in dummy space, one zoom higher and for one county: at z4 the world is 16 tiles
## across, so a tile's 4,096-unit extent quantises to a 610 m cell — 0.37 km2 —
## and Rose Island, 0.0998 km2 by the clipped archive's own Area column, is a
## quarter of one. Measured on census-counties-2020-geo: 3,233 of 3,234 at z4,
## complete from z5 up. Dummy space never met this because it drops the
## territories, and everything it does carry clears its quantum by z4.
ZOOMS   <- as.integer(strsplit(
  Sys.getenv("ZOOMS", if (SPACE == "geo") "5,6,8" else "4,6,8"),
  "[, ]+")[[1]])
PMTILES <- file.path("tiles", paste0(TILESET, ".pmtiles"))
INDEX   <- file.path("tiles", paste0(TILESET, "-index.json"))
stopifnot(file.exists(PMTILES))

## ── What the tileset says about itself ───────────────────────────────────────
## THE ZOOM CEILING IS READ, NEVER ASSUMED. The dummy family stops at 15 and the
## geo family at a maxzoom chosen for ground resolution rather than zoom number,
## so a literal here would be a number this gate has to be edited to keep — and
## the failure mode is the ugly one: ZOOMS=15 against a z13 tileset decodes
## nothing at all and reports every county missing at once.
##
## The PMTiles v3 header is a fixed, UNCOMPRESSED 127-byte little-endian struct
## at offset 0: 7-byte magic, version, eleven uint64s (bytes 8..95), then
## clustered / internal compression / tile compression / tile type at 96..99, and
## min and max zoom at 100 and 101. R indexes from 1, hence h[101] and h[102].
pmtiles_zooms <- function(f) {
  h <- readBin(f, "raw", n = 127L)
  if (length(h) < 127L || !identical(rawToChar(h[1:7]), "PMTiles"))
    stop("check-coverage: ", f, " is not a PMTiles file.", call. = FALSE)
  if (as.integer(h[8]) != 3L)
    stop("check-coverage: ", f, " is PMTiles v", as.integer(h[8]),
         ", and this header layout is v3's.", call. = FALSE)
  c(minzoom = as.integer(h[101]), maxzoom = as.integer(h[102]))
}

TZ <- pmtiles_zooms(PMTILES)
cat(sprintf("%s: %s space, tiles z%d..z%d\n",
            TILESET, SPACE, TZ[["minzoom"]], TZ[["maxzoom"]]))
if (any(ZOOMS > TZ[["maxzoom"]] | ZOOMS < TZ[["minzoom"]]))
  stop("check-coverage: ZOOMS=", paste(ZOOMS, collapse = ","),
       " asks for zoom(s) this tileset does not carry (z", TZ[["minzoom"]],
       "..z", TZ[["maxzoom"]], ").\n  An absent zoom decodes to nothing and",
       " would be reported as every county missing.", call. = FALSE)

## Territories the space cannot place. Duplicated from the build scripts on
## purpose: a gate that imports the value it is checking checks nothing.
##
## THE GEO FAMILY DROPS NOTHING, and that is the whole reason it exists. The six
## codes below are dummy-Albers' limit — it places CONUS, AK, HI and PR and has
## nowhere to put Guam, the Marianas, American Samoa or the USVI — not a
## statement about the archive, which carries them. In sfsa-geographic/1 they sit
## where they actually are, so the expected set is the source's own.
DROP_STATES <- if (SPACE == "geo") character(0) else
  c("60", "78", "14", "52", "69", "66")

## Expected ids, and a name per id for the failure message.
expected_from_index <- function() {
  idx <- jsonlite::fromJSON(INDEX)
  if (length(unique(idx$counties)) != idx$n)
    stop("check-coverage: the index carries DUPLICATE ids (", idx$n, " rows, ",
         length(unique(idx$counties)), " distinct). Dissolve by id alone.",
         call. = FALSE)
  ## The sidecar's tiles.maxzoom is what the app requests and the header is what
  ## exists; both are here, so they are compared. A sidecar written beside a
  ## tileset built to a different ceiling — a rebuild that changed the ceiling
  ## and stopped halfway, either file restored on its own — asks for a zoom that
  ## returns nothing, and nothing else in the stack looks at both numbers.
  if (length(idx$tiles$maxzoom) && idx$tiles$maxzoom != TZ[["maxzoom"]])
    stop("check-coverage: the sidecar says maxzoom ", idx$tiles$maxzoom,
         " and the PMTiles header says ", TZ[["maxzoom"]], ".", call. = FALSE)
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

from_index <- if (file.exists(INDEX)) expected_from_index() else NULL

## Both families read the same cached parquet; only the drop set differs, which
## is exactly the difference this gate exists to hold the build to.
from_source <- if (grepl("^census-counties-[0-9]{4}(-geo)?$", TILESET)) {
  suppressPackageStartupMessages(library(arrow))
  expected_from_census(sub("-geo$", "", sub("^census-counties-", "", TILESET)))
} else NULL

if (is.null(from_index) && is.null(from_source))
  stop("check-coverage: no index sidecar at ", INDEX,
       " and no source rule for tileset '", TILESET, "'.", call. = FALSE)

if (!is.null(from_index) && !is.null(from_source)) {
  only_idx <- setdiff(unname(from_index), unname(from_source))
  only_src <- setdiff(unname(from_source), unname(from_index))
  if (length(only_idx) || length(only_src))
    stop("check-coverage: the index sidecar and the source disagree.\n",
         "  in the index but not the archive: ",
         if (length(only_idx)) paste(head(sort(only_idx), 8), collapse = ", ") else "none", "\n",
         "  in the archive but not the index: ",
         if (length(only_src)) paste(head(sort(only_src), 8), collapse = ", ") else "none",
         call. = FALSE)
  cat("  sidecar agrees with the archive\n")
}

## ── The territories, counted out loud ────────────────────────────────────────
## The geo family exists because it carries the counties dummy-Albers had to
## drop, and the comparison above proves the sidecar carries them only as long as
## somebody notices that the archive's set was the full one to begin with. So
## report what was compared. The prefixes are the Census codes the clipped
## parquets use; the FSA composite's territory ids are legacy (Guam 14001, USVI
## 52001/52003/52005, MP 69085..69120, AS 60001) and those tilesets have no
## source rule, so this line is about census-counties-<year>-geo.
##
## A COUNT, NOT A DEMAND FOR THIRTEEN. cb 2010 has no American Samoa, Guam,
## Northern Marianas or USVI, so the 2000 and 2010 clipped vintages carry no
## territory rows at all and a fixed expectation would fail on correct data. The
## assertion is the comparison above; this is the evidence for reading it.
if (SPACE == "geo" && !is.null(from_source) && !is.null(from_index)) {
  terr <- function(v) v[substr(v, 1, 2) %in% c("60", "66", "69", "78")]
  ts <- terr(unname(from_source))
  cat(sprintf("  territories: %d in the archive, %d in the sidecar%s\n",
              length(ts), length(terr(unname(from_index))),
              if (length(ts))
                sprintf(" (%s)", paste(sprintf("%s:%d", names(table(substr(ts, 1, 2))),
                                               as.integer(table(substr(ts, 1, 2)))),
                                       collapse = " "))
              else ""))
}

## The source is the authority wherever there is a rule for it.
expected <- if (!is.null(from_source)) from_source else from_index

total <- unique(unname(expected))
cat(sprintf("%s: %d counties expected\n", TILESET, length(total)))
if (length(total) != length(expected))
  stop("check-coverage: the source carries DUPLICATE ids (", length(expected),
       " rows, ", length(total), " distinct). Dissolve by id alone.", call. = FALSE)

## ── Dummy space: the frozen box, one subprocess per tile ─────────────────────
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

## ── Geographic space: four boxes, one subprocess per zoom ─────────────────────
## WHY BOXES AND NOT ONE BOUNDING BOX. In real degrees the archive is four widely
## separated clusters and everything between them is ocean: a single box around
## all of it spans 251 degrees of longitude and 86 of latitude, which at z8 is
## 46,000 tiles of which a few thousand hold anything. Four boxes are ~5,400.
##
## STATED HERE, NOT IMPORTED. GEO_FRAME is a CONUS camera box and would audit
## nothing outside it; GEO_ENVELOPE is the full [-180, 180] by construction and
## audits the whole Pacific. Neither is the right box for this question, and a
## gate that took its search area from the file it is checking could be steered
## by the same edit that broke the tiles.
##
## AMERICAN SAMOA IS SOUTH OF THE EQUATOR, which is the one place this arithmetic
## goes wrong quietly: the Mercator y of a negative latitude is GREATER than
## 2^z/2, so a box runs from y(north) to y(south) and its numbers are in the
## bottom half of the grid. The per-box counts below are printed for exactly that
## reason — a box that was enumerated in the wrong hemisphere reports tiles and no
## ids, and says so, instead of quietly contributing nothing to a set that the
## other boxes fill in anyway.
##
## Alaska gets two boxes because it crosses the dateline: Aleutians West's
## easternmost islands reach 179.78 E and its westernmost -179.15, and both halves
## are the same county. Only the west box is needed to see the id, so the east one
## is coverage of the geometry rather than of the id list.
GEO_BOXES <- list(
  conus_ak_hi_pr = c(w = -180.0, s =  17.5, e =  -64.5, n =  72.0),
  aleutians_east = c(w =  172.0, s =  50.5, e =  180.0, n =  54.0),
  guam_mp        = c(w =  144.0, s =  13.0, e =  146.3, n =  20.6),
  amer_samoa     = c(w = -171.2, s = -14.6, e = -168.1, n = -11.0)
)

## Integer tile ranges per box, with a tile of slack on every side the way
## tiles_for() pads its degrees. Ranges rather than an enumerated key set:
## membership becomes four comparisons, and at maxzoom the enumeration would be
## millions of strings for no gain.
geo_ranges <- function(z) {
  n  <- 2^z
  xt <- function(lon) floor((lon + 180) / 360 * n)
  yt <- function(lat) floor((1 - asinh(tan(lat * pi / 180)) / pi) / 2 * n)
  cl <- function(v) pmin(pmax(v, 0), n - 1)
  do.call(rbind, lapply(names(GEO_BOXES), function(nm) {
    b <- GEO_BOXES[[nm]]
    data.frame(box = nm,
               x0 = cl(xt(b[["w"]]) - 1), x1 = cl(xt(b[["e"]]) + 1),
               y0 = cl(yt(b[["n"]]) - 1), y1 = cl(yt(b[["s"]]) + 1),
               stringsAsFactors = FALSE)
  }))
}

## Which boxes a tile is in, as a logical row per tile. EVERY MATCHING BOX, not
## the first: at z4 a tile is 22.5 degrees wide, so the tile holding American
## Samoa is also inside the box drawn around CONUS, Alaska, Hawaii and Puerto
## Rico. Attributing it to one of them would print "amer_samoa 0 ids" about a
## tile that was audited and did hold American Samoa.
##
## matrix() rather than vapply(): with a single tile in the chunk vapply would
## drop the dimension and the row indexing below would silently read the wrong
## box.
box_of <- function(x, y, rg) {
  matrix(unlist(lapply(seq_len(nrow(rg)), function(i)
           x >= rg$x0[i] & x <= rg$x1[i] & y >= rg$y0[i] & y <= rg$y1[i])),
         nrow = length(x), ncol = nrow(rg))
}

## ONE SUBPROCESS PER ZOOM, NOT PER TILE. The dummy path's per-tile decode is
## 121 processes at z8 and is fine; the geo boxes are ~5,400 at z8 and ~5.4
## million at z13, and process spawn alone would dominate. `-Z z -z z` emits the
## whole zoom as a FeatureCollection of per-tile FeatureCollections — 42 MB and
## 1.1 s for a census vintage at z8 — and the tiles outside the boxes are
## discarded here rather than never asked for.
##
## READ AS A STREAM, BY LINE, BECAUSE THE STRUCTURE IS IN THE LINES:
## tippecanoe-decode puts each tile header, each layer header and each feature on
## its own line, and at maxzoom the whole document will not fit in memory as a
## parsed tree. Tile and layer are carried forward across lines and across chunk
## boundaries, and a feature counts only when both carries are set — which is
## also what keeps the leading metadata block out of the result, since it precedes
## the first tile header.
##
## A PARSE THAT BREAKS CANNOT PASS THIS GATE. Every id it fails to see is a
## county reported missing, and the missing list is fatal; the only failure mode
## worth guarding separately is a decode that yielded no tiles at all, which would
## otherwise read as a tileset with no counties in it rather than as a broken
## call.
ids_at_geo <- function(z) {
  rg  <- geo_ranges(z)
  acc <- replicate(nrow(rg), character(0), simplify = FALSE)
  seen_tiles <- integer(nrow(rg))
  ndecoded <- 0   ## tile headers the decode emitted, in or out of a box

  con <- pipe(sprintf("tippecanoe-decode -Z %d -z %d %s 2>/dev/null",
                      z, z, shQuote(PMTILES)), "r")
  on.exit(close(con), add = TRUE)
  carry_box <- matrix(FALSE, nrow = 1, ncol = nrow(rg))
  carry_lay <- ""
  repeat {
    ln <- readLines(con, n = 20000L, warn = FALSE)
    if (!length(ln)) break
    is_tile <- grepl('"zoom":', ln, fixed = TRUE)
    is_lay  <- grepl('"layer": "', ln, fixed = TRUE)
    has_id  <- grepl('"id": "', ln, fixed = TRUE)

    tb <- matrix(FALSE, nrow = 0, ncol = nrow(rg))
    if (any(is_tile)) {
      h  <- ln[is_tile]
      tx <- as.integer(sub('^.*"x": ([0-9]+).*$', "\\1", h))
      ty <- as.integer(sub('^.*"y": ([0-9]+).*$', "\\1", h))
      ## Say so rather than letting an NA coordinate propagate into a comparison
      ## and surface as "missing value where TRUE/FALSE needed" ten lines later.
      if (anyNA(tx) || anyNA(ty))
        stop("check-coverage: a tile header carried no readable x/y — ",
             "tippecanoe-decode's output format is not what this parser expects.\n  ",
             h[which(is.na(tx) | is.na(ty))[1]], call. = FALSE)
      tb <- box_of(tx, ty, rg)
      ndecoded <- ndecoded + length(h)
      seen_tiles <- seen_tiles + colSums(tb)
    }
    lb <- if (any(is_lay))
      sub('^.*"layer": "([^"]*)".*$', "\\1", ln[is_lay]) else character(0)

    ## cumsum indexes each line to the tile and layer it sits under; index 0 is
    ## the one carried in from the previous chunk, hence the rbind/c of the carry.
    tb_all <- rbind(carry_box, tb)
    lb_all <- c(carry_lay, lb)
    ti <- cumsum(is_tile)
    li <- cumsum(is_lay)
    sel <- which(has_id & !is_tile & !is_lay & lb_all[li + 1L] == "counties")
    if (length(sel)) {
      ids  <- sub('^.*"id": "([^"]*)".*$', "\\1", ln[sel])
      rows <- ti[sel] + 1L
      for (i in seq_len(nrow(rg))) {
        hit <- tb_all[rows, i]
        if (any(hit)) acc[[i]] <- unique(c(acc[[i]], ids[hit]))
      }
    }
    carry_box <- tb_all[nrow(tb_all), , drop = FALSE]
    carry_lay <- lb_all[length(lb_all)]
  }

  if (!ndecoded)
    stop("check-coverage: tippecanoe-decode returned no tiles at z", z,
         " for ", PMTILES, ".\n  The tileset carries the zoom (header says z",
         TZ[["minzoom"]], "..z", TZ[["maxzoom"]],
         "), so this is the decode failing, not the tiles.", call. = FALSE)

  rg$enumerated <- (as.numeric(rg$x1 - rg$x0) + 1) * (as.numeric(rg$y1 - rg$y0) + 1)
  rg$present    <- seen_tiles
  rg$ids        <- vapply(acc, length, integer(1))
  list(ids = unique(unlist(acc)), ntiles = sum(rg$enumerated), detail = rg)
}

bad <- integer(0)
for (z in ZOOMS) {
  r <- if (SPACE == "geo") ids_at_geo(z) else ids_at(z)
  miss <- setdiff(total, r$ids)
  cat(sprintf("  z%-2d %4d tiles   present %5d   missing %4d%s\n",
              z, r$ntiles, length(r$ids), length(miss),
              if (length(miss)) "   <-- FAIL" else ""))
  ## Which boxes were actually asked, and what each one held. Guam and American
  ## Samoa are one line each here because "3,234 present" is the same number
  ## whether or not the Pacific was ever looked at.
  if (!is.null(r$detail))
    for (i in seq_len(nrow(r$detail)))
      cat(sprintf("      %-15s x %d..%d y %d..%d  %7d tiles  %6d in tileset  %5d ids\n",
                  r$detail$box[i], r$detail$x0[i], r$detail$x1[i],
                  r$detail$y0[i], r$detail$y1[i], r$detail$enumerated[i],
                  r$detail$present[i], r$detail$ids[i]))
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
