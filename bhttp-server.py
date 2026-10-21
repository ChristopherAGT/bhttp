#!/usr/bin/env python3
# Servidor BHTTP autonomo para DTunnel (version asyncio).
# Mismo protocolo binario que la app.
#
# Trama peticion : mode(1) sessionId(16) seq(8 BE) len(4 BE) + payload enmascarado
# Trama respuesta: status(1) len(4 BE) + payload enmascarado
# Mascara        : XOR con SHA256(sessionId||mode||seq||dir||contador)
# Modos          : 0=probe 1=subida 2=bajada 3=lote 4=ack

import argparse
import asyncio
import hashlib
import sys

MAGIC = b"BHP1"
LONGPOLL = 2.0


def log(msg):
    sys.stderr.write("[bhttp] %s\n" % msg)
    sys.stderr.flush()


def keystream(sess, mode, seq, d, n):
    base = hashlib.sha256(
        sess + bytes([mode]) + seq.to_bytes(8, "big") + bytes([d])
    )
    out = bytearray()
    c = 0

    while len(out) < n:
        h = base.copy()
        h.update(c.to_bytes(4, "big"))
        out += h.digest()
        c += 1

    return bytes(out[:n])


def mask(data, sess, mode, seq, d):
    stream = keystream(sess, mode, seq, d, len(data))
    return bytes(a ^ b for a, b in zip(data, stream))


def probe_reply(mode, size):
    n = size if (mode == 2 and size >= 10) else 10
    out = bytearray(MAGIC + bytes([1, mode]) + size.to_bytes(4, "big"))

    for i in range(10, n):
        out.append((i * 31) & 255)

    return bytes(out)


class Session:
    """Tunel logico que conecta BHTTP con el backend SSH."""

    def __init__(self, sess, backend):
        self.sess = sess
        self.backend = backend
        self.cond = asyncio.Condition()
        self.up_next = 0
        self.up_pending = {}
        self.down_raw = bytearray()
        self.down_chunks = {}
        self.down_assign = 0
        self.eof = False
        self.closed = False
        self.br = None
        self.bw = None

    async def connect(self):
        host, port = self.backend
        self.br, self.bw = await asyncio.open_connection(host, port)
        log(
            "sesion %s: conectada al backend %s:%d"
            % (self.sess.hex()[:8], host, port)
        )
        asyncio.create_task(self._reader())

    async def _reader(self):
        total = 0

        try:
            while True:
                data = await self.br.read(65536)

                if not data:
                    break

                total += len(data)

                async with self.cond:
                    self.down_raw += data
                    self.cond.notify_all()

        except Exception as e:
            log(
                "sesion %s: error leyendo del backend: %s"
                % (self.sess.hex()[:8], e)
            )

        finally:
            log(
                "sesion %s: el backend cerro (recibidos %d B en bajada)"
                % (self.sess.hex()[:8], total)
            )

            async with self.cond:
                self.eof = True
                self.cond.notify_all()

    async def upload(self, seq, data):
        async with self.cond:
            if data:
                self.up_pending[seq] = data

            while self.up_next in self.up_pending:
                chunk = self.up_pending.pop(self.up_next)

                try:
                    self.bw.write(chunk)
                    await self.bw.drain()
                except Exception:
                    self.closed = True

                self.up_next += 1

    async def download(self, seq, maxlen, deadline):
        if maxlen <= 0:
            maxlen = 1399

        loop = asyncio.get_running_loop()

        async with self.cond:
            while True:
                if seq < self.down_assign:
                    return self.down_chunks.get(seq, b"")

                if seq == self.down_assign:
                    if self.down_raw:
                        take = bytes(self.down_raw[:maxlen])
                        del self.down_raw[:maxlen]

                        self.down_chunks[self.down_assign] = take
                        self.down_assign += 1
                        self.cond.notify_all()

                        return take

                    if self.eof:
                        self.down_assign += 1
                        self.cond.notify_all()
                        return b""

                if not self.eof and loop.time() < deadline:
                    try:
                        await asyncio.wait_for(
                            self.cond.wait(),
                            timeout=max(0.01, deadline - loop.time())
                        )
                    except asyncio.TimeoutError:
                        pass

                    continue

                while self.down_assign <= seq:
                    self.down_assign += 1

                self.cond.notify_all()
                return b""

    async def ack(self, seq):
        async with self.cond:
            for k in [k for k in self.down_chunks if k <= seq]:
                del self.down_chunks[k]

    async def close(self):
        async with self.cond:
            self.closed = True
            self.cond.notify_all()

        try:
            self.bw.close()
        except Exception:
            pass


