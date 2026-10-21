
#!/usr/bin/env bash

set -uo pipefail

DESTDIR="/usr/local/lib/bhttp"
SERVER_PY="$DESTDIR/bhttp-server.py"
UNIT="/etc/systemd/system/bhttp.service"
SERVICE="bhttp"

SERVER_URL="https://raw.githubusercontent.com/ChristopherAGT/bhttp-server/main/bhttp-server.py"

CANDIDATOS=(8080 80 8443 443 2082 2095 8880 2052 3128)

PUERTO=""
SSHPORT=22
DESINSTALAR=0
NUEVO_USER=""
NUEVO_PASS=""
SOLO_DIAG=0

while [ $# -gt 0 ]; do
  case "$1" in
    --puerto|-p)
      [ $# -ge 2 ] || { echo "Falta el puerto"; exit 2; }
      shift
      PUERTO="$1"
      ;;
    --ssh-puerto)
      [ $# -ge 2 ] || { echo "Falta el puerto SSH"; exit 2; }
      shift
      SSHPORT="$1"
      ;;
    --crear-usuario)
      [ $# -ge 2 ] || { echo "Falta el usuario"; exit 2; }
      shift
      NUEVO_USER="$1"
      ;;
    --clave)
      [ $# -ge 2 ] || { echo "Falta la clave"; exit 2; }
      shift
      NUEVO_PASS="$1"
      ;;
    --desinstalar) DESINSTALAR=1 ;;
    --diag) SOLO_DIAG=1 ;;
    -h|--help)
      sed -n '1,35p' "$0"
      exit 0
      ;;
    *)
      echo "Opcion desconocida: $1" >&2
      exit 2
      ;;
  esac
  shift
done

rojo()  { printf '\033[31m%s\033[0m\n' "$*"; }
verde() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
paso()  { printf '\n[%s] %s\n' "$1" "$2"; }

if [ "$(id -u)" != 0 ]; then
  rojo "Ejecutalo como root: sudo bash $0"
  exit 2
fi

# ------------------------------------------------------------
# Crear usuario SSH opcional
# ------------------------------------------------------------

