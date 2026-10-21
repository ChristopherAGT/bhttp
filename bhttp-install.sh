#!/usr/bin/env bash

set -uo pipefail

# ------------------------------------------------------------
# CONFIGURACION PRINCIPAL DEL INSTALADOR
# ------------------------------------------------------------
# DESTDIR: directorio donde se instala el servidor Python.
# SERVER_PY: archivo Python descargado desde GitHub.
# UNIT: archivo de unidad systemd para administrar el servicio.
# SERVICE: nombre del servicio que se inicia con systemd.
#
# Este instalador descarga el servidor; no lo escribe dentro
# del propio script.
# ------------------------------------------------------------

DESTDIR="/usr/local/lib/bhttp"
SERVER_PY="$DESTDIR/bhttp-server.py"
UNIT="/etc/systemd/system/bhttp.service"
SERVICE="bhttp"

SERVER_URL="https://raw.githubusercontent.com/ChristopherAGT/bhttp-protocol/main/bhttp-server.py"

# PUERTO: puerto público en el que escuchará BHTTP.
# SSHPORT: puerto del servicio SSH al que se redirige el túnel.
# SSHPORT_EXPLICITO: indica si el puerto SSH se proporcionó
# mediante --ssh-puerto, evitando preguntar de nuevo.
# SOLO_DIAG: ejecuta únicamente el diagnóstico SSH/red.
PUERTO=""
SSHPORT=22
SSHPORT_EXPLICITO=0
SOLO_DIAG=0

# ------------------------------------------------------------
# INTERFAZ VISUAL PROFESIONAL
# ------------------------------------------------------------
# Se utilizan colores ANSI para mostrar una interfaz más clara.
#
# Cian: títulos y elementos destacados.
# Azul: información y etapas.
# Verde: operaciones completadas correctamente.
# Amarillo: advertencias y recomendaciones.
# Rojo: errores y operaciones fallidas.
#
# Los colores se desactivan cuando la salida no es una terminal,
# para evitar códigos ANSI en registros o salidas redirigidas.
# ------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RESET='\033[0m'
  NEGRITA='\033[1m'
  TENUE='\033[2m'
  ROJO='\033[38;5;203m'
  VERDE='\033[38;5;114m'
  AMARILLO='\033[38;5;221m'
  AZUL='\033[38;5;75m'
  CIAN='\033[38;5;87m'
  BLANCO='\033[97m'
  GRIS='\033[38;5;245m'
else
  RESET=''
  NEGRITA=''
  TENUE=''
  ROJO=''
  VERDE=''
  AMARILLO=''
  AZUL=''
  CIAN=''
  BLANCO=''
  GRIS=''
fi

rojo() {
  printf '%b❌ %s%b\n' "$ROJO" "$*" "$RESET"
}

verde() {
  printf '%b✅ %s%b\n' "$VERDE" "$*" "$RESET"
}

amarillo() {
  printf '%b⚠️  %s%b\n' "$AMARILLO" "$*" "$RESET"
}

cian() {
  printf '%b%s%b\n' "$CIAN" "$*" "$RESET"
}

info() {
  printf '  %b›%b %s\n' "$AZUL" "$RESET" "$*"
}

paso() {
  printf '\n%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' \
    "$CIAN" "$RESET"
  printf '%b  %s  %s%b\n' "$NEGRITA$AZUL" "$1" "$2" "$RESET"
  printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' \
    "$CIAN" "$RESET"
}

titulo() {
  printf '\n%b%s%b\n' "$NEGRITA$BLANCO" "$*" "$RESET"
}

separador() {
  printf '%b──────────────────────────────────────────────────%b\n' \
    "$GRIS" "$RESET"
}

