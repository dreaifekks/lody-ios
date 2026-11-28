import assert from 'node:assert/strict';
import test from 'node:test';
import { build } from 'esbuild';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { LoroDoc, LoroList, LoroMap } from 'loro-crdt/base64';
import { loadProject, openTestSession } from '../helpers.mjs';
import { editableUserTurn } from '../../../../packages/cloud-runtime/src/runtime/edit-session.ts';
import {
  resolveCanonicalAgentRoleRunConfig,
  roleRunConfigApplied,
} from '../../../../packages/cloud-runtime/src/protocol/agent-roles.ts';
import {
  fastModeFor,
  permissionModeFor,
  withPermissionMode,
} from '../../../../packages/cloud-runtime/src/protocol/capability.ts';

async function loadRoleRuntime() {
  const { outputFiles } = await build({
    stdin: {
      contents: `
        export { roleSnapshot } from './packages/cloud-runtime/src/runtime/role-settings.ts';
        export { bindTurnRole } from './packages/cloud-runtime/src/runtime/agent-roles.ts';
        export { creationOptions, readRoleTargetCapability } from './packages/cloud-runtime/src/runtime/create-session.ts';
      `,
      resolveDir: process.cwd(),
      loader: 'ts',
    },
    bundle: true,
    format: 'esm',
    platform: 'browser',
    write: false,
  });
  return import(
    `data:text/javascript;base64,${Buffer.from(outputFiles[0].text).toString('base64')}`
  );
}

function appendEntry(doc, value) {
  const history = doc.getList('history');
  const entry = history.pushContainer(new LoroMap());
  for (const [key, field] of Object.entries(value)) {
    if (key === 'items') {
      const items = entry.setContainer('items', new LoroList());
      for (const item of field) items.push(item);
    } else {
      entry.set(key, field);
    }
  }
  doc.commit();
}

test('projectSession hides session-rollover and board-maintenance assistant entries and passes rollover meta', async () => {
  const { projectSession, projectSessionFull } = await loadProject();
  const doc = new LoroDoc();
  appendEntry(doc, {
    id: 'u1',
    role: 'user',
    status: 'handled',
    finished: true,
    items: [{ type: 'text', text: 'First turn' }],
  });
  appendEntry(doc, {
    id: 'a1',
    role: 'assistant',
    userTurnId: 'u1',
    status: 'completed',
    finished: true,
    items: [{ type: 'text', text: 'First reply' }],
  });
  appendEntry(doc, {
    id: 'a-seal',
    role: 'assistant',
    userTurnId: 'session-rollover:run-1:seal',
    status: 'completed',
    finished: true,
    items: [{ type: 'text', text: 'Internal handoff card' }],
  });
  appendEntry(doc, {
    id: 'session-rollover:run-1',
    role: 'system',
    status: 'completed',
    finished: true,
    items: [
      {
        type: 'system_notice',
        name: 'session_context_rollover',
        meta: {
          kind: 'linear_rollover',
          trigger: 'manual',
          status: 'done',
          generation: 2,
          nodeId: 'node-2',
          usedBefore: 180000,
          usedAfter: 12500,
          reason: 'manual_command',
        },
      },
    ],
  });
  appendEntry(doc, {
    id: 'a-renew',
    role: 'assistant',
    userTurnId: 'session-rollover:run-1:renew',
    status: 'completed',
    finished: false,
    items: [{ type: 'text', text: 'Internal renew acknowledgement' }],
  });
  appendEntry(doc, {
    id: 'board-maintenance:m1',
    role: 'system',
    status: 'completed',
    finished: true,
    items: [
      {
        type: 'system_notice',
        name: 'board_context_maintenance',
        meta: {
          kind: 'fold_rollover',
          trigger: 'manual',
          status: 'done',
          usedBefore: 150000,
          usedAfter: 18000,
          nodeId: 'seg-3',
          foldedCount: 3,
          foldId: 'fold-1',
        },
      },
    ],
  });
  appendEntry(doc, {
    id: 'a-fold',
    role: 'assistant',
    userTurnId: 'board-maintenance:m1:fold',
    status: 'completed',
    finished: false,
    items: [{ type: 'text', text: 'Internal fold summary' }],
  });

  const projected = projectSession(doc, 'live');
  const full = projectSessionFull(doc, 'live');
  assert.deepEqual(
    projected.entries.map((entry) => entry.id),
    ['u1', 'a1', 'session-rollover:run-1', 'board-maintenance:m1'],
  );
  assert.deepEqual(
    full.entries.map((entry) => entry.id),
    projected.entries.map((entry) => entry.id),
  );
  assert.equal(projected.activeTurnId, 'a-fold');
  assert.equal(full.activeTurnId, 'a-fold');
  const rollover = projected.entries.find(
    (entry) => entry.id === 'session-rollover:run-1',
  );
  assert.deepEqual(rollover.items[0].meta, {
    reason: 'manual_command',
    code: undefined,
    message: undefined,
    kind: 'linear_rollover',
    trigger: 'manual',
    status: 'done',
    generation: 2,
    nodeId: 'node-2',
    usedBefore: 180000,
    usedAfter: 12500,
  });
  const fold = projected.entries.find(
    (entry) => entry.id === 'board-maintenance:m1',
  );
  assert.deepEqual(fold.items[0].meta, {
    reason: undefined,
    code: undefined,
    message: undefined,
    trigger: 'manual',
    status: 'done',
    kind: 'fold_rollover',
    usedBefore: 150000,
    usedAfter: 18000,
    nodeId: 'seg-3',
    foldedCount: 3,
    foldId: 'fold-1',
  });
});

