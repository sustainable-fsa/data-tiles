#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · tools/check-constants.R
##
## Gate: the frozen AlbersUSA inset constants in R/dummy-space.R still match what
## tigris::shift_geometry() would compute from the live Census file.
##
## WHY THIS EXISTS. shift_geometry() derives its placement from a live download
## of cb_2020_us_state_20m on every run: the CONUS bbox sets the three targets,
## and the state centroids set the scaling origins. We froze those numbers so a
## published tileset can never move under an upstream change — but freezing them
## silently is worse than not freezing them, because the composite would then
## disagree with every other consumer of tigris in the project without saying so.
##
## So: freeze, and check. If this fails, the upstream layout changed. That is a
## decision to make deliberately (new tiles do not register with old ones), not
## a number to quietly update.
##
##   Rscript tools/check-constants.R
## =============================================================================

suppressPackageStartupMessages({library(sf); library(tigris); library(dplyr)})
source("R/dummy-space.R")
options(tigris_use_cache = TRUE)

TOL_M <- 1e-6

st <- tigris::states(cb = TRUE, resolution = "20m", progress_bar = FALSE, year = 2020) |>
  sf::st_transform("ESRI:102003")
bb <- st |> dplyr::filter(!GEOID %in% c("02", "15", "72")) |> sf::st_bbox()
W <- bb$xmax - bb$xmin
H <- bb$ymax - bb$ymin

cen <- function(geoid, crs) {
  st |> dplyr::filter(GEOID == geoid) |> sf::st_transform(crs) |>
    sf::st_geometry() |> sf::st_centroid() |> sf::st_coordinates() |> as.numeric()
}
bbx <- function(geoid) {
  b <- st |> dplyr::filter(GEOID == geoid) |> sf::st_bbox()
  c(xmin = b$xmin, ymin = b$ymin, xmax = b$xmax, ymax = b$ymax)
}

## Targets are xmin + {0.08, 0.35, 0.65} * W and ymin + {0.07, 0, 0} * H, from
## tigris' position = "below" branch.
live <- list(
  conus_bbox = c(xmin = bb$xmin, ymin = bb$ymin, xmax = bb$xmax, ymax = bb$ymax),
  ak_bbox = bbx("02"), hi_bbox = bbx("15"), pr_bbox = bbx("72"),
  ak_centroid = cen("02", 3338),
  hi_centroid = cen("15", "ESRI:102007"),
  pr_centroid = cen("72", 32161),
  ak_target = c(bb$xmin + 0.08 * W, bb$ymin + 0.07 * H),
  hi_target = c(bb$xmin + 0.35 * W, bb$ymin + 0.00 * H),
  pr_target = c(bb$xmin + 0.65 * W, bb$ymin + 0.00 * H)
)
frozen <- list(
  conus_bbox = AUSA$conus_bbox,
  ak_bbox = AUSA$ak_bbox, hi_bbox = AUSA$hi_bbox, pr_bbox = AUSA$pr_bbox,
  ak_centroid = AUSA$ak$centroid, hi_centroid = AUSA$hi$centroid,
  pr_centroid = AUSA$pr$centroid,
  ak_target = AUSA$ak$target, hi_target = AUSA$hi$target, pr_target = AUSA$pr$target
)

bad <- character(0)
for (k in names(frozen)) {
  d <- max(abs(as.numeric(live[[k]]) - as.numeric(frozen[[k]])))
  cat(sprintf("  %-12s worst |live - frozen| = %.3e m%s\n", k, d,
              if (d > TOL_M) "   <-- FAIL" else ""))
  if (d > TOL_M) bad <- c(bad, k)
}

if (length(bad)) {
  stop("check-constants: ", paste(bad, collapse = ", "), " drifted from upstream.\n",
       "  The AlbersUSA layout changed. Tiles built after this will NOT register\n",
       "  with tiles built before it. Decide deliberately; do not just update.",
       call. = FALSE)
}
cat("\ncheck-constants: OK — the frozen AlbersUSA layout still matches upstream\n")
