// benchmarks/adapters/jevman/entry.ts
import { createInterface } from "node:readline";

// benchmarks/sources/jevman/src/layout.ts
var CLASSIC_LAYOUT = [
  "############################",
  "#............##............#",
  "#.####.#####.##.#####.####.#",
  "#o####.#####.##.#####.####o#",
  "#.####.#####.##.#####.####.#",
  "#..........................#",
  "#.####.##.########.##.####.#",
  "#.####.##.########.##.####.#",
  "#......##....##....##......#",
  "######.##### ## #####.######",
  "######.##### ## #####.######",
  "######.##          ##.######",
  "######.## ###--### ##.######",
  "######.## #______# ##.######",
  "      .   #______#   .      ",
  "######.## #______# ##.######",
  "######.## ######## ##.######",
  "######.##          ##.######",
  "######.## ######## ##.######",
  "######.## ######## ##.######",
  "#............##............#",
  "#.####.#####.##.#####.####.#",
  "#.####.#####.##.#####.####.#",
  "#o..##.......  .......##..o#",
  "###.##.##.########.##.##.###",
  "###.##.##.########.##.##.###",
  "#......##....##....##......#",
  "#.##########.##.##########.#",
  "#.##########.##.##########.#",
  "#..........................#",
  "############################"
];
var PACMAN_START = { x: 13, y: 23 };
var GHOST_DOOR_EXIT = { x: 13, y: 11 };
var FRUIT_TILE = { x: 13, y: 17 };
var HOUSE_TILES = {
  blinky: { x: 13, y: 11 },
  pinky: { x: 13, y: 14 },
  inky: { x: 11, y: 14 },
  clyde: { x: 15, y: 14 }
};
var SCATTER_CORNERS = {
  blinky: { x: 26, y: 1 },
  pinky: { x: 1, y: 1 },
  inky: { x: 26, y: 29 },
  clyde: { x: 1, y: 29 }
};

// benchmarks/sources/jevman/src/types.ts
var DIRS = ["up", "left", "down", "right"];
var GHOST_IDS = ["blinky", "pinky", "inky", "clyde"];
var ACTOR_IDS = ["pacman", ...GHOST_IDS];
var sameTile = (a, b) => a.x === b.x && a.y === b.y;

// benchmarks/sources/jevman/src/maze.ts
var DIR_VEC = {
  up: { x: 0, y: -1 },
  down: { x: 0, y: 1 },
  left: { x: -1, y: 0 },
  right: { x: 1, y: 0 }
};
var REVERSE = { up: "down", down: "up", left: "right", right: "left" };
var Maze = class {
  width;
  height;
  pellets = /* @__PURE__ */ new Set();
  powerPellets = /* @__PURE__ */ new Set();
  walls = [];
  distanceCache = /* @__PURE__ */ new Map();
  constructor(rows) {
    this.height = rows.length;
    this.width = rows[0]?.length ?? 0;
    if (rows.some((row) => row.length !== this.width)) throw new Error("ragged layout");
    rows.forEach(
      (row, y) => [...row].forEach((c, x) => {
        this.walls.push(c === "#" || c === "-" || c === "_");
        if (c === ".") this.pellets.add(y * this.width + x);
        if (c === "o") this.powerPellets.add(y * this.width + x);
      })
    );
  }
  key(t) {
    return t.y * this.width + t.x;
  }
  fromKey(k) {
    return { x: k % this.width, y: Math.floor(k / this.width) };
  }
  isWalkable(t) {
    if (t.y < 0 || t.y >= this.height) return false;
    const x = (t.x % this.width + this.width) % this.width;
    return !this.walls[t.y * this.width + x];
  }
  /** Adjacent tile in direction `d`, wrapping horizontally (the tunnel). */
  neighbor(t, d) {
    const v = DIR_VEC[d];
    return { x: (t.x + v.x + this.width) % this.width, y: t.y + v.y };
  }
  openDirs(t) {
    return DIRS.filter((d) => this.isWalkable(this.neighbor(t, d)));
  }
  /** BFS step counts from `from` to every tile (-1 = unreachable), never passing `blocked`. */
  distances(from, blocked) {
    const dist = new Int16Array(this.width * this.height).fill(-1);
    if (!this.isWalkable(from)) return dist;
    const blockedKey = blocked ? this.key(blocked) : -1;
    const queue = [this.key(from)];
    dist[queue[0]] = 0;
    for (let i = 0; i < queue.length; i++) {
      const tile = this.fromKey(queue[i]);
      for (const d of DIRS) {
        const n = this.neighbor(tile, d);
        if (!this.isWalkable(n)) continue;
        const k = this.key(n);
        if (k === blockedKey || dist[k] !== -1) continue;
        dist[k] = dist[queue[i]] + 1;
        queue.push(k);
      }
    }
    return dist;
  }
  /** Cached BFS distances to `to` (the maze is undirected, so from == to). */
  distanceMap(to) {
    const k = this.key(to);
    let map = this.distanceCache.get(k);
    if (!map) {
      map = this.distances(to);
      this.distanceCache.set(k, map);
    }
    return map;
  }
  /** Closest walkable tile to `t` (clamped into the grid, then searched in growing diamonds). */
  nearestWalkable(t) {
    const c = {
      x: Math.min(this.width - 1, Math.max(0, t.x)),
      y: Math.min(this.height - 1, Math.max(0, t.y))
    };
    if (this.isWalkable(c)) return c;
    for (let r = 1; r < this.width + this.height; r++) {
      for (let dx = -r; dx <= r; dx++) {
        const dy = r - Math.abs(dx);
        for (const n of [{ x: c.x + dx, y: c.y + dy }, { x: c.x + dx, y: c.y - dy }]) {
          if (n.x >= 0 && n.x < this.width && this.isWalkable(n)) return n;
        }
      }
    }
    return c;
  }
};