test('hidden active maintenance turns remain stoppable and preserve context compaction usage', async () => {
  const { projectSession, projectSessionFull } = await loadProject();
  const cancels = [];
  const f = await openTestSession({
    onRpc(request) {
      cancels.push(request);
      return { result: { success: true } };
    },
  });
  try {
    appendEntry(f.server, {
      id: 'u1',
      role: 'user',
      status: 'handled',
      finished: true,
      items: [{ type: 'text', text: 'Work' }],
    });
    appendEntry(f.server, {
      id: 'a1',
      role: 'assistant',
      userTurnId: 'u1',
      status: 'completed',
      finished: true,
      items: [{ type: 'text', text: 'Done' }],
    });
    appendEntry(f.server, {
      id: 'a-compact',
      role: 'assistant',
      userTurnId: 'board-maintenance:m2:compact',
      status: 'in_progress',
      finished: false,
      items: [
        {
          type: 'tool_call',
          toolCallId: 'compact-1',
          activityKind: 'context_compaction',
          status: 'in_progress',
        },
      ],
    });
    await f.pushUpdate();

    const projected = projectSession(f.server, 'live');
    const full = projectSessionFull(f.server, 'live');
    assert.deepEqual(
      projected.entries.map((entry) => entry.id),
      ['u1', 'a1'],
      'Hidden maintenance reply must not enter visible transcript entries',
    );
    assert.equal(projected.activeTurnId, 'a-compact');
    assert.equal(full.activeTurnId, 'a-compact');
    assert.equal(projected.usage.isContextCompacting, true);
    assert.equal(full.usage.isContextCompacting, true);

    const stopped = await f.runtime.controlTurn({
      action: 'stop',
      sessionId: 's1',
      machineId: 'm1',
      turnId: projected.activeTurnId,
    });
    assert.equal(stopped.state, 'stopped');
    assert.equal(cancels[0].method, 'session/cancel');
    assert.equal(cancels[0].params.turnId, 'a-compact');

    const compactEntry = f.server.getList('history').get(2);
    compactEntry.set('finished', true);
    compactEntry.set('items', [
      {
        type: 'tool_call',
        toolCallId: 'compact-1',
        activityKind: 'context_compaction',
        status: 'completed',
      },
    ]);
    f.server.commit();
    const after = projectSession(f.server, 'live');
    assert.equal(after.activeTurnId, undefined);
    assert.equal(after.usage.isContextCompacting, false);
  } finally {
    f.close();
  }
});

