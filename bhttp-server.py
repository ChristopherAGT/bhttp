#!/usr/bin/env python3
# Servidor BHTTP autonomo para DTunnel (version asyncio).
# Basado en el protocolo binario original.
#
# Trama peticion : mode(1) sessionId(16) seq(8 BE) len(4 BE) + payload
# Trama respuesta: status(1) len(4 BE) + payload enmascarado
# Mascara        : XOR con SHA256(sessionId||mode||seq||dir||contador)
# Modos          : 0=probe 1=subida 2=bajada 3=lote 4=ack

import argparse
import asyncio
import hashlib
import sys
import time

MAGIC = b"BHP1"
LONGPOLL = 2.0

MAX_FRAME_SIZE = 16 * 1024 * 1024
MAX_DOWN_BUFFER = 8 * 1024 * 1024
MAX_UNACKED_BYTES = 8 * 1024 * 1024
MAX_UNACKED_CHUNKS = 4096
MAX_PENDING_UPLOADS = 4096
MAX_PENDING_UPLOAD_BYTES = 32 * 1024 * 1024
MAX_SESSIONS = 1024

CONNECT_TIMEOUT = 8.0
WRITE_TIMEOUT = 15.0
UPLOAD_WAIT_TIMEOUT = 30.0
CLEANUP_INTERVAL = 60.0
CLOSED_RETENTION = 120.0


def log(msg):
    sys.stderr.write("[bhttp] %s\n" % msg)
    sys.stderr.flush()