// benchmarks/sources/jevman/src/sim.ts
var SPEED = { pacman: 7.5, ghost: 7, frightened: 4.5, eaten: 14 };
var READY_SECONDS = 1.5;
var DYING_SECONDS = 1.5;
var LEVELCLEAR_SECONDS = 2;
var FRUIT_SECONDS = 9.5;
var FRUIT_THRESHOLDS = [70, 170];
var RELEASE_AT = { blinky: 0, pinky: 1, inky: 4, clyde: 7 };
var MODE_SCHEDULE = [
  ["scatter", 7],
  ["chase", 20],
  ["scatter", 7],
  ["chase", 20],
  ["scatter", 5],
  ["chase", 20],
  ["scatter", 5],
  ["chase", Infinity]
];
var FRUITS = [
  [1, "cherry", 100],
  [2, "strawberry", 300],
  [4, "orange", 500],
  [6, "apple", 700],
  [8, "melon", 1e3],
  [10, "galaxian", 2e3],
  [12, "bell", 3e3],
  [Infinity, "key", 5e3]
];
var SUBSTEP = 1 / 60;
var COLLISION_DISTANCE = 0.6;
var CORRIDOR_LIMIT = 40;
var EPSILON = 1e-9;
function modeAt(seconds) {
  let t = seconds;
  for (const [mode2, length] of MODE_SCHEDULE) {
    if (t < length) return mode2;
    t -= length;
  }
  return "chase";
}
var frightSeconds = (level) => Math.max(2, 7 - level);
function fruitForLevel(level) {
  const [, kind, points] = FRUITS.find(([maxLevel]) => level <= maxLevel);
  return { kind, points };
}
function createGame(opts = {}) {
  const base = { tile: { x: 0, y: 0 }, dir: "left", progress: 0, waiting: false, epoch: 0 };
  const ghosts = Object.fromEntries(
    GHOST_IDS.map((id) => [id, { ...base, id, state: "house", releaseAt: 0 }])
  );
  const state = {
    layout: CLASSIC_LAYOUT,
    maze: new Maze(CLASSIC_LAYOUT),
    pacman: { ...base, id: "pacman" },
    ghosts,
    pacmanControl: opts.pacmanControl ?? "jev",
    // Unless asked, the AI plays one side: the ghosts when the player steers Pac-Man.
    ghostsByAI: opts.ghostsByAI ?? (opts.pacmanControl ?? "jev") === "keyboard",
    keyDir: null,
    status: "ready",
    statusTimer: READY_SECONDS,
    mode: "scatter",
    modeTime: 0,
    frightLeft: 0,
    frightChain: 0,
    score: 0,
    lives: 3,
    level: 1,
    pelletsEaten: 0,
    fruit: null,
    fruitsSpawned: 0,
    lifeTime: 0,
    popups: [],
    caughtBy: null
  };
  resetPositions(state);
  return state;
}
function resetPositions(state) {
  const p = state.pacman;
  p.tile = { ...PACMAN_START };
  p.dir = "left";
  p.progress = 0;
  p.waiting = false;
  p.epoch += 1;
  for (const id of GHOST_IDS) {
    const g = state.ghosts[id];
    g.tile = { ...HOUSE_TILES[id] };
    g.dir = id === "blinky" ? "left" : "up";
    g.progress = 0;
    g.waiting = false;
    g.epoch += 1;
    g.state = id === "blinky" ? "normal" : "house";
    g.releaseAt = RELEASE_AT[id];
  }
  state.status = "ready";
  state.statusTimer = READY_SECONDS;
  state.mode = "scatter";
  state.modeTime = 0;
  state.frightLeft = 0;
  state.frightChain = 0;
  state.lifeTime = 0;
  state.keyDir = null;
  state.caughtBy = null;
}
var actorOf = (state, id) => id === "pacman" ? state.pacman : state.ghosts[id];
var ghostList = (state) => GHOST_IDS.map((id) => state.ghosts[id]);
function isJevDriven(state, id) {
  if (id === "pacman") return state.pacmanControl === "jev";
  const s = state.ghosts[id].state;
  return s === "normal" || s === "frightened";
}
function actorPosition(a) {
  const v = DIR_VEC[a.dir];
  return { x: a.tile.x + v.x * a.progress, y: a.tile.y + v.y * a.progress };
}
function occupiedTile(state, a) {
  return a.progress >= 0.5 ? state.maze.neighbor(a.tile, a.dir) : a.tile;
}
function forcedDir(state, tile, heading) {
  const open = state.maze.openDirs(tile);
  const ahead = open.filter((d) => d !== REVERSE[heading]);
  if (ahead.length === 1) return ahead[0];
  if (ahead.length === 0) return open[0] ?? null;
  return null;
}
function optionsAt(state, id, tile, heading) {
  const open = state.maze.openDirs(tile);
  return id === "pacman" ? open : open.filter((d) => d !== REVERSE[heading]);
}
function decisionKey(state, id, tile, heading) {
  const mood = id === "pacman" ? state.frightLeft > 0 ? "hunt" : "eat" : state.ghosts[id].state;
  const mode2 = id === "pacman" ? "" : `:${state.mode}`;
  return `${id}@${tile.x},${tile.y}>${heading}#${actorOf(state, id).epoch}:${mood}${mode2}`;
}
function decisionPointAt(state, id, tile, heading) {
  if (forcedDir(state, tile, heading) !== null) return null;
  return {
    actor: id,
    tile: { ...tile },
    heading,
    options: optionsAt(state, id, tile, heading),
    key: decisionKey(state, id, tile, heading),
    distance: 0
  };
}
function nextDecisionPoint(state, id) {
  if (!isJevDriven(state, id)) return null;
  const a = actorOf(state, id);
  if (a.waiting) return decisionPointAt(state, id, a.tile, a.dir);
  let tile = state.maze.neighbor(a.tile, a.dir);
  let heading = a.dir;
  for (let i = 0; i < state.maze.width * state.maze.height; i++) {
    const point = decisionPointAt(state, id, tile, heading);
    if (point) return { ...point, distance: i + 1 };
    heading = forcedDir(state, tile, heading);
    tile = state.maze.neighbor(tile, heading);
  }
  return null;
}
function escapePoint(state) {
  const a = state.pacman;
  if (state.status !== "playing" || state.pacmanControl !== "jev" || a.waiting || !canTurnBack(state, a)) return null;
  const ahead = [];
  let tile = state.maze.neighbor(a.tile, a.dir);
  let heading = a.dir;
  for (let i = 0; i < CORRIDOR_LIMIT; i++) {
    ahead.push(tile);
    const next = forcedDir(state, tile, heading);
    if (next === null) break;
    heading = next;
    tile = state.maze.neighbor(tile, heading);
  }
  const junction = ahead[ahead.length - 1];
  const toJunction = state.maze.distances(junction, a.tile);
  const threats = GHOST_IDS.filter((id) => {
    const g = state.ghosts[id];
    if (g.state !== "normal") return false;
    const at = occupiedTile(state, g);
    const d = toJunction[state.maze.key(at)];
    return ahead.some((t) => sameTile(t, at)) || d >= 0 && d <= ahead.length;
  });
  if (!threats.length) return null;
  const mood = state.frightLeft > 0 ? "hunt" : "eat";
  return {
    actor: "pacman",
    tile: { ...a.tile },
    heading: a.dir,
    options: [a.dir, REVERSE[a.dir]],
    key: `pacman~${junction.x},${junction.y}#${a.epoch}:${mood}:${threats.join("+")}`,
    distance: 0,
    escape: true,
    threats
  };
}
function decisionPoints(state, id) {
  const escape = id === "pacman" ? escapePoint(state) : null;
  const junction = nextDecisionPoint(state, id);
  return [escape, junction].filter((p) => p !== null);
}
function step(state, dt, ctl) {
  state.popups = state.popups.filter((p) => (p.ttl -= dt) > 0);
  if (state.status === "gameover") return;
  if (state.status !== "playing") {
    state.statusTimer -= dt;
    if (state.statusTimer > EPSILON) return;
    if (state.status === "ready") {
      state.status = "playing";
    } else if (state.status === "dying") {
      state.lives -= 1;
      if (state.lives <= 0) state.status = "gameover";
      else resetPositions(state);
    } else if (state.status === "levelclear") {
      state.level += 1;
      state.maze = new Maze(state.layout);
      state.pelletsEaten = 0;
      state.fruit = null;
      state.fruitsSpawned = 0;
      resetPositions(state);
    }
    return;
  }
  for (let left = dt; left > EPSILON && state.status === "playing"; left -= SUBSTEP) {
    tick(state, Math.min(left, SUBSTEP), ctl);
  }
}
function tick(state, h, ctl) {
  state.lifeTime += h;
  if (state.frightLeft > 0) {
    state.frightLeft = Math.max(0, state.frightLeft - h);
    if (state.frightLeft === 0) {
      for (const g of ghostList(state)) if (g.state === "frightened") g.state = "normal";
    }
  } else {
    state.modeTime += h;
    state.mode = modeAt(state.modeTime);
  }
  if (state.fruit) {
    state.fruit.secondsLeft -= h;
    if (state.fruit.secondsLeft <= 0) state.fruit = null;
  }
  for (const g of ghostList(state)) if (g.state === "house" && state.lifeTime >= g.releaseAt) release(g);
  moveActor(state, state.pacman, h, ctl);
  if (state.status !== "playing") return;
  for (const g of ghostList(state)) if (g.state !== "house") moveActor(state, g, h, ctl);
  checkCollisions(state);
}
function release(g) {
  g.state = "normal";
  g.tile = { ...GHOST_DOOR_EXIT };
  g.dir = "left";
  g.progress = 0;
  g.waiting = false;
  g.epoch += 1;
}
function speedOf(a) {
  if (a.id === "pacman") return SPEED.pacman;
  const s = a.state;
  return s === "eaten" ? SPEED.eaten : s === "frightened" ? SPEED.frightened : SPEED.ghost;
}
function canTurnBack(state, a) {
  return a.progress > 0 || state.maze.isWalkable(state.maze.neighbor(a.tile, REVERSE[a.dir]));
}
function turnBack(state, a) {
  if (!canTurnBack(state, a)) return;
  if (a.progress > 0) {
    a.tile = state.maze.neighbor(a.tile, a.dir);
    a.progress = 1 - a.progress;
  }
  a.dir = REVERSE[a.dir];
}
function moveActor(state, a, h, ctl) {
  if (a.waiting && !chooseAt(state, a, ctl)) return;
  if (a.id === "pacman" && state.pacmanControl === "keyboard" && state.keyDir === REVERSE[a.dir] && a.progress > 0) {
    turnBack(state, a);
  }
  if (a.id === "pacman" && state.pacmanControl === "jev") {
    const escape = escapePoint(state);
    if (escape && ctl.decide(escape, state) === REVERSE[a.dir]) turnBack(state, a);
  }
  a.progress += speedOf(a) * h;
  while (a.progress >= 1) {
    a.tile = state.maze.neighbor(a.tile, a.dir);
    a.progress -= 1;
    onArrive(state, a);
    if (!chooseAt(state, a, ctl)) {
      a.progress = 0;
      return;
    }
  }
}
function chooseAt(state, a, ctl) {
  const dir = nextDir(state, a, ctl);
  if (dir === null) {
    a.waiting = true;
    return false;
  }
  a.dir = dir;
  a.waiting = false;
  return true;
}
function nextDir(state, a, ctl) {
  const { maze } = state;
  if (a.id === "pacman" && state.pacmanControl === "keyboard") {
    const open = maze.openDirs(a.tile);
    if (state.keyDir && open.includes(state.keyDir)) return state.keyDir;
    return open.includes(a.dir) ? a.dir : null;
  }
  if (a.id !== "pacman" && a.state === "eaten") {
    const home = maze.distanceMap(GHOST_DOOR_EXIT);
    const dist = (d) => home[maze.key(maze.neighbor(a.tile, d))];
    return maze.openDirs(a.tile).reduce((best, d) => dist(d) < dist(best) ? d : best);
  }
  const forced = forcedDir(state, a.tile, a.dir);
  if (forced) return forced;
  const point = decisionPointAt(state, a.id, a.tile, a.dir);
  const choice = ctl.decide(point, state);
  return choice && point.options.includes(choice) ? choice : null;
}
function onArrive(state, a) {
  if (a.id === "pacman") {
    eatAt(state, a.tile);
    return;
  }
  const g = a;
  if (g.state === "eaten" && sameTile(g.tile, GHOST_DOOR_EXIT)) {
    g.state = "normal";
    g.epoch += 1;
  }
}
function eatAt(state, tile) {
  const { maze } = state;
  const k = maze.key(tile);
  if (maze.pellets.delete(k)) {
    state.score += 10;
    pelletEaten(state);
  } else if (maze.powerPellets.delete(k)) {
    state.score += 50;
    pelletEaten(state);
    state.frightLeft = frightSeconds(state.level);
    state.frightChain = 0;
    for (const g of ghostList(state)) if (g.state === "normal") g.state = "frightened";
  }
  if (state.fruit && sameTile(tile, state.fruit.tile)) {
    state.score += state.fruit.points;
    state.popups.push({ tile: { ...tile }, text: String(state.fruit.points), ttl: 1.5 });
    state.fruit = null;
  }
  if (maze.pellets.size + maze.powerPellets.size === 0) {
    state.status = "levelclear";
    state.statusTimer = LEVELCLEAR_SECONDS;
  }
}
function pelletEaten(state) {
  state.pelletsEaten += 1;
  if (state.pelletsEaten === FRUIT_THRESHOLDS[state.fruitsSpawned]) {
    state.fruit = { ...fruitForLevel(state.level), tile: { ...FRUIT_TILE }, secondsLeft: FRUIT_SECONDS };
    state.fruitsSpawned += 1;
  }
}
function checkCollisions(state) {
  const p = actorPosition(state.pacman);
  for (const g of ghostList(state)) {
    if (g.state === "house" || g.state === "eaten") continue;
    const q = actorPosition(g);
    const adx = Math.abs(p.x - q.x);
    const dx = Math.min(adx, state.maze.width - adx);
    const dy = p.y - q.y;
    if (dx * dx + dy * dy >= COLLISION_DISTANCE ** 2) continue;
    if (g.state === "frightened") {
      const points = 200 * 2 ** state.frightChain;
      state.frightChain += 1;
      state.score += points;
      g.state = "eaten";
      state.popups.push({ tile: occupiedTile(state, g), text: String(points), ttl: 1.5 });
    } else {
      state.status = "dying";
      state.statusTimer = DYING_SECONDS;
      state.caughtBy = g.id;
      return;
    }
  }
}