test('editableUserTurn enforces linear rollover hard boundaries and skips hidden internal replies', () => {
  const meta = { isArchived: false, cliType: 'builtin', agentType: 'claude' };
  const cap = { provenance: 'runtime', sessionFork: true };
  const doneDivider = {
    id: 'session-rollover:r1',
    role: 'system',
    finished: true,
    items: [
      {
        type: 'system_notice',
        name: 'session_context_rollover',
        meta: { status: 'done', generation: 2 },
      },
    ],
  };
  const sealingDivider = {
    id: 'session-rollover:r1',
    role: 'system',
    finished: false,
    items: [
      {
        type: 'system_notice',
        name: 'session_context_rollover',
        meta: { status: 'sealing', generation: 2 },
      },
    ],
  };
  const sealAssistant = {
    id: 'a-seal',
    role: 'assistant',
    userTurnId: 'session-rollover:r1:seal',
    finished: true,
    acpTurnId: 'seal-acp',
  };
  const boardAssistant = {
    id: 'a-board',
    role: 'assistant',
    userTurnId: 'board-maintenance:m1:fold',
    finished: false,
  };

  // Old-node message cannot be edited after a completed rollover divider.
  assert.equal(
    editableUserTurn(
      [
        { id: 'u1', role: 'user', status: 'handled' },
        { id: 'a1', role: 'assistant', finished: true, acpTurnId: 'old-1' },
        sealAssistant,
        doneDivider,
      ],
      meta,
      cap,
    ),
    undefined,
  );

  // Scalar-only completed divider (without hydrated items) also blocks editing.
  assert.equal(
    editableUserTurn(
      [
        { id: 'u1', role: 'user', status: 'handled' },
        { id: 'session-rollover:r1', role: 'system', finished: true },
      ],
      meta,
      cap,
    ),
    undefined,
  );

  // Non-completed divider does not block editing; hidden :seal is skipped.
  assert.equal(
    editableUserTurn(
      [
        { id: 'u1', role: 'user', status: 'handled' },
        { id: 'a1', role: 'assistant', finished: true, acpTurnId: 'old-1' },
        sealAssistant,
        sealingDivider,
        { id: 'u2', role: 'user', status: 'handled' },
      ],
      meta,
      cap,
    )?.id,
    'u2',
  );

  // Unfinished board-maintenance assistant blocks editing (matches daemon resolveEditableTail).
  assert.equal(
    editableUserTurn(
      [
        { id: 'u1', role: 'user', status: 'handled' },
        { id: 'a1', role: 'assistant', finished: true, acpTurnId: 'old-1' },
        boardAssistant,
        { id: 'u2', role: 'user', status: 'handled' },
      ],
      meta,
      cap,
    ),
    undefined,
  );

  // Finished board-maintenance assistant without acpTurnId also blocks editing.
  assert.equal(
    editableUserTurn(
      [
        { id: 'u1', role: 'user', status: 'handled' },
        { id: 'a1', role: 'assistant', finished: true, acpTurnId: 'old-1' },
        {
          id: 'a-board-done',
          role: 'assistant',
          userTurnId: 'board-maintenance:m1:fold',
          finished: true,
        },
        { id: 'u2', role: 'user', status: 'handled' },
      ],
      meta,
      cap,
    ),
    undefined,
  );

  // First new-node user turn is editable when preceded by a finished :renew with acpTurnId.
  assert.equal(
    editableUserTurn(
      [
        { id: 'u1', role: 'user', status: 'handled' },
        { id: 'a1', role: 'assistant', finished: true, acpTurnId: 'old-1' },
        sealAssistant,
        doneDivider,
        {
          id: 'a-renew',
          role: 'assistant',
          userTurnId: 'session-rollover:r1:renew',
          finished: true,
          acpTurnId: 'renew-1',
        },
        { id: 'u2', role: 'user', status: 'handled' },
      ],
      meta,
      cap,
    )?.id,
    'u2',
  );

  // Unfinished or acpTurnId-less :renew cannot cross the divider to borrow old-node acpTurnId.
  assert.equal(
    editableUserTurn(
      [
        { id: 'u1', role: 'user', status: 'handled' },
        { id: 'a1', role: 'assistant', finished: true, acpTurnId: 'old-1' },
        sealAssistant,
        doneDivider,
        {
          id: 'a-renew',
          role: 'assistant',
          userTurnId: 'session-rollover:r1:renew',
          finished: true,
        },
        { id: 'u2', role: 'user', status: 'handled' },
      ],
      meta,
      cap,
    ),
    undefined,
  );

  // New-node user turn directly after a completed divider with no :renew is not editable.
  assert.equal(
    editableUserTurn(
      [
        { id: 'u1', role: 'user', status: 'handled' },
        { id: 'a1', role: 'assistant', finished: true, acpTurnId: 'old-1' },
        doneDivider,
        { id: 'u2', role: 'user', status: 'handled' },
      ],
      meta,
      cap,
    ),
    undefined,
  );
});

