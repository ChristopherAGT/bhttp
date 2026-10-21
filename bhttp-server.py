
#!/usr/bin/env python3
# Servidor BHTTP autonomo para DTunnel (version asyncio).
# Mantiene el formato binario y el algoritmo de mascara existentes.
#
# Trama peticion : mode(1) sessionId(16) seq(8 BE) len(4 BE) + payload enmascarado
# Trama respuesta: status(1) len(4 BE) + payload enmascarado
# Mascara        : XOR con SHA256(sessionId||mode||seq||dir||contador)
# Modos          : 0=probe 1=subida 2=bajada 3=lote 4=ack
#
# Mejoras:
# - Permite sesiones independientes y simultaneas.
# - Valida el tamano de las tramas entrantes.
# - Limita los buffers y las confirmaciones pendientes de bajada.
# - Evita mantener el candado de sesion durante drain() del backend.
# - No confirma una subida si falla la escritura al backend.
# - Controla tiempos de conexion y limpieza de recursos.
# - Conserva la compatibilidad del formato binario original.

import argparse
import asyncio
import hashlib
import sys
import time

MAGIC = b"BHP1"
LONGPOLL = 2.0

# Limites de seguridad y recursos.
MAX_FRAME_SIZE = 16 * 1024 * 1024
MAX_DOWN_BUFFER = 8 * 1024 * 1024
MAX_UNACKED_BYTES = 8 * 1024 * 1024
MAX_UNACKED_CHUNKS = 4096
MAX_PENDING_UPLOADS = 4096
MAX_SESSIONS = 1024