banner() {
  printf '\n'
  printf '%b╭──────────────────────────────────────────────────╮%b\n' \
    "$CIAN" "$RESET"
  printf '%b│%b                                                  %b│%b\n' \
    "$CIAN" "$RESET" "$CIAN" "$RESET"
  printf '%b│%b       ⚡ %bBHTTP SERVER%b                         %b│%b\n' \
    "$CIAN" "$RESET" "$NEGRITA$BLANCO" "$RESET" "$CIAN" "$RESET"
  printf '%b│%b       %bInstalador y configurador%b               %b│%b\n' \
    "$CIAN" "$RESET" "$AZUL" "$RESET" "$CIAN" "$RESET"
  printf '%b│%b                                                  %b│%b\n' \
    "$CIAN" "$RESET" "$CIAN" "$RESET"
  printf '%b╰──────────────────────────────────────────────────╯%b\n' \
    "$CIAN" "$RESET"
  printf '\n'
}

# ------------------------------------------------------------
# PROCESAR ARGUMENTOS DE LA LINEA DE COMANDOS
# ------------------------------------------------------------
# Ejemplos:
#   bash bhttp-install.sh
#   bash bhttp-install.sh --puerto 8880 --ssh-puerto 22
#   bash bhttp-install.sh --diag
#
# La instalación interactiva pregunta los puertos que falten.
# En modo no interactivo, el puerto BHTTP debe especificarse.
# ------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --puerto|-p)
      [ $# -ge 2 ] || {
        rojo "Falta indicar el puerto BHTTP."
        exit 2
      }
      shift
      PUERTO="$1"
      ;;
    --ssh-puerto)
      [ $# -ge 2 ] || {
        rojo "Falta indicar el puerto SSH."
        exit 2
      }
      shift
      SSHPORT="$1"
      SSHPORT_EXPLICITO=1
      ;;
    --diag)
      SOLO_DIAG=1
      ;;
    -h|--help)
      sed -n '1,35p' "$0"
      exit 0
      ;;
    *)
      rojo "Opción desconocida: $1"
      info "Utiliza --help para consultar las opciones."
      exit 2
      ;;
  esac
  shift
done

# ------------------------------------------------------------
# COMPROBAR PRIVILEGIOS
# ------------------------------------------------------------
# Se necesita root para escribir en /usr/local/lib, crear la
# unidad systemd y modificar los ajustes globales del sistema.
# ------------------------------------------------------------

if [ "$(id -u)" != 0 ]; then
  rojo "Debes ejecutar este instalador como root."
  info "Ejemplo: sudo bash $0"
  exit 2
fi

# ------------------------------------------------------------
# DIAGNOSTICO SSH Y RED
# ------------------------------------------------------------
# Una conexión BHTTP puede establecerse correctamente y aun así
# no permitir navegar si SSH no acepta el forwarding o si la
# VPS carece de conectividad de salida.
#
# Esta función comprueba:
# 1. AllowTcpForwarding en sshd_config.
# 2. Conectividad TCP hacia 8.8.8.8:53.
# 3. Si existe un socket escuchando en el puerto SSH configurado.
#
# La lectura de sshd_config es orientativa: otras directivas,
# archivos incluidos o bloques Match pueden cambiar el valor
# efectivo de la configuración SSH.
# ------------------------------------------------------------

diagnostico_ssh() {
  paso "🔎 DIAGNÓSTICO" "Comprobando SSH y conectividad de red"

  local cfg="/etc/ssh/sshd_config"
  local fwd=""

  if [ -r "$cfg" ]; then
    fwd="$(grep -iE '^[[:space:]]*AllowTcpForwarding' "$cfg" \
      | tail -1 | awk '{print tolower($2)}' || true)"
  fi

  if [ "$fwd" = "no" ]; then
    rojo "AllowTcpForwarding aparece desactivado."
    info "Revisa la configuración efectiva de sshd antes de modificarla."
  else
    verde "AllowTcpForwarding: ${fwd:-valor predeterminado o no definido}"
  fi

  separador

  # Prueba de salida TCP hacia un servidor DNS público.
  # Comprueba conectividad a ese destino concreto, no toda la red.
  if timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53' 2>/dev/null; then
    verde "Conectividad TCP hacia 8.8.8.8:53: correcta."
  else
    rojo "No se pudo abrir una conexión TCP hacia 8.8.8.8:53."
    info "Comprueba las reglas de salida y la conectividad del proveedor."
  fi

  # Comprueba el puerto backend configurado para SSH.
  # No modifica el puerto ni reinicia el servicio SSH.
  if command -v ss >/dev/null 2>&1 \
     && ss -ltn | awk '{print $4}' | grep -qE ":${SSHPORT}$"; then
    verde "Puerto SSH $SSHPORT: existe un socket en escucha."
  else
    rojo "No se detectó un socket escuchando en el puerto $SSHPORT."
    info "Verifica el puerto configurado en el servicio SSH."
  fi

  separador
}