test('resolveCanonicalAgentRoleRunConfig aligns registry/custom vs builtin precedence and per-model mode options', () => {
  const registryCapability = {
    configOptions: [
      {
        id: 'model',
        category: 'model',
        type: 'select',
        currentValue: 'gemini-3',
      },
      { id: 'interaction_mode', category: 'mode', type: 'select' },
      { id: 'mode', category: 'mode', type: 'select' },
    ],
    observedModelConfigOptions: {
      'gemini-4-neon': [
        { id: 'interaction_mode', category: 'mode', type: 'select' },
        { id: 'permission_mode', category: 'mode', type: 'select' },
      ],
    },
  };

  // Registry/custom prefers configOptionValues over top-level and resolves target model before mode option.
  const registryResolved = resolveCanonicalAgentRoleRunConfig(
    {
      modelId: 'gemini-3',
      modeId: 'ask',
      configOptionValues: {
        model: 'gemini-4-neon',
        permission_mode: 'yolo',
        interaction_mode: 'chat',
      },
    },
    { cliType: 'registry', capability: registryCapability },
  );
  assert.deepEqual(registryResolved, {
    modeId: undefined,
    modelId: undefined,
    configOptionValues: {
      model: 'gemini-4-neon',
      permission_mode: 'yolo',
      interaction_mode: 'chat',
    },
    canonicalModeId: 'yolo',
    canonicalModelId: 'gemini-4-neon',
    modeOptionId: 'permission_mode',
    modelOptionId: 'model',
  });

  // Registry bridges top-level modeId/modelId into configOptionValues when option keys are absent.
  const registryBridged = resolveCanonicalAgentRoleRunConfig(
    { modelId: 'gemini-4-neon', modeId: 'yolo' },
    { cliType: 'custom', capability: registryCapability },
  );
  assert.deepEqual(registryBridged, {
    modeId: undefined,
    modelId: undefined,
    configOptionValues: {
      model: 'gemini-4-neon',
      permission_mode: 'yolo',
    },
    canonicalModeId: 'yolo',
    canonicalModelId: 'gemini-4-neon',
    modeOptionId: 'permission_mode',
    modelOptionId: 'model',
  });

  // Builtin prefers top-level over configOptionValues and strips shadowed duplicates.
  const builtinResolved = resolveCanonicalAgentRoleRunConfig(
    {
      modelId: 'opus',
      modeId: 'auto',
      configOptionValues: {
        model: 'sonnet',
        mode: 'default',
        plan_mode: false,
      },
    },
    { cliType: 'builtin', capability: registryCapability },
  );
  assert.deepEqual(builtinResolved, {
    modeId: 'auto',
    modelId: 'opus',
    configOptionValues: { plan_mode: false },
    canonicalModeId: 'auto',
    canonicalModelId: 'opus',
    modeOptionId: 'mode',
    modelOptionId: 'model',
  });

  // Matching accepts iOS top-level modelId + configOption mode for a registry Role.
  const target = { cliType: 'registry', capability: registryCapability };
  assert.equal(
    roleRunConfigApplied(
      {
        modelId: 'gemini-3',
        modeId: 'ask',
        configOptionValues: { model: 'gemini-4-neon', permission_mode: 'yolo' },
      },
      {
        modelId: 'gemini-4-neon',
        configOptionValues: { permission_mode: 'yolo' },
      },
      target,
    ),
    true,
  );
  assert.equal(
    roleRunConfigApplied(
      {
        modelId: 'gemini-3',
        modeId: 'ask',
        configOptionValues: { model: 'gemini-4-neon', permission_mode: 'yolo' },
      },
      {
        modelId: 'gemini-3',
        configOptionValues: { permission_mode: 'ask' },
      },
      target,
    ),
    false,
  );
});

