import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import net from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));

async function availablePort() {
  const listener = net.createServer();
  await new Promise((resolve, reject) => {
    listener.once('error', reject);
    listener.listen(0, '127.0.0.1', resolve);
  });
  const port = listener.address().port;
  await new Promise((resolve, reject) => listener.close(error => error ? reject(error) : resolve()));
  return port;
}

function exchange(port, chunks, { endInput = false, fragmentDelay = 0 } = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port });
    const received = [];
    socket.setTimeout(5000, () => socket.destroy(new Error('Socket test timed out')));
    socket.on('data', data => received.push(data));
    socket.on('error', reject);
    socket.on('end', () => resolve(Buffer.concat(received)));
    socket.on('connect', async () => {
      try {
        for (const chunk of chunks) {
          socket.write(chunk);
          if (fragmentDelay) await delay(fragmentDelay);
        }
        if (endInput) socket.end();
      } catch (error) {
        socket.destroy(error);
      }
    });
  });
}

function request(method, path, body = '', headers = '') {
  return Buffer.from(`${method} ${path} HTTP/1.1\r\nHost: localhost\r\n` +
    `Content-Length: ${Buffer.byteLength(body)}\r\n${headers}\r\n${body}`);
}

function response(bytes, { head = false } = {}) {
  const boundary = bytes.indexOf('\r\n\r\n');
  assert.notEqual(boundary, -1, 'complete response headers');
  const lines = bytes.subarray(0, boundary).toString().split('\r\n');
  const status = Number(lines.shift().split(' ')[1]);
  const headers = Object.fromEntries(lines.map(line => {
    const colon = line.indexOf(':');
    return [line.slice(0, colon).toLowerCase(), line.slice(colon + 1).trim()];
  }));
  const body = bytes.subarray(boundary + 4);
  assert.equal(headers.connection, 'close');
  assert.equal(body.length, head ? 0 : Number(headers['content-length']));
  return { status, headers, body: body.toString() };
}