# Si se solicita solo el diagnóstico, no se instala ni modifica
# el servicio BHTTP.
if [ "$SOLO_DIAG" = 1 ]; then
  banner
  diagnostico_ssh
  exit 0
fi

banner

cian "🚀 Preparando la instalación de BHTTP..."
info "Servidor Python: $SERVER_PY"
info "Servicio systemd: $SERVICE"
info "Origen: GitHub"

# ------------------------------------------------------------
# COMPROBAR DEPENDENCIAS
# ------------------------------------------------------------
# python3: ejecuta el servidor y valida el archivo descargado.
# systemctl: administra el servicio BHTTP.
# curl: descarga el servidor desde GitHub y consulta la IP pública.
# ------------------------------------------------------------

paso "🔧 PREPARACIÓN" "Comprobando dependencias"

for cmd in python3 systemctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    rojo "Falta el comando necesario: $cmd"
    exit 1
  fi

  verde "$cmd está disponible."
done

if ! command -v curl >/dev/null 2>&1; then
  rojo "No se encuentra curl."
  info "Instálalo con: apt install -y curl"
  exit 1
fi

verde "Todas las dependencias necesarias están disponibles."

# ------------------------------------------------------------
# FUNCIONES PARA COMPROBAR PUERTOS
# ------------------------------------------------------------
# ocupados:
#   Obtiene los puertos TCP que tienen sockets en escucha.
#   Prefiere ss y utiliza netstat como alternativa.
#
# libre:
#   Comprueba si el puerto indicado no aparece en esa lista.
#
# Esta comprobación detecta sockets locales en escucha.
# No garantiza que el puerto sea accesible desde Internet:
# el firewall, las reglas del proveedor o el enrutamiento pueden
# bloquear conexiones externas aunque el puerto esté libre.
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# SELECCIONAR PUERTO BHTTP Y PUERTO DE REDIRECCION
# ------------------------------------------------------------
# Puerto BHTTP:
#   Es el puerto de entrada donde escucha el servidor BHTTP.
#
# Puerto de redirección:
#   Es el puerto del backend SSH local al que se conecta BHTTP.
#   Por defecto se utiliza el puerto 22.
#
# Se permite indicar ambos valores mediante argumentos o
# introducirlos cuando el instalador pregunta.
#
# Se validan los rangos TCP y se evita utilizar el mismo número
# para la escucha BHTTP y para el backend SSH.
# ------------------------------------------------------------

paso "1/4" "🌐 Configuración de puertos"

if [ -z "$PUERTO" ]; then
  if [ -t 0 ]; then
    echo
    printf '%b%s%b\n' "$CIAN" "  ┌─ Puerto de escucha BHTTP" "$RESET"
    read -r -p "  └─ Introduce el puerto que deseas utilizar: " PUERTO
  else
    rojo "Debes indicar el puerto en modo no interactivo."
    info "Ejemplo: bash $0 --puerto 8880 --ssh-puerto 22"
    exit 2
  fi
fi

# Si no se indicó explícitamente el puerto SSH y hay terminal,
# se pregunta. Si se presiona Enter, se conserva el puerto 22.
if [ "$SSHPORT_EXPLICITO" = 0 ] && [ -t 0 ]; then
  echo
  printf '%b%s%b\n' "$CIAN" "  ┌─ Puerto del backend SSH" "$RESET"
  read -r -p "  └─ Puerto SSH [22]: " RESP_SSH
  SSHPORT="${RESP_SSH:-22}"
fi