test('roleSnapshot, bindTurnRole, creationOptions, and sendTurn preserve registry Roles across model switch and reopen', async () => {
  const {
    roleSnapshot,
    bindTurnRole,
    creationOptions,
    readRoleTargetCapability,
  } = await loadRoleRuntime();
  const meta = new Flock(`meta-${crypto.randomUUID()}`);
  meta.set(['m', 'machine-m1', 'name'], 'Mini');
  meta.commit();
  const machine = new Flock(`machine-${crypto.randomUUID()}`);
  machine.set(['agentConfig', 'agy'], {
    id: 'agy',
    machineId: 'm1',
    name: 'Antigravity',
    cliType: 'registry',
    agentType: 'antigravity',
  });
  machine.set(['acpCapability', 'agy'], {
    cliType: 'registry',
    agentType: 'antigravity',
    fetchedAt: 10,
    configOptions: [
      {
        id: 'model',
        name: 'Model',
        type: 'select',
        category: 'model',
        currentValue: 'gemini-3',
        options: [
          { value: 'gemini-3', name: 'Gemini 3' },
          { value: 'gemini-4-neon', name: 'Gemini 4 Neon' },
        ],
      },
      {
        id: 'interaction_mode',
        name: 'Interaction',
        type: 'select',
        category: 'mode',
        currentValue: 'code',
        options: [{ value: 'code', name: 'Code' }],
      },
      {
        id: 'mode',
        name: 'Permission',
        type: 'select',
        category: 'mode',
        currentValue: 'ask',
        options: [
          { value: 'ask', name: 'Ask' },
          { value: 'yolo', name: 'YOLO' },
        ],
      },
    ],
  });
  machine.set(['acpModelConfigOptionsShape', 'agy', 'shape-neon'], {
    version: 1,
    configOptions: [
      {
        id: 'interaction_mode',
        name: 'Interaction',
        type: 'select',
        category: 'mode',
        currentValue: 'code',
        options: [{ value: 'code', name: 'Code' }],
      },
      {
        id: 'permission_mode',
        name: 'Permission',
        type: 'select',
        category: 'mode',
        currentValue: 'ask',
        options: [
          { value: 'ask', name: 'Ask' },
          { value: 'yolo', name: 'YOLO' },
        ],
      },
    ],
  });
  machine.set(['acpModelConfigOptions', 'agy', 'gemini-4-neon'], {
    version: 1,
    sourceVersion: '1',
    shape: 'shape-neon',
  });
  machine.commit();

  const storedRole = {
    v: 1,
    id: 'agy-yolo',
    ownerUserId: 'u1',
    visibility: 'private',
    name: 'Agy YOLO',
    promptPrefix: 'Ship carefully.',
    machineId: 'm1',
    agentConfigId: 'agy',
    runConfig: {
      modelId: 'gemini-4-neon',
      modeId: 'yolo',
    },
    revision: 1,
    createdAt: 1,
    updatedAt: 1,
  };
  const workspace = new Flock(`ws-${crypto.randomUUID()}`);
  workspace.set(['agentRole', 'agy-yolo'], storedRole);
  workspace.commit();

  const options = creationOptions(undefined, meta, new Map([['m1', machine]]));
  const uiCapability = options.capabilities[0];
  assert.ok(uiCapability.observedModelConfigOptions?.['gemini-4-neon']);
  const neonPermission = permissionModeFor(uiCapability, {
    modelId: 'gemini-4-neon',
    configOptionValues: { mode: 'ask', permission_mode: 'yolo' },
  });
  assert.equal(neonPermission?.configId, 'permission_mode');
  assert.equal(neonPermission?.value, 'yolo');
  const toggledToAsk = withPermissionMode(
    uiCapability,
    {
      modelId: 'gemini-4-neon',
      configOptionValues: { mode: 'ask', permission_mode: 'yolo' },
    },
    'ask',
  );
  assert.equal(toggledToAsk.configOptionValues?.permission_mode, 'ask');
  assert.equal(permissionModeFor(uiCapability, toggledToAsk)?.value, 'ask');

  const capability = readRoleTargetCapability(machine, 'agy');
  const snapshot = roleSnapshot(
    workspace,
    'u1',
    meta,
    new Map([['m1', machine]]),
  );
  assert.deepEqual(snapshot.roles[0].targets[0].runConfig, {
    configOptionValues: {
      model: 'gemini-4-neon',
      permission_mode: 'yolo',
    },
  });

  const bound = bindTurnRole(storedRole, {
    roleId: 'agy-yolo',
    userId: 'u1',
    machineId: 'm1',
    agentConfigId: 'agy',
    target: { cliType: 'registry', capability },
  });
  assert.deepEqual(bound.runConfig, {
    configOptionValues: {
      model: 'gemini-4-neon',
      permission_mode: 'yolo',
    },
  });

  const calls = [];
  const f = await openTestSession({
    settings: () => workspace.exportFile(),
    onRpc(request) {
      calls.push(request);
      return { result: { accepted: true } };
    },
  });
  const finishTurn = async (id) => {
    appendEntry(f.server, {
      id,
      role: 'assistant',
      finished: true,
      items: [],
    });
    await f.pushUpdate();
  };
  try {
    // Turn 1 ran with Model A (`gemini-3`) in configOptionValues (registry representation).
    appendEntry(f.server, {
      id: 'u-prev',
      role: 'user',
      status: 'handled',
      finished: true,
      inputConfig: {
        cliType: 'registry',
        agentType: 'antigravity',
        configOptionValues: { model: 'gemini-3', mode: 'ask' },
      },
      items: [{ type: 'text', text: 'Previous turn' }],
    });
    await finishTurn('a-prev');

    // Turn 2 switches to Registry Role pinning Model B (`gemini-4-neon`) via top-level modelId.
    const sent = await f.runtime.sendTurn({
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      cliType: 'registry',
      agentType: 'antigravity',
      text: 'Run checks',
      agentRoleId: 'agy-yolo',
      agentConfigId: 'agy',
      roleCapability: capability,
      modelId: 'gemini-4-neon',
      configOptionValues: { permission_mode: 'yolo' },
    });
    assert.equal(sent.state, 'accepted');
    const dispatched = calls[0].params.inputConfig;
    assert.equal(dispatched.agentRoleId, 'agy-yolo');
    assert.equal(dispatched.modelId, undefined);
    assert.equal(dispatched.modeId, undefined);
    assert.equal(dispatched.configOptionValues.model, 'gemini-4-neon');
    assert.equal(dispatched.configOptionValues.permission_mode, 'yolo');

    // Reopen projection lifts canonical model from configOptionValues so Swift preserves the Role.
    await finishTurn('a-role');
    const reopened = f.runtime.projectSession(f.server, 'live');
    assert.equal(reopened.composer.modelId, 'gemini-4-neon');
    assert.equal(reopened.composer.agentRoleId, 'agy-yolo');
    assert.equal(reopened.composer.configOptionValues.permission_mode, 'yolo');
    assert.equal('model' in reopened.composer.configOptionValues, false);

    // Next turn using reopened composer state retains the Role when inheriting or explicit.
    const followUp = await f.runtime.sendTurn({
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      cliType: 'registry',
      agentType: 'antigravity',
      text: 'Follow-up after reopen',
      agentConfigId: 'agy',
      roleCapability: capability,
      modelId: reopened.composer.modelId,
      configOptionValues: reopened.composer.configOptionValues,
    });
    assert.equal(followUp.state, 'accepted');
    assert.equal(calls[1].params.inputConfig.agentRoleId, 'agy-yolo');
    assert.equal(
      calls[1].params.inputConfig.configOptionValues.model,
      'gemini-4-neon',
    );

    // Explicitly switching model away detaches the inherited Role.
    await finishTurn('a-follow');
    const drifted = await f.runtime.sendTurn({
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      cliType: 'registry',
      agentType: 'antigravity',
      text: 'Switch back to Gemini 3',
      agentConfigId: 'agy',
      roleCapability: capability,
      modelId: 'gemini-3',
      configOptionValues: { mode: 'ask' },
    });
    assert.equal(drifted.state, 'accepted');
    assert.equal(calls[2].params.inputConfig.agentRoleId, null);
    assert.equal(
      calls[2].params.inputConfig.configOptionValues.model,
      'gemini-3',
    );
  } finally {
    f.close();
  }
});