// benchmarks/sources/jevman/src/replay.ts
var roundDt = (dt) => Math.round(dt * 1e4) / 1e4;
var Recorder = class {
  frames = [];
  decisions = [];
  events = [];
  keys = [];
  lastKey = null;
  /** Before a frame's step: notes the player's steering if it changed since the end of the last step. */
  key(frame, dir) {
    if (dir !== this.lastKey) this.keys.push([frame, dir]);
    this.lastKey = dir;
  }
  /** After a frame's step: the game may have cleared the steering itself (a lost life does). */
  settle(dir) {
    this.lastKey = dir;
  }
  /** Keeps a scheduler event for the panel, without its trace id. */
  record(frame, e) {
    if (e.type === "call") {
      const { traceId: _omit, ...rest } = e;
      this.events.push([frame, rest]);
    } else this.events.push([frame, e]);
  }
  wrap(ctl, frame) {
    return {
      decide: (point, state) => {
        const choice = ctl.decide(point, state);
        if (choice !== null) this.decisions.push([frame(), point.key, choice]);
        return choice;
      }
    };
  }
  finish(state, model, setup) {
    return {
      ...setup ? { setup, keys: this.keys } : {},
      version: 1,
      recordedAt: (/* @__PURE__ */ new Date()).toISOString(),
      model,
      frames: this.frames,
      decisions: this.decisions,
      events: this.events,
      final: { score: state.score, lives: state.lives, level: state.level, frames: this.frames.length }
    };
  }
};
var Replay = class {
  state;
  frame = 0;
  rec;
  keys = /* @__PURE__ */ new Map();
  /** Per frame+key, the answers decide() returned, in call order (a key can be asked several times per frame). */
  choices = /* @__PURE__ */ new Map();
  eventsByFrame = /* @__PURE__ */ new Map();
  constructor(rec) {
    this.rec = rec;
    this.state = createGame(rec.setup ?? {});
    for (const [f, dir] of rec.keys ?? []) this.keys.set(f, dir);
    for (const [f, key, dir] of rec.decisions) {
      const k = `${f}|${key}`;
      const list = this.choices.get(k);
      if (list) list.push(dir);
      else this.choices.set(k, [dir]);
    }
    for (const [f, e] of rec.events) {
      const event = e.type === "call" ? { ...e, traceId: null } : e;
      this.eventsByFrame.set(f, [...this.eventsByFrame.get(f) ?? [], event]);
    }
  }
  get done() {
    return this.frame >= this.length;
  }
  get length() {
    return this.rec.frames.length || (this.rec.steps ?? 0);
  }
  /** Advances one recorded frame and returns the panel events recorded for it; once done, does nothing. */
  stepFrame() {
    if (this.done) return [];
    const f = this.frame;
    if (this.keys.has(f)) this.state.keyDir = this.keys.get(f);
    step(this.state, this.rec.frames[f] ?? this.rec.fixedStep ?? 0, { decide: (p) => this.choices.get(`${f}|${p.key}`)?.shift() ?? null });
    this.frame += 1;
    return this.eventsByFrame.get(f) ?? [];
  }
};

// benchmarks/sources/jevman/scripts/verify.ts
import { createHash } from "node:crypto";

// benchmarks/sources/jevman/shared/models.ts
var DECISION_MODELS = [
  { id: "typesafe/jev-1.13.0", name: "jev 1.13", maker: "TypeSafe" },
  { id: "opper/clef", name: "Clef", maker: "Cloudflare", opper: "sference/clef" },
  { id: "opper/clef-flash", name: "Clef Flash", maker: "Cloudflare", opper: "cloudflare:global/clef-flash" },
  { id: "opper/kev-4b", name: "Kev 4B", maker: "Jared Palmer" },
  { id: "berget/convaiinnovations/laya", name: "Laya", maker: "ConvAI Innovations" },
  { id: "openai/gpt-6-luna-decisions", name: "GPT-6 Luna", maker: "OpenAI" }
];
var DEFAULT_MODEL = "typesafe/jev-1.13.0";
var modelName = (id) => DECISION_MODELS.find((m) => m.id === id)?.name ?? id;