# Los puertos TCP válidos están entre 1 y 65535.
if ! [[ "$PUERTO" =~ ^[0-9]+$ ]] \
   || [ "$PUERTO" -lt 1 ] || [ "$PUERTO" -gt 65535 ]; then
  rojo "Puerto BHTTP inválido: $PUERTO"
  exit 1
fi

if ! [[ "$SSHPORT" =~ ^[0-9]+$ ]] \
   || [ "$SSHPORT" -lt 1 ] || [ "$SSHPORT" -gt 65535 ]; then
  rojo "Puerto de redirección inválido: $SSHPORT"
  exit 1
fi

if [ "$PUERTO" = "$SSHPORT" ]; then
  rojo "Los puertos BHTTP y SSH no pueden ser iguales."
  info "Selecciona dos puertos diferentes."
  exit 1
fi

# Evita continuar si ya existe un socket TCP escuchando en
# el puerto de entrada seleccionado para BHTTP.
if ! libre "$PUERTO"; then
  rojo "El puerto $PUERTO ya está ocupado."
  info "Elige otro puerto o libera el puerto antes de continuar."
  exit 1
fi

echo
titulo "📋 RESUMEN DE CONFIGURACIÓN"
separador
info "Puerto público BHTTP : $PUERTO"
info "Backend SSH          : 127.0.0.1:$SSHPORT"
info "Directorio            : $DESTDIR"
info "Servicio              : $SERVICE"
separador

if ! command -v ss >/dev/null 2>&1; then
  amarillo "No se encontró ss; la comprobación depende de netstat."
fi

# ------------------------------------------------------------
# DESCARGAR Y VALIDAR EL SERVIDOR PYTHON
# ------------------------------------------------------------
# El servidor se obtiene desde SERVER_URL.
#
# Primero se descarga a un archivo temporal dentro del directorio
# de instalación para evitar reemplazar el servidor con una
# descarga incompleta.
#
# Después se comprueba:
# 1. Que curl pueda descargar el archivo sin error HTTP.
# 2. Que Python pueda analizar su sintaxis.
# 3. Que existan las definiciones esperadas del servidor.
#
# Solo después de pasar esas comprobaciones se reemplaza el
# archivo instalado.
# ------------------------------------------------------------

paso "2/4" "📦 Descargando y validando el servidor"

if ! mkdir -p "$DESTDIR"; then
  rojo "No se pudo crear el directorio $DESTDIR"
  exit 1
fi

TMP_PY="$(mktemp "$DESTDIR/.bhttp-server.py.XXXXXX")" || {
  rojo "No se pudo crear el archivo temporal."
  exit 1
}

info "Conectando con GitHub..."
info "Descargando el código fuente..."

if ! curl -fLsS --connect-timeout 10 --max-time 60 \
  "$SERVER_URL" -o "$TMP_PY"; then
  rm -f "$TMP_PY"
  rojo "No se pudo descargar el servidor."
  info "Comprueba que la URL sea correcta y que el archivo exista."
  exit 1
fi

verde "Descarga completada."

# Validación sintáctica sin ejecutar el código descargado.
info "Validando la sintaxis de Python..."

if ! python3 -c \
  'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' \
  "$TMP_PY"; then
  rm -f "$TMP_PY"
  rojo "El archivo Python descargado tiene errores de sintaxis."
  exit 1
fi

verde "Sintaxis de Python correcta."

# Comprueba que el archivo tenga las definiciones principales
# esperadas. Es una comprobación básica, no una auditoría del
# contenido ni una garantía de compatibilidad con la aplicación.
if ! grep -q 'class Server' "$TMP_PY" \
   || ! grep -q 'async def serve' "$TMP_PY"; then
  rm -f "$TMP_PY"
  rojo "El archivo descargado no parece ser el servidor esperado."
  exit 1
fi

verde "Estructura básica del servidor validada."

chmod 644 "$TMP_PY"

if ! mv -f "$TMP_PY" "$SERVER_PY"; then
  rm -f "$TMP_PY"
  rojo "No se pudo instalar el archivo Python."
  exit 1
