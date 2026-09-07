import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
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

test('LeanWeb over real TCP', { timeout: 30000 }, async t => {
  const port = await availablePort();
  const server = spawn(`${root}.lake/build/bin/leanweb`, [String(port)], {
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
    await exited;
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