// benchmarks/sources/jevman/src/features.ts
var CORRIDOR_LIMIT2 = 40;
var CLYDE_SHY_DISTANCE = 8;
var NEARBY_STEPS = 8;
var isTrap = (f) => f.junctionGhost !== null && f.junctionGhost.steps <= f.junctionSteps;
function goalFor(state, id) {
  if (id === "pacman") {
    return state.frightLeft > 0 ? { kind: "hunt", label: "frightened ghost", target: null } : { kind: "eat", label: "pellet", target: null };
  }
  const { maze } = state;
  const ghost = state.ghosts[id];
  const pac = occupiedTile(state, state.pacman);
  if (ghost.state === "frightened") return { kind: "flee", label: "Pac-Man", target: pac };
  const corner = { kind: "corner", label: "home corner", target: SCATTER_CORNERS[id] };
  if (state.mode === "scatter") return corner;
  const ahead = (n) => {
    const v = DIR_VEC[state.pacman.dir];
    return { x: pac.x + v.x * n, y: pac.y + v.y * n };
  };
  switch (id) {
    case "blinky":
      return { kind: "pacman", label: "Pac-Man", target: pac };
    case "pinky":
      return { kind: "ambush", label: "ambush point ahead of Pac-Man", target: maze.nearestWalkable(ahead(4)) };
    case "inky": {
      const pivot = ahead(2);
      const b = occupiedTile(state, state.ghosts.blinky);
      return {
        kind: "flank",
        label: "flanking point",
        target: maze.nearestWalkable({ x: 2 * pivot.x - b.x, y: 2 * pivot.y - b.y })
      };
    }
    case "clyde": {
      const d = maze.distances(occupiedTile(state, ghost))[maze.key(pac)];
      return d >= 0 && d <= CLYDE_SHY_DISTANCE ? corner : { kind: "pacman", label: "Pac-Man", target: pac };
    }
  }
}
function optionFeatures(state, point) {
  const { maze } = state;
  const goal = goalFor(state, point.actor);
  const pac = occupiedTile(state, state.pacman);
  const others = GHOST_IDS.filter((id) => id !== point.actor).map((id) => state.ghosts[id]);
  const danger = others.filter((g) => g.state === "normal");
  const frightened = others.filter((g) => g.state === "frightened");
  const pelletTiles = [...maze.pellets, ...maze.powerPellets].map((k) => maze.fromKey(k));
  const powerTiles = [...maze.powerPellets].map((k) => maze.fromKey(k));
  return point.options.map((dir) => {
    const { start, origin } = routeOf(state, point, dir);
    const dist = maze.distances(start, origin);
    const steps2 = (t) => {
      const v = dist[maze.key(t)];
      return v < 0 ? null : v + 1;
    };
    const nearest = (tiles) => {
      let best = null;
      for (const t of tiles) {
        const s = steps2(t);
        if (s !== null && (best === null || s < best)) best = s;
      }
      return best;
    };
    const corridor = corridorFrom(state, start, dir);
    const junction = corridor[corridor.length - 1];
    const toJunction = maze.distanceMap(junction);
    let junctionGhost = null;
    for (const g of danger) {
      const d = toJunction[maze.key(occupiedTile(state, g))];
      if (d >= 0 && (junctionGhost === null || d < junctionGhost.steps)) junctionGhost = { id: g.id, steps: d };
    }
    const dangerSteps = danger.map((g) => ({ g, steps: steps2(occupiedTile(state, g)) })).filter((x) => x.steps !== null).sort((a, b) => a.steps - b.steps);
    const closest = dangerSteps[0];
    const nearestPellet = nearest(pelletTiles);
    const frightenedGhostSteps = frightened.map((g) => steps2(occupiedTile(state, g))).filter((d) => d !== null).sort((a, b) => a - b);
    const nearestFrightenedGhost = frightenedGhostSteps[0] ?? null;
    const goalDistance = goal.target ? steps2(goal.target) : goal.kind === "hunt" ? nearestFrightenedGhost ?? nearestPellet : nearestPellet;
    return {
      dir,
      goalDistance,
      pacmanDistance: point.actor === "pacman" ? null : steps2(pac),
      nearestPellet,
      corridorPellets: corridor.filter((t) => maze.pellets.has(maze.key(t)) || maze.powerPellets.has(maze.key(t))).length,
      nearestDangerGhost: nearest(danger.map((g) => occupiedTile(state, g))),
      dangerInCorridor: danger.filter((g) => corridor.some((t) => sameTile(t, occupiedTile(state, g)))).map((g) => g.id),
      nearestFrightenedGhost,
      frightenedGhostSteps,
      fruitDistance: state.fruit ? steps2(state.fruit.tile) : null,
      nearestPowerPellet: nearest(powerTiles),
      dangerApproaching: closest !== void 0 && movingToward(state, closest.g, origin),
      dangerNearby: dangerSteps.filter((x) => x.steps <= NEARBY_STEPS).length,
      // Ghost steps are counted from where the ghosts are now, so count Pac-Man's walk to the decision point too.
      junctionSteps: point.distance + corridor.length,
      junctionGhost
    };
  });
}
function movingToward(state, g, to) {
  const { maze } = state;
  const dist = maze.distanceMap(to);
  const here = dist[maze.key(g.tile)];
  const moves = g.waiting ? optionsAt(state, g.id, g.tile, g.dir) : [g.dir];
  return moves.some((d) => {
    const next = dist[maze.key(maze.neighbor(g.tile, d))];
    return next >= 0 && next < here;
  });
}
function routeOf(state, point, dir) {
  if (point.escape && dir !== point.heading && state.pacman.progress > 0) {
    return { start: point.tile, origin: state.maze.neighbor(point.tile, point.heading) };
  }
  return { start: state.maze.neighbor(point.tile, dir), origin: point.tile };
}
function corridorFrom(state, start, heading) {
  const tiles = [];
  let tile = start;
  let dir = heading;
  for (let i = 0; i < CORRIDOR_LIMIT2; i++) {
    tiles.push(tile);
    const ahead = state.maze.openDirs(tile).filter((d) => d !== REVERSE[dir]);
    if (ahead.length !== 1) break;
    dir = ahead[0];
    tile = state.maze.neighbor(tile, dir);
  }
  return tiles;
}
var PACMAN_STEPS_PER_SECOND = 7;
var frightReach = (state, point) => Math.floor(state.frightLeft * PACMAN_STEPS_PER_SECOND) - point.distance;
function fruitRoute(state, point, feats) {
  if (!state.fruit) return null;
  const reach = Math.floor(state.fruit.secondsLeft * PACMAN_STEPS_PER_SECOND);
  const soonDangerous = (f) => f.frightenedGhostSteps.some((d) => d <= f.fruitDistance && d > frightReach(state, point));
  const ok = feats.filter(
    (f) => f.fruitDistance !== null && point.distance + f.fruitDistance <= reach && f.dangerInCorridor.length === 0 && (f.nearestDangerGhost ?? 999) > 2 && !isTrap(f) && !soonDangerous(f)
  );
  return ok.length ? ok.reduce((best, f) => f.fruitDistance < best.fruitDistance ? f : best).dir : null;
}
function greedyChoice(state, point, feats) {
  const lowest = (pool2, score) => pool2.reduce((best, f) => score(f) < score(best) ? f : best).dir;
  const or = (v, missing) => v ?? missing;
  if (point.actor !== "pacman") {
    return goalFor(state, point.actor).kind === "flee" ? lowest(feats, (f) => -or(f.pacmanDistance, 999)) : lowest(feats, (f) => or(f.goalDistance, 999));
  }
  const safe = feats.filter((f) => f.dangerInCorridor.length === 0 && or(f.nearestDangerGhost, 999) > 2 && !isTrap(f));
  const pool = safe.length ? safe : feats;
  const huntReach = frightReach(state, point);
  const huntable = pool.filter((f) => f.nearestFrightenedGhost !== null && f.nearestFrightenedGhost <= huntReach);
  if (huntable.length) return lowest(huntable, (f) => or(f.nearestFrightenedGhost, 999));
  const fruit = fruitRoute(state, point, pool);
  if (fruit) return fruit;
  return lowest(pool, (f) => or(f.nearestPellet, 999));
}