crear_usuario() {
  local u="$1" p="$2"

  if ! [[ "$u" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
    rojo "Nombre de usuario invalido"
    return 1
  fi

  if id "$u" >/dev/null 2>&1; then
    info "El usuario '$u' ya existe; se actualizara su clave"
  else
    useradd -M -s /bin/bash "$u" || {
      rojo "No pude crear el usuario"
      return 1
    }
    info "Usuario creado: $u"
  fi

  if [ -z "$p" ]; then
    p="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
    [ -n "$p" ] || {
      rojo "No pude generar una clave"
      return 1
    }
  fi

  if ! printf '%s:%s\n' "$u" "$p" | chpasswd; then
    rojo "No pude establecer la clave"
    return 1
  fi

  USER_FINAL="$u"
  PASS_FINAL="$p"
}

if [ -n "$NUEVO_USER" ]; then
  echo "=== Crear usuario SSH ==="

  if crear_usuario "$NUEVO_USER" "$NUEVO_PASS"; then
    verde "Usuario listo"
    echo "  Usuario: $USER_FINAL"
    echo "  Clave:   $PASS_FINAL"
  else
    exit 1
  fi

  if [ -z "$PUERTO" ] && [ "$DESINSTALAR" = 0 ] \
     && [ "$SOLO_DIAG" = 0 ]; then
    echo "Usuario creado. Para instalar: bash $0"
    exit 0
  fi
fi

# ------------------------------------------------------------
# Diagnostico SSH y red
# ------------------------------------------------------------

diagnostico_ssh() {
  paso "diag" "Comprobando SSH y red"

  local cfg="/etc/ssh/sshd_config"
  local fwd=""

  if [ -r "$cfg" ]; then
    fwd="$(grep -iE '^[[:space:]]*AllowTcpForwarding' "$cfg" \
      | tail -1 | awk '{print tolower($2)}' || true)"
  fi

  if [ "$fwd" = "no" ]; then
    rojo "AllowTcpForwarding esta desactivado"
    info "Revisa la configuracion efectiva de sshd antes de modificarla"
  else
    info "AllowTcpForwarding: ${fwd:-valor predeterminado o no definido}"
  fi

  if timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53' 2>/dev/null; then
    info "Salida TCP a 8.8.8.8:53: OK"
  else
    rojo "No se pudo abrir TCP hacia 8.8.8.8:53"
  fi

  if command -v ss >/dev/null 2>&1 \
     && ss -ltn | awk '{print $4}' | grep -qE ":${SSHPORT}$"; then
    info "Puerto SSH $SSHPORT: escuchando"
  else
    rojo "No se detecto un socket escuchando en el puerto $SSHPORT"
  fi
}

if [ "$SOLO_DIAG" = 1 ]; then
  diagnostico_ssh
  exit 0
fi

# ------------------------------------------------------------
# Desinstalar
# ------------------------------------------------------------

if [ "$DESINSTALAR" = 1 ]; then
  systemctl disable --now "$SERVICE" 2>/dev/null || true

  rm -f "$UNIT"
  rm -rf "$DESTDIR"
  rm -f /etc/sysctl.d/99-bhttp.conf
  rm -f /etc/security/limits.d/99-bhttp.conf

  systemctl daemon-reload

  verde "BHTTP desinstalado"
  info "Los ajustes TCP aplicados en el kernel pueden persistir hasta reiniciar"
  info "No se eliminan los usuarios SSH creados"

  exit 0
fi

echo "=== Instalador BHTTP ==="

for cmd in python3 systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    rojo "Falta el comando: $cmd"
    exit 1
  }
done

if ! command -v curl >/dev/null 2>&1; then
  rojo "Falta curl. Instala con: apt install -y curl"
  exit 1
fi

# ------------------------------------------------------------
# Seleccionar puerto
# ------------------------------------------------------------

paso "1/4" "Seleccionando puerto"

ocupados() {
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn 2>/dev/null |
      awk '{print $4}' |
      sed 's/.*://' |
      grep -E '^[0-9]+$' |
      sort -u
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null |
      awk '/^tcp/ {print $4}' |
      sed 's/.*://' |
      grep -E '^[0-9]+$' |
      sort -u
  fi
}

libre() {
  ! ocupados | grep -qx "$1"
}

primer_libre=""

for p in "${CANDIDATOS[@]}"; do
  if libre "$p"; then
    primer_libre="$p"
    break
  fi
done

if [ -z "$PUERTO" ]; then
  if [ -t 0 ]; then
    read -r -p "Puerto BHTTP [${primer_libre:-8080}]: " PUERTO
    PUERTO="${PUERTO:-${primer_libre:-8080}}"
  else
    PUERTO="${primer_libre:-8080}"
    info "Puerto elegido automaticamente: $PUERTO"
  fi
fi

if ! [[ "$PUERTO" =~ ^[0-9]+$ ]] \
   || [ "$PUERTO" -lt 1 ] || [ "$PUERTO" -gt 65535 ]; then
  rojo "Puerto invalido: $PUERTO"
  exit 1
fi

if ! [[ "$SSHPORT" =~ ^[0-9]+$ ]] \
   || [ "$SSHPORT" -lt 1 ] || [ "$SSHPORT" -gt 65535 ]; then
  rojo "Puerto SSH invalido: $SSHPORT"
  exit 1
fi

if ! libre "$PUERTO"; then
  rojo "El puerto $PUERTO ya esta ocupado"
  exit 1
fi

info "Puerto BHTTP: $PUERTO"
info "Backend SSH: 127.0.0.1:$SSHPORT"

# ------------------------------------------------------------
# Descargar el servidor Python desde GitHub
# ------------------------------------------------------------

paso "2/4" "Descargando servidor desde GitHub"

mkdir -p "$DESTDIR" || {
  rojo "No se pudo crear $DESTDIR"
  exit 1
}

TMP_PY="$(mktemp "$DESTDIR/.bhttp-server.py.XXXXXX")" || exit 1

if ! curl -fLsS --connect-timeout 10 --max-time 60 \
  "$SERVER_URL" -o "$TMP_PY"; then
  rm -f "$TMP_PY"
  rojo "No se pudo descargar el servidor"
  info "Comprueba la URL y que el archivo exista en GitHub"
  exit 1
fi

if ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$TMP_PY"; then
  rm -f "$TMP_PY"
  rojo "El archivo Python descargado tiene errores de sintaxis"
  exit 1
fi

if ! grep -q 'class Server' "$TMP_PY" \
   || ! grep -q 'async def serve' "$TMP_PY"; then
  rm -f "$TMP_PY"
  rojo "El archivo descargado no parece ser el servidor esperado"
  exit 1
fi

chmod 644 "$TMP_PY"

if ! mv -f "$TMP_PY" "$SERVER_PY"; then
  rm -f "$TMP_PY"
  rojo "No se pudo instalar el archivo Python"
  exit 1
fi

info "Servidor instalado: $SERVER_PY"

# ------------------------------------------------------------
# Configurar systemd
# ------------------------------------------------------------

PYBIN="$(command -v python3)"

cat > "$UNIT" <<EOF
[Unit]
Description=Servidor BHTTP (DTunnel) puerto $PUERTO
After=network.target

[Service]
Type=simple
ExecStart=$PYBIN $SERVER_PY --host 0.0.0.0 --port $PUERTO --backend-host 127.0.0.1 --backend-port $SSHPORT
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$UNIT"

# ------------------------------------------------------------
# Ajustes TCP
# ------------------------------------------------------------

paso "tcp" "Configurando capacidad TCP"

SYSCTL_FILE="/etc/sysctl.d/99-bhttp.conf"

cat > "$SYSCTL_FILE" <<'EOF'
# BHTTP: ajustes de capacidad TCP.
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 1048576
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_tw_reuse = 0
net.ipv4.tcp_slow_start_after_idle = 1
net.ipv4.tcp_mtu_probing = 0
EOF

if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
  echo "net.netfilter.nf_conntrack_max = 262144" >> "$SYSCTL_FILE"
fi

if sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1; then
  info "Ajustes TCP aplicados"
else
  info "Algunos ajustes TCP no pudieron aplicarse"
fi

mkdir -p /etc/security/limits.d

cat > /etc/security/limits.d/99-bhttp.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

# ------------------------------------------------------------
# Arrancar servicio
# ------------------------------------------------------------

paso "3/4" "Iniciando servicio"

systemctl daemon-reload || {
  rojo "Fallo al recargar systemd"
  exit 1
}

systemctl enable "$SERVICE" >/dev/null || {
  rojo "No se pudo habilitar el servicio"
  exit 1
}

if ! systemctl restart "$SERVICE"; then
  rojo "No se pudo iniciar BHTTP"
  journalctl -u "$SERVICE" -n 30 --no-pager
  exit 1
fi

LEVANTADO=0

for _ in $(seq 1 10); do
  if [ "$(systemctl is-active "$SERVICE" 2>/dev/null)" = active ] \
     && ocupados | grep -qx "$PUERTO"; then
    LEVANTADO=1
    break
  fi

  sleep 1
done

if [ "$LEVANTADO" != 1 ]; then
  rojo "El servicio no esta escuchando correctamente"
  journalctl -u "$SERVICE" -n 30 --no-pager
  exit 1
fi

verde "BHTTP activo en el puerto $PUERTO"

# ------------------------------------------------------------
# Verificacion local del protocolo
# ------------------------------------------------------------

paso "4/4" "Verificando protocolo BHTTP"

VERIF="$(python3 - "$PUERTO" <<'PYTEST'
import hashlib
import os
import socket
import sys

PORT = int(sys.argv[1])
SESS = os.urandom(16)
MAGIC = b"BHP1"


def ks(mode, seq, direction, n):
    out = b""
    counter = 0

    while len(out) < n:
        out += hashlib.sha256(
            SESS
            + bytes([mode])
            + seq.to_bytes(8, "big")
            + bytes([direction])
            + counter.to_bytes(4, "big")
        ).digest()
        counter += 1

    return out[:n]


def mask(data, mode, seq, direction):
    return bytes(
        a ^ b for a, b in zip(
            data, ks(mode, seq, direction, len(data))
        )
    )


def readn(sock, n):
    out = b""

    while len(out) < n:
        part = sock.recv(n - len(out))
        if not part:
            raise EOFError("conexion cerrada")
        out += part

    return out


def send(sock, mode, seq, payload=b"", length=None):
    if length is None:
        length = len(payload)

    sock.sendall(
        bytes([mode])
        + SESS
        + seq.to_bytes(8, "big")
        + length.to_bytes(4, "big")
    )

    if payload:
        sock.sendall(payload)


def response(sock):
    status = readn(sock, 1)[0]
    length = int.from_bytes(readn(sock, 4), "big")
    body = readn(sock, length) if length else b""
    return status, body


def open_sock():
    return socket.create_connection(("127.0.0.1", PORT), timeout=5)


try:
    # Handshake
    payload = MAGIC + bytes([1, 0]) + (0).to_bytes(4, "big")

    with open_sock() as sock:
        send(sock, 0, 0, mask(payload, 0, 0, 0))
        status, body = response(sock)

    if status != 0 or mask(body, 0, 0, 1)[:4] != MAGIC:
        raise RuntimeError("handshake no valido")

    print("HANDSHAKE_OK")

    # Prueba de subida y banner SSH
    with open_sock() as sock:
        send(sock, 1, 0)
        status, _ = response(sock)

    if status != 0:
        raise RuntimeError("registro no valido")

    with open_sock() as sock:
        sock.settimeout(5)
        send(
            sock, 1, 0,
            mask(b"SSH-2.0-Test\r\n", 1, 0, 0)
        )
        response(sock)

    # La comprobacion real del banner requiere descargar datos.
    with open_sock() as sock:
        sock.settimeout(5)
        batch = (1399).to_bytes(4, "big") + bytes([0, 1])
        send(sock, 3, 0, mask(batch, 3, 0, 0))
        status, body = response(sock)

    if status != 2 or len(body) < 4:
        raise RuntimeError("respuesta de descarga no valida")

    length = int.from_bytes(body[:4], "big")
    if length != len(body) - 4:
        raise RuntimeError("longitud de descarga incorrecta")

    chunk = mask(body[4:], 3, 0, 1)

    if chunk.startswith(b"SSH-"):
        print("TUNEL_OK")
        print("BANNER=" + chunk[:40].decode("latin1").strip())
    else:
        print("TUNEL_SIN_BANNER")
        print("La prueba BHTTP respondio, pero no recibio el banner SSH.")

except Exception as exc:
    print("ERROR=" + str(exc))
PYTEST
)"

echo "$VERIF" | sed 's/^/  /'

echo
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

if command -v curl >/dev/null 2>&1; then
  PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$PUBLIC_IP" ] && IP="$PUBLIC_IP"
fi

if echo "$VERIF" | grep -q HANDSHAKE_OK; then
  verde "=== Servidor BHTTP instalado ==="
  echo
  echo "  Host:      ${IP:-IP_DE_TU_VPS}"
  echo "  Puerto:    $PUERTO"
  echo "  Protocolo: bhttp"
  echo "  Backend:   127.0.0.1:$SSHPORT"
  echo
  info "Estado: systemctl status bhttp"
  info "Reiniciar: systemctl restart bhttp"
  info "Logs: journalctl -u bhttp -f"
  info "Desinstalar: bash $0 --desinstalar"
  echo
  diagnostico_ssh
else
  rojo "La verificacion del protocolo fallo"
  info "Consulta: journalctl -u bhttp -n 50 --no-pager"
  exit 1
fi