fi

verde "Servidor instalado correctamente."
info "Ubicación: $SERVER_PY"

# ------------------------------------------------------------
# CONFIGURAR SYSTEMD
# ------------------------------------------------------------
# Se crea la unidad bhttp.service para ejecutar el servidor
# automáticamente al iniciar la VPS.
#
# --host 0.0.0.0:
#   Escucha en todas las interfaces IPv4.
#
# --port:
#   Puerto público de entrada seleccionado para BHTTP.
#
# --backend-host 127.0.0.1:
#   El backend SSH se encuentra en la propia VPS.
#
# --backend-port:
#   Puerto SSH al que se redirige el túnel.
#
# Restart=always:
#   Intenta volver a iniciar el proceso si termina.
#
# RestartSec=2:
#   Espera dos segundos antes de intentar reiniciarlo.
#
# LimitNOFILE=1048576:
#   Eleva el límite de descriptores de archivos del servicio.
#   Los sockets TCP también consumen descriptores; un límite
#   demasiado bajo puede provocar errores bajo alta concurrencia.
# ------------------------------------------------------------

PYBIN="$(command -v python3)"

paso "⚙️  CONFIGURACIÓN" "Creando el servicio systemd"

if ! cat > "$UNIT" <<EOF
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
then
  rojo "No se pudo escribir la unidad systemd."
  exit 1
fi

chmod 644 "$UNIT"
verde "Unidad systemd creada: $UNIT"

# ------------------------------------------------------------
# AJUSTES TCP DEL SISTEMA
# ------------------------------------------------------------
# El cliente BHTTP puede generar muchas conexiones TCP cortas.
# Con límites predeterminados bajos, una VPS puede experimentar
# colas saturadas o falta de descriptores durante picos de tráfico.
#
# Ajustes de capacidad:
#   somaxconn:
#     Límite de la cola de conexiones pendientes de aceptación.
#
#   netdev_max_backlog:
#     Cola de paquetes recibidos que esperan procesamiento.
#
#   tcp_max_syn_backlog:
#     Cola de conexiones que aún están completando el handshake.
#
#   ip_local_port_range:
#     Rango de puertos efímeros disponibles para conexiones salientes.
#
#   fs.file-max:
#     Límite global de descriptores de archivos del kernel.
#
# También se escriben valores explícitos para algunas opciones
# TCP para evitar que permanezcan valores activados por ajustes
# anteriores de este mismo archivo.
#
# IMPORTANTE:
# Estos valores no garantizan que desaparezcan los cortes.
# El rendimiento también depende del kernel, la RAM, la CPU,
# el firewall, el proveedor y el comportamiento del cliente.
# ------------------------------------------------------------

paso "🚀 OPTIMIZACIÓN" "Configurando capacidad TCP"

SYSCTL_FILE="/etc/sysctl.d/99-bhttp.conf"

if ! cat > "$SYSCTL_FILE" <<'EOF'
# BHTTP: ajustes de capacidad TCP.
# Archivo administrado por el instalador BHTTP.
#
# Capacidad de colas y descriptores:
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 1048576
#
# Valores explícitos para evitar conservar configuraciones
# anteriores que pudieran haber quedado activadas.
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_tw_reuse = 0
net.ipv4.tcp_slow_start_after_idle = 1
net.ipv4.tcp_mtu_probing = 0
EOF
then
  rojo "No se pudo escribir la configuración TCP."
  exit 1
fi

# conntrack:
# La tabla de seguimiento de conexiones se utiliza cuando el
# kernel dispone de ese subsistema. Se añade el ajuste únicamente
# si el parámetro existe en esta VPS.
if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
  echo "net.netfilter.nf_conntrack_max = 262144" >> "$SYSCTL_FILE"
  info "Seguimiento de conexiones: ajuste conntrack incluido."
else
  amarillo "Conntrack no está disponible; se omite ese parámetro."
fi

# Aplica los parámetros disponibles en el kernel en ejecución.
# Si falla alguno, se conserva el archivo para que el administrador
# pueda revisar los mensajes y comprobar la compatibilidad.
if sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1; then
  verde "Ajustes TCP aplicados correctamente."
