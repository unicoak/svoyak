const MIN_ONE_WAY_MS = 5;
const MAX_ONE_WAY_MS = 250;
const FUTURE_GUARD_MS = 20;
const JITTER_GUARD_MS = 40;

export interface EffectivePressParams {
  recvServerMs: number;
  pressClientMs: number;
  offsetMs: number;
  rttMs: number;
}

export const clamp = (value: number, min: number, max: number): number =>
  Math.max(min, Math.min(max, value));

export const computeEffectivePressMs = ({
  recvServerMs,
  pressClientMs,
  offsetMs,
  rttMs,
}: EffectivePressParams): number => {
  const oneWayMs = clamp(Math.round(rttMs / 2), MIN_ONE_WAY_MS, MAX_ONE_WAY_MS);
  const projectedServerPressMs = pressClientMs + offsetMs;
  const lowerBound = recvServerMs - oneWayMs - JITTER_GUARD_MS;
  const upperBound = recvServerMs + FUTURE_GUARD_MS;

  return clamp(projectedServerPressMs, lowerBound, upperBound);
};

export interface NetSample {
  offsetMs: number;
  rttMs: number;
  previousRttMs: number;
}

export const updateJitter = (sample: NetSample): number =>
  Math.abs(sample.rttMs - sample.previousRttMs);
