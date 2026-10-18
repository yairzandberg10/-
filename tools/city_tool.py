#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
city_tool.py - edits data/city.json for Tel Batata without touching what exists.

Rules it follows on every change:
  * existing ids are never changed or reused; new ids come from "next_ids"
  * new blocks only go on free grid cells; new objects must not overlap anything
  * a timestamped backup of city.json is written to data/backups/ first
  * the file is written atomically, one entity per line (readable git diffs)

Examples:
  python tools/city_tool.py init
  python tools/city_tool.py add-neighborhood --name "נווה פירה" --houses 50
  python tools/city_tool.py add-neighborhood --name "מגדלי הצ'יפס" --apartments 3 --shops 1 --direction south
  python tools/city_tool.py add-building --type kiosk --x 120 --z 30 --rot 90
  python tools/city_tool.py remove --id b_00042
  python tools/city_tool.py stats
  python tools/city_tool.py validate
  python tools/city_tool.py import-overlay "%APPDATA%/TelBatata/city_overlay.json"
"""
import argparse
import datetime
import json
import math
import os
import random
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
CITY_PATH = os.path.join(DATA, "city.json")
TYPES_PATH = os.path.join(DATA, "building_types.json")
BACKUP_DIR = os.path.join(DATA, "backups")
KEEP_BACKUPS = 20

HOUSE_TYPES = ["house_small", "house_small", "house_villa", "house_tall"]
APARTMENT_TYPES = ["apartment_bauhaus", "apartment_bauhaus", "apartment_tower"]
CIVIC_TYPES = ["town_hall", "school", "library"]
KEY_ORDER = ["version", "name", "chunk_size", "grid", "environment", "next_ids",
             "districts", "blocks", "roads", "buildings", "props"]


# --------------------------------------------------------------------- files

def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_city(city, path=CITY_PATH):
    keys = [k for k in KEY_ORDER if k in city] + [k for k in city if k not in KEY_ORDER]
    lines = ["{"]
    for ki, k in enumerate(keys):
        v = city[k]
        comma = "," if ki < len(keys) - 1 else ""
        if isinstance(v, list) and v and all(isinstance(e, dict) for e in v):
            lines.append(f"  {json.dumps(k)}: [")
            for i, e in enumerate(v):
                lines.append("    " + json.dumps(e, ensure_ascii=False) + ("," if i < len(v) - 1 else ""))
            lines.append("  ]" + comma)
        else:
            lines.append(f"  {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}{comma}")
    lines.append("}")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def backup():
    if not os.path.exists(CITY_PATH):
        return None
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    dst = os.path.join(BACKUP_DIR, f"city_{stamp}.json")
    shutil.copy2(CITY_PATH, dst)
    old = sorted(f for f in os.listdir(BACKUP_DIR) if f.startswith("city_"))
    for f in old[:-KEEP_BACKUPS]:
        os.remove(os.path.join(BACKUP_DIR, f))
    return dst


# ---------------------------------------------------------------------- city

class City:
    def __init__(self, data, types):
        self.d = data
        self.types = types["types"]
        g = data["grid"]
        self.pitch = float(g["pitch"])
        self.rw = float(g["road_width"])
        self.sidewalk = float(g["sidewalk"])
        for k in ("districts", "blocks", "roads", "buildings", "props"):
            data.setdefault(k, [])
        data.setdefault("next_ids", {})
        self.ids = set()
        for k in ("districts", "blocks", "roads", "buildings", "props"):
            self.ids.update(e["id"] for e in data[k])
        self.cells = {tuple(b["cell"]): b for b in data["blocks"]}
        self.road_keys = {self._rkey(r["a"], r["b"]) for r in data["roads"]}

    # ids
    def new_id(self, prefix):
        n = int(self.d["next_ids"].get(prefix, 1))
        while True:
            i = f"{prefix}_{n:05d}"
            n += 1
            if i not in self.ids:
                break
        self.d["next_ids"][prefix] = n
        self.ids.add(i)
        return i

    # geometry
    def cell_rect(self, i, j):
        p, h = self.pitch, self.rw / 2
        return [i * p + h, j * p + h, (i + 1) * p - h, (j + 1) * p - h]

    def inner_rect(self, i, j):
        x0, z0, x1, z1 = self.cell_rect(i, j)
        s = self.sidewalk
        return [x0 + s, z0 + s, x1 - s, z1 - s]

    def footprint(self, t):
        return self.types[t].get("footprint", [2, 2])

    def variant_count(self, t):
        cols = self.types[t].get("colors", {})
        return max([len(v) for v in cols.values()] + [1])

    def object_rect(self, o):
        fw, fd = self.footprint(o["type"])
        a = math.radians(o.get("rot", 0))
        c, s = abs(math.cos(a)), abs(math.sin(a))
        ex, ez = fw * c + fd * s, fw * s + fd * c
        x, z = o["pos"]
        return (x - ex / 2, z - ez / 2, x + ex / 2, z + ez / 2)

    @staticmethod
    def overlaps(a, b, margin=0.25):
        return a[0] + margin < b[2] and b[0] + margin < a[2] and a[1] + margin < b[3] and b[1] + margin < a[3]

    def road_rect(self, r):
        h = r.get("width", self.rw) / 2
        (ax, az), (bx, bz) = r["a"], r["b"]
        return (min(ax, bx) - h, min(az, bz) - h, max(ax, bx) + h, max(az, bz) + h)

    def occupied_cells(self):
        occ = set(self.cells)
        for o in self.d["buildings"] + self.d["props"]:
            occ.add((math.floor(o["pos"][0] / self.pitch), math.floor(o["pos"][1] / self.pitch)))
        return occ

    # roads
    @staticmethod
    def _rkey(a, b):
        a, b = tuple(round(v, 2) for v in a), tuple(round(v, 2) for v in b)
        return (a, b) if a <= b else (b, a)

    def ensure_roads(self, i, j):
        p = self.pitch
        c = [(i * p, j * p), ((i + 1) * p, j * p), ((i + 1) * p, (j + 1) * p), (i * p, (j + 1) * p)]
        for k in range(4):
            a, b = list(c[k]), list(c[(k + 1) % 4])
            key = self._rkey(a, b)
            if key not in self.road_keys:
                self.road_keys.add(key)
                self.d["roads"].append({"id": self.new_id("r"), "a": a, "b": b, "width": self.rw})

    # blocks / objects
    def add_block(self, i, j, btype, district):
        if (i, j) in self.cells:
            raise ValueError(f"cell {(i, j)} already has a block")
        b = {"id": self.new_id("blk"), "cell": [i, j], "type": btype, "district": district,
             "rect": self.cell_rect(i, j), "sidewalk": self.sidewalk}
        self.d["blocks"].append(b)
        self.cells[(i, j)] = b
        self.ensure_roads(i, j)
        return b

    def add_object(self, t, x, z, rot=0, variant=None, district="", rng=None, check=False):
        if t not in self.types:
            raise ValueError(f"unknown type '{t}'")
        kind = "props" if self.types[t].get("detail") == "prop" else "buildings"
        if variant is None:
            variant = (rng or random).randrange(self.variant_count(t))
        o = {"id": None, "type": t, "pos": [round(x, 2), round(z, 2)], "rot": int(rot) % 360,
             "variant": int(variant), "district": district}
        if check:
            r = self.object_rect(o)
            for other in self.d["buildings"] + self.d["props"]:
                if self.overlaps(r, self.object_rect(other)):
                    raise ValueError(f"overlaps {other['id']} ({other['type']})")
            for road in self.d["roads"]:
                if self.overlaps(r, self.road_rect(road)):
                    raise ValueError(f"overlaps road {road['id']}")
        o["id"] = self.new_id("b" if kind == "buildings" else "p")
        self.d[kind].append(o)
        return o

    def add_district(self, name, dtype):
        d = {"id": self.new_id("d"), "name": name, "type": dtype,
             "created": datetime.date.today().isoformat()}
        self.d["districts"].append(d)
        return d


# ------------------------------------------------------------- block fillers

def setback_pos(edge_x, edge_z, rot, dist):
    """Move from a block edge point inwards by `dist`, for an object facing `rot`."""
    if rot == 0:
        return edge_x, edge_z - dist
    if rot == 180:
        return edge_x, edge_z + dist
    if rot == 90:
        return edge_x - dist, edge_z
    return edge_x + dist, edge_z


def ring_lots(inner, per_row=3):
    """Lots facing the four streets: rows on the z sides, one lot on each x side."""
    x0, z0, x1, z1 = inner
    w = x1 - x0
    lots = []
    for k in range(per_row):
        cx = x0 + w * (2 * k + 1) / (2 * per_row)
        lots.append((cx, z1, 0))
        lots.append((cx, z0, 180))
    cz = (z0 + z1) / 2
    lots += [(x1, cz, 90), (x0, cz, 270)]
    return lots


def sidewalk_props(city, blk, rng, trees=True):
    x0, z0, x1, z1 = blk["rect"]
    d = blk["district"]
    for x, z in ((x0 + 1.2, z0 + 1.2), (x1 - 1.2, z0 + 1.2), (x0 + 1.2, z1 - 1.2), (x1 - 1.2, z1 - 1.2)):
        city.add_object("lamp", x, z, rng.choice([0, 90, 180, 270]), 0, d)
    if trees:
        for f in (1 / 3, 2 / 3):
            city.add_object("tree_round", x0 + (x1 - x0) * f, z0 + 1.5, 0, None, d, rng)
            city.add_object("tree_round", x0 + (x1 - x0) * f, z1 - 1.5, 0, None, d, rng)


def fill_residential(city, blk, n_houses, rng):
    i, j = blk["cell"]
    inner = city.inner_rect(i, j)
    d = blk["district"]
    placed = 0
    for ex, ez, rot in ring_lots(inner):
        if placed < n_houses:
            t = rng.choice(HOUSE_TYPES)
            depth = city.footprint(t)[1]
            x, z = setback_pos(ex, ez, rot, 2.0 + depth / 2)
            city.add_object(t, x, z, rot, None, d, rng)
            placed += 1
        else:
            x, z = setback_pos(ex, ez, rot, 6.0)
            city.add_object("tree_round", x, z, 0, None, d, rng)
    cx, cz = (inner[0] + inner[2]) / 2, (inner[1] + inner[3]) / 2
    for dx, dz in rng.sample([(-3.5, -3.5), (3.5, -3.5), (-3.5, 3.5), (3.5, 3.5)], rng.randint(2, 4)):
        city.add_object("tree_round", cx + dx + rng.uniform(-0.7, 0.7), cz + dz + rng.uniform(-0.7, 0.7), 0, None, d, rng)
    sidewalk_props(city, blk, rng)
    return placed


def fill_apartments(city, blk, rng, count=4):
    i, j = blk["cell"]
    x0, z0, x1, z1 = city.inner_rect(i, j)
    d = blk["district"]
    qx = [x0 + (x1 - x0) * 0.25, x0 + (x1 - x0) * 0.75]
    spots = [(qx[0], z1, 0), (qx[1], z1, 0), (qx[0], z0, 180), (qx[1], z0, 180)]
    placed = 0
    for ex, ez, rot in spots[:count]:
        t = rng.choice(APARTMENT_TYPES)
        x, z = setback_pos(ex, ez, rot, 1.5 + city.footprint(t)[1] / 2)
        city.add_object(t, x, z, rot, None, d, rng)
        placed += 1
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    city.add_object("tree_round", cx - 3, cz, 0, None, d, rng)
    city.add_object("tree_round", cx + 3, cz, 0, None, d, rng)
    city.add_object("bench", cx, cz, 0, 0, d)
    sidewalk_props(city, blk, rng)
    return placed


def fill_commercial(city, blk, rng):
    i, j = blk["cell"]
    inner = city.inner_rect(i, j)
    d = blk["district"]
    placed = 0
    for ex, ez, rot in ring_lots(inner):
        t = "cafe" if rng.random() < 0.3 and rot in (0, 180) else "shop_small"
        x, z = setback_pos(ex, ez, rot, 1.0 + city.footprint(t)[1] / 2)
        city.add_object(t, x, z, rot, None, d, rng)
        placed += 1
    cx, cz = (inner[0] + inner[2]) / 2, (inner[1] + inner[3]) / 2
    city.add_object("kiosk", cx, cz, rng.choice([0, 90, 180, 270]), None, d, rng)
    city.add_object("tree_round", cx - 5, cz - 4, 0, None, d, rng)
    city.add_object("tree_round", cx + 5, cz + 4, 0, None, d, rng)
    city.add_object("bench", cx, cz + 4, 180, 0, d)
    sidewalk_props(city, blk, rng, trees=False)
    return placed


def fill_civic(city, blk, rng, kind):
    i, j = blk["cell"]
    x0, z0, x1, z1 = city.inner_rect(i, j)
    d = blk["district"]
    fw, fd = city.footprint(kind)
    cx = (x0 + x1) / 2
    city.add_object(kind, cx, z1 - 1.5 - fd / 2, 0, None, d, rng)
    for x in (x0 + 2.5, x1 - 2.5):
        city.add_object("tree_round", x, z0 + 2.5, 0, None, d, rng)
    sidewalk_props(city, blk, rng)
    return 1


def fill_park(city, blk, rng):
    i, j = blk["cell"]
    x0, z0, x1, z1 = city.inner_rect(i, j)
    d = blk["district"]
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    city.add_object("fountain", cx, cz, 0, None, d, rng)
    for k in range(4):
        a = k * math.pi / 2
        rot = (180 + k * 90) % 360  # bench front (+Z) faces the fountain
        bx, bz = cx + math.sin(a) * 5.5, cz + math.cos(a) * 5.5
        city.add_object("bench", bx, bz, rot, 0, d)
    trees = 0
    tries = 0
    spots = []
    while trees < 14 and tries < 400:
        tries += 1
        x, z = rng.uniform(x0 + 1.5, x1 - 1.5), rng.uniform(z0 + 1.5, z1 - 1.5)
        if math.hypot(x - cx, z - cz) < 8.5 or any(math.hypot(x - a, z - b) < 3.5 for a, b in spots):
            continue
        spots.append((x, z))
        city.add_object("tree_round" if rng.random() < 0.8 else "tree_palm", x, z, 0, None, d, rng)
        trees += 1
    city.add_object("hedge", cx, z0 + 0.8, 0, 0, d)
    city.add_object("hedge", cx, z1 - 0.8, 0, 0, d)
    sidewalk_props(city, blk, rng, trees=False)
    return 1


def fill_plaza(city, blk, rng):
    i, j = blk["cell"]
    x0, z0, x1, z1 = city.inner_rect(i, j)
    d = blk["district"]
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    city.add_object("potato_statue", cx, cz, 0, 0, d)
    for k in range(4):
        a = k * math.pi / 2
        city.add_object("bench", cx + math.sin(a) * 5, cz + math.cos(a) * 5, (180 + k * 90) % 360, 0, d)
    for x, z in ((x0 + 3, z0 + 3), (x1 - 3, z0 + 3), (x0 + 3, z1 - 3), (x1 - 3, z1 - 3)):
        city.add_object("tree_palm", x, z, 0, None, d, rng)
    city.add_object("kiosk", x1 - 4, cz, 90, None, d, rng)
    city.add_object("cafe", x0 + 5.3, cz, 270, None, d, rng)
    sidewalk_props(city, blk, rng, trees=False)
    return 1


def fill_block(city, blk, rng, houses=8, civic=None):
    t = blk["type"]
    if t == "residential":
        return fill_residential(city, blk, houses, rng)
    if t == "apartments":
        return fill_apartments(city, blk, rng)
    if t == "commercial":
        return fill_commercial(city, blk, rng)
    if t == "civic":
        return fill_civic(city, blk, rng, civic or rng.choice(CIVIC_TYPES))
    if t == "park":
        return fill_park(city, blk, rng)
    if t == "plaza":
        return fill_plaza(city, blk, rng)
    raise ValueError(f"unknown block type {t}")


# -------------------------------------------------------------- region search

def find_region(city, k, direction="auto"):
    """Pick k free grid cells next to the city (never west of the beach, i >= 0)."""
    occ = city.occupied_cells()
    if not occ:
        return [(i, j) for i in range(k) for j in range(1)][:k]
    imin, imax = min(c[0] for c in occ), max(c[0] for c in occ)
    jmin, jmax = min(c[1] for c in occ), max(c[1] for c in occ)
    ccx, ccz = (imin + imax) / 2, (jmin + jmax) / 2
    cols = max(1, math.ceil(math.sqrt(k)))
    rows = math.ceil(k / cols)
    best = None
    for (w, h) in {(cols, rows), (rows, cols)}:
        for i0 in range(0, imax + 2):
            for j0 in range(jmin - h - 1, jmax + 2):
                cells = [(i0 + a, j0 + b) for b in range(h) for a in range(w)]
                if any(c in occ for c in cells):
                    continue
                if direction == "east" and i0 <= imax:
                    continue
                if direction == "north" and j0 + h - 1 >= jmin:
                    continue
                if direction == "south" and j0 <= jmax:
                    continue
                touching = sum(1 for (i, j) in cells for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1))
                               if (i + di, j + dj) in occ)
                if touching == 0:
                    continue
                # keep the k cells closest to the city centre
                cells.sort(key=lambda c: (c[0] - ccx) ** 2 + (c[1] - ccz) ** 2)
                cells = cells[:k]
                mx = sum(c[0] for c in cells) / k
                mz = sum(c[1] for c in cells) / k
                score = math.hypot(mx - ccx, mz - ccz) - 0.3 * touching
                if best is None or score < best[0]:
                    best = (score, cells)
    if best is None:
        raise SystemExit("no free area found in that direction")
    return best[1]


# ------------------------------------------------------------------ commands

def cmd_init(args):
    if os.path.exists(CITY_PATH) and not args.force:
        raise SystemExit("data/city.json already exists (use --force to rebuild from scratch)")
    backup()
    data = {
        "version": 1, "name": "תל בטטה", "chunk_size": 64,
        "grid": {"pitch": 48, "road_width": 8, "sidewalk": 3},
        "environment": {"sea_x": -46, "beach_x": -4, "spawn": [72, 84]},
        "next_ids": {},
    }
    city = City(data, read_json(TYPES_PATH))
    rng = random.Random(args.seed)
    layout = [
        ("מרכז העיר", "center", [((1, 1), "plaza", None), ((2, 1), "civic", "town_hall"),
                                ((1, 2), "commercial", None), ((2, 2), "park", None)]),
        ("שדרות הים", "seafront", [((0, j), "apartments", None) for j in range(4)]),
        ("שוק הבטטה", "market", [((1, 0), "commercial", None), ((2, 0), "civic", "school")]),
        ("נווה צ'יפס", "neighborhood", [((3, j), "residential", None) for j in range(4)]),
        ("גבעת הפירה", "neighborhood", [((1, 3), "residential", None), ((2, 3), "civic", "library")]),
    ]
    for name, dtype, cells in layout:
        dist = city.add_district(name, dtype)
        dist["cells"] = [list(c) for c, _, _ in cells]
        for (i, j), btype, civic in cells:
            blk = city.add_block(i, j, btype, dist["id"])
            fill_block(city, blk, rng, civic=civic)
    beach = city.add_district("חוף הבטטה", "beach")
    env = data["environment"]
    z_end = 4 * city.pitch
    for k in range(int(z_end // 16) + 1):
        city.add_object("tree_palm", env["beach_x"] - 2.5, 4 + k * 16, 0, None, beach["id"], rng)
    for k in range(3):
        city.add_object("lifeguard_tower", env["sea_x"] + 9, 30 + k * 65, 270, None, beach["id"], rng)
    spots = []
    while len(spots) < 34:
        x, z = rng.uniform(env["sea_x"] + 6, env["beach_x"] - 9), rng.uniform(4, z_end - 4)
        if any(math.hypot(x - a, z - b) < 4.5 for a, b in spots) or \
                any(abs(z - (30 + k * 65)) < 4 and abs(x - (env["sea_x"] + 9)) < 4 for k in range(3)):
            continue
        spots.append((x, z))
        city.add_object("beach_umbrella", x, z, rng.randrange(0, 360, 15), None, beach["id"], rng)
    write_city(data)
    print_stats(data, "created starter city")


def cmd_add_neighborhood(args):
    data = read_json(CITY_PATH)
    city = City(data, read_json(TYPES_PATH))
    rng = random.Random(args.seed if args.seed is not None else len(city.ids))
    res_blocks = math.ceil(args.houses / 8) if args.houses > 0 else 0
    parks = args.parks if args.parks is not None else (1 if res_blocks >= 3 else 0)
    shops = args.shops if args.shops is not None else (1 if res_blocks >= 4 else 0)
    civic = [c for c in (args.civic or "").split(",") if c]
    for c in civic:
        if c not in CIVIC_TYPES:
            raise SystemExit(f"unknown civic building '{c}' (choose from {', '.join(CIVIC_TYPES)})")
    plan = ["commercial"] * shops + ["civic"] * len(civic) + ["park"] * parks + \
           ["apartments"] * args.apartments + ["residential"] * res_blocks
    if not plan:
        raise SystemExit("nothing to build: give --houses / --apartments / --shops / --parks / --civic")
    cells = find_region(city, len(plan), args.direction)
    before = {k: len(data[k]) for k in ("buildings", "props", "blocks", "roads")}
    backup()
    dist = city.add_district(args.name, "neighborhood")
    dist["cells"] = [list(c) for c in cells]
    # cells are sorted nearest-to-centre first: shops/civic face the old city
    houses_left = args.houses
    civic_left = list(civic)
    for (i, j), btype in zip(cells, plan):
        blk = city.add_block(i, j, btype, dist["id"])
        if btype == "residential":
            n = min(8, houses_left)
            houses_left -= fill_block(city, blk, rng, houses=n)
        else:
            fill_block(city, blk, rng, civic=civic_left.pop(0) if btype == "civic" else None)
    write_city(data)
    added = {k: len(data[k]) - before[k] for k in before}
    print(f"added district {dist['id']} '{args.name}' on cells {cells}")
    print(f"  +{added['blocks']} blocks, +{added['buildings']} buildings "
          f"({args.houses - houses_left} houses), +{added['props']} props, +{added['roads']} roads")
    print_stats(data)


def cmd_add_building(args):
    data = read_json(CITY_PATH)
    city = City(data, read_json(TYPES_PATH))
    try:
        o = city.add_object(args.type, args.x, args.z, args.rot, args.variant, args.district or "", check=True)
    except ValueError as e:
        raise SystemExit(f"cannot place: {e}")
    backup()
    write_city(data)
    print(f"added {o['id']} ({o['type']}) at {o['pos']}")


def cmd_remove(args):
    data = read_json(CITY_PATH)
    backup()
    removed = 0
    if args.id:
        ids = set(args.id)
        for k in ("buildings", "props"):
            n = len(data[k])
            data[k] = [o for o in data[k] if o["id"] not in ids]
            removed += n - len(data[k])
    if args.district:
        d = args.district
        for k in ("buildings", "props", "blocks"):
            n = len(data[k])
            data[k] = [o for o in data[k] if o.get("district") != d]
            removed += n - len(data[k])
        data["districts"] = [x for x in data["districts"] if x["id"] != d]
        # drop roads that no longer border any block
        city = City(data, read_json(TYPES_PATH))
        keep = set()
        for (i, j) in city.cells:
            p = city.pitch
            c = [(i * p, j * p), ((i + 1) * p, j * p), ((i + 1) * p, (j + 1) * p), (i * p, (j + 1) * p)]
            for n in range(4):
                keep.add(City._rkey(list(c[n]), list(c[(n + 1) % 4])))
        data["roads"] = [r for r in data["roads"] if City._rkey(r["a"], r["b"]) in keep]
    write_city(data)
    print(f"removed {removed} entries")


def cmd_import_overlay(args):
    """Bake in-game edits (user://city_overlay.json) into the base city."""
    data = read_json(CITY_PATH)
    city = City(data, read_json(TYPES_PATH))
    ov = read_json(args.path)
    backup()
    removed = set(ov.get("removed", []))
    for k in ("buildings", "props"):
        data[k] = [o for o in data[k] if o["id"] not in removed]
    n = 0
    for o in ov.get("added", []):
        if o["type"] not in city.types:
            print(f"  skip unknown type {o['type']}")
            continue
        city.add_object(o["type"], o["pos"][0], o["pos"][1], o.get("rot", 0), o.get("variant", 0),
                        o.get("district", ""))
        n += 1
    write_city(data)
    done = args.path + ".imported"
    os.replace(args.path, done)
    print(f"imported {n} added, {len(removed)} removed; overlay renamed to {done}")


def cmd_validate(args):
    data = read_json(CITY_PATH)
    city = City(data, read_json(TYPES_PATH))
    problems = []
    seen = set()
    for k in ("districts", "blocks", "roads", "buildings", "props"):
        for e in data[k]:
            if e["id"] in seen:
                problems.append(f"duplicate id {e['id']}")
            seen.add(e["id"])
    objs = data["buildings"] + data["props"]
    for o in objs:
        if o["type"] not in city.types:
            problems.append(f"{o['id']}: unknown type {o['type']}")
    # overlap check via a coarse grid hash
    buckets = {}
    for o in objs:
        r = city.object_rect(o)
        for gx in range(math.floor(r[0] / 16), math.floor(r[2] / 16) + 1):
            for gz in range(math.floor(r[1] / 16), math.floor(r[3] / 16) + 1):
                buckets.setdefault((gx, gz), []).append((o, r))
    pairs = set()
    for items in buckets.values():
        for a in range(len(items)):
            for b in range(a + 1, len(items)):
                (oa, ra), (ob, rb) = items[a], items[b]
                if city.overlaps(ra, rb, 0.3):
                    pairs.add(tuple(sorted((oa["id"], ob["id"]))))
    roads = [(r, city.road_rect(r)) for r in data["roads"]]
    for o in objs:
        r = city.object_rect(o)
        for road, rr in roads:
            if city.overlaps(r, rr, 0.3):
                problems.append(f"{o['id']} ({o['type']}) overlaps road {road['id']}")
    for a, b in sorted(pairs):
        problems.append(f"overlap: {a} / {b}")
    if problems:
        print("\n".join(problems))
        print(f"{len(problems)} problem(s)")
        sys.exit(1)
    print(f"ok: {len(objs)} objects, {len(data['blocks'])} blocks, {len(data['roads'])} roads, no problems")


def print_stats(data, title=None):
    if title:
        print(title)
    by_type = {}
    for o in data["buildings"] + data["props"]:
        by_type[o["type"]] = by_type.get(o["type"], 0) + 1
    print(f"  {data.get('name')}: {len(data['districts'])} districts, {len(data['blocks'])} blocks, "
          f"{len(data['roads'])} roads, {len(data['buildings'])} buildings, {len(data['props'])} props")
    print("  " + ", ".join(f"{t}={n}" for t, n in sorted(by_type.items())))


def cmd_stats(args):
    data = read_json(CITY_PATH)
    print_stats(data)
    for d in data["districts"]:
        n = sum(1 for o in data["buildings"] if o.get("district") == d["id"])
        print(f"  {d['id']}  {d['name']}  ({d.get('type')})  buildings={n}  cells={d.get('cells', [])}")


def cmd_list_types(args):
    types = read_json(TYPES_PATH)["types"]
    for k, t in types.items():
        print(f"  {k:18s} {t.get('name', ''):20s} footprint={t.get('footprint')} "
              f"{t.get('category', '')}{' (prop)' if t.get('detail') == 'prop' else ''}")


def main():
    p = argparse.ArgumentParser(description="Tel Batata city data editor")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("init", help="create the starter city")
    s.add_argument("--force", action="store_true")
    s.add_argument("--seed", type=int, default=7)
    s.set_defaults(func=cmd_init)

    s = sub.add_parser("add-neighborhood", help="add a new district on free land next to the city")
    s.add_argument("--name", required=True)
    s.add_argument("--houses", type=int, default=0, help="number of houses (8 per block)")
    s.add_argument("--apartments", type=int, default=0, help="number of apartment blocks (4 buildings each)")
    s.add_argument("--shops", type=int, default=None, help="number of commercial blocks")
    s.add_argument("--parks", type=int, default=None, help="number of park blocks")
    s.add_argument("--civic", default="", help="comma list: town_hall,school,library")
    s.add_argument("--direction", choices=["auto", "east", "north", "south"], default="auto")
    s.add_argument("--seed", type=int, default=None)
    s.set_defaults(func=cmd_add_neighborhood)

    s = sub.add_parser("add-building", help="add one object at an exact position")
    s.add_argument("--type", required=True)
    s.add_argument("--x", type=float, required=True)
    s.add_argument("--z", type=float, required=True)
    s.add_argument("--rot", type=float, default=0)
    s.add_argument("--variant", type=int, default=0)
    s.add_argument("--district", default="")
    s.set_defaults(func=cmd_add_building)

    s = sub.add_parser("remove", help="remove objects by id, or a whole district")
    s.add_argument("--id", nargs="*")
    s.add_argument("--district")
    s.set_defaults(func=cmd_remove)

    s = sub.add_parser("import-overlay", help="bake in-game edits into city.json")
    s.add_argument("path")
    s.set_defaults(func=cmd_import_overlay)

    sub.add_parser("validate", help="check ids, types and overlaps").set_defaults(func=cmd_validate)
    sub.add_parser("stats", help="summary of the city").set_defaults(func=cmd_stats)
    sub.add_parser("list-types", help="list building types").set_defaults(func=cmd_list_types)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