class Server:
    def __init__(self, host, port, backend):
        self.host = host
        self.port = port
        self.backend = backend
        self.sessions = {}
        self.slock = asyncio.Lock()

    async def get_session(self, sess):
        async with self.slock:
            s = self.sessions.get(sess)

            if s is None or s.closed:
                for old_sid, old in list(self.sessions.items()):
                    if old_sid != sess:
                        await old.close()
                        del self.sessions[old_sid]

                s = Session(sess, self.backend)
                await s.connect()
                self.sessions[sess] = s

                log(
                    "sesion %s: registrada (sesiones vivas: %d)"
                    % (sess.hex()[:8], len(self.sessions))
                )

            return s

    async def handle(self, reader, writer):
        try:
            while True:
                hdr = await reader.readexactly(29)

                mode = hdr[0]
                sess = hdr[1:17]
                seq = int.from_bytes(hdr[17:25], "big")
                ln = int.from_bytes(hdr[25:29], "big")

                payload = b""

                if ln and mode in (0, 1, 2, 3):
                    raw = await reader.readexactly(ln)
                    payload = mask(raw, sess, mode, seq, 0)

                if payload[:4] == MAGIC:
                    size = (
                        int.from_bytes(payload[6:10], "big")
                        if len(payload) >= 10 else 0
                    )
                    pmode = payload[5] if len(payload) >= 6 else mode

                    body = mask(
                        probe_reply(pmode, size),
                        sess, mode, seq, 1
                    )

                    writer.write(
                        bytes([0]) + len(body).to_bytes(4, "big") + body
                    )
                    await writer.drain()
                    continue

                s = await self.get_session(sess)

                if mode == 1:
                    await s.upload(seq, payload)

                    writer.write(bytes([0]) + (0).to_bytes(4, "big"))
                    await writer.drain()

                elif mode == 2:
                    chunk = await s.download(
                        seq,
                        ln if ln > 0 else 1399,
                        asyncio.get_running_loop().time() + LONGPOLL
                    )

                    self._send_data(writer, sess, mode, seq, chunk)
                    await writer.drain()

                elif mode == 3:
                    if len(payload) >= 6:
                        chunk_size = int.from_bytes(payload[0:4], "big")
                        count = payload[5]
                    else:
                        chunk_size, count = 1399, 1

                    if chunk_size <= 0:
                        chunk_size = 1399

                    if count <= 0:
                        count = 1

                    deadline = (
                        asyncio.get_running_loop().time() + LONGPOLL
                    )

                    for i in range(count):
                        chunk = await s.download(
                            seq + i, chunk_size, deadline
                        )
                        self._send_data(
                            writer, sess, mode, seq + i, chunk
                        )

                    await writer.drain()

                elif mode == 4:
                    await s.ack(seq)

                    writer.write(bytes([0]) + (0).to_bytes(4, "big"))
                    await writer.drain()

                else:
                    return

        except (
            asyncio.IncompleteReadError,
            ConnectionError,
            OSError
        ):
            pass

        except Exception as e:
            log("handle: excepcion inesperada: %r" % e)

        finally:
            try:
                writer.close()
            except Exception:
                pass

    def _send_data(self, writer, sess, mode, seq, data):
        real = len(data)
        masked = mask(data, sess, mode, seq, 1) if data else b""

        body = real.to_bytes(4, "big") + masked

        writer.write(
            bytes([2]) + len(body).to_bytes(4, "big") + body
        )

    async def serve(self):
        srv = await asyncio.start_server(
            self.handle,
            self.host,
            self.port,
            backlog=512
        )

        print(
            "BHTTP escuchando en %s:%d -> backend %s:%d"
            % (
                self.host,
                self.port,
                self.backend[0],
                self.backend[1]
            ),
            flush=True
        )

        async with srv:
            await srv.serve_forever()


def main():
    ap = argparse.ArgumentParser()

    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--backend-host", default="127.0.0.1")
    ap.add_argument("--backend-port", type=int, default=22)

    a = ap.parse_args()

    asyncio.run(
        Server(
            a.host,
            a.port,
            (a.backend_host, a.backend_port)
        ).serve()
    )


if __name__ == "__main__":
    main()
    
