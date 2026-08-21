#!/usr/bin/env Rscript
## =============================================================================
## sustainable-fsa/data-tiles · tools/check-shift.R
##
## Gate: albers_usa_shift() places the insets exactly where tigris::shift_geometry()
## would, on real county geometry.
##
## check-constants.R proves the frozen NUMBERS still match upstream; this proves
## our implementation USES them the way tigris does. They fail differently:
## a wrong constant moves an inset a few kilometres, a wrong composition (scaling
## about the wrong origin, translating before scaling, reprojecting a relabelled
## geometry) moves it hundreds.
##
## Only the inset states are compared. CONUS is a plain st_transform in both
## implementations, so there is nothing to get wrong there.
##
##   Rscript tools/check-shift.R
## =============================================================================

suppressPackageStartupMessages({library(sf); library(arrow); library(dplyr); library(tigris)})
source("R/dummy-space.R")
sf::sf_use_s2(FALSE)
options(tigris_use_cache = TRUE)

TOL_M <- 0.001
SRC <- Sys.getenv(
  "DD22_PARQUET",
  "https://sustainable-fsa.com/fsa-counties-dd22/fsa-counties-dd22.parquet"
)

p <- arrow::read_parquet(SRC)
g <- sf::st_as_sfc(structure(p$geometry, class = "WKB"))
sf::st_crs(g) <- 4326
x <- sf::st_sf(id = as.character(p$FSA_STCOU), stfips = as.character(p$FIPSST),
               geometry = g) |>
  dplyr::filter(stfips %in% c("02", "15", "72")) |>
  sf::st_make_valid() |>
  ## One row per id. Without this the comparison joins many-to-many and reports
  ## the distance between DIFFERENT counties, which looks like a catastrophic
  ## failure and is not one.
  dplyr::group_by(id, stfips) |>
  dplyr::summarise(.groups = "drop")

cat(sprintf("inset counties: %d  (AK %d, HI %d, PR %d)\n", nrow(x),
            sum(x$stfips == "02"), sum(x$stfips == "15"), sum(x$stfips == "72")))

mine   <- albers_usa_shift(x, state_fips = x$stfips)
theirs <- suppressWarnings(tigris::shift_geometry(x, geoid_column = "id"))

cen <- function(z) {
  c <- suppressWarnings(sf::st_coordinates(sf::st_centroid(sf::st_geometry(z))))
  data.frame(id = z$id, X = c[, 1], Y = c[, 2])
}
j <- dplyr::inner_join(
  cen(mine) |> dplyr::rename(mx = X, my = Y),
  cen(theirs) |> dplyr::rename(tx = X, ty = Y),
  by = "id", relationship = "one-to-one"
) |>
  dplyr::mutate(d_m = sqrt((mx - tx)^2 + (my - ty)^2),
                region = dplyr::case_when(substr(id, 1, 2) == "02" ~ "AK",
                                          substr(id, 1, 2) == "15" ~ "HI",
                                          TRUE ~ "PR"))

print(j |> dplyr::group_by(region) |>
        dplyr::summarise(n = dplyr::n(), median_m = round(median(d_m), 6),
                         max_m = round(max(d_m), 6), .groups = "drop"),
      row.names = FALSE)

worst <- max(j$d_m)
cat(sprintf("\nworst displacement: %.6f m over %d counties\n", worst, nrow(j)))
if (worst > TOL_M) {
  stop(sprintf("check-shift: worst displacement %.6f m exceeds %g m", worst, TOL_M),
       call. = FALSE)
}
cat("check-shift: OK — insets land exactly where tigris::shift_geometry() puts them\n")
