# Tel Batata – notes for Claude

Godot 4.3, Compatibility renderer, target = weak PC. The owner writes in Hebrew and asks for city
changes in natural language ("תבנה שכונה חדשה עם 50 בתים"). Answer in Hebrew.

## Changing the city
- Never hand-edit ids or rewrite `data/city.json` wholesale. Use `tools/city_tool.py`
  (`add-neighborhood`, `add-building`, `remove`, `import-overlay`, `stats`, `validate`, `list-types`).
  It only builds on free cells, allocates fresh ids, and backs up first.
- Translate requests into tool flags: houses → `--houses N` (8 per block, park/shops added automatically
  for bigger neighbourhoods), towers → `--apartments N` (blocks of 4), shops → `--shops N`,
  public buildings → `--civic school,library,town_hall`, side of town → `--direction east|north|south`.
- New building kinds: add a type to `data/building_types.json` (see docs/CITY_DATA.md). Keep part
  counts low and mark the body/roof parts `"lod": true`. If the tool should place it, extend the
  matching list or filler in `city_tool.py`.
- In-game edits live in the player's `user://city_overlay.json`, not in the repo. Base ids that
  disappear from `city.json` are simply ignored by the overlay, so removing things is safe, but tell
  the owner if a change could overlap something they may have built in that area.

## Always verify before committing
```
python3 tools/city_tool.py validate
godot --headless --path . -- --smoke
xvfb-run -a godot --path . --rendering-driver opengl3 -- --test-story      # all 12 chapters complete
xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 -- --shots --quality=low
```
`--shots` writes 6 PNGs to `~/.local/share/TelBatata/shots/`; look at them. In the cloud container
Godot 4.3 is not preinstalled: download the Linux build from the godotengine GitHub releases.
`--benchmark --quality=low|medium|high` prints average / 1% low FPS and draw calls.
Software rendering (llvmpipe) gave ~35 FPS / ~60 draw calls for the starter city at low quality.

## Rendering gotchas (Compatibility renderer)
- A shadow-casting DirectionalLight is drawn in an additive pass that is blended in sRGB space,
  which over-brightens everything. That's why low/medium have no realtime shadows and main.gd dims
  ambient + fill light when shadows are on. Don't "fix" brightness by just raising light energy.
- Depth fog (`FOG_MODE_DEPTH`) ending at the draw distance hides the far clip; keep sky ground
  colours equal to the fog colour.
- Everything shares one vertex-coloured material; no textures. Keep it that way for performance.

## Gameplay code map
- Story is data (`data/story.json`); quest logic in `scripts/autoload/game_state.gd`; world side
  (markers, drops, enemies, levers, challenges) in `scripts/systems/story_system.gd`; fights in
  `combat_system.gd`; UI widgets in `scripts/ui/` wired by `scripts/autoload/game_ui.gd`.
- UI widgets use RTL layout; set full-rect anchors from the parent (`GameUI._fill`), not in their own
  `_ready`, or they end up zero-sized.
- If you edit story.json, run `--test-story`.
