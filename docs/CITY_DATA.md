# City data format

All coordinates are metres. X grows east, Z grows south (Godot convention), Y is up.
The sea is west of `environment.sea_x`; the city grid starts at x = 0.

## data/city.json

Written by `tools/city_tool.py`, one entity per line so git diffs stay readable.

```jsonc
{
  "version": 1,
  "name": "תל בטטה",
  "chunk_size": 64,                         // streaming cell size used by the game
  "grid": {"pitch": 48, "road_width": 8, "sidewalk": 3},
  "environment": {"sea_x": -46, "beach_x": -4, "spawn": [72, 84]},
  "next_ids": {"b": 85, "p": 225, ...},     // id counters; ids are never reused
  "districts": [{"id": "d_00001", "name": "מרכז העיר", "type": "center", "cells": [[1,1], ...]}],
  "blocks":    [{"id": "blk_00001", "cell": [1,1], "type": "plaza", "district": "d_00001",
                 "rect": [52, 52, 92, 92], "sidewalk": 3}],
  "roads":     [{"id": "r_00001", "a": [48, 48], "b": [96, 48], "width": 8}],
  "buildings": [{"id": "b_00001", "type": "potato_statue", "pos": [72, 72], "rot": 0,
                 "variant": 0, "district": "d_00001"}],
  "props":     [{"id": "p_00001", "type": "bench", "pos": [72, 77], "rot": 180, ...}]
}
```

* **Grid.** Block cell `(i, j)` covers `[i*pitch, j*pitch] .. [(i+1)*pitch, (j+1)*pitch]`.
  Roads run along the cell edges; the block (`rect`) is the cell minus half a road on each side.
  Block types: `residential`, `apartments`, `commercial`, `civic`, `park`, `plaza`.
* **Roads** are straight segments between grid nodes. They also form the graph the traffic system drives on.
* **Objects** (`buildings` and `props`): `pos` is `[x, z]` of the footprint centre, `rot` is degrees
  around Y (0 = front faces +Z/south, 90 = east, 180 = north, 270 = west), `variant` picks the colour set.
  Optional `"y"` lifts an object.
* **Ids** have the form `b_00001` (building), `p_00001` (prop), `blk_`, `r_`, `d_`.
  In-game builds get `u_<unixtime>_<n>`.

## Player edits: user://city_overlay.json

```jsonc
{
  "version": 1,
  "added":   [ { "id": "u_1760790000_1", "type": "kiosk", "pos": [120, 30], "rot": 90, "variant": 1 } ],
  "removed": [ "b_00042" ],                 // base objects the player deleted
  "player":  { "pos": [72, 0.2, 84], "yaw": 3.14 },
  "saved_at": "2026-10-18T13:00:00"
}
```

The game loads `city.json`, drops every id listed in `removed`, then adds `added`.
Saving is atomic (`.tmp` then rename) and the previous file is kept as `.bak`.
`city_tool.py import-overlay <path>` bakes these edits into `city.json` and renames the overlay.

## data/building_types.json

```jsonc
"house_small": {
  "name": "בית קטן", "category": "residential",
  "footprint": [7, 7],                      // collision, placement checks and the tool's layout
  "detail": "prop",                         // optional: small object, no far-LOD, hidden beyond prop distance
  "far": true,                              // optional (props): bake the "lod" parts into far chunks too
  "collide": true,                          // optional: default true for buildings, false for props
  "placeable": true,                        // optional: listed in the in-game build menu (default true)
  "colors": {"wall": ["#f4e1c1", "#d8e8f0"], "roof": ["#c8553d", "#7a8fb3"]},  // one entry per variant
  "parts": [
    {"shape": "box", "size": [6, 3, 6], "pos": [0, 1.5, 0], "color": "wall", "lod": true},
    {"shape": "gable", "size": [6.8, 2.2, 6.8], "pos": [0, 4.1, 0], "color": "roof", "lod": true},
    {"shape": "box", "size": [1, 1, 0.08], "pos": [1.8, 1.7, 3.03], "color": "window", "around": 4}
  ]
}
```

Part fields:

| field | meaning |
|---|---|
| `shape` | `box` (`size`), `gable` (`size`, triangular roof, ridge along Z), `cylinder` / `cone` (`radius`, `top`, `bottom`, `height`, `segments`), `sphere` (`radius`, `segments`, `rings`) |
| `pos`, `rot`, `scale` | placement in the building's local space (front = +Z), rotation in degrees |
| `color` | `"#hex"`, a slot from `colors` (picked by variant), or a name from the top-level `palette` |
| `lod` | keep this part in the far low-detail mesh. Without any `lod` part the far mesh is a box |
| `array` | `{"x": [count, step], "y": [...], "z": [...]}` repeats the part on a grid centred on `pos` |
| `around` | repeat N times around the Y axis (e.g. windows on all four sides); `around_start` in degrees |

Every type and variant is built once at runtime and shared by every instance (MultiMesh), so adding
detail to a type costs memory once, not per building. Keep parts few for things that appear hundreds of times.
