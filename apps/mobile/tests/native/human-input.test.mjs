import assert from 'node:assert/strict';
import test from 'node:test';
import { LoroDoc, LoroMap } from 'loro-crdt/base64';
import { openTestSession } from '../helpers.mjs';

const args = {
  sessionId: 's1',
  machineId: 'm1',
  userId: 'local:hub',
  cliType: 'builtin',
  agentType: 'codex',
  text: 'Human reply',
};
const id = '11111111-1111-4111-8111-111111111111';

for (const kind of ['first', 'queue', 'guide', 'continue']) {
  test(`${kind}: receipt and human input reach the hub together, before activation`, async () => {
    const stages = [];
    const fixture = await openTestSession({
      onAppend({ url, part, producer }) {
        if (url.includes(':rpc:')) return;
        assert.ok(
          producer?.producerId,
          'the append is deduplicated by its producer tuple',
        );
        const candidate = new LoroDoc();
        candidate.import(fixture.server.export({ mode: 'snapshot' }));
        candidate.import(part.body.subarray(4));
        const receipt = candidate.getMap('humanInputReceipts').get(id);
        assert.ok(receipt instanceof LoroMap, 'the receipt value is a LoroMap');
        assert.equal(receipt.get('userId'), args.userId);
        const raw = candidate.toJSON();
        const turn =
          kind === 'queue'
            ? raw.mq[0]
            : raw.history.find((row) => row.id === id);
        assert.equal(turn.userId, receipt.get('userId'));
        assert.equal(turn.userTurnId ?? turn.id, id);
        stages.push('receipt+turn');
      },
      markDispatch(_sessionId, turnId) {
        assert.equal(turnId, id);
        assert.deepEqual(fixture.server.toJSON().humanInputReceipts[id], {
          userId: args.userId,
        });
        stages.push('pointer');
      },
      onRpc(request) {
        assert.deepEqual(fixture.server.toJSON().humanInputReceipts[id], {
          userId: request.params.userId,
        });
        stages.push('rpc');
        return {
          result: {
            accepted: true,
            applied: false,
            disposition: 'no-active-turn',
          },
        };
      },
    });
    try {
      if (kind === 'guide') {
        fixture.server
          .getList('history')
          .push({ id: 'reply', role: 'assistant', finished: false, items: [] });
        await fixture.pushUpdate();
      }
      const result = await fixture.runtime.sendTurn({
        ...args,
        id,
        queue: kind === 'queue',
        guide: kind === 'guide',
        ...(kind === 'continue' ? { deliveryKind: 'continue' } : {}),
      });
      assert.equal(
        result.state,
        {
          first: 'accepted',
          queue: 'queued',
          guide: 'uploaded',
          continue: 'accepted',
        }[kind],
      );
      if (kind === 'guide')
        await new Promise((resolve) => setImmediate(resolve));
      const expected = {
        first: ['receipt+turn', 'pointer', 'rpc'],
        queue: ['receipt+turn', 'pointer'],
        guide: ['receipt+turn', 'rpc'],
        continue: ['receipt+turn', 'pointer', 'rpc'],
      };
      assert.deepEqual(stages, expected[kind]);
      assert.deepEqual(
        fixture.runtime.sessionDoc('s1').toJSON().humanInputReceipts,
        { [id]: { userId: args.userId } },
      );
      const count = fixture.appends.length;
      assert.equal(
        (await fixture.runtime.sendTurn({ ...args, id })).state,
        'unknown',
      );
      assert.equal(
        fixture.appends.length,
        count,
        'the same turn is not appended again',
      );
    } finally {
      fixture.close();
    }
  });
}

test('dispatch inputOrigin is sent only to machines advertising Operation Inbox', async () => {
  for (const capabilities of [
    undefined,
    {},
    { operationInbox: 0 },
    { operationInbox: 1 },
    { operationInbox: 2 },
  ]) {
    const requests = [];
    const fixture = await openTestSession({
      onRpc(request) {
        requests.push(request);
        return { result: { accepted: true } };
      },
    });
    try {
      assert.equal(
        (await fixture.runtime.sendTurn(args, undefined, capabilities)).state,
        'accepted',
      );
      const params = requests[0].params;
      assert.equal(requests[0].method, 'session/dispatch-turn');
      assert.equal(
        Object.hasOwn(params, 'inputOrigin'),
        (capabilities?.operationInbox ?? 0) >= 1,
      );
      if (capabilities?.operationInbox)
        assert.equal(params.inputOrigin, 'human');
      assert.deepEqual(
        fixture.server.toJSON().humanInputReceipts[params.userTurnId],
        { userId: params.userId },
      );
    } finally {
      fixture.close();
    }
  }
});

