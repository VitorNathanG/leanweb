import http from 'node:http';

http.createServer({ requestTimeout: 5000 }, (request, response) => {
  response.sendDate = false;
  response.setHeader('Connection', 'close');
  if (request.method === 'GET' && request.url === '/health') {
    const body = '{"status":"ok"}';
    response.writeHead(200, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': Buffer.byteLength(body),
    });
    response.end(body);
  } else if (request.method === 'POST' && request.url === '/echo') {
    const chunks = [];
    let size = 0;
    request.on('data', chunk => {
      size += chunk.length;
      if (size > 65536) request.destroy();
      else chunks.push(chunk);
    });
    request.on('end', () => {
      const body = Buffer.concat(chunks);
      response.writeHead(200, {
        'Content-Type': 'text/plain; charset=utf-8',
        'Content-Length': body.length,
      });
      response.end(body);
    });
  } else {
    response.writeHead(404, { 'Content-Length': 0 });
    response.end();
  }
}).listen(8080, '127.0.0.1');
