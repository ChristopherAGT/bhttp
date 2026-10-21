
#!/usr/bin/env bash

set -uo pipefail

DESTDIR="/usr/local/lib/bhttp"
UNIT="/etc/systemd/system/bhttp.service"
SERVICE="bhttp"
SYSCTL_FILE="/etc/sysctl.d/99-bhttp.conf"
LIMITS_FILE="/etc/security/limits.d/99-bhttp.conf"

rojo()  { printf '\033[31m%s\033[0m\n' "$*"; }
verde() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
paso()  { printf '\n[%s] %s\n' "$1" "$2"; }

# ------------------------------------------------------------
# Comprobar permisos
# ------------------------------------------------------------

if [ "$(id -u)" != 0 ]; then
  rojo "Ejecutalo como root: sudo bash $0"
  exit 2
fi

echo "=== Desinstalador BHTTP ==="

# ------------------------------------------------------------
# Confirmar desinstalacion
# ------------------------------------------------------------

if [ -t 0 ]; then
  echo
  info "Se eliminaran los siguientes componentes:"
  info "Servicio:       $SERVICE"
  info "Unidad:         $UNIT"
  info "Servidor:       $DESTDIR"
  info "Ajustes TCP:    $SYSCTL_FILE"
  info "Limites nofile: $LIMITS_FILE"
  echo
  read -r -p "¿Deseas continuar? [s/N]: " RESPUESTA

  case "$RESPUESTA" in
    [sS]|[sS][iI])
      ;;
    *)
      info "Desinstalacion cancelada"
      exit 0
      ;;
  esac
fi

# ------------------------------------------------------------
# Detener y deshabilitar el servicio
# ------------------------------------------------------------

paso "1/4" "Deteniendo servicio"

if systemctl list-unit-files "$SERVICE.service" --no-legend \
  2>/dev/null | grep -q "^${SERVICE}.service"; then

  systemctl disable --now "$SERVICE" 2>/dev/null || true
  verde "Servicio detenido y deshabilitado"
else
  info "La unidad no figura en la lista de servicios instalados"
  systemctl stop "$SERVICE" 2>/dev/null || true
fi

# ------------------------------------------------------------
# Eliminar unidad systemd
# ------------------------------------------------------------

paso "2/4" "Eliminando unidad de systemd"

if [ -f "$UNIT" ]; then
  rm -f "$UNIT" || {
    rojo "No se pudo eliminar $UNIT"
    exit 1
  }
  info "Unidad eliminada"
else
  info "La unidad ya no existe"
fi

if ! systemctl daemon-reload; then
  rojo "No se pudo recargar systemd"
  exit 1
fi

systemctl reset-failed "$SERVICE" 2>/dev/null || true

# ------------------------------------------------------------
# Eliminar archivos de BHTTP
# ------------------------------------------------------------

paso "3/4" "Eliminando archivos de BHTTP"

if [ -d "$DESTDIR" ]; then
  rm -rf -- "$DESTDIR" || {
    rojo "No se pudo eliminar $DESTDIR"
    exit 1
  }
  info "Servidor Python y archivos de BHTTP eliminados"
else
  info "El directorio del servidor ya no existe"
fi

# ------------------------------------------------------------
# Eliminar configuraciones creadas por el instalador
# ------------------------------------------------------------

paso "4/4" "Eliminando configuraciones"

if [ -f "$SYSCTL_FILE" ]; then
  rm -f "$SYSCTL_FILE" || {
    rojo "No se pudo eliminar $SYSCTL_FILE"
    exit 1
  }
  info "Archivo de ajustes TCP eliminado"
else
  info "No existe el archivo de ajustes TCP"
fi

if [ -f "$LIMITS_FILE" ]; then
  rm -f "$LIMITS_FILE" || {
    rojo "No se pudo eliminar $LIMITS_FILE"
    exit 1
  }
  info "Archivo de limites nofile eliminado"
else
  info "No existe el archivo de limites nofile"
fi

# Intentar restaurar los valores sysctl definidos por
# los archivos restantes del sistema.
if command -v sysctl >/dev/null 2>&1; then
  sysctl --system >/dev/null 2>&1 || {
    info "Algunos ajustes del sistema no pudieron recargarse"
  }
fi

# ------------------------------------------------------------
# Resultado
# ------------------------------------------------------------

echo
verde "=== BHTTP desinstalado ==="
echo
info "Servicio bhttp detenido y eliminado"
info "Archivos del servidor eliminados"
info "Configuraciones creadas por el instalador eliminadas"
echo
info "No se eliminaron usuarios SSH ni sus claves"
info "No se modificaron otros servicios"
info "Los cambios TCP activos pueden requerir reiniciar"
info "El limite nofile de sesiones existentes puede persistir"
echo