test('rejected and lost-ACK appends discard the replica and never write a second turn', async () => {
  for (const lostAck of [false, true]) {
    const id = crypto.randomUUID();
    const fixture = await openTestSession({
      failAppend: () => !lostAck,
      loseAck: () => lostAck,
      markDispatch: () => assert.fail('no pointer without a confirmed append'),
    });
    try {
      const before = fixture.runtime.sessionDoc('s1');
      assert.equal(
        (await fixture.runtime.sendTurn({ ...args, id })).state,
        'unknown',
      );
      assert.notEqual(
        fixture.runtime.sessionDoc('s1'),
        before,
        'the unconfirmed replica is discarded',
      );
      await fixture.runtime.ensureSession(
        's1',
        'w1',
        async () => ({
          token: 'synthetic',
          gatewayBaseUrl: 'https://x.invalid',
        }),
        () => {},
        async () => {},
      );
      const raw = fixture.runtime.sessionDoc('s1').toJSON();
      assert.equal(Boolean(raw.humanInputReceipts?.[id]), lostAck);
      assert.equal(raw.history?.length ?? 0, lostAck ? 1 : 0);
      const count = fixture.appends.length;
      assert.equal(
        (await fixture.runtime.sendTurn({ ...args, id })).state,
        'unknown',
      );
      assert.equal(fixture.appends.length, count);
    } finally {
      fixture.close();
    }
  }
});

test('agent forwards and imported history never acquire human receipts on sync or confirmation', async () => {
  const fixture = await openTestSession();
  try {
    fixture.server.getList('history').push({
      id,
      role: 'user',
      userId: args.userId,
      author: { v: 1, kind: 'agent', sessionId: 'sender' },
      status: 'pending',
      items: [],
    });
    await fixture.pushUpdate();
    await fixture.runtime.confirmTurn({ sessionId: 's1', id });
    assert.deepEqual(
      fixture.runtime.sessionDoc('s1').getMap('humanInputReceipts').toJSON(),
      {},
    );
    assert.equal(fixture.server.toJSON().humanInputReceipts, undefined);
    assert.equal(fixture.appends.length, 0);
  } finally {
    fixture.close();
  }
});

for (const failure of ['rejected', 'lost-ack', 'thrown']) {
  test(`edit-and-resend recovers a ${failure} receipt append before its machine-owned history write`, async () => {
    let fail = true;
    const requests = [];
    const fixture = await openTestSession({
      failAppend: (url) =>
        fail && failure === 'rejected' && !url.includes(':rpc:'),
      loseAck: (url) =>
        fail && failure === 'lost-ack' && !url.includes(':rpc:'),
      onAppend({ url }) {
        if (fail && failure === 'thrown' && !url.includes(':rpc:'))
          throw new Error('connection_lost');
      },
      onRpc(request) {
        requests.push(request);
        assert.equal(request.method, 'session/edit-and-resend');
        const raw = fixture.server.toJSON();
        assert.deepEqual(raw.humanInputReceipts, {
          [id]: { userId: request.params.requestedByUserId },
        });
        assert.equal(
          raw.history[0].id,
          'original',
          'the client does not replace history',
        );
        return { result: { success: true } };
      },
    });
    try {
      fixture.server.getList('history').push({
        id: 'original',
        role: 'user',
        status: 'completed',
        items: [],
        inputConfig: {},
      });
      await fixture.pushUpdate();
      const edit = {
        ...args,
        action: 'send',
        expectedUserTurnId: 'original',
        id,
        retainedIds: [],
      };
      const meta = { machineId: 'm1', cliType: 'builtin', agentType: 'codex' };
      const before = fixture.runtime.sessionDoc('s1');
      assert.equal(
        (await fixture.runtime.editSession(edit, meta)).state,
        'not_sent',
      );
      assert.notEqual(
        fixture.runtime.sessionDoc('s1'),
        before,
        'a refused receipt discards the replica',
      );
      await fixture.runtime.ensureSession(
        's1',
        'w1',
        async () => ({
          token: 'synthetic',
          gatewayBaseUrl: 'https://x.invalid',
        }),
        () => {},
        async () => {},
      );
      assert.deepEqual(
        fixture.runtime.sessionDoc('s1').getMap('humanInputReceipts').toJSON(),
        failure === 'lost-ack' ? { [id]: { userId: args.userId } } : {},
        'only the hub copy can restore the receipt after an unconfirmed append',
      );
      assert.equal(
        requests.length,
        0,
        'a failed receipt upload cannot activate replacement history',
      );
      fail = false;
      assert.equal(
        (await fixture.runtime.editSession(edit, meta)).state,
        'accepted',
      );
      const receipts = fixture.appends.filter(
        (url) => !url.includes(':rpc:'),
      ).length;
      assert.equal(
        (await fixture.runtime.editSession(edit, meta)).state,
        'accepted',
      );
      assert.equal(
        fixture.appends.filter((url) => !url.includes(':rpc:')).length,
        receipts,
        'repeating an acknowledged replacement does not write another receipt',
      );
    } finally {
      fixture.close();
    }
  });
}