else
  amarillo "Algunos ajustes TCP no pudieron aplicarse."
  info "Detalles de los parámetros que no se pudieron aplicar:"

  sysctl -p "$SYSCTL_FILE" 2>/dev/null | sed 's/^/    /' || true
fi

# ------------------------------------------------------------
# LIMITES GLOBALES DE DESCRIPTORES
# ------------------------------------------------------------
# Este archivo configura límites nofile para sesiones que utilicen
# PAM y para root. No sustituye LimitNOFILE de systemd: el límite
# explícito de la unidad controla el proceso del servicio BHTTP.
#
# Estos límites globales no siempre afectan a servicios ya
# iniciados ni a todos los tipos de sesión.
# ------------------------------------------------------------

paso "📂 LÍMITES" "Configurando descriptores de archivos"

if ! mkdir -p /etc/security/limits.d; then
  rojo "No se pudo crear /etc/security/limits.d"
  exit 1
fi

if ! cat > /etc/security/limits.d/99-bhttp.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
then
  rojo "No se pudieron configurar los límites globales."
  exit 1
fi

verde "Límite nofile configurado: 1048576"

# ------------------------------------------------------------
# RECARGAR SYSTEMD E INICIAR BHTTP
# ------------------------------------------------------------
# daemon-reload:
#   Hace que systemd vuelva a leer los archivos de unidades.
#
# enable:
#   Habilita el servicio para que arranque con el sistema.
#
# restart:
#   Inicia el servicio o reinicia la instancia existente.
#
# Si el inicio falla, se muestran los últimos registros para
# ayudar a identificar errores de configuración o ejecución.
# ------------------------------------------------------------

paso "3/4" "🔄 Activando el servicio BHTTP"

info "Recargando las unidades de systemd..."

if ! systemctl daemon-reload; then
  rojo "Falló la recarga de systemd."
  exit 1
fi

verde "Systemd actualizado."

info "Habilitando el inicio automático..."

if ! systemctl enable "$SERVICE" >/dev/null; then
  rojo "No se pudo habilitar el servicio."
  exit 1
fi

verde "Inicio automático habilitado."

info "Iniciando el servidor..."

if ! systemctl restart "$SERVICE"; then
  rojo "No se pudo iniciar BHTTP."
  titulo "📋 Últimos registros del servicio"
  journalctl -u "$SERVICE" -n 30 --no-pager
  exit 1
fi

# Espera hasta diez segundos para que systemd inicie el proceso
# y el puerto seleccionado aparezca entre los sockets en escucha.
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
  rojo "El servicio no está escuchando correctamente."
  titulo "📋 Últimos registros del servicio"
  journalctl -u "$SERVICE" -n 30 --no-pager
  exit 1
fi

verde "BHTTP está activo en el puerto $PUERTO."

# ------------------------------------------------------------
# VERIFICACION LOCAL DEL PROTOCOLO BHTTP
# ------------------------------------------------------------
# Esta prueba intenta comprobar localmente el protocolo mediante
# el puerto de escucha. No sustituye una prueba real desde una
# aplicación externa ni garantiza el acceso desde Internet.
#
# Se comprueban:
#   1. El handshake BHP1.
#   2. La respuesta al registro de sesión.
#   3. La comunicación de prueba con el backend SSH.
#   4. El formato de una respuesta de descarga.
#
# Si el servidor responde al handshake pero no entrega un banner
# SSH, se distingue esa situación de un error de handshake.
# ------------------------------------------------------------

paso "4/4" "🧪 Verificando el protocolo BHTTP"