def keystream(sess, mode, seq, d, n):
    base = hashlib.sha256(
        sess + bytes([mode]) + seq.to_bytes(8, "big") + bytes([d])
    )
    out = bytearray()
    counter = 0

    while len(out) < n:
        h = base.copy()
        h.update(counter.to_bytes(4, "big"))
        out.extend(h.digest())
        counter += 1

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
    """Tunel logico independiente hacia un backend SSH."""

    def __init__(self, sess, backend):
        self.sess = sess
        self.backend = backend

        self.cond = asyncio.Condition()

        # Cola de subida: seq -> (datos, Future).
        self.up_next = 0
        self.up_pending = {}
        self.up_pending_bytes = 0

        # Cola de descarga.
        self.down_raw = bytearray()
        self.down_chunks = {}
        self.down_unacked_bytes = 0
        self.down_assign = 0

        self.eof = False
        self.closed = False
        self.close_reason = ""
        self.closed_at = None
        self.last_activity = time.monotonic()

        self.br = None
        self.bw = None
        self.reader_task = None
        self.writer_task = None

    async def connect(self):
        host, port = self.backend

        self.br, self.bw = await asyncio.wait_for(
            asyncio.open_connection(host, port),
            timeout=CONNECT_TIMEOUT
        )

        log(
            "sesion %s: conectada al backend %s:%d"
            % (self.sess.hex()[:8], host, port)
        )

        self.reader_task = asyncio.create_task(self._reader())
        self.writer_task = asyncio.create_task(self._writer())

    async def _reader(self):
        total = 0

        try:
            while True:
                async with self.cond:
                    while (
                        len(self.down_raw) >= MAX_DOWN_BUFFER
                        and not self.closed
                    ):
                        await self.cond.wait()

                    if self.closed:
                        break

                    capacity = MAX_DOWN_BUFFER - len(self.down_raw)
                    read_size = min(65536, capacity)

                data = await self.br.read(read_size)

                if not data:
                    break

                async with self.cond:
                    if self.closed:
                        break

                    self.down_raw.extend(data)
                    total += len(data)
                    self.last_activity = time.monotonic()
                    self.cond.notify_all()

        except asyncio.CancelledError:
            raise

        except Exception as e:
            log(
                "sesion %s: error leyendo backend: %s"
                % (self.sess.hex()[:8], e)
            )

        finally:
            async with self.cond:
                self.eof = True
                self.cond.notify_all()

            log(
                "sesion %s: backend finalizado (%d B recibidos)"
                % (self.sess.hex()[:8], total)
            )

    async def _writer(self):
        """Un unico escritor mantiene el orden de subida."""

        try:
            while True:
                async with self.cond:
                    while True:
                        if self.closed:
                            return

                        item = self.up_pending.get(self.up_next)

                        if item is not None:
                            seq = self.up_next
                            data, future = item
                            break

                        if self.eof:
                            pending = list(self.up_pending.values())
                            self.up_pending.clear()
                            self.up_pending_bytes = 0

                            for _, fut in pending:
                                if not fut.done():
                                    fut.set_exception(
                                        ConnectionError(
                                            "backend SSH cerrado"
                                        )
                                    )

                            self.cond.notify_all()
                            return

                        await self.cond.wait()

                self.bw.write(data)

                await asyncio.wait_for(
                    self.bw.drain(),
                    timeout=WRITE_TIMEOUT
                )

                async with self.cond:
                    item = self.up_pending.get(seq)

                    if item is None or seq != self.up_next:
                        continue

                    saved_data, saved_future = item

                    del self.up_pending[seq]
                    self.up_pending_bytes -= len(saved_data)
                    self.up_pending_bytes = max(
                        0, self.up_pending_bytes
                    )

                    self.up_next += 1
                    self.last_activity = time.monotonic()

                    if not saved_future.done():
                        saved_future.set_result(True)

                    self.cond.notify_all()

        except asyncio.CancelledError:
            raise

        except Exception as e:
            log(
                "sesion %s: error escribiendo backend: %s"
                % (self.sess.hex()[:8], e)
            )
            await self.close("error de escritura backend")

    async def upload(self, seq, data):
        if len(data) > MAX_FRAME_SIZE:
            raise BufferError("trama de subida demasiado grande")

        async with self.cond:
            if self.closed or self.eof or self.bw is None:
                raise ConnectionError("backend SSH cerrado")

            self.last_activity = time.monotonic()

            # Retransmision de una subida ya procesada.
            if seq < self.up_next:
                return

            item = self.up_pending.get(seq)

            if item is not None:
                old_data, future = item

                if old_data != data:
                    raise ValueError(
                        "secuencia repetida con datos diferentes"
                    )
            else:
                if len(self.up_pending) >= MAX_PENDING_UPLOADS:
                    raise BufferError("demasiadas subidas pendientes")

                if (
                    self.up_pending_bytes + len(data)
                    > MAX_PENDING_UPLOAD_BYTES
                ):
                    raise BufferError(
                        "limite de subida pendiente alcanzado"
                    )

                future = asyncio.get_running_loop().create_future()

                self.up_pending[seq] = (data, future)
                self.up_pending_bytes += len(data)
                self.cond.notify_all()

        # No confirmar hasta que el escritor complete drain().
        # El timeout no cancela la escritura que ya esta en cola.
        await asyncio.wait_for(
            asyncio.shield(future),
            timeout=UPLOAD_WAIT_TIMEOUT
        )

    async def download(self, seq, maxlen, deadline):
        if maxlen <= 0:
            maxlen = 1399

        maxlen = min(maxlen, MAX_FRAME_SIZE)
        loop = asyncio.get_running_loop()

        async with self.cond:
            while True:
                self.last_activity = time.monotonic()

                if seq < self.down_assign:
                    return self.down_chunks.get(seq, b"")

                if self.closed and not self.down_raw:
                    return b""

                if seq == self.down_assign:
                    can_assign = (
                        len(self.down_chunks) < MAX_UNACKED_CHUNKS
                    )

                    available = (
                        MAX_UNACKED_BYTES - self.down_unacked_bytes
                    )

                    if self.down_raw and can_assign and available > 0:
                        amount = min(
                            maxlen,
                            len(self.down_raw),
                            available
                        )

                        chunk = bytes(self.down_raw[:amount])
                        del self.down_raw[:amount]

                        self.down_chunks[seq] = chunk
                        self.down_unacked_bytes += len(chunk)
                        self.down_assign += 1

                        self.cond.notify_all()
                        return chunk

                    if self.eof and not self.down_raw:
                        if can_assign:
                            self.down_chunks[seq] = b""
                            self.down_assign += 1
                            self.cond.notify_all()

                        return b""

                remaining = deadline - loop.time()

                if remaining <= 0 or self.closed:
                    # No avanzar la secuencia solo por un timeout.
                    return b""

                try:
                    await asyncio.wait_for(
                        self.cond.wait(),
                        timeout=remaining
                    )
                except asyncio.TimeoutError:
                    pass

    async def ack(self, seq):
        async with self.cond:
            removed = [
                k for k in self.down_chunks
                if k <= seq
            ]

            for k in removed:
                chunk = self.down_chunks.pop(k)
                self.down_unacked_bytes -= len(chunk)

            self.down_unacked_bytes = max(
                0, self.down_unacked_bytes
            )

            self.last_activity = time.monotonic()
            self.cond.notify_all()

    async def close(self, reason="cierre solicitado"):
        async with self.cond:
            if not self.closed:
                self.closed = True
                self.close_reason = reason
                self.closed_at = time.monotonic()

            self.eof = True

            pending = list(self.up_pending.values())
            self.up_pending.clear()
            self.up_pending_bytes = 0

            for _, future in pending:
                if not future.done():
                    future.set_exception(
                        ConnectionError("sesion backend cerrada")
                    )

            self.cond.notify_all()

        if self.bw is not None:
            try:
                self.bw.close()
                await self.bw.wait_closed()
            except Exception:
                pass

        current = asyncio.current_task()
        tasks = (self.reader_task, self.writer_task)

        for task in tasks:
            if task is not None and task is not current and not task.done():
                task.cancel()

        for task in tasks:
            if task is None or task is current:
                continue

            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass


