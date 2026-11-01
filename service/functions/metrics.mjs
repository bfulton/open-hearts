// Watching it run: counts to Workers Analytics Engine.

/// A request out of how many is written down, by handler: one in ten
/// for the config, which every open app asks for each quarter of an
/// hour, and for the health, which the monitors ask for over and over;
/// every one of the rest, which are a person doing something.
const SAMPLED = { config: 10, health: 10 };

/// One line of numbers a request, for the operator (docs/explanation/service.md):
/// which handler, what it answered and how long it took — and
/// how many requests the line stands for, when only some are written.
/// Never a key, an address or anything else about who asked. Written to
/// the OH_METRICS dataset when the project binds one, and nowhere when
/// it does not.
export function measure(env, handler, status, ms, { random = Math.random } = {}) {
  const sink = env.OH_METRICS;
  if (!sink) return;
  const weight = SAMPLED[handler] ?? 1;
  if (weight > 1 && random() >= 1 / weight) return;
  try {
    sink.writeDataPoint({ indexes: [handler], blobs: [handler, String(status)], doubles: [ms, weight] });
  } catch {
    // What is watched never stops what is watched.
  }
}
