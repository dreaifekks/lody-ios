import assert from 'node:assert/strict';
import test from 'node:test';
import { relativeTime } from '../../src/ui/time.ts';
import {
  agentName,
  sessionState,
  stateSubtitle,
  stateSymbol,
  stateTint,
} from '../../src/features/sessions/status.ts';
import { setLocale } from '../../src/lib/i18n/index.ts';
import { accent } from '../../src/lib/theme/tokens.ts';

setLocale('zh-Hans');

const ACCENT = accent.light;
// Calendar boundaries use local time; construct wall-clock fixtures in that same zone.
const now = new Date(2026, 8, 6, 15).getTime();
const at = (hour, minute = 0, second = 0, day = 6) =>
  relativeTime(new Date(2026, 8, day, hour, minute, second).getTime(), now);

test('relative time degrades from minutes to a calendar date', () => {
  assert.equal(at(14, 59, 30), '刚刚');
  assert.equal(at(14, 57), '3 分钟前');
  assert.equal(at(11), '4 小时前');
  assert.equal(at(23, 0, 0, 5), '昨天');
  assert.equal(at(10, 0, 0, 2), '9月2日');
  assert.equal(relativeTime('not a date', now), '');
});

test('archived overrides the backend status', () => {
  assert.equal(sessionState('running', true), 'archived');
  assert.equal(sessionState('running'), 'live');
  assert.equal(sessionState('anything-unknown'), 'idle');
});

test('server status types and the awaiting flag map to list states', () => {
  assert.equal(sessionState('requestPermission'), 'attention');
  assert.equal(sessionState('initializing'), 'live');
  assert.equal(sessionState('idle', false, true), 'attention');
  assert.equal(sessionState('running', false, true), 'live');
  assert.equal(relativeTime(now - 3 * 60_000, now), '3 分钟前');
  assert.equal(agentName('claude'), 'Claude Code');
  assert.equal(agentName('custom-agent'), 'custom-agent');
});

test('accent carries only the live state', () => {
  assert.equal(stateTint('live', ACCENT), ACCENT);
  for (const state of ['attention', 'failed', 'idle', 'done', 'archived']) {
    assert.notEqual(stateTint(state, ACCENT), ACCENT);
  }
});

test('every state has a distinct symbol, not just a distinct color', () => {
  const symbols = Object.values(stateSymbol);
  assert.equal(new Set(symbols).size, symbols.length);
});

test('completed rows drop the state word, the checkmark already says it', () => {
  assert.equal(stateSubtitle('done', 'lody-ios', '昨天'), 'lody-ios · 昨天');
  assert.equal(
    stateSubtitle('attention', 'lody-ios', '刚刚'),
    '等待确认 · lody-ios · 刚刚',
  );
  assert.equal(stateSubtitle('live', 'lody-ios', ''), '进行中 · lody-ios');
});
