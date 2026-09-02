#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · tools/check-aiannh.R
##
## Gate: the AIANNH TopoJSON decodes, carries every component the TIGER source
## has, and lands in the space it claims. The PMTiles side is check-coverage.R's
## job (TILESET=census-aiannh-2025[-geo]); this is the TopoJSON's independent
## second opinion, the way check-usdm.R is usdm.R's.
##
## THE EXPECTED SET COMES FROM THE SOURCE ZIP, not from anything the build
## wrote: the same cached tl_<y>_us_aiannh.zip the build read, ids re-derived
## here. Comparing against the sidecar would only prove the build is
## self-consistent.
##
## THE RETENTION DENOMINATOR IS THE SOURCE, deliberately, where the build gates
## against its own post-transform count — same division of labour as
## check-usdm.R vs usdm.R. The clip and the quantisation both cost vertices, so
## the floor here is lower than the build's 0.99: measured 2026-09-01 on the
## 2025 vintage, the cb clip keeps 0.9831 of the 890,880 source vertices in
## both spaces (TIGER runs past the coastline; that loss is the clip working)
## and the round trip keeps 0.9994 of what the clip left, so the product lands
## at ~0.9825. The floor is 0.97 — room for the measured costs, nowhere near
## census-counties' failure mode, which lost whole rings.
##
##   Rscript tools/check-aiannh.R
##   SPACE=geo Rscript tools/check-aiannh.R
##   VINTAGE=2025 SPACE=geo Rscript tools/check-aiannh.R
## =============================================================================

suppressPackageStartupMessages({library(sf); library(jsonlite)})
source("R/dummy-space.R")
source("R/geo-space.R")
sf::sf_use_s2(FALSE)

SPACE <- Sys.getenv("SPACE", unset = "dummy")
if (!SPACE %in% c("dummy", "geo"))
  stop("check-aiannh: unknown SPACE '", SPACE,
       "' — expected 'dummy' or 'geo'", call. = FALSE)
## Typed, not taken from space_suffix(), for check-usdm.R's reason: the suffix
## is how this gate finds the files, and a gate that took its filenames from
## the helper the build used could not notice the helper breaking. The space
## TOKEN below is imported, because a label is a contract name both parties
## should read identically.
SUFFIX  <- if (SPACE == "geo") "-geo" else ""
VINTAGE <- Sys.getenv("VINTAGE", unset = "2025")
if (SPACE != "dummy") cat("space: ", SPACE, "\n", sep = "")

DIR    <- Sys.getenv("AIANNH_DIR", "tiles")
REMOTE <- Sys.getenv("AIANNH_BASE",
                     "https://data.sustainable-fsa.com/data-tiles/tiles")
MIN_RETAIN <- 0.97

f_local <- file.path(DIR, sprintf("census-aiannh-%s%s.topojson", VINTAGE, SUFFIX))
remote  <- !file.exists(f_local)
f_topo  <- if (remote)
  sprintf("%s/census-aiannh-%s%s.topojson", REMOTE, VINTAGE, SUFFIX) else f_local
f_read  <- if (remote) paste0("/vsicurl/", f_topo) else f_topo
f_index <- if (remote) {
  sprintf("%s/census-aiannh-%s%s-index.json", REMOTE, VINTAGE, SUFFIX)
} else {
  file.path(DIR, sprintf("census-aiannh-%s%s-index.json", VINTAGE, SUFFIX))
}
cat("checking ", if (remote) "the published artifact" else f_local, "\n", sep = "")

## The source of truth: the cached TIGER zip.
f_src <- file.path("build", "aiannh", sprintf("tl_%s_us_aiannh.zip", VINTAGE))
if (!file.exists(f_src))
  stop("check-aiannh: ", f_src, " is not cached — run\n",
       "  VINTAGES=", VINTAGE, " PUBLISH=0 Rscript census-aiannh.R\nfirst.",
       call. = FALSE)