// benchmarks/sources/jevman/src/brain.ts
var ACTOR_NAMES = {
  pacman: "Pac-Man",
  blinky: "Blinky",
  pinky: "Pinky",
  inky: "Inky",
  clyde: "Clyde"
};
var LETTERS = { blinky: "B", pinky: "K", inky: "I", clyde: "C" };
var PERSONA = {
  blinky: "You are Blinky, the red ghost. You are relentless: always close the distance to Pac-Man directly.",
  pinky: "You are Pinky, the pink ghost. You ambush: head for the spot about 4 tiles ahead of Pac-Man to cut him off.",
  inky: "You are Inky, the cyan ghost. You flank: approach Pac-Man from the side opposite Blinky to trap him between you.",
  clyde: "You are Clyde, the orange ghost. You chase Pac-Man while he is far away, but within 8 tiles you lose your nerve and retreat to your home corner (bottom-left)."
};
var questionName = (point) => point.escape ? `${point.actor}_escape` : point.actor;
var round1 = (n) => Math.round(n * 10) / 10;
function summarizeState(state) {
  const { maze } = state;
  const grid = state.layout.map(
    (row, y) => [...row].map((c, x) => {
      const k = maze.key({ x, y });
      if (c === ".") return maze.pellets.has(k) ? "." : " ";
      if (c === "o") return maze.powerPellets.has(k) ? "o" : " ";
      return c === "_" ? "#" : c;
    })
  );
  const put = (t, ch) => {
    grid[t.y][t.x] = ch;
  };
  if (state.fruit) put(state.fruit.tile, "F");
  for (const id of GHOST_IDS) {
    const g = state.ghosts[id];
    if (g.state === "house") continue;
    put(occupiedTile(state, g), g.state === "normal" ? LETTERS[id] : g.state === "frightened" ? LETTERS[id].toLowerCase() : "e");
  }
  const pac = occupiedTile(state, state.pacman);
  put(pac, "P");
  return {
    maze: grid.map((r) => r.join("")),
    legend: "# wall, - ghost-house door, . pellet, o power pellet, F fruit, P Pac-Man, B Blinky, K Pinky, I Inky, C Clyde (lowercase = frightened, edible), e eyes of an eaten ghost",
    mode: state.mode,
    frightened_seconds_left: round1(state.frightLeft),
    pacman: { x: pac.x, y: pac.y, dir: state.pacman.dir },
    ghosts: Object.fromEntries(
      GHOST_IDS.map((id) => {
        const g = state.ghosts[id];
        const t = occupiedTile(state, g);
        return [id, { x: t.x, y: t.y, dir: g.dir, state: g.state }];
      })
    ),
    pellets_left: maze.pellets.size + maze.powerPellets.size,
    lives: state.lives,
    level: state.level,
    score: state.score,
    fruit: state.fruit ? { kind: state.fruit.kind, points: state.fruit.points, x: state.fruit.tile.x, y: state.fruit.tile.y, seconds_left: round1(state.fruit.secondsLeft) } : null
  };
}
function instructionsFor(state, point, feats = optionFeatures(state, point)) {
  const back = point.options.find((d) => d !== point.heading);
  const at = point.escape ? `You are running ${point.heading} through a corridor and ${(point.threats ?? []).map((id) => ACTOR_NAMES[id]).join(" and ")} ${point.threats?.length === 1 ? "is" : "are"} in the corridor ahead or can block the junction at its end before you get there. Keep going ${point.heading}, or turn back ${back} right now?` : `You are approaching junction (${point.tile.x},${point.tile.y}) heading ${point.heading}. Pick the direction to take there.`;
  if (point.actor === "pacman") {
    const f = state.fruit;
    const marked = f && fruitRoute(state, point, feats);
    const fruit = !f ? "" : marked ? `A ${f.kind} worth ${f.points} points (as much as ${f.points / 10} pellets) is on the board and will disappear soon. One route is marked FRUIT: it is the fastest way to it that looks safe. ${state.frightLeft > 0 ? "Hunt a frightened ghost you can reach first; otherwise take the FRUIT route." : "Take the FRUIT route."} ` : point.escape ? "" : `A ${f.kind} worth ${f.points} points is on the board but cannot be reached safely in time; ignore it. `;
    return state.frightLeft > 0 ? `You are Pac-Man. A power pellet is active for ${round1(state.frightLeft)} more seconds: frightened ghosts (lowercase letters) are worth 200, 400, 800 and 1600 points in a row. Hunt the nearest frightened ghost if you can reach it in time, but never run into a normal ghost. ${fruit}${at}` : `You are Pac-Man. Clear the maze by eating every pellet while staying away from the ghosts; touching a non-frightened ghost costs a life. Power pellets (o) make ghosts frightened and edible, so take one when ghosts are closing in. Never pick a route marked DANGER or TRAP unless every route is; prefer routes where ghosts are moving away. ${fruit}${at}`;
  }
  const ghost = state.ghosts[point.actor];
  if (ghost.state === "frightened") {
    return `You are ${ACTOR_NAMES[point.actor]}, a ghost. You are frightened for ${round1(state.frightLeft)} more seconds and Pac-Man can eat you. Flee: pick the route that keeps you farthest from Pac-Man. ${at}`;
  }
  if (state.mode === "scatter") {
    return `${PERSONA[point.actor]} Right now it is scatter time: head back to your home corner instead of chasing. ${at}`;
  }
  return `${PERSONA[point.actor]} ${at}`;
}
var plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;
var steps = (n, what) => n === null ? `${what} not reachable this way` : `${what} ${plural(n, "step")} away`;
function criteriaFor(state, point, feats) {
  const goal = goalFor(state, point.actor);
  const fruit = point.actor === "pacman" ? fruitRoute(state, point, feats) : null;
  const names = (ids) => ids.map((id) => ACTOR_NAMES[id]).join(" and ");
  return Object.fromEntries(
    feats.map((f) => {
      const parts = [];
      if (point.actor === "pacman") {
        parts.push(steps(f.nearestPellet, "nearest pellet"));
        parts.push(`${plural(f.corridorPellets, "pellet")} in the next corridor`);
        parts.push(
          f.nearestDangerGhost === null ? "no dangerous ghost reachable this way" : `${steps(f.nearestDangerGhost, "nearest dangerous ghost")}, ${f.dangerApproaching ? "coming toward you" : "moving away"}`
        );
        if (f.dangerNearby >= 2) parts.push(`${f.dangerNearby} dangerous ghosts within ${NEARBY_STEPS} steps`);
        if (f.dangerInCorridor.length) parts.push(`DANGER: ${names(f.dangerInCorridor)} in this corridor`);
        if (f.junctionGhost && isTrap(f)) {
          parts.push(`TRAP: ${ACTOR_NAMES[f.junctionGhost.id]} can reach the next junction in ${plural(f.junctionGhost.steps, "step")}, you need ${f.junctionSteps}`);
        } else if (f.junctionGhost) {
          parts.push(`you reach the next junction in ${plural(f.junctionSteps, "step")}, ${plural(f.junctionGhost.steps - f.junctionSteps, "step")} before any ghost`);
        }
        if (state.frightLeft === 0 && f.nearestPowerPellet !== null) parts.push(steps(f.nearestPowerPellet, "power pellet"));
        if (state.frightLeft > 0 && f.nearestFrightenedGhost !== null) parts.push(steps(f.nearestFrightenedGhost, "frightened ghost"));
        if (state.fruit && f.dir === fruit) {
          parts.unshift(`FRUIT \u2014 fastest safe-looking way to the ${state.fruit.kind} (${plural(f.fruitDistance, "step")}, worth ${state.fruit.points} points)`);
        }
      } else if (goal.kind === "flee") {
        parts.push(`${steps(f.pacmanDistance, "Pac-Man")} via this route (farther is safer)`);
      } else {
        parts.push(`${steps(f.goalDistance, goal.label)} via this route`);
        if (goal.kind !== "pacman") parts.push(steps(f.pacmanDistance, "Pac-Man"));
        if (f.dangerInCorridor.length) parts.push(`passes ${names(f.dangerInCorridor)}`);
      }
      return [f.dir, `Go ${f.dir}: ${parts.join("; ")}`];
    })
  );
}
function buildRequest(state, batch) {
  return {
    state: summarizeState(state),
    questions: Object.fromEntries(
      batch.map(({ point, features }) => [
        questionName(point),
        { type: "choice", instructions: instructionsFor(state, point, features), criteria: criteriaFor(state, point, features) }
      ])
    )
  };
}
function parseAnswer(answer, q) {
  if (!answer || typeof answer !== "object") return null;
  const a = answer;
  if (a.type !== "choice" || typeof a.choice !== "string") return null;
  const choice = a.choice;
  if (!q.point.options.includes(choice)) return null;
  const raw = a.probabilities && typeof a.probabilities === "object" ? a.probabilities : {};
  const probabilities = {};
  for (const d of q.point.options) if (typeof raw[d] === "number") probabilities[d] = raw[d];
  return {
    actor: q.point.actor,
    key: q.point.key,
    tile: q.point.tile,
    choice,
    options: q.point.options,
    probabilities,
    confidence: typeof a.confidence === "number" ? a.confidence : null,
    source: "jev",
    ...q.point.escape ? { escape: true } : {}
  };
}
function fallbackDecision(state, q, reason) {
  return {
    actor: q.point.actor,
    key: q.point.key,
    tile: q.point.tile,
    choice: greedyChoice(state, q.point, q.features),
    options: q.point.options,
    probabilities: {},
    confidence: null,
    source: "fallback",
    reason,
    ...q.point.escape ? { escape: true } : {}
  };
}

