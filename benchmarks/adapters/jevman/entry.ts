// Adapter orchestration only. Rules, replay and scoring are imported verbatim
// from the fixed AGPL-3.0-or-later submodule; see NOTICE and the resource manifest.
import { createInterface } from 'node:readline';
import { Replay, type Recording } from '../../sources/jevman/src/replay';
import { verifyGame } from '../../sources/jevman/scripts/verify';
import { Recorder, roundDt } from '../../sources/jevman/src/replay';
import { Scheduler, type Transport } from '../../sources/jevman/src/scheduler';
import { createGame, step, type Controls } from '../../sources/jevman/src/sim';
import { GameStats } from '../../sources/jevman/src/stats';
import { GHOST_IDS } from '../../sources/jevman/src/types';
import { emptyResult, finishResult, scriptedControls } from '../../sources/jevman/scripts/game';
import { summarize, type GameResult } from '../../sources/jevman/shared/leaderboard';
import { summarizeState, type DecideResponse } from '../../sources/jevman/src/brain';

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
const emit = (value: unknown) => process.stdout.write(`${JSON.stringify(value)}\n`);
const mode = process.argv[2];
if (mode === 'play') {
  await play();
} else if (mode === 'replay') {

for await (const line of input) {
  const { recording } = JSON.parse(line) as { recording: Recording };
  const verdict = verifyGame(recording);
  if (!verdict.ok) {
    process.stdout.write(`${JSON.stringify(verdict)}\n`);
  } else {
    const replay = new Replay(recording);
    while (!replay.done) replay.stepFrame();
    process.stdout.write(`${JSON.stringify({
      ...verdict,
      final: {
        score: replay.state.score,
        lives: replay.state.lives,
        level: replay.state.level,
        frames: replay.frame,
      },
    })}\n`);
  }
  break;
}
input.close();
} else {
  throw new Error('Unknown Jevman runtime command');
}

