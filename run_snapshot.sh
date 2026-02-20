#!/usr/bin/env bash
set -euo pipefail

LABEL="${1:-snapshot}"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_BASE="${2:-$HOME/testes-jvm}"
OUT_DIR="${OUT_BASE}/${LABEL}_${TS}"

mkdir -p "$OUT_DIR"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "Saída: $OUT_DIR"

# =========
# SISTEMA
# =========
{
  echo "=== DATE ==="
  date
  echo
  echo "=== UPTIME ==="
  uptime
  echo
  echo "=== KERNEL ==="
  uname -a
  echo
  echo "=== CPU ==="
  lscpu || true
  echo
  echo "=== MEMORY (free -h) ==="
  free -h
  echo
  echo "=== SWAP (swapon --show) ==="
  swapon --show || true
  echo
  echo "=== SWAPPINESS ==="
  cat /proc/sys/vm/swappiness 2>/dev/null || true
  echo
  echo "=== DISK (df -h) ==="
  df -h
} > "$OUT_DIR/sistema.txt"

# vmstat (10 segundos)
log "Coletando vmstat (10s)..."
vmstat 1 10 > "$OUT_DIR/vmstat_1s_10s.txt" || true

# top batch
log "Coletando top (processos)..."
top -b -n 1 > "$OUT_DIR/top.txt" || true

# =========
# PROCESSOS JAVA: detectar JBoss / Tomcat / IDEs etc.
# =========
log "Coletando lista de processos Java..."
ps -eo pid,ppid,comm,etimes,args --sort=etimes \
  | grep -E "java|jboss|wildfly|tomcat|catalina|idea|IntelliJ" \
  | grep -v grep \
  > "$OUT_DIR/java_processos.txt" || true

# =========
# DETECTAR CANDIDATOS (PIDs Java)
# =========
mapfile -t JAVA_PIDS < <(pgrep -f "java" || true)

# Separar "tomcat/jboss" por heurística no cmdline
mkdir -p "$OUT_DIR/pids"
for PID in "${JAVA_PIDS[@]}"; do
  CMDLINE="$(tr '\0' ' ' < /proc/$PID/cmdline 2>/dev/null || true)"
  [[ -z "$CMDLINE" ]] && continue

  ROLE="java"
  if echo "$CMDLINE" | grep -qiE "catalina|tomcat|org\.apache\.catalina"; then ROLE="tomcat"; fi
  if echo "$CMDLINE" | grep -qiE "jboss|wildfly|standalone\.sh|org\.jboss"; then ROLE="jboss"; fi
  if echo "$CMDLINE" | grep -qiE "idea|intellij"; then ROLE="intellij"; fi

  PID_DIR="$OUT_DIR/pids/${ROLE}_${PID}"
  mkdir -p "$PID_DIR"

  echo "$CMDLINE" > "$PID_DIR/cmdline.txt"

  # Snapshot básico do processo
  {
    echo "=== ps ==="
    ps -p "$PID" -o pid,ppid,etime,%cpu,%mem,rss,vsz,comm,args
    echo
    echo "=== /proc/status ==="
    cat "/proc/$PID/status" 2>/dev/null || true
    echo
    echo "=== /proc/smaps_rollup ==="
    cat "/proc/$PID/smaps_rollup" 2>/dev/null || true
  } > "$PID_DIR/proc_snapshot.txt" 2>/dev/null || true

  # jcmd (pode falhar se permissão/Java diferente)
  if command -v jcmd >/dev/null 2>&1; then
    jcmd "$PID" VM.flags > "$PID_DIR/jcmd_VM.flags.txt" 2>/dev/null || true
    jcmd "$PID" GC.heap_info > "$PID_DIR/jcmd_GC.heap_info.txt" 2>/dev/null || true
    jcmd "$PID" VM.system_properties > "$PID_DIR/jcmd_VM.system_properties.txt" 2>/dev/null || true

    # NMT só sai se NativeMemoryTracking estiver ligado
    jcmd "$PID" VM.native_memory summary > "$PID_DIR/jcmd_NMT_summary.txt" 2>/dev/null || true
    jcmd "$PID" VM.native_memory detail > "$PID_DIR/jcmd_NMT_detail.txt" 2>/dev/null || true
  fi

  # Verificar limites de cgroup (se estiver em container ou restrição)
  if [[ -f /proc/$PID/cgroup ]]; then
    cat /proc/$PID/cgroup > "$PID_DIR/cgroup.txt" 2>/dev/null || true
  fi
done

# =========
# TOMCAT/JBOSS: capturar configs se você apontar caminhos (opcional)
# =========
# Você pode exportar variáveis antes de rodar:
# export JBOSS_HOME=/caminho/jboss
# export CATALINA_HOME=/caminho/tomcat

if [[ -n "${JBOSS_HOME:-}" && -d "${JBOSS_HOME:-}" ]]; then
  log "JBOSS_HOME detectado: $JBOSS_HOME (coletando configs principais)"
  mkdir -p "$OUT_DIR/configs/jboss"
  ( ls -la "$JBOSS_HOME" > "$OUT_DIR/configs/jboss/ls.txt" ) || true

  # confs típicas
  for f in \
    "$JBOSS_HOME/bin/standalone.conf" \
    "$JBOSS_HOME/bin/domain.conf" \
    "$JBOSS_HOME/standalone/configuration/standalone.xml" \
    "$JBOSS_HOME/domain/configuration/domain.xml"
  do
    [[ -f "$f" ]] && cp -a "$f" "$OUT_DIR/configs/jboss/" || true
  done
fi

if [[ -n "${CATALINA_HOME:-}" && -d "${CATALINA_HOME:-}" ]]; then
  log "CATALINA_HOME detectado: $CATALINA_HOME (coletando configs principais)"
  mkdir -p "$OUT_DIR/configs/tomcat"
  ( ls -la "$CATALINA_HOME" > "$OUT_DIR/configs/tomcat/ls.txt" ) || true

  for f in \
    "$CATALINA_HOME/bin/setenv.sh" \
    "$CATALINA_HOME/bin/catalina.sh" \
    "$CATALINA_HOME/conf/server.xml" \
    "$CATALINA_HOME/conf/context.xml"
  do
    [[ -f "$f" ]] && cp -a "$f" "$OUT_DIR/configs/tomcat/" || true
  done
fi

log "OK. Snapshot concluído."
echo "$OUT_DIR"