// benchmarks/sources/jevman/src/stats.ts
var GHOST_POINTS = /* @__PURE__ */ new Set(["200", "400", "800", "1600"]);
var REACT_SECONDS = 0.4;
function deathContext(state) {
  if (state.status !== "playing") return null;
  const p = state.pacman;
  if (p.waiting && state.pacmanControl === "jev") return "waiting at junction";
  const asJev = { ...state, pacmanControl: "jev" };
  if (escapePoint(asJev)) return "ghost ahead in corridor";
  const back = p.progress > 0 ? { ...p, tile: state.maze.neighbor(p.tile, p.dir), dir: REVERSE[p.dir], progress: 1 - p.progress } : { ...p, dir: REVERSE[p.dir] };
  if (escapePoint({ ...asJev, pacman: back })) return "ghost from behind";
  return "at/near junction";
}
var GameStats = class {
  seconds = 0;
  pellets = 0;
  ghostsEaten = 0;
  fruit = [];
  deaths = [];
  calls = 0;
  decisions = 0;
  fallbacks = 0;
  latency = { sum: 0, n: 0 };
  confidence = { sum: 0, n: 0 };
  cost = { sum: 0, known: false };
  costEstimated = false;
  errors = 0;
  models = /* @__PURE__ */ new Set();
  /** This life's recent situations, oldest first, trimmed to a little more than REACT_SECONDS. */
  recent = [];
  before = null;
  beforeStep(state) {
    this.before = {
      status: state.status,
      pelletsEaten: state.pelletsEaten,
      score: state.score,
      fruit: state.fruit ? { kind: state.fruit.kind, points: state.fruit.points, tile: { ...state.fruit.tile } } : null,
      popups: new Set(state.popups),
      context: deathContext(state)
    };
  }
  afterStep(state, dt) {
    const b = this.before;
    if (!b) return;
    if (b.status === "playing") this.seconds += dt;
    if (state.pelletsEaten > b.pelletsEaten) this.pellets += state.pelletsEaten - b.pelletsEaten;
    this.ghostsEaten += state.popups.filter((p) => !b.popups.has(p) && GHOST_POINTS.has(p.text)).length;
    const fruit = b.fruit;
    if (fruit && !state.fruit && state.popups.some((p) => !b.popups.has(p) && p.text === String(fruit.points) && sameTile(p.tile, fruit.tile))) {
      this.fruit.push({ kind: fruit.kind, points: fruit.points });
    }
    if (b.status === "playing") {
      this.recent.push({ seconds: this.seconds - dt, context: b.context });
      while (this.recent.length > 1 && this.recent[1].seconds <= this.seconds - REACT_SECONDS - 0.5) this.recent.shift();
    }
    if (b.status === "playing" && state.status === "dying") {
      let context = b.context ?? "at/near junction";
      if (context === "ghost ahead in corridor" || context === "ghost from behind") {
        let since = this.seconds;
        for (let i = this.recent.length - 1; i >= 0 && this.recent[i].context === context; i--) since = this.recent[i].seconds;
        if (this.seconds - since < REACT_SECONDS) context = "at/near junction";
      }
      this.deaths.push({ ghost: state.caughtBy, context, seconds: Math.round(this.seconds * 10) / 10 });
      this.recent = [];
    }
    this.before = null;
  }
  onSchedulerEvent(e) {
    if (e.type === "call") {
      this.calls += 1;
      if (e.model) this.models.add(e.model === "jev-1.13.0" ? DEFAULT_MODEL : e.model);
      if (Number.isFinite(e.latencyMs)) {
        this.latency.sum += e.latencyMs;
        this.latency.n += 1;
      }
      if (e.costUsd !== null && Number.isFinite(e.costUsd)) {
        this.cost.sum += e.costUsd;
        this.cost.known = true;
      }
      if (e.costEstimated) this.costEstimated = true;
    } else if (e.type === "error") {
      this.errors += 1;
    } else if (e.type === "decision" || e.type === "superseded") {
      const sign = e.type === "decision" ? 1 : -1;
      this.decisions += sign;
      if (e.decision.source === "fallback") this.fallbacks += sign;
      else if (e.decision.confidence !== null && Number.isFinite(e.decision.confidence)) {
        this.confidence.sum += sign * e.decision.confidence;
        this.confidence.n += sign;
      }
    }
  }
  summary(state) {
    const round2 = (n, places) => Math.round(n * 10 ** places) / 10 ** places;
    return {
      score: state.score,
      level: state.level,
      seconds: round2(this.seconds, 1),
      pellets: this.pellets,
      ghostsEaten: this.ghostsEaten,
      fruit: [...this.fruit],
      deaths: [...this.deaths],
      jev: {
        calls: this.calls,
        decisions: this.decisions,
        fallbacks: this.fallbacks,
        meanLatencyMs: this.latency.n ? Math.round(this.latency.sum / this.latency.n) : null,
        meanConfidence: this.confidence.n ? round2(this.confidence.sum / this.confidence.n, 2) : null,
        costUsd: this.cost.known ? round2(this.cost.sum, 6) : null,
        costEstimated: this.costEstimated,
        errors: this.errors,
        models: [...this.models]
      }
    };
  }
};

// benchmarks/sources/jevman/shared/leaderboard.ts
var round = (n, places = 0) => Math.round(n * 10 ** places) / 10 ** places;
function summarize(model, games, name = modelName(model)) {
  const mean = (f) => games.length ? games.reduce((a, g) => a + f(g), 0) / games.length : 0;
  const sum = (f) => games.reduce((a, g) => a + f(g), 0);
  const deathsBy = {};
  for (const g of games) for (const [k, v] of Object.entries(g.deathsBy)) deathsBy[k] = (deathsBy[k] ?? 0) + v;
  const calls = sum((g) => g.calls);
  const decisions = sum((g) => g.decisions);
  return {
    model,
    name,
    games: games.length,
    meanScore: round(mean((g) => g.score)),
    bestScore: Math.max(0, ...games.map((g) => g.score)),
    scoreStdError: round(stdError(games.map((g) => g.score))),
    meanSurvivedSeconds: round(mean((g) => g.survived), 1),
    meanPellets: round(mean((g) => g.pellets)),
    pelletsPerLife: round(sum((g) => g.pellets) / Math.max(1, sum((g) => g.deaths))),
    meanGhostsEaten: round(mean((g) => g.ghostsEaten), 1),
    fruitEaten: `${sum((g) => g.fruitEaten)}/${sum((g) => g.fruitSpawned)}`,
    bestLevel: Math.max(1, ...games.map((g) => g.level)),
    fallbackRate: decisions ? round(sum((g) => g.fallbacks) / decisions, 3) : 0,
    meanLatencyMs: calls ? round(sum((g) => g.latencyMsSum) / calls) : null,
    costPerGame: round(mean((g) => g.cost), 5),
    deathsBy
  };
}
function stdError(xs) {
  if (xs.length < 2) return 0;
  const m = xs.reduce((a, x) => a + x, 0) / xs.length;
  const variance = xs.reduce((a, x) => a + (x - m) ** 2, 0) / (xs.length - 1);
  return Math.sqrt(variance / xs.length);
}
var SUBMISSION_RULES = { minGames: 24, maxSeconds: 300, maxStep: 0.05 };

// benchmarks/sources/jevman/scripts/game.ts
function scriptedControls() {
  const answeredEscapes = /* @__PURE__ */ new Set();
  return {
    decide: (point, s) => {
      if (point.escape) {
        if (answeredEscapes.has(point.key)) return null;
        answeredEscapes.add(point.key);
      }
      return greedyChoice(s, point, optionFeatures(s, point));
    }
  };
}
var emptyResult = () => ({
  survived: 0,
  score: 0,
  pellets: 0,
  deaths: 0,
  level: 1,
  calls: 0,
  decisions: 0,
  fallbacks: 0,
  latencyMsSum: 0,
  cost: 0,
  fruitSpawned: 0,
  fruitEaten: 0,
  ghostsEaten: 0,
  deathsBy: {}
});
function finishResult(r, stats, state) {
  const summary = stats.summary(state);
  Object.assign(r, {
    score: state.score,
    level: state.level,
    pellets: summary.pellets,
    deaths: summary.deaths.length,
    decisions: summary.jev.decisions,
    fallbacks: summary.jev.fallbacks,
    fruitEaten: summary.fruit.length,
    ghostsEaten: summary.ghostsEaten
  });
  for (const d of summary.deaths) r.deathsBy[d.context] = (r.deathsBy[d.context] ?? 0) + 1;
  return r;
}

