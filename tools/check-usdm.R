#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · tools/check-usdm.R
##
## Gate: the published USDM weeks decode, carry the geometry the source archive
## has, and land in the space they claim.
##
## SAMPLED, NOT EXHAUSTIVE, the way check-coverage.R samples zooms rather than
## decoding every tile. There are 1,390 weeks and each check downloads its source
## parquet to compare against; a dozen spread across the archive catches a
## systematic fault, and a fault here would be systematic. The build itself gates
## every week — region classification, per-region area, and the round trip — so
## this is the independent second opinion, not the only one.
##
## The vertex comparison is against the SOURCE PARQUET, deliberately: comparing
## against anything usdm.R wrote would only prove usdm.R is self-consistent.
## Measured floor is 0.995 (quantisation collapsing coincident points, plus the
## dissolve merging vertices where exploded polygons met), so 0.99 has room
## without being meaningless.
##
## TWO FAMILIES, ONE PER INVOCATION. SPACE=dummy, the default, checks
## USDM_<date>.topojson against usdm-index.json in sfsa-albers-usa/1; SPACE=geo
## checks USDM_<date>-geo.topojson against usdm-geo-index.json in
## sfsa-geographic/1. Everything that is not a filename or a bounding box is the
## same check: the object name, the class set, the date, and the vertex retention
## against the source parquet, which is one archive serving both.
##
## THE LISTING PATTERN IS ANCHORED ON THE DATE AND ON THIS SPACE'S SUFFIX. The
## loose `^USDM_.*\.topojson$` this file used to carry admits the other family,
## and then a dummy run reads USDM_2020-01-07-geo.topojson as the week
## "2020-01-07-geo", finds it absent from the dummy index, and reports a missing
## week that is not missing. usdm.R:187 carries the same anchored pattern for the
## same reason.
##
##   Rscript tools/check-usdm.R
##   SAMPLE=30 Rscript tools/check-usdm.R
##   SPACE=geo SAMPLE=3 Rscript tools/check-usdm.R
## =============================================================================

suppressPackageStartupMessages({library(sf); library(jsonlite)})
source("R/dummy-space.R")
source("R/geo-space.R")
sf::sf_use_s2(FALSE)

SPACE <- Sys.getenv("SPACE", unset = "dummy")
if (!SPACE %in% c("dummy", "geo"))
  stop("check-usdm: unknown SPACE '", SPACE,
       "' — expected 'dummy' or 'geo'", call. = FALSE)
## Stated here rather than taken from space_suffix(). The space TOKEN is imported
## below, because a label is a contract name and both parties should read the same
## string; the suffix is how this gate finds the files, and a gate that took its
## filenames from the same helper the build did could not notice the helper being
## the thing that broke.
SUFFIX <- if (SPACE == "geo") "-geo" else ""
if (SPACE != "dummy") cat("space: ", SPACE, "\n", sep = "")

DIR          <- Sys.getenv("USDM_DIR", "usdm")
## Where to look when there is no local mirror. A CI run that publishes nothing
## — the common case, a quiet Thursday — holds no files at all, and a gate that
## can only read a local directory would either fail or have to be skipped. Read
## the PUBLISHED artifacts instead: on that path this checks the thing users
## actually fetch, which is the better test anyway.
REMOTE       <- Sys.getenv("USDM_BASE",
                  "https://data.sustainable-fsa.com/data-tiles/usdm")
SAMPLE       <- as.integer(Sys.getenv("SAMPLE", "12"))
MIN_RETAIN   <- 0.99
CLASSES      <- paste0("D", 0:4)
USDM_ARCHIVE <- Sys.getenv("USDM_ARCHIVE",
                           unset = "https://data.sustainable-fsa.com/usdm")

local_weeks <- if (dir.exists(DIR))
  list.files(DIR, pattern = sprintf("^USDM_[0-9]{4}-[0-9]{2}-[0-9]{2}%s\\.topojson$",
                                    SUFFIX)) else character(0)
remote <- !length(local_weeks)
src_of <- if (remote) {
  function(d) sprintf("/vsicurl/%s/USDM_%s%s.topojson", REMOTE, d, SUFFIX)
} else {
  function(d) file.path(DIR, sprintf("USDM_%s%s.topojson", d, SUFFIX))
}
raw_of <- if (remote) {
  function(d) sprintf("%s/USDM_%s%s.topojson", REMOTE, d, SUFFIX)
} else {
  function(d) file.path(DIR, sprintf("USDM_%s%s.topojson", d, SUFFIX))
}

f_index <- if (remote) {
  sprintf("%s/usdm%s-index.json", REMOTE, SUFFIX)
} else {
  file.path(DIR, sprintf("usdm%s-index.json", SUFFIX))
}
cat("checking ", if (remote) "the published archive" else DIR, "\n", sep = "")
idx <- jsonlite::fromJSON(f_index)

## ── The index describes what is actually there ───────────────────────────────
## EVERY LOCAL FILE MUST BE IN THE INDEX, and that is the direction that matters:
## the failure worth catching is an index that forgot weeks the archive holds.
## The reverse is normal and not an error — a CI runner builds one week and
## mirrors nothing else, so the index legitimately names 1,389 weeks it has no
## file for. Only a full local mirror can assert equality, and it is told so.
## Three subs, not one alternation, and the suffix first — usdm.R:152 has the
## account. sub("^USDM_|\\.topojson$", "", x) replaces only the FIRST match. The
## suffix sub is a no-op on dummy, and the listing above cannot hand it the other
## family's names anyway.
on_disk <- sort(sub(paste0(SUFFIX, "$"), "",
                    sub("\\.topojson$", "", sub("^USDM_", "", local_weeks))))
