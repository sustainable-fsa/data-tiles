## =============================================================================
## sustainable-fsa/data-tiles · R/publish.R
##
## THE ONLY COPY of what this repo's artifacts are and how they are cached.
## Three scripts publish the same three artifact classes, and until this file
## existed each carried its own literal content type and cache policy — six
## pairs of strings that had to agree and nothing checking that they did.
##
## THE CACHE POLICY IS NOT `immutable`, DELIBERATELY, AND IT USED TO BE. The
## PMTiles went up `public, max-age=31536000, immutable` under filenames that
## are stable across rebuilds — `census-counties-2020.pmtiles` is the same key
## every run. That combination is a contradiction: `immutable` is a promise that
## the bytes at this URL will never change, and within one session those exact
## keys were republished twice, first to add an index sidecar and then to add a
## states mesh.
##
## A CloudFront invalidation does not rescue that. It clears the edge, not the
## browser: a client that fetched the file under `immutable` is entitled to keep
## it for a year and will not even send a conditional request. The republishes
## only went unnoticed because nothing consumes these tiles yet.
##
## So: one hour, revalidate after. Big files, but PMTiles is read by many Range
## requests against one URL, so an hour of hard caching covers a session and the
## revalidation that follows is a 304. The publish path still invalidates, which
## now collapses the window at the edge to seconds instead of papering over a
## year-long promise. This matches the `max-age=3600` the sidecars always used.
##
## IF THESE EVER NEED REAL IMMUTABILITY, the answer is a content hash in the
## filename, not a longer max-age — that is the only version of `immutable`
## that is true.
## =============================================================================

CACHE_TILES <- "public, max-age=3600"

## Artifact classes, matched in order. An unrecognised file is an error rather
## than a default: a new artifact class should be declared here, not silently
## published as an octet-stream nobody can cache correctly.
ARTIFACTS <- list(
  list(pattern = "\\.pmtiles$",
       content_type = "application/octet-stream",
       cache_control = CACHE_TILES),
  list(pattern = "-index\\.json$",
       content_type = "application/json",
       cache_control = CACHE_TILES),
  list(pattern = "-outline-dummy\\.geojson$",
       content_type = "application/geo+json",
       cache_control = CACHE_TILES),
  ## application/json, not application/topojson or application/geo+json: it is
  ## what the boundary archives settled on, and it is what CloudFront will
  ## compress — worth 3x over the wire on exactly the payload the app scrubs
  ## through fastest.
  list(pattern = "\\.topojson$",
       content_type = "application/json",
       cache_control = CACHE_TILES)
)

artifact_spec <- function(file) {
  for (a in ARTIFACTS) if (grepl(a$pattern, basename(file))) return(a)
  stop("no artifact class for '", basename(file),
       "' — declare it in R/publish.R rather than guessing a content type",
       call. = FALSE)
}

## Publish one artifact under <prefix>/<subdir>/. PMTiles carry NO
## Content-Encoding by design: the header records tile_compression = gzip and the
## client shim decompresses, while a Content-Encoding would break Range
## semantics.
##
## subdir is "tiles" for everything tiled and "usdm" for the weekly TopoJSON,
## which is 1,390 files and would otherwise swamp the tiles/ listing.
put_artifact <- function(bucket, prefix, file, subdir = "tiles") {
  sp <- artifact_spec(file)
  s3_put(bucket = bucket,
         key = paste0(prefix, "/", subdir, "/", basename(file)),
         file = file,
         content_type = sp$content_type,
         cache_control = sp$cache_control)
}