// benchmarks/sources/jevman/scripts/verify.ts
var DIRS2 = /* @__PURE__ */ new Set(["up", "down", "left", "right"]);
var MIN_STEP = 1e-3;
var MAX_ANSWER_SECONDS = 4.5;
var MAX_CALL_USD = 1;
var MAX_CALL_MS = 6e4;
var MAX_ITEMS = 1e5;
function verifyGame(rec, rules = SUBMISSION_RULES) {
  const fail = (error) => ({ ok: false, error });
  if (rec?.version !== 1) return fail("not a version 1 recording");
  if (!Array.isArray(rec.frames) || !Array.isArray(rec.decisions) || !Array.isArray(rec.events)) return fail("frames, decisions and events must be lists");
  if (rec.frames.length > (rules.maxSeconds + 120) / MIN_STEP) return fail(`${rec.frames.length} frames is more than a game has`);
  if (rec.decisions.length > MAX_ITEMS || rec.events.length > MAX_ITEMS) return fail("more decisions or events than a game has");
  const badStep = rec.frames.findIndex((dt) => typeof dt !== "number" || !(dt >= MIN_STEP) || dt > rules.maxStep);
  if (badStep >= 0) return fail(`frame ${badStep}: a step must be ${MIN_STEP} to ${rules.maxStep} s`);
  const moves = /* @__PURE__ */ new Map();
  let pacmanMoves = 0;
  for (const d of rec.decisions) {
    if (!Array.isArray(d) || !Number.isInteger(d[0]) || typeof d[1] !== "string" || !DIRS2.has(d[2])) return fail("malformed decision");
    if (!/^pacman[@~]/.test(d[1])) continue;
    const k = `${d[0]}|${d[1]}`;
    const queue = moves.get(k);
    if (queue) queue.push(d[2]);
    else moves.set(k, [d[2]]);
    pacmanMoves += 1;
  }
  const events = /* @__PURE__ */ new Map();
  for (const e of rec.events) {
    if (!Array.isArray(e) || !Number.isInteger(e[0]) || typeof e[1]?.type !== "string") return fail("malformed event");
    const within = (v, max) => typeof v === "number" && v >= 0 && v <= max;
    if (e[1].type === "call" && !((e[1].costUsd === null || within(e[1].costUsd, MAX_CALL_USD)) && within(e[1].latencyMs, MAX_CALL_MS))) {
      return fail("a call with a negative or impossible cost or latency");
    }
    const event = e[1].type === "call" ? { ...e[1], traceId: null } : e[1];
    const list = events.get(e[0]);
    if (list) list.push(event);
    else events.set(e[0], [event]);
  }
  const state = createGame();
  const stats = new GameStats();
  const r = emptyResult();
  const scripted = scriptedControls();
  let used = 0;
  let illegal = null;
  let clock = 0;
  const firstSeen = /* @__PURE__ */ new Map();
  const answered = /* @__PURE__ */ new Set();
  const fingerprint = createHash("sha256");
  const at = (a) => [a.tile.x, a.tile.y, Math.round(a.progress * 100)];
  try {
    for (let f = 0; f < rec.frames.length; f++) {
      if (state.status === "gameover") return fail(`frames go on after game over (frame ${f})`);
      if (r.survived >= rules.maxSeconds) return fail(`frames go on past the ${rules.maxSeconds} s cap (frame ${f})`);
      const open = new Set(decisionPoints(state, "pacman").map((p) => p.key));
      for (const key of open) if (!firstSeen.has(key)) firstSeen.set(key, { at: clock, frame: f });
      for (const key of firstSeen.keys()) if (!open.has(key)) firstSeen.delete(key);
      for (const key of answered) if (!open.has(key)) answered.delete(key);
      for (const e of events.get(f) ?? []) {
        stats.onSchedulerEvent(e);
        if (e.type === "call") {
          r.calls += 1;
          r.cost += typeof e.costUsd === "number" ? e.costUsd : 0;
          if (Number.isFinite(e.latencyMs)) r.latencyMsSum += e.latencyMs;
        }
      }
      const dt = rec.frames[f];
      const fruitBefore = state.fruit;
      stats.beforeStep(state);
      step(state, dt, {
        decide: (point, s) => {
          if (point.actor !== "pacman") return scripted.decide(point, s);
          const dir = moves.get(`${f}|${point.key}`)?.shift() ?? null;
          if (dir === null) return null;
          used += 1;
          if (illegal !== null) return dir;
          if (!point.options.includes(dir)) illegal = `frame ${f}: ${dir} is not a way out of (${point.tile.x},${point.tile.y})`;
          else if (!((firstSeen.get(point.key)?.frame ?? f) < f)) illegal = `frame ${f}: an answer to a question that was not asked yet`;
          else if (point.escape && answered.has(point.key)) illegal = `frame ${f}: an escape question answered twice`;
          else if (clock - firstSeen.get(point.key).at > MAX_ANSWER_SECONDS) illegal = `frame ${f}: an answer after more than ${MAX_ANSWER_SECONDS} s`;
          if (point.escape) answered.add(point.key);
          fingerprint.update(JSON.stringify([point.key, dir, at(s.pacman), ...GHOST_IDS.map((id) => [...at(s.ghosts[id]), s.ghosts[id].state])]));
          return dir;
        }
      });
      if (illegal) return fail(illegal);
      stats.afterStep(state, dt);
      if (!fruitBefore && state.fruit) r.fruitSpawned += 1;
      if (state.status === "playing") r.survived += dt;
      clock += dt;
    }
  } catch (err) {
    return fail(`the game could not be replayed: ${err.message}`);
  }
  if (state.status !== "gameover" && r.survived < rules.maxSeconds) return fail("the game stops before game over or the time cap");
  if (used !== pacmanMoves) return fail(`${pacmanMoves - used} of Pac-Man's recorded moves were never asked for: the game went differently`);
  const claimed = rec.final;
  if (claimed?.score !== state.score || claimed.level !== state.level || claimed.lives !== state.lives || claimed.frames !== rec.frames.length) {
    return fail(`the replay ends at score ${state.score}, level ${state.level}, ${state.lives} lives; the recording claims score ${claimed?.score}, level ${claimed?.level}, ${claimed?.lives} lives`);
  }
  return { ok: true, result: finishResult(r, stats, state), fingerprint: fingerprint.digest("hex") };
}

// benchmarks/sources/jevman/src/scheduler.ts
var Scheduler = class {
  constructor(deps) {
    this.deps = deps;
    this.timeoutMs = deps.timeoutMs ?? 2e3;
    this.maxInFlight = deps.maxInFlight ?? 3;
    this.actors = deps.actors ?? ACTOR_IDS;
    this.slots = deps.slots ?? { inFlight: 0 };
  }
  deps;
  pending = /* @__PURE__ */ new Map();
  ready = /* @__PURE__ */ new Map();
  /** Answers already handed to the sim whose question is still open (escape questions); never re-asked. */
  consumed = /* @__PURE__ */ new Set();
  /** The decision the last `decide` handed out: a recorded game keeps its signature (or that it was a fallback). */
  lastDecision = null;
  slots;
  timeoutMs;
  maxInFlight;
  actors;
  update(state) {
    const now = this.deps.now();
    const live = /* @__PURE__ */ new Set();
    const fruitOnBoard = state.fruit !== null;
    for (const id of typeof this.actors === "function" ? this.actors(state) : this.actors) {
      for (const point of decisionPoints(state, id)) {
        live.add(point.key);
        const model = this.deps.modelFor?.(id);
        const sent = this.pending.get(point.key);
        if (sent && sent.sentAt !== null && sent.model !== model) this.pending.delete(point.key);
        if (this.ready.has(point.key) && this.ready.get(point.key).model !== model) this.dropReady(point.key);
        if (id === "pacman") {
          if (this.pending.get(point.key)?.fruitOnBoard === !fruitOnBoard) this.pending.delete(point.key);
          if (this.ready.get(point.key)?.fruitOnBoard === !fruitOnBoard) this.dropReady(point.key);
        }
        if (this.pending.has(point.key) || this.ready.has(point.key) || this.consumed.has(point.key)) continue;
        const features = optionFeatures(state, point);
        this.pending.set(point.key, {
          q: { point, features },
          sentAt: null,
          queuedAt: now,
          fruitOnBoard,
          fruitRoute: id === "pacman" ? fruitRoute(state, point, features) : null
        });
      }
    }
    for (const key of [...this.pending.keys()]) if (!live.has(key)) this.pending.delete(key);
    for (const key of [...this.ready.keys()]) if (!live.has(key)) this.dropReady(key);
    for (const key of [...this.consumed]) if (!live.has(key)) this.consumed.delete(key);
    for (const [key, p] of [...this.pending]) {
      const from = this.deps.timeoutFrom === "queue" ? p.queuedAt : p.sentAt;
      if (from !== null && now - from > this.timeoutMs) this.resolve(key, fallbackDecision(state, p.q, "timeout"), null);
    }
    const byModel = /* @__PURE__ */ new Map();
    for (const p of this.pending.values()) {
      if (p.sentAt !== null) continue;
      const model = this.deps.modelFor?.(p.q.point.actor);
      byModel.set(model, [...byModel.get(model) ?? [], p]);
    }
    for (const [model, batch] of byModel) {
      if (this.slots.inFlight >= this.maxInFlight) break;
      this.send(state, batch, now, model);
    }
  }
  decide(point, state) {
    const r = this.ready.get(point.key);
    if (!r) return null;
    this.ready.delete(point.key);
    let d = r.decision;
    this.lastDecision = d;
    const features = point.actor === "pacman" && (r.fruitOnBoard || state.fruit) ? optionFeatures(state, point) : null;
    if (features && (r.fruitOnBoard !== (state.fruit !== null) || fruitRoute(state, point, features) !== r.fruitRoute)) {
      this.deps.onEvent({ type: "superseded", decision: d });
      d = fallbackDecision(state, { point, features }, "fruit changed");
      this.lastDecision = d;
      this.deps.onEvent({ type: "decision", decision: d, latencyMs: null, fruitOnBoard: state.fruit !== null });
    }
    if (!point.escape) return d.choice;
    this.consumed.add(point.key);
    return d.choice === d.options[0] ? point.options[0] : point.options[1];
  }
  reset() {
    this.pending.clear();
    this.ready.clear();
    this.consumed.clear();
  }
  send(state, batch, now, requested) {
    for (const p of batch) {
      p.sentAt = now;
      p.model = requested;
    }
    this.slots.inFlight += 1;
    const isCurrent = (p) => this.pending.get(p.q.point.key) === p;
    this.deps.transport({ ...requested ? { model: requested } : {}, ...buildRequest(state, batch.map((p) => p.q)), keys: Object.fromEntries(batch.map((p) => [questionName(p.q.point), p.q.point.key])) }).then(
      (res) => {
        const model = res.model ?? requested;
        this.deps.onEvent({
          type: "call",
          model,
          actors: batch.map((p) => p.q.point.actor),
          latencyMs: res.latencyMs,
          usage: res.usage,
          costUsd: res.costUsd,
          costEstimated: res.costEstimated === true,
          traceId: res.traceId
        });
        for (const p of batch) {
          if (!isCurrent(p)) {
            this.deps.onEvent({ type: "stale", actor: p.q.point.actor, key: p.q.point.key });
            continue;
          }
          const parsed = parseAnswer(res.answers[questionName(p.q.point)], p.q);
          const sig = res.signatures?.[questionName(p.q.point)];
          const decision = parsed ? { ...parsed, model, ...sig && res.signedAs ? { sig, signedAs: res.signedAs } : {} } : fallbackDecision(state, p.q, "invalid answer");
          this.resolve(p.q.point.key, decision, res.latencyMs);
        }
      },
      (err) => {
        this.deps.onEvent({ type: "error", message: err instanceof Error ? err.message : String(err) });
        for (const p of batch) if (isCurrent(p)) this.resolve(p.q.point.key, fallbackDecision(state, p.q, "error"), null);
      }
    ).finally(() => {
      this.slots.inFlight -= 1;
    });
  }
  /** Discard an answer that was announced as a decision but will never be used. */
  dropReady(key) {
    const r = this.ready.get(key);
    if (!r) return;
    this.ready.delete(key);
    this.deps.onEvent({ type: "superseded", decision: r.decision });
  }
  resolve(key, decision, latencyMs) {
    const p = this.pending.get(key);
    if (!p) return;
    this.pending.delete(key);
    this.ready.set(key, { decision, fruitOnBoard: p.fruitOnBoard, fruitRoute: p.fruitRoute, model: p.model });
    this.deps.onEvent({ type: "decision", decision, latencyMs, fruitOnBoard: p.fruitOnBoard });
  }
};