async function play(): Promise<void> {
  let cancelled: string | null = null;
  let id = 0;
  let phase = 'warmup';
  let gameIndex = 0;
  let start!: (value: { model: string }) => void;
  const started = new Promise<{ model: string }>((resolve) => { start = resolve; });
  const waiting = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
  const stop = (status: string) => {
    cancelled ??= status;
    for (const pending of waiting.values()) pending.reject(new Error(status));
    waiting.clear();
  };
  input.on('line', (line) => {
    const message = JSON.parse(line);
    if (message.type === 'start') start(message);
    else if (message.type === 'cancel') stop(message.status ?? 'cancelled');
    else if (typeof message.id === 'number') {
      waiting.get(message.id)?.resolve(message);
      waiting.delete(message.id);
    }
  });
  input.on('close', () => stop('interrupted'));
  process.on('SIGTERM', () => stop('interrupted'));
  const { model } = await started;
  const request = async (body: unknown, timeoutMs: number) => {
    if (cancelled) throw new Error(cancelled);
    const requestId = ++id;
    const response = new Promise<any>((resolve, reject) => waiting.set(requestId, { resolve, reject }));
    emit({ type: 'request', id: requestId, phase, game: gameIndex, body, timeoutMs });
    return await response;
  };
  const games: { index: number; complete: boolean; result: GameResult; recording: Recording; costKnown: boolean }[] = [];
  const warmupStarted = performance.now();
  let warmupElapsedMs = 0;
  let warmupAttempts = 0;
  let warmupError: string | null = null;
  try {
    // Verbatim original scripts/bench.ts warmup request and acceptance rule.
    const body = { state: { note: 'warm-up' }, questions: { warmup: { type: 'choice', instructions: 'Pick one.', criteria: { a: 'Option A', b: 'Option B' } } } };
    let warm = false;
    while (performance.now() - warmupStarted < 300_000 && !cancelled) {
      warmupAttempts += 1;
      const t0 = performance.now();
      const reply = await request(body, 30_000);
      const ms = Math.round(performance.now() - t0);
      if (reply.status === 200 && ms < 1800) { warm = true; break; }
      if (reply.status !== 200 && reply.status !== 504) { warmupError = reply.error ?? 'warmup failed'; break; }
    }
    if (!warm && !cancelled) warmupError ??= 'did not answer within 1.8 s in 5 minutes of trying';
    warmupElapsedMs = performance.now() - warmupStarted;
    emit({ type: 'warmup', attempts: warmupAttempts, elapsedMs: warmupElapsedMs, error: warmupError });
    if (warm && !cancelled) {
      phase = 'game';
      // Fixed complete product scale. There is deliberately no games option.
      for (gameIndex = 1; gameIndex <= 100 && !cancelled; gameIndex++) {
        const state = createGame();
        const result = emptyResult();
        const stats = new GameStats();
        const recorder = new Recorder();
        const outstanding = new Set<Promise<DecideResponse>>();
        let frame = 0;
        let sealed = false;
        let costKnown = true;
        const transport: Transport = (body) => {
          const pending = request(body, 2000).then((reply) => {
            if (reply.status !== 200) throw new Error(reply.error ?? `endpoint answered ${reply.status}`);
            const output = reply.output;
            if (typeof output.costUsd !== 'number') costKnown = false;
            return { model, answers: output.answers, usage: output.usage ?? { input_tokens: 0, output_tokens: 0 }, latencyMs: reply.elapsedMs, costUsd: typeof output.costUsd === 'number' ? output.costUsd : null, traceId: null } as DecideResponse;
          });
          outstanding.add(pending);
          // A separate success/error branch prevents an unhandled rejection.
          void pending.then(() => outstanding.delete(pending), () => outstanding.delete(pending));
          return pending;
        };
        const scheduler = new Scheduler({ transport, now: () => performance.now(), actors: ['pacman'], onEvent: (event) => {
          if (sealed) return; // Late answers cannot mutate an already sealed game.
          recorder.record(frame, event);
          stats.onSchedulerEvent(event);
          if (event.type === 'call') {
            result.calls += 1;
            result.cost += event.costUsd ?? 0;
            if (Number.isFinite(event.latencyMs)) result.latencyMsSum += event.latencyMs;
          }
        } });
        const scripted = scriptedControls();
        const base: Controls = { decide: (point, current) => point.actor === 'pacman' ? scheduler.decide(point, current) : scripted.decide(point, current) };
        const controls = recorder.wrap(base, () => frame);
        let last = performance.now();
        try {
        while (!cancelled && state.status !== 'gameover' && result.survived < 300) {
          await new Promise((resolve) => setTimeout(resolve, 16));
          const now = performance.now();
          const dt = roundDt(Math.min(0.05, (now - last) / 1000));
          last = now;
          recorder.frames.push(dt);
          scheduler.update(state);
          const fruitBefore = state.fruit;
          stats.beforeStep(state);
          step(state, dt, controls);
          stats.afterStep(state, dt);
          if (!fruitBefore && state.fruit) result.fruitSpawned += 1;
          for (const actor of [state.pacman, ...GHOST_IDS.map((ghost) => state.ghosts[ghost])]) {
            if (actor.id !== 'pacman' && state.ghosts[actor.id].state === 'house') continue;
            const into = state.maze.neighbor(actor.tile, actor.dir);
            if (!state.maze.isWalkable(actor.tile) || (actor.progress > 0 && !state.maze.isWalkable(into))) throw new Error(`${actor.id} left the maze`);
          }
          if (state.status === 'playing') result.survived += dt;
          frame += 1;
          // Passive observation: never await a renderer or change the schedule.
          emit({ type: 'frame', game: gameIndex, frame, playingSeconds: result.survived, state: summarizeState(state), status: state.status });
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
        // Original game state/trace is already sealed. Drain only its normal
        // calls before publishing one durable-commit event; frame pacing never
        // waits for storage, renderers or a new acknowledgement protocol.
        emit({ type: 'game', game });
        if (warmupError) break;
      }
    }
  } catch (error) {
    if (!cancelled) warmupError = error instanceof Error ? error.message : String(error);
    if (phase === 'warmup') warmupElapsedMs = performance.now() - warmupStarted;
  }
  const complete = !cancelled && !warmupError && games.length === 100 && games.every((game) => game.complete);
  const originalSummary = complete ? summarize(model, games.map((game) => game.result), model) : null;
  emit({ type: 'result', result: {
    status: cancelled ?? (complete ? 'completed' : 'failed'), complete,
    expectedGames: 100, games, error: warmupError,
    warmup: { attempts: warmupAttempts, elapsedMs: warmupElapsedMs },
    summary: originalSummary ? { ...originalSummary, costPerGame: games.every((game) => game.costKnown) ? originalSummary.costPerGame : null } : null,
    originalSummary,
  } });
  input.close();
}
