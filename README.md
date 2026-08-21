# data-tiles

Vector tiles for the [Sustainable FSA](https://sustainable-fsa.com) web maps:
the FSA county composite and the weekly US Drought Monitor, published as
[PMTiles](https://docs.protomaps.com/pmtiles/) and pre-projected into the
`sfsa-albers-usa/1` coordinate space.

**This is a presentation archive, not an archive of record.** It derives
everything it publishes from archives that *are* records, and it holds no
authoritative data of its own:

| input | from |
|---|---|
| county boundaries, full resolution, true-position WGS84 | [`fsa-counties-dd17`](https://github.com/sustainable-fsa/fsa-counties-dd17), [`fsa-counties-dd22`](https://github.com/sustainable-fsa/fsa-counties-dd22) |
| weekly USDM polygons, GeoParquet, WGS84 | [`usdm`](https://github.com/sustainable-fsa/usdm) |

Those repositories stay projection-neutral and publish real coordinates in a
real CRS. Everything app-specific — the territory filter, the coastline clip,
the AlbersUSA inset shift, the dummy rescale, the tiling — happens here.

## The coordinate space

`sfsa-albers-usa/1` is the AlbersUSA composite (CONUS with Alaska, Hawaii and
Puerto Rico scaled and repositioned as insets) rescaled into a 10-degree box
centred on (0, 0), which MapLibre renders as if it were lng/lat. It is **not a
geographic CRS**, and coordinates in it are meaningless outside this system.

It exists because MapLibre supports only Mercator-family projections, so a map
that wants to *look* like Albers has to be fed coordinates that are already
Albers. Tiles inherit their addressing from their coordinates, so the transform
has to happen before tiling — it cannot be applied in the browser.

Two consequences worth knowing before consuming these tiles:

- **A conventional basemap cannot register against them.** Real-world tiles are
  addressed in Mercator-of-true-lng/lat; these are addressed in
  Mercator-of-dummy-degrees, which lands in the Gulf of Guinea. Separately, the
  composite *moves* Alaska, Hawaii and Puerto Rico, so no real basemap could be
  correct beneath the insets in any projection.
- **The shear is corrected.** Mercator's y is the inverse Gudermannian of
  latitude, so emitting a y linear in Albers northing would render the plane
  with a 0.14% vertical stretch, accumulating to 765 m of displacement at the
  top and bottom edges — and a 0.141% area error in a projection chosen
  *because* it is equal-area. `R/dummy-space.R` emits the Gudermannian instead,
  so Mercator undoes it and the rendered plane is true Albers.

## Layout

```
R/dummy-space.R              the ONLY copy of the transform
tools/check-registration.R   gate G4 — proves it matches the JavaScript
```

`R/dummy-space.R` is deliberately **not** vendored into the archive repos, the
way `R/s3-archive.R` is. Two implementations of a projection that disagree
produce a silent misregistration: layers that line up at the centre of the map
and drift apart toward the edges, with nothing on screen to say so. That file
already exists in 16 copies across 3 distinct versions in this project, which is
exactly how it happens.

## Gates

```sh
Rscript tools/check-registration.R
```

Runs the twelve reference points from the specification — the header of
`js/projection.js` in
[`lfp-explorer`](https://github.com/sustainable-fsa/lfp-explorer) — through the
R implementation and asserts agreement to **1e-9 dummy degrees** (about half a
millimetre). Three of the twelve sit at high |y|, which is deliberate: the shear
correction vanishes at the equator, so a producer that skipped it would pass a
centre-only test and be 765 m out at the edges.

## Citation

Bocinsky, R. Kyle. *Sustainable FSA Data Tiles*. Montana Climate Office,
University of Montana. Sustainable FSA project.
<https://sustainable-fsa.com/data-tiles/>

**Acknowledgment**: This work is part of the [*Enhancing Sustainable Disaster
Relief in FSA Programs*](https://www.ars.usda.gov/research/project/?accnNo=444612)
project, supported by the USDA Office of the Chief Economist, Office of Energy
and Environmental Policy, and the USDA Climate Hubs.