info "Ejecutando las pruebas locales..."
info "Esto puede tardar unos segundos."

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
    # 1. Handshake BHP1.
    payload = MAGIC + bytes([1, 0]) + (0).to_bytes(4, "big")

    with open_sock() as sock:
        send(sock, 0, 0, mask(payload, 0, 0, 0))
        status, body = response(sock)

    if status != 0 or mask(body, 0, 0, 1)[:4] != MAGIC:
        raise RuntimeError("handshake no valido")

    print("HANDSHAKE_OK")

    # 2. Registro de sesión.
    with open_sock() as sock:
        send(sock, 1, 0)
        status, _ = response(sock)

    if status != 0:
        raise RuntimeError("registro no valido")

    # 3. Envía una cadena SSH de prueba por el modo de subida.
    # Esta prueba no inicia una sesión SSH autenticada.
    with open_sock() as sock:
        sock.settimeout(5)
        send(
            sock, 1, 0,
            mask(b"SSH-2.0-Test\r\n", 1, 0, 0)
        )
        response(sock)

    # 4. Comprueba la estructura de una respuesta de descarga.
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

if [ -n "$VERIF" ]; then
  while IFS= read -r linea; do
    case "$linea" in
      HANDSHAKE_OK)
        verde "Handshake BHP1: correcto."
        ;;
      TUNEL_OK)
        verde "Comunicación con el backend: correcta."
        ;;
      TUNEL_SIN_BANNER)
        amarillo "El protocolo respondió, pero no se recibió el banner SSH."
        ;;
      BANNER=*)
        info "Respuesta del backend: ${linea#BANNER=}"
        ;;
      ERROR=*)
        rojo "Error en la prueba: ${linea#ERROR=}"
        ;;
      *)
        info "$linea"
        ;;
    esac
  done <<< "$VERIF"
else
  rojo "No se obtuvo una respuesta de la prueba local."
fi

# ------------------------------------------------------------
# MOSTRAR DATOS DE CONEXION Y RESULTADO FINAL
# ------------------------------------------------------------
# Primero intenta obtener la IP pública mediante un servicio HTTP.
# Si no está disponible, utiliza la primera dirección que reporte
# hostname -I como alternativa.
#
# La IP y el puerto mostrados son los datos de conexión del
# servidor; el acceso externo también depende de las reglas de
# firewall y de la red del proveedor.
# ------------------------------------------------------------

echo
titulo "🌍 Información de conexión"

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

if command -v curl >/dev/null 2>&1; then
  PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$PUBLIC_IP" ] && IP="$PUBLIC_IP"
fi

if echo "$VERIF" | grep -q HANDSHAKE_OK; then
  printf '\n%b╭──────────────────────────────────────────────────╮%b\n' \
    "$VERDE" "$RESET"
  printf '%b│%b  ✅ %bBHTTP INSTALADO CORRECTAMENTE%b              %b│%b\n' \
    "$VERDE" "$RESET" "$NEGRITA$BLANCO" "$RESET" "$VERDE" "$RESET"
  printf '%b╰──────────────────────────────────────────────────╯%b\n' \
    "$VERDE" "$RESET"

  echo
  printf '  %b🌐 Host%b       : %s\n' "$CIAN" "$RESET" "${IP:-IP_DE_TU_VPS}"
  printf '  %b🔌 Puerto%b     : %s\n' "$CIAN" "$RESET" "$PUERTO"
  printf '  %b🔐 Protocolo%b  : bhttp\n' "$CIAN" "$RESET"
  printf '  %b🎯 Backend%b    : 127.0.0.1:%s\n' "$CIAN" "$RESET" "$SSHPORT"
  printf '  %b⚙️  Servicio%b   : %s\n' "$CIAN" "$RESET" "$SERVICE"

  echo
  titulo "🛠️  Comandos de administración"
  separador
  info "Estado   : systemctl status bhttp"
  info "Reiniciar: systemctl restart bhttp"
  info "Detener  : systemctl stop bhttp"
  info "Registros: journalctl -u bhttp -f"
  info "Diagnóstico: bash $0 --diag --ssh-puerto $SSHPORT"
  separador

  diagnostico_ssh

  echo
  verde "Instalación finalizada."
  info "Verifica también la accesibilidad del puerto desde Internet."
else
  rojo "La verificación del protocolo no se completó correctamente."
  info "Consulta los registros con: journalctl -u bhttp -n 50 --no-pager"
  exit 1
fi