class Server:
    def __init__(self, host, port, backend):
        self.host = host
        self.port = port
        self.backend = backend

        self.sessions = {}
        self.slock = asyncio.Lock()
        self.cleanup_task = None

    async def get_session(self, sess):
        async with self.slock:
            s = self.sessions.get(sess)

            if s is not None and not s.closed:
                return s

            if s is not None:
                del self.sessions[sess]

            now = time.monotonic()

            for old_sid, old in list(self.sessions.items()):
                if (
                    old.closed
                    and old.closed_at is not None
                    and now - old.closed_at >= CLOSED_RETENTION
                ):
                    del self.sessions[old_sid]

            if len(self.sessions) >= MAX_SESSIONS:
                raise ConnectionError("limite de sesiones alcanzado")

            s = Session(sess, self.backend)

            try:
                await s.connect()
            except Exception:
                await s.close("fallo de conexion")
                raise

            self.sessions[sess] = s

            log(
                "sesion %s: registrada (sesiones: %d)"
                % (sess.hex()[:8], len(self.sessions))
            )

            return s

    async def get_existing_session(self, sess):
        async with self.slock:
            return self.sessions.get(sess)

    async def cleanup(self):
        while True:
            await asyncio.sleep(CLEANUP_INTERVAL)
            now = time.monotonic()
            expired = []

            async with self.slock:
                for sid, s in list(self.sessions.items()):
                    if (
                        s.closed
                        and s.closed_at is not None
                        and now - s.closed_at >= CLOSED_RETENTION
                    ):
                        del self.sessions[sid]
                        expired.append(s)

            if expired:
                await asyncio.gather(
                    *(s.close("limpieza") for s in expired),
                    return_exceptions=True
                )

    async def handle(self, reader, writer):
        peer = writer.get_extra_info("peername")
        sess = None

        try:
            while True:
                hdr = await reader.readexactly(29)

                mode = hdr[0]
                sess = hdr[1:17]
                seq = int.from_bytes(hdr[17:25], "big")
                ln = int.from_bytes(hdr[25:29], "big")

                if mode not in (0, 1, 2, 3, 4):
                    log("modo invalido desde %s: %d" % (peer, mode))
                    break

                if ln > MAX_FRAME_SIZE:
                    log("trama demasiado grande desde %s: %d" % (peer, ln))
                    break

                payload = b""

                if ln and mode in (0, 1, 2, 3):
                    raw = await reader.readexactly(ln)
                    payload = mask(raw, sess, mode, seq, 0)

                elif ln and mode == 4:
                    log("ACK con payload no admitido desde %s" % (peer,))
                    break

                # Probe BHP1: no abre una sesion SSH.
                if payload[:4] == MAGIC:
                    size = (
                        int.from_bytes(payload[6:10], "big")
                        if len(payload) >= 10 else 0
                    )
                    pmode = payload[5] if len(payload) >= 6 else mode

                    if size > MAX_FRAME_SIZE:
                        log("probe solicita tamano excesivo")
                        break

                    body = mask(
                        probe_reply(pmode, size),
                        sess, mode, seq, 1
                    )

                    writer.write(
                        bytes([0]) + len(body).to_bytes(4, "big") + body
                    )
                    await writer.drain()
                    continue

                if mode == 0:
                    writer.write(bytes([0]) + (0).to_bytes(4, "big"))
                    await writer.drain()
                    continue

                # ACK no debe crear un backend nuevo.
                if mode == 4:
                    s = await self.get_existing_session(sess)

                    if s is not None:
                        await s.ack(seq)

                    writer.write(bytes([0]) + (0).to_bytes(4, "big"))
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

                    chunk_size = min(chunk_size, MAX_FRAME_SIZE)
                    count = max(1, count)

                    if seq + count - 1 > (1 << 64) - 1:
                        log("secuencia de lote fuera de rango")
                        break

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

        except asyncio.IncompleteReadError:
            pass

        except asyncio.CancelledError:
            raise

        except (
            ConnectionError,
            BrokenPipeError,
            OSError,
            asyncio.TimeoutError,
            BufferError,
            ValueError
        ) as e:
            log("conexion %s: %s" % (peer, e))

        except Exception as e:
            log("handle %s: excepcion inesperada: %r" % (peer, e))

        finally:
            try:
                writer.close()
                await writer.wait_closed()
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

        self.cleanup_task = asyncio.create_task(self.cleanup())

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

        try:
            async with srv:
                await srv.serve_forever()

        finally:
            self.cleanup_task.cancel()

            try:
                await self.cleanup_task
            except asyncio.CancelledError:
                pass

            async with self.slock:
                sessions = list(self.sessions.values())
                self.sessions.clear()

            await asyncio.gather(
                *(s.close("apagado del servidor") for s in sessions),
                return_exceptions=True
            )


def main():
    ap = argparse.ArgumentParser(
        description="Servidor BHTTP asyncio para DTunnel"
    )

    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--backend-host", default="127.0.0.1")
    ap.add_argument("--backend-port", type=int, default=22)

    a = ap.parse_args()

    if not 1 <= a.port <= 65535:
        ap.error("--port debe estar entre 1 y 65535")

    if not 1 <= a.backend_port <= 65535:
        ap.error("--backend-port debe estar entre 1 y 65535")

    try:
        asyncio.run(
            Server(
                a.host,
                a.port,
                (a.backend_host, a.backend_port)
            ).serve()
        )
    except KeyboardInterrupt:
        log("servidor detenido")


if __name__ == "__main__":
    main()