CONNECT_TIMEOUT = 8.0
WRITE_TIMEOUT = 15.0
CLEANUP_INTERVAL = 60.0
CLOSED_SESSION_RETENTION = 120.0


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
    # Se conserva la estructura de respuesta del probe original.
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
        self.up_lock = asyncio.Lock()

        self.up_next = 0
        self.up_pending = {}

        self.down_raw = bytearray()
        self.down_chunks = {}
        self.down_unacked_bytes = 0
        self.down_assign = 0

        self.eof = False
        self.closed = False
        self.close_reason = ""
        self.created_at = time.monotonic()
        self.last_activity = self.created_at
        self.closed_at = None

        self.br = None
        self.bw = None
        self.reader_task = None

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

    async def _reader(self):
        total = 0

        try:
            while True:
                data = await self.br.read(65536)

                if not data:
                    break

                total += len(data)

                async with self.cond:
                    # Backpressure: no permitir que el buffer crezca
                    # indefinidamente si el cliente deja de descargar.
                    while (
                        len(self.down_raw) >= MAX_DOWN_BUFFER
                        and not self.closed
                    ):
                        await self.cond.wait()

                    if self.closed:
                        break

                    self.down_raw.extend(data)
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
                "sesion %s: lectura backend finalizada (%d B)"
                % (self.sess.hex()[:8], total)
            )

    async def upload(self, seq, data):
        # Serializa las escrituras al backend sin bloquear las descargas
        # mientras se espera a que drain() complete.
        async with self.up_lock:
            async with self.cond:
                if self.closed or self.eof or self.bw is None:
                    raise ConnectionError("sesion backend cerrada")

                self.last_activity = time.monotonic()

                # Una retransmision ya procesada no debe escribirse
                # de nuevo en el flujo SSH.
                if seq < self.up_next:
                    return

                if seq not in self.up_pending:
                    if len(self.up_pending) >= MAX_PENDING_UPLOADS:
                        raise BufferError("demasiadas subidas pendientes")

                    self.up_pending[seq] = data

                # Procesar unicamente secuencias consecutivas.
                while self.up_next in self.up_pending:
                    chunk = self.up_pending[self.up_next]

                    # No mantener self.cond durante una escritura de red.
                    try:
                        self.bw.write(chunk)

                        await asyncio.wait_for(
                            self.bw.drain(),
                            timeout=WRITE_TIMEOUT
                        )

                    except Exception as e:
                        self.closed = True
                        self.close_reason = "error de escritura backend"
                        self.closed_at = time.monotonic()
                        self.cond.notify_all()

                        log(
                            "sesion %s: fallo escribiendo al backend: %s"
                            % (self.sess.hex()[:8], e)
                        )
                        raise ConnectionError(
                            "fallo de escritura al backend"
                        ) from e

                    del self.up_pending[self.up_next]
                    self.up_next += 1
                    self.last_activity = time.monotonic()

    async def download(self, seq, maxlen, deadline):
        if maxlen <= 0:
            maxlen = 1399

        maxlen = min(maxlen, MAX_FRAME_SIZE)
        loop = asyncio.get_running_loop()

        async with self.cond:
            while True:
                self.last_activity = time.monotonic()

                # Repeticion de una secuencia ya asignada:
                # devolver el mismo fragmento mientras siga almacenado.
                if seq < self.down_assign:
                    return self.down_chunks.get(seq, b"")

                if self.closed and not self.down_raw:
                    return b""

                if seq == self.down_assign:
                    can_assign = (
                        len(self.down_chunks) < MAX_UNACKED_CHUNKS
                        and self.down_unacked_bytes < MAX_UNACKED_BYTES
                    )

                    if self.down_raw and can_assign:
                        take_len = min(maxlen, len(self.down_raw))
                        take = bytes(self.down_raw[:take_len])
                        del self.down_raw[:take_len]

                        self.down_chunks[seq] = take
                        self.down_unacked_bytes += len(take)
                        self.down_assign += 1

                        self.cond.notify_all()
                        return take

                    if self.eof and not self.down_raw:
                        self.down_chunks[seq] = b""
                        self.down_assign += 1
                        self.cond.notify_all()
                        return b""

                remaining = deadline - loop.time()

                if remaining > 0 and not self.closed:
                    try:
                        await asyncio.wait_for(
                            self.cond.wait(),
                            timeout=remaining
                        )
                    except asyncio.TimeoutError:
                        pass

                    continue

                # Se conserva el comportamiento original de avanzar
                # la secuencia al terminar el long-poll sin datos.
                # Esto debe verificarse con el cliente DTunnel real.
                while self.down_assign <= seq:
                    self.down_assign += 1

                self.cond.notify_all()
                return b""

    async def ack(self, seq):
        async with self.cond:
            removed = [
                k for k in self.down_chunks
                if k <= seq
            ]

            for k in removed:
                chunk = self.down_chunks.pop(k)
                self.down_unacked_bytes -= len(chunk)

            if self.down_unacked_bytes < 0:
                self.down_unacked_bytes = 0

            self.last_activity = time.monotonic()
            self.cond.notify_all()

    async def close(self, reason="cierre solicitado"):
        async with self.cond:
            if not self.closed:
                self.closed = True
                self.close_reason = reason
                self.closed_at = time.monotonic()

            self.cond.notify_all()

        if self.bw is not None:
            try:
                self.bw.close()
                await self.bw.wait_closed()
            except Exception:
                pass

        task = self.reader_task

        if task is not None and task is not asyncio.current_task():
            if not task.done():
                task.cancel()

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

            # Eliminar unicamente la sesion solicitada si esta cerrada.
            # No cerrar sesiones de otros usuarios.
            if s is not None and s.closed:
                del self.sessions[sess]

            # Retirar sesiones cerradas antiguas para liberar memoria.
            now = time.monotonic()

            for old_sid, old in list(self.sessions.items()):
                if (
                    old.closed
                    and old.closed_at is not None
                    and now - old.closed_at >= CLOSED_SESSION_RETENTION
                ):
                    del self.sessions[old_sid]

            if len(self.sessions) >= MAX_SESSIONS:
                raise ConnectionError("limite de sesiones alcanzado")

            s = Session(sess, self.backend)

            try:
                await s.connect()
            except Exception:
                await s.close("fallo de conexion al backend")
                raise

            self.sessions[sess] = s

            log(
                "sesion %s: registrada (sesiones registradas: %d)"
                % (sess.hex()[:8], len(self.sessions))
            )

            return s

    async def cleanup(self):
        while True:
            await asyncio.sleep(CLEANUP_INTERVAL)
            now = time.monotonic()

            async with self.slock:
                for sid, s in list(self.sessions.items()):
                    if (
                        s.closed
                        and s.closed_at is not None
                        and now - s.closed_at >= CLOSED_SESSION_RETENTION
                    ):
                        del self.sessions[sid]

    async def handle(self, reader, writer):
        peer = writer.get_extra_info("peername")

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
                    log(
                        "trama demasiado grande desde %s: %d B"
                        % (peer, ln)
                    )
                    break

                payload = b""

                # Los modos de datos y probe conservan el procesamiento
                # de payload del protocolo original.
                if ln and mode in (0, 1, 2, 3):
                    raw = await reader.readexactly(ln)
                    payload = mask(raw, sess, mode, seq, 0)

                elif ln and mode == 4:
                    # ACK no consume payload en la implementacion original.
                    # Se rechaza una longitud no valida para evitar
                    # desincronizar la siguiente trama TCP.
                    log("ACK con payload no admitido desde %s" % (peer,))
                    break

                if payload[:4] == MAGIC:
                    size = (
                        int.from_bytes(payload[6:10], "big")
                        if len(payload) >= 10 else 0
                    )
                    pmode = payload[5] if len(payload) >= 6 else mode

                    if size > MAX_FRAME_SIZE:
                        log("probe solicita un tamano excesivo")
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
                    # Un probe que no contiene MAGIC no abre un backend.
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

                    # El byte count tiene un maximo de 255 por formato.
                    # Se mantiene el valor de la trama original.
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

        except asyncio.IncompleteReadError:
            pass

        except (
            ConnectionError,
            BrokenPipeError,
            OSError,
            asyncio.TimeoutError
        ):
            pass

        except BufferError as e:
            log("sesion %s: limite de buffer alcanzado: %s" % (
                sess.hex()[:8] if "sess" in locals() else "?",
                e
            ))

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
            if self.cleanup_task is not None:
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