async function startServer(t, binary = 'leanweb') {
  const port = await availablePort();
  const server = spawn(`${root}.lake/build/bin/${binary}`, [String(port)], {
    cwd: root, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  let spawnError;
  server.stdout.on('data', data => { output += data; });
  server.stderr.on('data', data => { output += data; });
  server.on('error', error => { spawnError = error; });
  t.after(async () => {
    if (server.exitCode !== null || server.signalCode !== null || spawnError) return;
    const exited = new Promise(resolve => server.once('exit', resolve));
    server.kill('SIGTERM');
    const force = setTimeout(() => server.kill('SIGKILL'), 1000);
    try { await exited; } finally { clearTimeout(force); }
  });
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    if (spawnError) throw spawnError;
    assert.equal(server.exitCode, null, output);
    try {
      const result = response(await exchange(port, [request('GET', '/health')]));
      assert.equal(result.status, 200);
      ready = true;
      break;
    } catch (error) {
      if (error.code !== 'ECONNREFUSED') throw error;
      await delay(25);
    }
  }
  assert.ok(ready, `server did not become ready: ${output}`);
  return { port, output: () => output };
}

test('LeanWeb over real TCP', { timeout: 30000 }, async t => {
  const { port } = await startServer(t);

  await t.test('health, query separation, and injected greeting', async () => {
    const health = response(await exchange(port, [request('GET', '/health?check=1')]));
    assert.equal(health.status, 200);
    assert.equal(health.headers['content-type'], 'application/json; charset=utf-8');
    assert.deepEqual(JSON.parse(health.body), { status: 'ok' });
    const greeting = response(await exchange(port, [request('GET', '/')]));
    assert.match(greeting.body, /LeanWeb/);
  });

  await t.test('fragmented UTF-8 request with byte-based lengths', async () => {
    const body = 'hello \u03bb\ud83d\ude80\r\n\u0000';
    const bytes = request('POST', '/echo', body);
    const split = bytes.indexOf(Buffer.from('\u03bb')) + 1;
    const result = response(await exchange(port,
      [bytes.subarray(0, 7), bytes.subarray(7, split), bytes.subarray(split)],
      { fragmentDelay: 10 }));
    assert.equal(result.status, 200);
    assert.equal(result.body, body);
  });

  await t.test('HEAD retains length but omits body', async () => {
    const result = response(await exchange(port, [request('HEAD', '/health')]), { head: true });
    assert.equal(result.status, 200);
    assert.equal(Number(result.headers['content-length']), Buffer.byteLength('{"status":"ok"}'));
    const missing = response(await exchange(port, [request('HEAD', '/missing')]), { head: true });
    assert.equal(missing.status, 404);
  });

  await t.test('typed body and query decoding reaches the verified controller', async () => {
    for (const [body, by, quotient, remainder] of [
      ['17', '5', 3, 2], ['00017', '0005', 3, 2], ['0', '1', 0, 0],
      ['1', '2', 0, 1], ['1000000', '1', 1000000, 0], ['1000000', '1000000', 1, 0],
    ]) {
      const result = response(await exchange(port, [request('POST', `/divide?by=${by}`, body)]));
      assert.equal(result.status, 200);
      assert.equal(result.headers['content-type'], 'application/json; charset=utf-8');
      assert.deepEqual(JSON.parse(result.body), { quotient, remainder });
      assert.equal(Number(by) * quotient + remainder, Number(body));
      assert.ok(remainder < Number(by));
    }
  });

  await t.test('typed decoding rejects malformed, ambiguous, and out-of-range input', async () => {
    for (const [body, query] of [
      ['17', ''], ['17', 'by=0'], ['1000001', 'by=1'], ['17', 'by=1000001'],
      ['', 'by=5'], ['-17', 'by=5'], ['17\n', 'by=5'], ['1.7', 'by=5'],
      ['\u0661', 'by=5'], ['123456789012345678901', 'by=5'],
      ['17', 'by=5&by=5'], ['17', 'by=5&by=0'], ['17', 'by'],
      ['17', 'by=5&broken'], ['17', 'by=%35'], ['17', '%62y=5'],
      ['1_7', 'by=5'], ['17', 'by=1_0'], ['_17', 'by=5'], ['17_', 'by=5'],
    ]) {
      const result = response(await exchange(port, [request('POST', `/divide?${query}`, body)]));
      assert.equal(result.status, 400, `${body} / ${query}`);
    }
    const missing = response(await exchange(port, [request('POST', '/divide', '17')]));
    assert.equal(missing.body, 'Missing field: by\n');
    const duplicate = response(await exchange(port, [request('POST', '/divide?by=5&by=5', '17')]));
    assert.equal(duplicate.body, 'Duplicate field: by\n');
  });

  await t.test('method and raw path must match exactly', async () => {
    for (const [method, path] of [['GET', '/missing'], ['POST', '/health'],
      ['GET', '/echo'], ['GET', '/health/'], ['GET', '/%68ealth']]) {
      assert.equal(response(await exchange(port, [request(method, path)])).status, 404);
    }
  });

  await t.test('malformed and ambiguous request framing is rejected', async () => {
    for (const input of [
      'GET / HTTP/1.1\r\n\r\n',
      'GET / HTTP/1.1\nHost: a\n\n',
      'GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n',
      'POST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n',
      'POST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n',
      'GET /#fragment HTTP/1.1\r\nHost: a\r\n\r\n',
    ]) {
      assert.equal(response(await exchange(port, [input])).status, 400);
    }
  });

  await t.test('unsupported features fail without waiting for a body', async () => {
    for (const header of ['Transfer-Encoding: chunked', 'Expect: 100-continue']) {
      const input = `POST /echo HTTP/1.1\r\nHost: a\r\n${header}\r\n\r\n`;
      assert.equal(response(await exchange(port, [input])).status, 501);
    }
    assert.equal(response(await exchange(port,
      ['TRACE / HTTP/1.1\r\nHost: a\r\n\r\n'])).status, 501);
  });

  await t.test('premature EOF and invalid UTF-8 are rejected', async () => {
    const incomplete = 'POST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: 4\r\n\r\nab';
    assert.equal(response(await exchange(port, [incomplete], { endInput: true })).status, 400);
    const invalid = Buffer.concat([
      Buffer.from('POST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\n\r\n'),
      Buffer.from([255]),
    ]);
    assert.equal(response(await exchange(port, [invalid])).status, 400);
  });

  await t.test('wire and application limits are enforced', async () => {
    const input = 'POST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: 1048576\r\n\r\n';
    assert.equal(response(await exchange(port, [input])).status, 413);
    assert.equal(response(await exchange(port, [request('POST', '/echo', 'x'.repeat(65537))])).status, 413);
    const body = 'x'.repeat(65536);
    assert.equal(response(await exchange(port, [request('POST', '/echo', body)])).body, body);
  });

  await t.test('server remains usable after rejected requests', async () => {
    assert.equal(response(await exchange(port, [request('GET', '/health')])).status, 200);
  });
});

// Unlike exchange, this observes silent close/reset as well as HTTP responses.
async function connection(t, port) {
  const socket = net.createConnection({ host: '127.0.0.1', port });
  const chunks = [];
  let error;
  socket.on('data', chunk => chunks.push(chunk));
  socket.on('error', value => { error = value; });
  socket.setTimeout(3000, () => socket.destroy(new Error('Connection did not close')));
  const done = new Promise(resolve => socket.once('close', () =>
    resolve({ bytes: Buffer.concat(chunks), error })));
  t.after(async () => { socket.destroy(); await done; });
  await once(socket, 'connect');
  return { socket, done };
}

function silentClose(result) {
  assert.equal(result.bytes.length, 0, 'timeout sends no HTTP response');
  assert.ok(!result.error || result.error.code === 'ECONNRESET', String(result.error));
}

test('bounded connections and absolute read deadlines', { timeout: 30000 }, async t => {
  const { port, output } = await startServer(t, 'leanweb_transport_tests');
  const get = async path => response(await exchange(port, [request('GET', path)]));
  const effects = async () => Number((await get('/effects')).body);

  await t.test('silent peers and incomplete headers/bodies do not block healthy clients', async t => {
    for (const partial of ['', 'GET /touch HTTP/1.1\r\nHost: local',
      'POST /touch HTTP/1.1\r\nHost: local\r\nContent-Length: 4\r\n\r\nab']) {
      const before = await effects();
      const slow = await connection(t, port);
      const start = performance.now();
      slow.socket.write(partial);
      assert.equal((await get('/health')).status, 200);
      assert.ok(!slow.socket.destroyed, 'healthy request finishes before the slow peer expires');
      silentClose(await slow.done);
      assert.ok(performance.now() - start < 1500, 'server deadline, not the 3s harness timeout');
      assert.equal(await effects(), before, 'expired request never reaches handler');
    }
  });

  await t.test('dripped bytes do not refresh the total request deadline', async t => {
    const before = await effects();
    const slow = await connection(t, port);
    slow.socket.write('POST /touch HTTP/1.1\r\nHost: local\r\nContent-Length: 100\r\n\r\n');
    const start = performance.now();
    const drip = setInterval(() => { if (!slow.socket.destroyed) slow.socket.write('x'); }, 40);
    try { silentClose(await slow.done); } finally { clearInterval(drip); }
    assert.ok(performance.now() - start < 700, 'continuous progress cannot extend the 200ms deadline');
    assert.equal(await effects(), before);
  });

  await t.test('full capacity backpressures acceptance, then reuses expired slots', async t => {
    for (let repeat = 0; repeat < 3; repeat++) {
      const first = await connection(t, port);
      const second = await connection(t, port);
      let completed = false;
      const queued = get('/health').then(value => { completed = true; return value; });
      await delay(60);
      assert.equal(completed, false, 'no third worker while both slots are occupied');
      silentClose(await first.done);
      silentClose(await second.done);
      assert.equal((await queued).status, 200, 'queued complete request gets a fresh accepted deadline');
    }
  });

  await t.test('completed reads cancel timers; handlers retain capacity until they finish', async () => {
    const before = await effects();
    for (let i = 0; i < 20; i++) assert.equal((await get('/touch')).status, 200);
    await delay(250);
    assert.equal(await effects(), before + 20);
    const first = get('/slow-handler');
    const second = get('/slow-handler');
    for (let attempt = 0; attempt < 50 && (output().match(/slow-handler-start/g) ?? []).length < 2;
      attempt++) await delay(5);
    assert.equal((output().match(/slow-handler-start/g) ?? []).length, 2, 'both handlers admitted');
    let completed = false;
    const queued = get('/health').then(value => { completed = true; return value; });
    await delay(300);
    assert.equal(completed, false, 'read deadline does not release live handler slots');
    assert.equal((await first).body, 'finished');
    assert.equal((await second).body, 'finished');
    assert.equal((await queued).status, 200);
    assert.equal(await effects(), before + 22);
  });

  await t.test('completion versus deadline races select at most one handler', async t => {
    const before = await effects();
    let successes = 0;
    let expired = 0;
    for (let i = 0; i < 24; i++) {
      const client = await connection(t, port);
      client.socket.write('GET /touch HTTP/1.1\r\nHost: local\r\n');
      const send = setTimeout(() => {
        if (!client.socket.destroyed) client.socket.write('\r\n');
      }, [0, 190, 200, 220][i % 4]);
      let result;
      try { result = await client.done; } finally { clearTimeout(send); }
      if (result.bytes.length) {
        assert.equal(response(result.bytes).status, 200);
        successes++;
      } else { silentClose(result); expired++; }
    }
    assert.ok(successes > 0 && expired > 0, 'exercise both terminal outcomes');
    assert.equal(await effects(), before + successes);
  });

  await t.test('EOF, resets, and handler errors release capacity', async t => {
    for (let i = 0; i < 20; i++) {
      const client = await connection(t, port);
      client.socket.write('POST /touch HTTP/1.1\r\nHost: local\r\nContent-Length: 4\r\n\r\nab');
      if (i % 2) {
        client.socket.end();
        assert.equal(response((await client.done).bytes).status, 400);
      } else { client.socket.resetAndDestroy(); await client.done; }
      const failure = await get('/throw');
      assert.equal(failure.status, 500);
      assert.equal(failure.body, 'Internal server error\n');
      assert.equal((await get('/health')).status, 200);
    }
  });

  await t.test('EOF and malformed completion race the same silent deadline', async t => {
    const before = await effects();
    for (const eof of [true, false]) {
      for (const ms of [0, 190, 200, 220]) {
        const client = await connection(t, port);
        client.socket.write('GET /touch HTTP/1.1\r\nHost: local\r\n');
        const finish = setTimeout(() => {
          if (!client.socket.destroyed) {
            if (eof) client.socket.end();
            else client.socket.write('malformed\r\n\r\n');
          }
        }, ms);
        let result;
        try { result = await client.done; } finally { clearTimeout(finish); }
        if (result.bytes.length) assert.equal(response(result.bytes).status, 400);
        else silentClose(result);
        if (ms === 0) assert.ok(result.bytes.length > 0, 'ordinary rejection still returns 400');
        if (ms === 220) silentClose(result);
      }
    }
    assert.equal(await effects(), before);
  });

  await t.test('stalled writes keep their slots until disconnect, without abandoned workers', async t => {
    const readers = [];
    for (let i = 0; i < 2; i++) {
      const client = await connection(t, port);
      // Wait for response data to confirm admission and sending, then stop consuming it.
      client.socket.once('data', () => client.socket.pause());
      const started = once(client.socket, 'data');
      client.socket.write(request('GET', '/large'));
      await started;
      readers.push(client);
    }
    let completed = false;
    const queued = get('/health').then(value => { completed = true; return value; });
    await delay(300);
    assert.equal(completed, false, 'pending sends still occupy both slots beyond read deadline');
    for (const client of readers) { client.socket.resetAndDestroy(); await client.done; }
    assert.equal((await queued).status, 200, 'disconnect completes sends and restores capacity');
  });

  await t.test('descriptor counts recover after repeated timeout/reset/success batches', {
    skip: process.platform !== 'linux',
  }, async t => {
    const baseline = Number((await get('/fds')).body);
    assert.ok(Number.isInteger(baseline) && baseline > 0, 'self-process FD measurement available');
    for (let batch = 0; batch < 3; batch++) {
      for (let i = 0; i < 10; i++) {
        const client = await connection(t, port);
        if (i % 2) { client.socket.resetAndDestroy(); await client.done; }
        else silentClose(await client.done);
        assert.equal((await get('/health')).status, 200);
      }
      let current;
      for (let attempt = 0; attempt < 20; attempt++) {
        current = Number((await get('/fds')).body);
        if (current <= baseline) break;
        await delay(25);
      }
      assert.ok(current <= baseline, `FDs return to baseline: ${current} <= ${baseline}`);
      t.diagnostic(`batch=${batch + 1} baseline_fds=${baseline} current_fds=${current}`);
    }
  });
});