test('Antigravity with non-empty legacyModes, configOptions.mode, and thought_level=xhigh preserves Role across reopen and edits mode canonically', async () => {
  const { creationOptions, readRoleTargetCapability, roleSnapshot } =
    await loadRoleRuntime();
  const meta = new Flock(`meta-${crypto.randomUUID()}`);
  meta.set(['m', 'machine-m1', 'name'], 'Mini');
  meta.commit();
  const machine = new Flock(`machine-${crypto.randomUUID()}`);
  machine.set(['agentConfig', 'agy'], {
    id: 'agy',
    machineId: 'm1',
    name: 'Antigravity',
    cliType: 'registry',
    agentType: 'antigravity',
  });
  machine.set(['acpCapability', 'agy'], {
    cliType: 'registry',
    agentType: 'antigravity',
    fetchedAt: 10,
    modes: [
      { id: 'ask', name: 'Ask' },
      { id: 'auto', name: 'Auto' },
      { id: 'yolo', name: 'YOLO' },
    ],
    configOptions: [
      {
        id: 'model',
        name: 'Model',
        type: 'select',
        category: 'model',
        currentValue: 'gemini-4-neon',
        options: [{ value: 'gemini-4-neon', name: 'Gemini 4 Neon' }],
      },
      {
        id: 'interaction_mode',
        name: 'Interaction',
        type: 'select',
        category: 'mode',
        currentValue: 'code',
        options: [{ value: 'code', name: 'Code' }],
      },
      {
        id: 'mode',
        name: 'Permission',
        type: 'select',
        category: 'mode',
        currentValue: 'ask',
        options: [
          { value: 'ask', name: 'Ask' },
          { value: 'auto', name: 'Auto' },
          { value: 'yolo', name: 'YOLO' },
        ],
      },
      {
        id: 'thought_level',
        name: 'Reasoning',
        type: 'select',
        category: 'thought_level',
        currentValue: 'high',
        options: [
          { value: 'high', name: 'High' },
          { value: 'xhigh', name: 'XHigh' },
        ],
      },
    ],
  });
  machine.commit();

  const options = creationOptions(undefined, meta, new Map([['m1', machine]]));
  const uiCapability = options.capabilities[0];
  assert.equal(uiCapability.reasoningEffortConfigId, 'thought_level');
  assert.equal(uiCapability.legacyModes?.length, 3);

  // Even when legacyModes is non-empty, registry Antigravity reads and writes configOptions.mode.
  const roleChoice = {
    modelId: 'gemini-4-neon',
    modeId: 'ask',
    configOptionValues: { mode: 'yolo' },
  };
  const perm = permissionModeFor(uiCapability, roleChoice);
  assert.equal(perm?.configId, 'mode');
  assert.equal(perm?.value, 'yolo');
  const edited = withPermissionMode(uiCapability, roleChoice, 'auto');
  assert.equal(edited.configOptionValues?.mode, 'auto');
  assert.equal(edited.modeId, undefined);

  const storedRole = {
    v: 2,
    id: 'agy-xhigh',
    ownerUserId: 'u1',
    visibility: 'private',
    name: 'Neon XHigh',
    promptPrefix: 'Ship cleanly.',
    revision: 1,
    createdAt: 100,
    updatedAt: 100,
    targets: [
      {
        id: 't1',
        machineId: 'm1',
        agentConfigId: 'agy',
        runConfig: {
          configOptionValues: {
            model: 'gemini-4-neon',
            mode: 'yolo',
            thought_level: 'xhigh',
          },
        },
      },
    ],
  };
  const workspace = new Flock(`ws-${crypto.randomUUID()}`);
  workspace.set(['agentRole', 'agy-xhigh'], storedRole);
  workspace.commit();
  const snapshot = roleSnapshot(
    workspace,
    'u1',
    meta,
    new Map([['m1', machine]]),
  );
  assert.deepEqual(snapshot.roles[0].targets[0].runConfig, {
    configOptionValues: {
      model: 'gemini-4-neon',
      mode: 'yolo',
      thought_level: 'xhigh',
    },
  });

  const capability = readRoleTargetCapability(machine, 'agy');
  const calls = [];
  const f = await openTestSession({
    settings: () => workspace.exportFile(),
    onRpc(request) {
      calls.push(request);
      return { result: { accepted: true } };
    },
  });
  const finishTurn = async (id) => {
    appendEntry(f.server, {
      id,
      role: 'assistant',
      finished: true,
      items: [],
    });
    await f.pushUpdate();
  };
  try {
    // Turn 1: send with Antigravity Role pinning thought_level=xhigh + mode=yolo.
    const first = await f.runtime.sendTurn({
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      cliType: 'registry',
      agentType: 'antigravity',
      text: 'Start with xhigh role',
      agentConfigId: 'agy',
      agentRoleId: 'agy-xhigh',
      roleCapability: capability,
      modelId: 'gemini-4-neon',
      reasoningEffort: 'xhigh',
      reasoningEffortConfigId: 'thought_level',
      configOptionValues: { mode: 'yolo' },
    });
    assert.equal(first.state, 'accepted');
    assert.deepEqual(calls[0].params.inputConfig.configOptionValues, {
      model: 'gemini-4-neon',
      mode: 'yolo',
      thought_level: 'xhigh',
    });
    assert.equal(calls[0].params.inputConfig.agentRoleId, 'agy-xhigh');

    // Reopen projection lifts thought_level into composer.effort and strips it from configOptionValues.
    await finishTurn('a-1');
    const reopened = f.runtime.projectSession(f.server, 'live');
    assert.equal(reopened.composer.modelId, 'gemini-4-neon');
    assert.equal(reopened.composer.effort, 'xhigh');
    assert.equal(reopened.composer.agentRoleId, 'agy-xhigh');
    assert.deepEqual(reopened.composer.configOptionValues, { mode: 'yolo' });

    // Turn 2: follow-up after reopen keeps Role and thought_level=xhigh.
    const followUp = await f.runtime.sendTurn({
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      cliType: 'registry',
      agentType: 'antigravity',
      text: 'Continue after reopen',
      agentConfigId: 'agy',
      agentRoleId: 'agy-xhigh',
      roleCapability: capability,
      modelId: reopened.composer.modelId,
      reasoningEffort: reopened.composer.effort,
      reasoningEffortConfigId: 'thought_level',
      configOptionValues: reopened.composer.configOptionValues,
    });
    assert.equal(followUp.state, 'accepted');
    assert.equal(calls[1].params.inputConfig.agentRoleId, 'agy-xhigh');
    assert.deepEqual(calls[1].params.inputConfig.configOptionValues, {
      model: 'gemini-4-neon',
      mode: 'yolo',
      thought_level: 'xhigh',
    });

    // Turn 3: user changes permission in panel from yolo to auto — sends auto (never stale yolo) and preserves thought_level=xhigh.
    await finishTurn('a-2');
    const switchedMode = await f.runtime.sendTurn({
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      cliType: 'registry',
      agentType: 'antigravity',
      text: 'Switch to auto mode',
      agentConfigId: 'agy',
      agentRoleId: null,
      roleCapability: capability,
      modelId: 'gemini-4-neon',
      reasoningEffort: 'xhigh',
      reasoningEffortConfigId: 'thought_level',
      configOptionValues: { mode: 'auto' },
    });
    assert.equal(switchedMode.state, 'accepted');
    assert.equal(calls[2].params.inputConfig.agentRoleId, null);
    assert.equal(calls[2].params.inputConfig.modeId, undefined);
    assert.deepEqual(calls[2].params.inputConfig.configOptionValues, {
      model: 'gemini-4-neon',
      mode: 'auto',
      thought_level: 'xhigh',
    });
  } finally {
    f.close();
  }

  // Declared fastMode: true stays available even when observedModelConfigOptions omits fast-mode.
  const codexCap = {
    machineId: 'm1',
    cliType: 'builtin',
    agentType: 'codex',
    models: [
      { id: 'gpt-5.3', name: 'GPT-5.3' },
      { id: 'gpt-5.4', name: 'GPT-5.4' },
    ],
    modes: [],
    reasoningEfforts: {},
    fastModes: { 'gpt-5.3': false, 'gpt-5.4': true },
    configOptions: [
      {
        id: 'model',
        name: 'Model',
        category: 'model',
        type: 'select',
        currentValue: 'gpt-5.3',
        options: [
          { id: 'gpt-5.3', name: 'GPT-5.3' },
          { id: 'gpt-5.4', name: 'GPT-5.4' },
        ],
      },
      {
        id: 'fast-mode',
        name: 'Fast',
        type: 'boolean',
        currentValue: false,
        options: [],
      },
    ],
    observedModelConfigOptions: {
      'gpt-5.4': [],
    },
    steer: true,
  };
  assert.equal(fastModeFor(codexCap, { modelId: 'gpt-5.3' }), undefined);
  assert.deepEqual(fastModeFor(codexCap, { modelId: 'gpt-5.4' }), {
    id: 'fast-mode',
    enabled: false,
  });
});