src    <- sf::read_sf(paste0("/vsizip/", f_src))
nv_src <- nrow(sf::st_coordinates(src))
exp_id <- sort(as.character(src$GEOID))
exp_rt <- table(as.character(src$COMPTYP))

bad <- character(0)

## ── The document ─────────────────────────────────────────────────────────────
topo <- jsonlite::fromJSON(f_topo, simplifyVector = FALSE)
if (!identical(names(topo$objects), "aiannh"))
  bad <- c(bad, sprintf("object is '%s', expected 'aiannh'",
                        paste(names(topo$objects), collapse = ",")))

geoms <- topo$objects$aiannh$geometries
ids   <- sort(vapply(geoms, `[[`, "", "id"))
ct    <- vapply(geoms, function(g) g$properties$comptyp, "")
if (!identical(ids, exp_id)) {
  miss  <- setdiff(exp_id, ids)
  extra <- setdiff(ids, exp_id)
  bad <- c(bad, sprintf("id set differs from the source: %d missing (%s), %d extra (%s)",
                        length(miss),  paste(head(miss, 5),  collapse = ", "),
                        length(extra), paste(head(extra, 5), collapse = ", ")))
}
for (k in names(exp_rt))
  if (sum(ct == k) != exp_rt[[k]])
    bad <- c(bad, sprintf("comptyp %s: %d in the TopoJSON, %d in the source",
                          k, sum(ct == k), exp_rt[[k]]))

## ── The index sidecar agrees about what this is ──────────────────────────────
idx <- jsonlite::fromJSON(f_index)
EXPECT_SPACE <- if (SPACE == "geo") GEO_SPACE else SFSA_SPACE
if (!identical(idx$space, EXPECT_SPACE))
  bad <- c(bad, sprintf("index space is '%s', expected %s", idx$space, EXPECT_SPACE))
if (!identical(sort(idx$areas), exp_id))
  bad <- c(bad, "the index sidecar's id set differs from the source")

## ── The geometry a client would actually get ─────────────────────────────────
## Dummy space is DEFINED by its frozen bounds, so the gate reads them; the
## geographic envelope is restated rather than imported from GEO_ENVELOPE, for
## check-usdm.R's reason — four numbers, typed twice, and a divergence is a
## conversation.
g  <- sf::read_sf(f_read)
bb <- sf::st_bbox(g)
b  <- if (SPACE == "geo")
  c(xmin = -180, ymin = -15.5, xmax = 180, ymax = 72.6) else DUMMY$bounds
TOL <- 0.02
if (bb[["xmin"]] < b[["xmin"]] - TOL || bb[["ymin"]] < b[["ymin"]] - TOL ||
    bb[["xmax"]] > b[["xmax"]] + TOL || bb[["ymax"]] > b[["ymax"]] + TOL)
  bad <- c(bad, sprintf("bbox %.4f %.4f %.4f %.4f outside %s",
                        bb[["xmin"]], bb[["ymin"]], bb[["xmax"]], bb[["ymax"]],
                        if (SPACE == "geo") "the geographic envelope"
                        else "the frozen box"))

nv_out <- nrow(sf::st_coordinates(g))
keep   <- nv_out / nv_src
if (keep < MIN_RETAIN)
  bad <- c(bad, sprintf("only %.3f of source vertices survived (%s of %s)",
                        keep, format(nv_out, big.mark = ","),
                        format(nv_src, big.mark = ",")))

cat(sprintf("  %s vintage %s: %d features  %s verts  retained %.4f vs source\n",
            SPACE, VINTAGE, length(geoms), format(nv_out, big.mark = ","), keep))

if (length(bad)) {
  for (m in bad) cat("  FAIL ", m, "\n", sep = "")
  stop("check-aiannh: ", length(bad), " problem(s)", call. = FALSE)
}
cat("\ncheck-aiannh: OK — the TopoJSON decodes, matches the source and registers\n")