missing <- setdiff(on_disk, idx$dates)
if (length(missing))
  stop("check-usdm: ", length(missing), " week(s) on disk are absent from the index",
       " — e.g. ", paste(head(missing, 5), collapse = ", "),
       "\n  an index that forgets a published week is the failure this catches.",
       call. = FALSE)
unmirrored <- if (remote) character(0) else setdiff(idx$dates, on_disk)
if (length(unmirrored))
  cat(sprintf("  (%d indexed week(s) not mirrored locally — sampling the %d that are)\n",
              length(unmirrored), length(on_disk)))
EXPECT_SPACE <- if (SPACE == "geo") GEO_SPACE else SFSA_SPACE
if (!identical(idx$space, EXPECT_SPACE))
  stop("check-usdm: index space is '", idx$space, "', expected ", EXPECT_SPACE, call. = FALSE)
cat(sprintf("index: %d weeks, %s .. %s, quantization %g\n",
            idx$n, min(idx$dates), max(idx$dates), idx$quantization))

## Spread the sample across the archive rather than taking the first N — a fault
## that only touches the sparse early years would hide behind a head().
## Sample what is actually reachable: the local mirror if there is one, the
## index's own date list if the archive is only remote.
avail <- if (remote) idx$dates else on_disk
if (!length(avail))
  stop("check-usdm: nothing to check — no local weeks and an empty index",
       call. = FALSE)
pick <- avail[unique(round(seq(1, length(avail), length.out = min(SAMPLE, length(avail)))))]

## ── The box the decoded geometry has to land in ──────────────────────────────
## Dummy space is DEFINED by its frozen bounds, so the gate reads them: a week
## outside that box is not in the space at all. The geographic envelope is a
## different kind of number — a sanity range around real degrees, wide by design
## because Guam is at 144 E and the Aleutians reach both sides of the dateline —
## and it is RESTATED HERE rather than imported from GEO_ENVELOPE, because a gate
## that read the same object the build asserted on would agree with it by
## construction. Four numbers, typed twice, and a divergence is a conversation.
b <- if (SPACE == "geo")
  c(xmin = -180, ymin = -15.5, xmax = 180, ymax = 72.6) else DUMMY$bounds
BOXNAME <- if (SPACE == "geo") "the geographic envelope" else "the frozen box"
TOL <- 0.02
bad <- character(0)

for (d in pick) {
  topo <- jsonlite::fromJSON(raw_of(d), simplifyVector = FALSE)

  if (!identical(names(topo$objects), "usdm"))
    bad <- c(bad, sprintf("%s: object is '%s', expected 'usdm'", d,
                          paste(names(topo$objects), collapse = ",")))

  props <- lapply(topo$objects$usdm$geometries, `[[`, "properties")
  cls   <- sort(unique(vapply(props, `[[`, "", "usdm_class")))
  dts   <- unique(vapply(props, `[[`, "", "date"))
  if (!all(cls %in% CLASSES))
    bad <- c(bad, sprintf("%s: unexpected class(es) %s", d,
                          paste(setdiff(cls, CLASSES), collapse = ",")))
  if (!identical(dts, d))
    bad <- c(bad, sprintf("%s: carries date(s) %s", d, paste(dts, collapse = ",")))

  ## Decoded, so this is the geometry a client would actually get.
  g  <- sf::read_sf(src_of(d))
  bb <- sf::st_bbox(g)
  if (bb[["xmin"]] < b[["xmin"]] - TOL || bb[["ymin"]] < b[["ymin"]] - TOL ||
      bb[["xmax"]] > b[["xmax"]] + TOL || bb[["ymax"]] > b[["ymax"]] + TOL)
    bad <- c(bad, sprintf("%s: bbox %.4f %.4f %.4f %.4f outside %s",
                          d, bb[["xmin"]], bb[["ymin"]], bb[["xmax"]], bb[["ymax"]],
                          BOXNAME))

  src <- sf::read_sf(sprintf("%s/data/parquet/USDM_%s.parquet", USDM_ARCHIVE, d))
  nv_src <- nrow(sf::st_coordinates(src))
  nv_out <- nrow(sf::st_coordinates(g))
  keep   <- nv_out / nv_src
  if (keep < MIN_RETAIN)
    bad <- c(bad, sprintf("%s: only %.3f of source vertices survived (%s of %s)",
                          d, keep, format(nv_out, big.mark = ","),
                          format(nv_src, big.mark = ",")))

  ## The source's own class set has to come through intact — a dropped class is
  ## a whole drought severity missing from the map.
  cls_src <- sort(unique(as.character(src$usdm_class)))
  if (!identical(cls, cls_src))
    bad <- c(bad, sprintf("%s: classes %s, source has %s", d,
                          paste(cls, collapse = ","), paste(cls_src, collapse = ",")))

  cat(sprintf("  %s  %d classes  %8s verts  retained %.4f\n",
              d, length(cls), format(nv_out, big.mark = ","), keep))
}

if (length(bad)) {
  for (m in bad) cat("  FAIL ", m, "\n", sep = "")
  stop("check-usdm: ", length(bad), " problem(s) across ", length(pick),
       " sampled week(s)", call. = FALSE)
}
cat(sprintf("\ncheck-usdm: OK — %d sampled week(s) decode, register and retain their geometry\n",
            length(pick)))