// benchmarks/adapters/jevman/entry.ts
var input = createInterface({ input: process.stdin, crlfDelay: Infinity });
var emit = (value) => process.stdout.write(`${JSON.stringify(value)}
`);
var mode = process.argv[2];
if (mode === "play") {
  await play();
} else if (mode === "replay") {
  for await (const line of input) {
    const { recording } = JSON.parse(line);
    const verdict = verifyGame(recording);
    if (!verdict.ok) {
      process.stdout.write(`${JSON.stringify(verdict)}
`);
    } else {
      const replay = new Replay(recording);
      while (!replay.done) replay.stepFrame();
      process.stdout.write(`${JSON.stringify({
        ...verdict,
        final: {
          score: replay.state.score,
          lives: replay.state.lives,
          level: replay.state.level,
          frames: replay.frame
        }
      })}
`);
    }
    break;
  }
  input.close();
} else {
  throw new Error("Unknown Jevman runtime command");
}
async function play() {
  let cancelled = null;
  let id = 0;
  let phase = "warmup";
  let gameIndex = 0;
  let start;
  const started = new Promise((resolve) => {
    start = resolve;
  });
  const waiting = /* @__PURE__ */ new Map();
  const stop = (status) => {
    cancelled ??= status;
    for (const pending of waiting.values()) pending.reject(new Error(status));
    waiting.clear();
  };
  input.on("line", (line) => {
    const message = JSON.parse(line);
    if (message.type === "start") start(message);
    else if (message.type === "cancel") stop(message.status ?? "cancelled");
    else if (typeof message.id === "number") {
      waiting.get(message.id)?.resolve(message);
      waiting.delete(message.id);
    }
  });
  input.on("close", () => stop("interrupted"));
  process.on("SIGTERM", () => stop("interrupted"));
  const { model } = await started;
  const request = async (body, timeoutMs) => {
    if (cancelled) throw new Error(cancelled);
    const requestId = ++id;
    const response = new Promise((resolve, reject) => waiting.set(requestId, { resolve, reject }));
    emit({ type: "request", id: requestId, phase, game: gameIndex, body, timeoutMs });
    return await response;
  };
  const games = [];
  const warmupStarted = performance.now();
  let warmupElapsedMs = 0;
  let warmupAttempts = 0;
  let warmupError = null;
  try {
    const body = { state: { note: "warm-up" }, questions: { warmup: { type: "choice", instructions: "Pick one.", criteria: { a: "Option A", b: "Option B" } } } };
    let warm = false;
    while (performance.now() - warmupStarted < 3e5 && !cancelled) {
      warmupAttempts += 1;
      const t0 = performance.now();
      const reply = await request(body, 3e4);
      const ms = Math.round(performance.now() - t0);
      if (reply.status === 200 && ms < 1800) {
        warm = true;
        break;
      }
      if (reply.status !== 200 && reply.status !== 504) {
        warmupError = reply.error ?? "warmup failed";
        break;
      }
    }
    if (!warm && !cancelled) warmupError ??= "did not answer within 1.8 s in 5 minutes of trying";
    warmupElapsedMs = performance.now() - warmupStarted;
    emit({ type: "warmup", attempts: warmupAttempts, elapsedMs: warmupElapsedMs, error: warmupError });
    if (warm && !cancelled) {
      phase = "game";
      for (gameIndex = 1; gameIndex <= 100 && !cancelled; gameIndex++) {
        const state = createGame();
        const result = emptyResult();
        const stats = new GameStats();
        const recorder = new Recorder();
        const outstanding = /* @__PURE__ */ new Set();
        let frame = 0;
        let sealed = false;
        let costKnown = true;
        const transport = (body2) => {
          const pending = request(body2, 2e3).then((reply) => {
            if (reply.status !== 200) throw new Error(reply.error ?? `endpoint answered ${reply.status}`);
            const output = reply.output;
            if (typeof output.costUsd !== "number") costKnown = false;
            return { model, answers: output.answers, usage: output.usage ?? { input_tokens: 0, output_tokens: 0 }, latencyMs: reply.elapsedMs, costUsd: typeof output.costUsd === "number" ? output.costUsd : null, traceId: null };
          });
          outstanding.add(pending);
          void pending.then(() => outstanding.delete(pending), () => outstanding.delete(pending));
          return pending;
        };
        const scheduler = new Scheduler({ transport, now: () => performance.now(), actors: ["pacman"], onEvent: (event) => {
          if (sealed) return;
          recorder.record(frame, event);
          stats.onSchedulerEvent(event);
          if (event.type === "call") {
            result.calls += 1;
            result.cost += event.costUsd ?? 0;
            if (Number.isFinite(event.latencyMs)) result.latencyMsSum += event.latencyMs;
          }
        } });
        const scripted = scriptedControls();
        const base = { decide: (point, current) => point.actor === "pacman" ? scheduler.decide(point, current) : scripted.decide(point, current) };
        const controls = recorder.wrap(base, () => frame);
        let last = performance.now();
        try {
          while (!cancelled && state.status !== "gameover" && result.survived < 300) {
            await new Promise((resolve) => setTimeout(resolve, 16));
            const now = performance.now();
            const dt = roundDt(Math.min(0.05, (now - last) / 1e3));
            last = now;
            recorder.frames.push(dt);
            scheduler.update(state);
            const fruitBefore = state.fruit;
            stats.beforeStep(state);
            step(state, dt, controls);
            stats.afterStep(state, dt);
            if (!fruitBefore && state.fruit) result.fruitSpawned += 1;
            for (const actor of [state.pacman, ...GHOST_IDS.map((ghost) => state.ghosts[ghost])]) {
              if (actor.id !== "pacman" && state.ghosts[actor.id].state === "house") continue;
              const into = state.maze.neighbor(actor.tile, actor.dir);
              if (!state.maze.isWalkable(actor.tile) || actor.progress > 0 && !state.maze.isWalkable(into)) throw new Error(`${actor.id} left the maze`);
            }
            if (state.status === "playing") result.survived += dt;
            frame += 1;
            emit({ type: "frame", game: gameIndex, frame, playingSeconds: result.survived, state: summarizeState(state), status: state.status });
          }
        } catch (error) {
          warmupError = error instanceof Error ? error.message : String(error);
        }
        sealed = true;
        finishResult(result, stats, state);
        const game = { index: gameIndex, complete: !cancelled && !warmupError, result, recording: recorder.finish(state, model), costKnown: costKnown && result.calls > 0 };
        games.push(game);
        scheduler.reset();
        await Promise.allSettled(outstanding);
        emit({ type: "game", game });
        if (warmupError) break;
      }
    }
  } catch (error) {
    if (!cancelled) warmupError = error instanceof Error ? error.message : String(error);
    if (phase === "warmup") warmupElapsedMs = performance.now() - warmupStarted;
  }
  const complete = !cancelled && !warmupError && games.length === 100 && games.every((game) => game.complete);
  const originalSummary = complete ? summarize(model, games.map((game) => game.result), model) : null;
  emit({ type: "result", result: {
    status: cancelled ?? (complete ? "completed" : "failed"),
    complete,
    expectedGames: 100,
    games,
    error: warmupError,
    warmup: { attempts: warmupAttempts, elapsedMs: warmupElapsedMs },
    summary: originalSummary ? { ...originalSummary, costPerGame: games.every((game) => game.costKnown) ? originalSummary.costPerGame : null } : null,
    originalSummary
  } });
  input.close();
}
