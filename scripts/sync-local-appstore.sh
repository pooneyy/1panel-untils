#!/usr/bin/env bash

set -Eeuo pipefail

_detected_self="${BASH_SOURCE[0]:-$0}"
case "$_detected_self" in
  /dev/fd/*|/proc/self/fd/*|*/dev/fd/*|/dev/stdin|/dev/tty|bash|sh|*/bash|*/sh|"")
    _SELF_NAME="sync-local-appstore.sh" ;;
  *) _SELF_NAME="$(basename "$_detected_self")" ;;
esac
readonly SCRIPT_NAME="$_SELF_NAME"

PCTL="/usr/local/bin/1pctl"
AGENT_SOCK="/etc/1panel/agent.sock"
HEALTH_PATH="/api/v2/health/check"
SYNC_PATH="/api/v2/apps/sync/local"
TASK_PATH="/api/v2/logs/tasks/search"

BASE_DIR=""
SOURCE_DIR=""
RUN_DIR=""
TASK_DB=""
AGENT_DB=""
ROLE=""
DIAG_DIR=""

CHECK_ONLY=false
ASSUME_YES=false
WAIT_SECS=180
DEBUG=false
DB_SNAPSHOT_BEFORE=""
DB_FP_BEFORE=""
DB_CHANGED="unknown"
TRIGGER_BODY_UNKNOWN=false

OFFLINE=false
OFFLINE_APPLY=false
OFFLINE_PRUNE=false
OFFLINE_REFRESH_PARAMS=false
OFFLINE_BACKUP_DIR=""
CLEAR_DB_BAK=false

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()   { printf '[%s] %s\n' "$(_ts)" "$*"; }
info()  { printf '[%s] [INFO]  %s\n' "$(_ts)" "$*"; }
warn()  { printf '[%s] [WARN]  %s\n' "$(_ts)" "$*" >&2; }
err()   { printf '[%s] [ERROR] %s\n' "$(_ts)" "$*" >&2; }
die()   { err "$*"; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
step()  { printf '\n[%s] ===== %s =====\n' "$(_ts)" "$*"; }

trap 'err "脚本在第 ${LINENO} 行异常退出"; exit 1' ERR

cleanup() {
  if [ -n "$DIAG_DIR" ] && [ -d "$DIAG_DIR" ]; then
    rm -rf -- "$DIAG_DIR" || true
  fi
}
trap cleanup EXIT

conf_get() {
  local file="$1" key="$2" line val
  [ -f "$file" ] || return 1
  line="$(grep -m1 "^${key}=" "$file" 2>/dev/null || true)"
  [ -n "$line" ] || return 1
  val="${line#*=}"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

gen_task_id() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif have uuidgen; then
    uuidgen
  elif have openssl; then
    openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
  else
    printf '%s' "$(date +%s%N)$$" | md5sum | cut -c1-32
  fi
}

json_get() {
  local json="$1" path="$2" key val out
  if have python3; then
    out="$(python3 -c '
import sys, json
try:
  d = json.load(sys.stdin)
  for k in sys.argv[1].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
  if d is None:
    sys.exit(0)
  print(d if not isinstance(d, (dict, list)) else json.dumps(d, ensure_ascii=False))
except Exception:
  sys.exit(1)
' "$path" <<<"$json" 2>/dev/null || true)"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  fi
  key="${path##*.}"
  val="$(printf '%s' "$json" | grep -o "\"${key}\"[: ]*[^,}]*" | head -n1 || true)"
  printf '%s' "$val" | sed "s/^\"${key}\"[: ]*//; s/^\"//; s/\"$//; s/^[[:space:]]*//"
}

json_is_valid() {
  have python3 || return 1
  python3 -c 'import json,sys; json.load(sys.stdin)' <<<"$1" >/dev/null 2>&1
}

print_raw() {
  local label="$1" raw="$2" limit=300 n
  if [ "$DEBUG" = true ]; then limit=800; fi
  n="$(printf '%s' "$raw" | wc -c)"
  info "$label 原始响应 (${n} 字节): $(printf '%s' "$raw" | head -c "$limit")"
}

print_headers() {
  local label="$1" f="$DIAG_DIR/headers" line n=0
  [ -n "$DIAG_DIR" ] && [ -r "$f" ] || return 0
  info "$label 响应头:"
  while IFS= read -r line && [ "$n" -lt 25 ]; do
    line="${line%$'\r'}"
    if [ -n "$line" ]; then info "  $line"; fi
    n=$((n + 1))
  done < "$f"
}

db_fingerprint() {
  local db="$1"
  [ -r "$db" ] || return 1
  have python3 || return 1
  python3 - "$db" <<'PY' 2>/dev/null || return 1
import hashlib, sqlite3, sys
try:
  con = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
  h = hashlib.sha256()
  for t in ('apps', 'app_details', 'app_tags'):
    cols = [r[1] for r in con.execute('PRAGMA table_info(%s)' % t)]
    if not cols:
      h.update((t + ':MISSING\n').encode())
      continue
    rows = con.execute('SELECT * FROM %s ORDER BY 1' % t).fetchall()
    h.update((t + '|' + ','.join(cols) + '|%d\n' % len(rows)).encode())
    for row in rows:
      h.update(repr(row).encode())
      h.update(b'\n')
  print(h.hexdigest()[:16])
except Exception:
  raise SystemExit(1)
PY
}

db_local_apps() {
  local db="$1"
  [ -r "$db" ] || return 1
  have python3 || return 1
  python3 - "$db" <<'PY' 2>/dev/null || return 1
import sqlite3, sys
try:
  con = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
  rows = con.execute("select key from apps where resource = ? order by key", ('local',)).fetchall()
  keys = [r[0] for r in rows]
  print('%d|%s' % (len(keys), ','.join(keys)))
except Exception:
  raise SystemExit(1)
PY
}

task_db_status() {
  local db="$1" tid="$2"
  [ -r "$db" ] || return 1
  have python3 || return 1
  python3 - "$db" "$tid" <<'PY' 2>/dev/null || return 1
import sqlite3, sys
try:
  con = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
  row = con.execute('select status, error_msg, name from tasks where id = ?', (sys.argv[2],)).fetchone()
  if row:
    print('%s|%s|%s' % (row[0] or '', (row[1] or '').replace('\n', ' '), row[2] or ''))
except Exception:
  raise SystemExit(1)
PY
}

usage() {
  cat <<EOF
同步 1Panel 当前节点的本地应用

用法:
  bash ${SCRIPT_NAME} [选项]

角色差异:
  master  主节点   -> Unix socket /etc/1panel/agent.sock (免认证)
  node    子节点   -> 直接写入数据库 agent.db

运行范围
  -s, --source <dir>      本地应用源目录 (默认 \$BASE_DIR/1panel/resource/apps/local)
  -b, --base-dir <dir>    覆盖安装根目录 (默认自动探测 agent.db 所在位置;
                          子节点没有 1pctl 也能识别, 常见为 /opt)
      --check             只做环境检查与目录预检, 不触发同步
  -y, --yes               跳过交互确认

数据库直写模式 (--offline, 子节点默认自动启用)
      --offline           将会直接向 agent.db 写入数据, 不依赖 agent 服务,
                          默认只读预览, 不写任何数据
                          在子节点上无需显式指定, 子节点仅支持 offline 模式
      --apply             配合 --offline 写入数据库, 写前自动备份
      --prune             配合 --offline --apply, 允许物理删除目录中已移除
                          且无安装实例的本地应用/版本 (默认只标记 TakeDown)
      --refresh-params    配合 --offline --apply, 强制刷新已有版本的安装表单
                          params (默认保留库中原值, 规避 YAML 近似解析风险)
      --backup-dir <dir>  --apply 时备份文件存放目录 (默认 agent.db 所在目录)
      --clear-db-bak      清除历史同步备份 agent.db.syncbak.*
                          默认 agent.db 所在目录, 可用 --backup-dir 指定

示例
  bash ${SCRIPT_NAME} --check                      # 只读预览
  bash ${SCRIPT_NAME} --yes                        # 主节点通过 socket; 子节点预览
  bash ${SCRIPT_NAME} --apply --yes                # 任意节点同步本地应用商店
  bash ${SCRIPT_NAME} --offline --apply --yes      # 离线的方式写入数据库 (任意节点)
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    if [[ "$1" =~ ^(-s|--source|-b|--base-dir|--socket|--wait|--backup-dir)$ ]]; then
      [ "$#" -ge 2 ] || die "$1 需要参数"
      [ -n "$2" ] || die "$1 参数不能为空"
    fi
    case "$1" in
      -s|--source)        SOURCE_DIR="$2"; shift 2 ;;
      -b|--base-dir)      BASE_DIR="$2"; shift 2 ;;
      --socket)           AGENT_SOCK="$2"; shift 2 ;;
      --check)            CHECK_ONLY=true; shift ;;
      --yes|-y)           ASSUME_YES=true; shift ;;
      --wait)             WAIT_SECS="$2"; shift 2 ;;
      --debug)            DEBUG=true; shift ;;
      --offline)          OFFLINE=true; shift ;;
      --apply)            OFFLINE_APPLY=true; shift ;;
      --prune)            OFFLINE_PRUNE=true; shift ;;
      --refresh-params)   OFFLINE_REFRESH_PARAMS=true; shift ;;
      --backup-dir)       OFFLINE_BACKUP_DIR="$2"; shift 2 ;;
      --clear-db-bak)     CLEAR_DB_BAK=true; shift ;;
      -h|--help)          usage; exit 0 ;;
      *)                  die "未知参数: $1 (用 --help 查看用法)" ;;
    esac
  done
  [[ "$WAIT_SECS" =~ ^[0-9]+$ ]] || die "--wait 必须是非负整数"
}

resolve_base_dir() {
  local db="" c pid env_line sbd fa=()

  if [ -n "$BASE_DIR" ]; then
    [[ "$BASE_DIR" = /* ]] || die "BASE_DIR 必须是绝对路径: $BASE_DIR"
    db="$BASE_DIR/1panel/db/agent.db"
    [ -r "$db" ] || die "$BASE_DIR 下未找到可读的 agent.db: $db (请用 --base-dir 指定正确安装根目录)"
    info "安装根目录      : $BASE_DIR (--base-dir)"
    return 0
  fi

  if [ -r "$PCTL" ]; then
    c="$(conf_get "$PCTL" BASE_DIR || true)"
    if [ -n "$c" ] && [[ "$c" = /* ]] && [ -r "$c/1panel/db/agent.db" ]; then
      BASE_DIR="$c"
      db="$BASE_DIR/1panel/db/agent.db"
      info "安装根目录      : $BASE_DIR (1pctl BASE_DIR)"
    fi
  fi

  if [ -z "$BASE_DIR" ]; then
    for c in /opt /usr/local /home/1panel /data /www /srv; do
      if [ -r "$c/1panel/db/agent.db" ]; then
        BASE_DIR="$c"
        db="$BASE_DIR/1panel/db/agent.db"
        info "安装根目录      : $BASE_DIR (自动探测)"
        break
      fi
    done
  fi

  if [ -z "$BASE_DIR" ] && have pgrep; then
    for pid in $(pgrep -f '1panel-agent' 2>/dev/null || true); do
      [ -r "/proc/$pid/environ" ] || continue
      env_line="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -m1 '^BASE_DIR=' || true)"
      c="${env_line#BASE_DIR=}"
      if [ -n "$c" ] && [[ "$c" = /* ]] && [ -r "$c/1panel/db/agent.db" ]; then
        BASE_DIR="$c"
        db="$BASE_DIR/1panel/db/agent.db"
        info "安装根目录      : $BASE_DIR (agent 进程环境)"
        break
      fi
    done
  fi

  if [ -z "$BASE_DIR" ] && have find; then
    fa=(find /opt /usr /home /data /www /srv /mnt -maxdepth 6
      -type f -path '*/1panel/db/agent.db' -print -quit)
    if have timeout; then
      fa=(timeout 8 "${fa[@]}")
    fi
    db="$("${fa[@]}" 2>/dev/null || true)"
    if [ -n "$db" ] && [ -r "$db" ]; then
      BASE_DIR="$(dirname "$(dirname "$(dirname "$db")")")"
      info "安装根目录      : $BASE_DIR (路径查找 $db)"
    fi
  fi

  [ -n "$BASE_DIR" ] || die "未找到 agent.db: 被纳管子节点通常没有 $PCTL, 请用 --base-dir 指定安装根目录 (例如 --base-dir /opt)"
  [[ "$BASE_DIR" = /* ]] || die "BASE_DIR 必须是绝对路径: $BASE_DIR"
  [ -n "$db" ] || db="$BASE_DIR/1panel/db/agent.db"
  [ -r "$db" ] || die "agent.db 不可读: $db"

  if have python3; then
    sbd="$(python3 -c '
import sqlite3, sys
try:
  con = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
  row = con.execute("select value from settings where key = ?", ("BaseDir",)).fetchone()
  print(row[0] if row else "")
except Exception:
  print("")
' "$db" 2>/dev/null || true)"
    if [ -n "$sbd" ] && [[ "$sbd" = /* ]] && [ "$sbd" != "$BASE_DIR" ] \
      && [ -r "$sbd/1panel/db/agent.db" ]; then
      info "安装根目录      : 按 settings.BaseDir 校正为 $sbd"
      BASE_DIR="$sbd"
    fi
  fi
}

detect_role() {
  local db="$RUN_DIR/db/agent.db" scope=""
  if [ -r "$db" ] && have python3; then
    scope="$(python3 -c '
import sqlite3, sys
try:
  con = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
  row = con.execute("select value from settings where key = ?", ("NodeScope",)).fetchone()
  print(row[0] if row else "")
except Exception:
  print("")
' "$db" 2>/dev/null || true)"
  fi

  if [ "$scope" = "master" ] || { [ -z "$scope" ] && [ -S "$AGENT_SOCK" ]; }; then
    ROLE="master"
  else
    ROLE="node"
  fi
  info "节点角色        : $ROLE"
}

preflight_base() {
  step "环境检查"

  [ "$(id -u)" -eq 0 ] || die "必须以 root 运行 (bash $SCRIPT_NAME ...)"

  resolve_base_dir
  RUN_DIR="$BASE_DIR/1panel"
  AGENT_DB="$RUN_DIR/db/agent.db"
  TASK_DB="$RUN_DIR/db/task.db"

  [ -n "$SOURCE_DIR" ] || SOURCE_DIR="$RUN_DIR/resource/apps/local"
}

preflight_channel() {
  have curl || die "缺少 curl"

  DIAG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sync-local-appstore-diag.XXXXXX")" || die "无法创建诊断临时目录"
  chmod 700 "$DIAG_DIR"

  [ -d "$SOURCE_DIR" ] || warn "本地应用源目录不存在: $SOURCE_DIR (同步将为空操作)"

  info "应用源目录      : $SOURCE_DIR"
  info "目标范围        : 仅当前节点"
  if [ -r "$TASK_DB" ]; then
    info "任务库          : $TASK_DB (可读)"
  else
    warn "任务库不可读    : $TASK_DB (将无法用本机库判定任务状态)"
  fi
}

channel_unavailable() {
  err "agent Unix socket 不可用: $AGENT_SOCK"
  err "  排查: 1) systemctl status 1panel-agent   2) 路径不对用 --socket <path>   3) 仅主节点监听该 socket"
  err "  本脚本仅走主节点本机 Unix socket 通道, 不提供跨节点 / 面板 API 回退"
  exit 1
}

verify_channel() {
  local code
  [ -S "$AGENT_SOCK" ] || channel_unavailable
  code="$(curl -sS --max-time 5 --unix-socket "$AGENT_SOCK" \
    -o /dev/null -w '%{http_code}' "http://localhost${HEALTH_PATH}" 2>/dev/null || true)"
  [ -n "$code" ] && [ "$code" != "000" ] || channel_unavailable
  info "触发通道      : agent Unix socket -> $AGENT_SOCK"
  return 0
}

scan_source() {
  step "本地应用目录预检"
  local app_dir key missing versions valid vdir vkey vmissing total=0 ok=0 bad=0 warns=0 note

  if [ ! -d "$SOURCE_DIR" ]; then
    warn "源目录不存在, 跳过预检"
    return 0
  fi

  printf '  %-28s %-8s %-10s %s\n' '应用 Key' '版本数' '判定' '备注'
  printf '  %-28s %-8s %-10s %s\n' '----------------------------' '--------' '----------' '--------------------'

  for app_dir in "$SOURCE_DIR"/*; do
    [ -d "$app_dir" ] || continue
    key="${app_dir##*/}"
    total=$((total + 1))
    missing=""
    [ -f "$app_dir/data.yml" ] || missing="缺 data.yml"
    [ -f "$app_dir/logo.png" ] || missing="${missing:+$missing, }缺 logo.png"

    versions=0; valid=0; vmissing=""
    for vdir in "$app_dir"/*/; do
      [ -d "$vdir" ] || continue
      versions=$((versions + 1))
      vkey="${vdir%/}"; vkey="${vkey##*/}"
      [ -f "$vdir/docker-compose.yml" ] || vmissing="${vmissing:+$vmissing, }${vkey}:缺 compose"
      [ -f "$vdir/data.yml" ]          || vmissing="${vmissing:+$vmissing, }${vkey}:缺 data.yml"
      if [ -f "$vdir/docker-compose.yml" ] && [ -f "$vdir/data.yml" ]; then
        valid=$((valid + 1))
      fi
    done

    note=""
    if [ -n "$missing" ] || [ "$valid" -eq 0 ]; then
      bad=$((bad + 1))
      printf '  %-28s %-8s %-10s %s\n' "$key" "$versions" '将被跳过' \
        "${missing:-无有效版本}${vmissing:+(版本问题: $vmissing)}"
    else
      ok=$((ok + 1))
      if grep -qE '^[[:space:]]*key[[:space:]]*:[[:space:]]*local' "$app_dir/data.yml" 2>/dev/null; then
        note="警告: data.yml 的 key 带了 local 前缀"
        warns=$((warns + 1))
      fi
      printf '  %-28s %-8s %-10s %s\n' "$key" "$versions" "$([ -n "$note" ] && echo '警告' || echo 'OK')" "${note:-有效版本 $valid}"
    fi
  done

  info "合计: ${total} 个应用目录, ${ok} 个可用, ${bad} 个会被跳过, ${warns} 个警告"
  [ "$total" -gt 0 ] || warn "源目录为空: 同步会清空/下架已有的本地应用 (官方 diff 逻辑会把 DB 中旧 local 应用标记废弃)"
  if [ "$bad" -gt 0 ]; then
    warn "被跳过的应用不会阻断同步, 官方会往任务日志写 LocalAppErr / LocalAppVersionErr"
  fi
}

api_post() {
  local path="$1" body="$2" timeout="${3:-30}"
  curl -sS --max-time "$timeout" \
    --unix-socket "$AGENT_SOCK" -D "$DIAG_DIR/headers" \
    -H 'Content-Type: application/json' -d "$body" \
    -w '\n%{http_code}' "http://localhost${path}"
}

probe_task_query() {
  local body resp code raw rcode=""
  body='{"page":1,"pageSize":1}'
  resp="$(api_post "$TASK_PATH" "$body" 10 2>/dev/null || true)"
  if [ -z "$resp" ]; then
    warn "任务查询探测: 无响应 (curl 失败或连接被重置), 脚本将只用本机 task.db 判定"
    return 0
  fi
  code="$(printf '%s' "$resp" | tail -n1)"
  raw="$(printf '%s' "$resp" | sed '$d')"
  if json_is_valid "$raw"; then
    rcode="$(json_get "$raw" code 2>/dev/null || true)"
  fi
  if [ "$code" = "200" ] && [ "$rcode" = "200" ]; then
    info "任务查询探测  : 可用 (HTTP 200 / code 200 / total $(json_get "$raw" data.total 2>/dev/null || printf '?'))"
  else
    warn "任务查询探测: 异常 (HTTP ${code:-000} / code ${rcode:-<空或非法 JSON>}), 脚本将只用本机 task.db 判定"
    print_raw "任务查询探测" "$raw"
    print_headers "任务查询探测"
    if [ -z "$raw" ]; then
      if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
        warn "子节点业务接口返回 ${code} 空响应体: 开源源码中 Success()/health 必返回 JSON,"
        warn "  该请求可能未进入 agent 业务路由 (前置层静默受理), 最终以 agent.db 写入为准"
      else
        warn "子节点业务接口未建立有效响应 (HTTP ${code:-000}): 连接可能被服务端断开"
      fi
    fi
  fi
}

trigger_sync() {
  local task_id="$1" body resp code raw rcode=""
  body="$(printf '{"taskID":"%s"}' "$task_id")"

  resp="$(api_post "$SYNC_PATH" "$body" 30)" || \
    { err "无法连接本机 agent 通道 (角色: $ROLE)"; print_headers "触发"; return 1; }

  code="$(printf '%s' "$resp" | tail -n1)"
  raw="$(printf '%s' "$resp" | sed '$d')"
  if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
    err "触发失败 (HTTP ${code:-<空>})"
    print_raw "触发" "$raw"
    print_headers "触发"
    return 1
  fi

  if ! json_is_valid "$raw"; then
    TRIGGER_BODY_UNKNOWN=true
    warn "触发响应体为空或非 JSON (HTTP $code), 不据此判定成败"
    warn "将以本机 task.db 任务状态 + agent.db 应用表内容为准"
    print_raw "触发" "$raw"
    print_headers "触发"
    return 0
  fi

  rcode="$(json_get "$raw" code)"
  if [ "$rcode" != "200" ]; then
    err "接口返回错误 code=${rcode:-<缺失>}: $(json_get "$raw" message)"
    print_raw "触发" "$raw"
    print_headers "触发"
    return 1
  fi
  if [ "$DEBUG" = true ]; then print_raw "触发" "$raw"; print_headers "触发"; fi
  return 0
}

wait_task() {
  local task_id="$1" body resp code raw rcode="" total status msg logfile i=0
  local db_status db_st db_msg http_seen=0 last_http=""
  local db_path

  body="$(printf '{"taskID":"%s","page":1,"pageSize":1}' "$task_id")"

  while [ "$i" -lt "$WAIT_SECS" ]; do
    db_status="$(task_db_status "$TASK_DB" "$task_id" || true)"
    if [ -n "$db_status" ]; then
      db_st="${db_status%%|*}"
      db_msg="${db_status#*|}"; db_msg="${db_msg%%|*}"
      case "$db_st" in
        Success)
          info "任务完成        : $task_id"
          return 0 ;;
        Failed|Canceled)
          err "任务${db_st}: ${db_msg:-无错误信息} (来源 task.db)"
          return 1 ;;
        Executing|Waiting|"")
          : ;;
        *)
          info "任务状态: $db_st (来源 task.db)" ;;
      esac
    fi

    resp="$(api_post "$TASK_PATH" "$body" 15 2>/dev/null || true)"
    if [ -n "$resp" ]; then
      code="$(printf '%s' "$resp" | tail -n1)"
      raw="$(printf '%s' "$resp" | sed '$d')"
      last_http="HTTP=$code code=$(json_get "$raw" code 2>/dev/null || printf '?') total=$(json_get "$raw" data.total 2>/dev/null || printf '?') status=$(json_get "$raw" "data.items.0.status" 2>/dev/null || printf '?')"
      if [ "$code" = "200" ] && json_is_valid "$raw"; then
        rcode="$(json_get "$raw" code 2>/dev/null || true)"
        if [ "$rcode" = "200" ]; then
          total="$(json_get "$raw" data.total 2>/dev/null || true)"
          if [ -n "$total" ] && [ "$total" != "0" ]; then
            status="$(json_get "$raw" "data.items.0.status" 2>/dev/null || true)"
            case "$status" in
              Success)
                info "任务完成        : $task_id (Success, 来源 HTTP)"
                return 0 ;;
              Failed|Canceled)
                msg="$(json_get "$raw" "data.items.0.errorMsg" 2>/dev/null || true)"
                logfile="$(json_get "$raw" "data.items.0.logFile" 2>/dev/null || true)"
                err "任务${status}: ${msg:-无错误信息} (来源 HTTP)"
                if [ -n "$logfile" ]; then err "任务日志: $logfile"; fi
                return 1 ;;
            esac
          fi
        fi
      fi
      if [ "$http_seen" -eq 0 ]; then
        http_seen=1
        info "任务查询首轮诊断: $last_http"
        if [ "$code" != "200" ] || [ "$rcode" != "200" ]; then
          warn "任务查询接口未返回 code=200, 可能被子节点中间件拦截; 已改用本机 task.db 判据"
          print_raw "任务查询" "$raw"
        fi
      fi
    elif [ "$http_seen" -eq 0 ] && [ "$i" -eq 0 ]; then
      warn "任务查询接口无响应 (curl 失败或连接被重置); 已改用本机 task.db 判据"
    fi

    if [ "$i" -eq 10 ] && [ -z "$db_status" ]; then
      warn "提交后 10s 仍未在 task.db / HTTP 中查到任务记录, agent 可能未创建任务 (继续等待至 ${WAIT_SECS}s)"
    fi
    sleep 2
    i=$((i + 2))
  done

  warn "等待 ${WAIT_SECS}s 后仍未拿到任务终态 (将用 agent.db 应用表指纹做最终裁决)"
  if [ -n "$last_http" ]; then warn "任务查询末轮诊断: $last_http"; fi
  db_path="$TASK_DB"
  if [ -r "$db_path" ]; then
    warn "请检查本机任务库: $db_path (按 id='${task_id}' 查询 tasks 表)"
  else
    warn "本机任务库不可读: $db_path"
  fi
  warn "agent 日志: $RUN_DIR/log/1Panel.log (关键字 Create sync task failed / Synchronization of local applications)"
  return 2
}

verify_result() {
  local after fp_after
  DB_CHANGED="unknown"

  after="$(db_local_apps "$AGENT_DB" || true)"
  if [ -n "$after" ]; then
    info "同步后本地应用  : ${after%%|*} 个 (agent.db)"
  else
    warn "数据库验收      : 同步后无法读取 agent.db 的本地应用清单"
  fi

  fp_after="$(db_fingerprint "$AGENT_DB" || true)"
  if [ -n "$DB_FP_BEFORE" ] && [ -n "$fp_after" ]; then
    if [ "$fp_after" != "$DB_FP_BEFORE" ]; then
      DB_CHANGED=true
      info "数据库验收      : apps/app_details/app_tags 内容已变化 -> 同步确实写入了 agent.db"
    else
      DB_CHANGED=false
      info "数据库验收      : 应用表内容无变化 (可能是幂等同步, 也可能同步未执行)"
    fi
    if [ "$DEBUG" = true ]; then
      info "  指纹前: $DB_FP_BEFORE"
      info "  指纹后: $fp_after"
    fi
  else
    warn "数据库验收      : 无法计算应用表指纹 (写入检测不可用)"
  fi

  if [ -n "$DB_SNAPSHOT_BEFORE" ] && [ -n "$after" ]; then
    if [ "$after" != "$DB_SNAPSHOT_BEFORE" ]; then
      info "数据库验收      : 本地应用清单已变化"
    elif [ "$DB_CHANGED" != true ]; then
      info "数据库验收      : 本地应用清单无变化"
    fi
    if [ "$DEBUG" = true ]; then
      info "  前: ${DB_SNAPSHOT_BEFORE#*|}"
      info "  后: ${after#*|}"
    fi
  fi
  if [ -n "$after" ]; then
    info "当前本地应用清单: ${after#*|}"
  fi
}

offline_run() {
  step "数据库直写, 将写入本机 agent.db"

  local apply=0 prune=0 refresh=0 debug=0 forced_ro=0 rc=0
  if [ "$OFFLINE_APPLY" = true ]; then apply=1; fi
  if [ "$OFFLINE_PRUNE" = true ]; then prune=1; fi
  if [ "$OFFLINE_REFRESH_PARAMS" = true ]; then refresh=1; fi
  if [ "$DEBUG" = true ]; then debug=1; fi

  if [ "$CHECK_ONLY" = true ]; then
    if [ "$apply" -eq 1 ]; then
      warn "只读模式          : 已忽略 --apply, 不会写入任何数据"
    fi
    apply=0
    prune=0
    forced_ro=1
  fi

  have python3 || die "--offline 需要 python3"
  [ -r "$AGENT_DB" ] || die "agent.db 不可读: $AGENT_DB"
  [ -d "$SOURCE_DIR" ] || die "本地应用源目录不存在: $SOURCE_DIR (离线模式要求目录存在, 避免误下架全部应用)"

  info "数据库            : $AGENT_DB"
  info "应用源目录        : $SOURCE_DIR"
  info "任务日志          : 不写入"
  if [ "$apply" -eq 0 ]; then
    if [ "$forced_ro" -eq 1 ]; then
      warn "只读预览          : 不会写入任何数据"
    else
      warn "只读预览          : 不会写入任何数据; 确认计划后传入 --apply 执行"
    fi
  fi

  python3 - "$AGENT_DB" "$SOURCE_DIR" "$apply" "$prune" "$refresh" \
    "$OFFLINE_BACKUP_DIR" "$debug" "$forced_ro" <<'PYEOF' || rc=$?
import base64, datetime, json, os, re, sqlite3, sys

DB, SRC, APPLY, PRUNE, REFRESH, BACKUP_DIR, DEBUG, FORCED_RO = sys.argv[1:9]
FORCED_RO = FORCED_RO == "1"
APPLY = APPLY == "1"
PRUNE = PRUNE == "1"
REFRESH = REFRESH == "1"
DEBUG = DEBUG == "1"

def _ts():
  return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
def info(m):
  print("[%s] [INFO]  %s" % (_ts(), m), flush=True)
def warn(m):
  print("[%s] [WARN]  %s" % (_ts(), m), flush=True)
def err(m):
  print("[%s] [ERROR] %s" % (_ts(), m), file=sys.stderr, flush=True)
def die(m):
  err(m)
  sys.exit(1)

try:
  import yaml as _yaml
  HAVE_YAML = True
except Exception:
  HAVE_YAML = False

def _scalar(s):
  s = s.strip()
  if s == "":
    return ""
  if len(s) >= 2 and ((s[0] == '"' and s[-1] == '"') or (s[0] == "'" and s[-1] == "'")):
    return s[1:-1]
  low = s.lower()
  if low in ("true", "yes", "on"):
    return True
  if low in ("false", "no", "off"):
    return False
  if low in ("null", "~", "none"):
    return None
  if re.match(r"^-?\d+$", s):
    try:
      return int(s)
    except Exception:
      pass
  if re.match(r"^-?\d+\.\d+$", s):
    try:
      return float(s)
    except Exception:
      pass
  if s.startswith("[") and s.endswith("]"):
    inner = s[1:-1].strip()
    return [] if not inner else [_scalar(x) for x in inner.split(",")]
  if s.startswith("{") and s.endswith("}"):
    inner = s[1:-1].strip()
    d = {}
    if inner:
      for x in inner.split(","):
        if ":" in x:
          k, v = x.split(":", 1)
          d[str(_scalar(k))] = _scalar(v)
    return d
  return s

def _strip_comment(line):
  out, quote = "", ""
  for ch in line:
    if quote:
      out += ch
      if ch == quote:
        quote = ""
    elif ch in ('"', "'"):
      quote = ch
      out += ch
    elif ch == "#":
      break
    else:
      out += ch
  return out.rstrip()

def _mini_yaml(text):
  lines = []
  for raw in text.splitlines():
    line = _strip_comment(raw)
    if line.strip():
      lines.append((len(line) - len(line.lstrip(" ")), line.strip()))
  def block(i, ind):
    if i >= len(lines):
      return None, i
    is_list = lines[i][1] == "-" or lines[i][1].startswith("- ")
    result = [] if is_list else {}
    while i < len(lines):
      cur, txt = lines[i]
      if cur < ind:
        break
      if cur > ind:
        i += 1
        continue
      if is_list:
        item = txt[2:].strip() if txt.startswith("- ") else ""
        i += 1
        m = re.match(r"^([^:]+):\s*(.*)$", item)
        if m and not item.startswith(('"', "'")):
          d = {m.group(1).strip(): _scalar(m.group(2))}
          while i < len(lines) and lines[i][0] > ind and not lines[i][1].startswith("- "):
            sub_ind, sub_txt = lines[i]
            m2 = re.match(r"^([^:]+):\s*(.*)$", sub_txt)
            i += 1
            if not m2:
              continue
            k, v = m2.group(1).strip(), m2.group(2)
            if v == "" and i < len(lines) and lines[i][0] > sub_ind:
              sub, i = block(i, lines[i][0])
              d[k] = sub
            else:
              d[k] = _scalar(v)
          result.append(d)
        elif item == "" and i < len(lines) and lines[i][0] > ind:
          sub, i = block(i, lines[i][0])
          result.append(sub)
        else:
          result.append(_scalar(item))
      else:
        m = re.match(r"^([^:]+):\s*(.*)$", txt)
        if not m:
          i += 1
          continue
        k, v = m.group(1).strip(), m.group(2)
        i += 1
        if v == "" and i < len(lines) and lines[i][0] > ind:
          sub, i = block(i, lines[i][0])
          result[k] = sub
        elif v == "":
          result[k] = None
        else:
          result[k] = _scalar(v)
    return result, i
  val, _ = block(0, lines[0][0] if lines else 0)
  return val if isinstance(val, dict) else {}

def load_dict(path):
  try:
    with open(path, "r", encoding="utf-8") as f:
      text = f.read()
  except Exception as e:
    warn("读取失败 %s: %s" % (path, e))
    return {}
  if HAVE_YAML:
    try:
      d = _yaml.safe_load(text)
      return d if isinstance(d, dict) else {}
    except Exception:
      pass
  return _mini_yaml(text)

LOCALE_KEYS = ["en", "ja", "ms", "pt-br", "ru", "zh-hant", "zh", "ko", "tr", "es-es", "fa", "lo"]

def truthy(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return v != 0
  return str(v).strip().lower() in ("true", "yes", "on", "1")

def to_int(v):
  try:
    return int(v)
  except Exception:
    return 0

def build_app(ap, app_dir):
  key = str(ap.get("key") or "").strip()
  if not key:
    return None, "data.yml 缺少 additionalProperties.key"
  desc = ap.get("description") or {}
  if not isinstance(desc, dict):
    desc = {}
  loc = {}
  for k in LOCALE_KEYS:
    loc[k] = str(desc.get(k, "") or "")
  if ap.get("shortDescZh"):
    loc["zh"] = str(ap["shortDescZh"])
  if ap.get("shortDescEn"):
    loc["en"] = str(ap["shortDescEn"])
  icon = ""
  try:
    with open(os.path.join(app_dir, "logo.png"), "rb") as f:
      icon = base64.b64encode(f.read()).decode("ascii")
  except Exception:
    pass
  readme = ""
  rp = os.path.join(app_dir, "README.md")
  if os.path.isfile(rp):
    try:
      with open(rp, "r", encoding="utf-8") as f:
        readme = f.read()
    except Exception:
      pass
  arch = ap.get("architectures") or []
  if not isinstance(arch, (list, tuple)):
    arch = [arch]
  values = {
    "name": str(ap.get("name") or ""),
    "key": "local" + key,
    "short_desc_zh": str(ap.get("shortDescZh") or ""),
    "short_desc_en": str(ap.get("shortDescEn") or ""),
    "description": json.dumps(loc, ensure_ascii=False, separators=(",", ":")),
    "icon": icon,
    "type": str(ap.get("type") or ""),
    "status": "Normal",
    "cross_version_update": 1 if truthy(ap.get("crossVersionUpdate")) else 0,
    "limit": to_int(ap.get("limit")),
    "website": str(ap.get("website") or ""),
    "github": str(ap.get("github") or ""),
    "document": str(ap.get("document") or ""),
    "recommend": 9999,
    "resource": "local",
    "read_me": readme,
    "architectures": ",".join(str(x) for x in arch),
    "memory_required": to_int(ap.get("memoryRequired")),
    "gpu_support": 1 if truthy(ap.get("gpuSupport")) else 0,
  }
  tags = ap.get("tags") or []
  if not isinstance(tags, (list, tuple)):
    tags = [tags]
  return {"values": values, "tags": [str(x) for x in tags] + ["Local", "local"]}, None

def gen_params(vdata_path):
  if not HAVE_YAML:
    return '{"formFields":[]}', "未安装 PyYAML, params 使用空表单 (可在面板重新同步或用 --refresh-params 修正)"
  d = load_dict(vdata_path)
  ap = d.get("additionalProperties") or {}
  ff = ap.get("formFields") if isinstance(ap, dict) else None
  s = json.dumps({"formFields": ff}, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
  s = s.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
  return s, None

def main():
  if not os.path.isdir(SRC):
    die("应用源目录不存在: %s" % SRC)
  conn = sqlite3.connect(DB, timeout=10, isolation_level=None)
  conn.row_factory = sqlite3.Row
  conn.execute("PRAGMA busy_timeout=10000")

  existing_tables = set(r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'"))
  for t in ("apps", "app_details", "app_tags", "tags"):
    if t not in existing_tables:
      die("agent.db 缺少表 %s, schema 不兼容" % t)
  if HAVE_YAML:
    info("YAML 解析         : PyYAML 可用")
  else:
    warn("YAML 解析      : 未安装 PyYAML, 解析受限; 新增版本的 params 将为空表单")

  def cols(t):
    return [(r[1], (r[2] or "").upper(), r[3], r[4], r[5])
            for r in conn.execute("PRAGMA table_info(%s)" % t)]

  app_names = set(c[0] for c in cols("apps"))
  det_names = set(c[0] for c in cols("app_details"))
  tag_names = set(c[0] for c in cols("app_tags"))
  if "key" not in app_names or "resource" not in app_names:
    die("apps 表缺少 key/resource 列, schema 不兼容")
  if "app_id" not in det_names or "version" not in det_names:
    die("app_details 表缺少 app_id/version 列, schema 不兼容")
  if "app_id" not in tag_names or "tag_id" not in tag_names:
    die("app_tags 表缺少 app_id/tag_id 列, schema 不兼容")
  tag_tbl_names = set(c[0] for c in cols("tags"))
  miss_app = sorted(set(("short_desc_zh", "short_desc_en", "description", "icon",
    "type", "cross_version_update", "limit", "website", "github", "document",
    "recommend", "resource", "read_me", "last_modified", "architectures",
    "memory_required", "gpu_support", "required_panel_version",
    "batch_install_support")) - app_names)
  miss_det = sorted(set(("params", "docker_compose", "status", "last_version",
    "last_modified", "download_url", "download_call_back_url", "update")) - det_names)
  if miss_app or miss_det:
    info("动态取列       : apps 跳过 %s" % (",".join(miss_app) or "无"))
    info("动态取列       : app_details 跳过 %s" % (",".join(miss_det) or "无"))

  now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

  def default_for(name, typ):
    if any(x in typ for x in ("INT", "REAL", "NUM", "BOOL", "FLOAT", "DOUB", "DEC")):
      return 0
    if name in ("created_at", "updated_at"):
      return now
    return ""

  def insert_row(table, values):
    row = {}
    for name, typ, notnull, dflt, pk in cols(table):
      if pk:
        continue
      if name in values:
        row[name] = values[name]
      elif notnull and dflt is None:
        row[name] = default_for(name, typ)
    keys = list(row)
    sql = "INSERT INTO %s (%s) VALUES (%s)" % (
        table, ",".join('"%s"' % k for k in keys), ",".join("?" for _ in keys))
    return conn.execute(sql, [row[k] for k in keys]).lastrowid

  def update_row(table, id_, values):
    names = set(c[0] for c in cols(table))
    row = {}
    for k, v in values.items():
      if k in names and k not in ("id", "created_at"):
        row[k] = v
    if "updated_at" in names:
      row["updated_at"] = now
    if not row:
      return
    sql = "UPDATE %s SET %s WHERE id=?" % (
        table, ",".join('"%s"=?' % k for k in row))
    conn.execute(sql, [row[k] for k in row] + [id_])

  scanned = []
  for entry in sorted(os.listdir(SRC)):
    ad = os.path.join(SRC, entry)
    if not os.path.isdir(ad):
      continue
    dfile, lfile = os.path.join(ad, "data.yml"), os.path.join(ad, "logo.png")
    if not (os.path.isfile(dfile) and os.path.isfile(lfile)):
      warn("跳过 %s: 缺 data.yml 或 logo.png (官方 handleLocalApp 同样跳过)" % entry)
      continue
    d = load_dict(dfile)
    ap = d.get("additionalProperties") or {}
    if not isinstance(ap, dict):
      warn("跳过 %s: data.yml 缺少 additionalProperties" % entry)
      continue
    built, why = build_app(ap, ad)
    if why:
      warn("跳过 %s: %s" % (entry, why))
      continue
    versions = []
    for vd in sorted(os.listdir(ad)):
      vp = os.path.join(ad, vd)
      if not os.path.isdir(vp):
        continue
      comp, vdata = os.path.join(vp, "docker-compose.yml"), os.path.join(vp, "data.yml")
      if not (os.path.isfile(comp) and os.path.isfile(vdata)):
        warn("跳过版本 %s/%s: 缺 docker-compose.yml 或 data.yml" % (entry, vd))
        continue
      try:
        with open(comp, "r", encoding="utf-8") as f:
          compose = f.read()
      except Exception as e:
        warn("跳过版本 %s/%s: 读取 compose 失败 %s" % (entry, vd, e))
        continue
      versions.append((vd, compose, vdata))
    if not versions:
      warn("跳过 %s: 无有效版本目录" % entry)
      continue
    built["versions"] = versions
    built["dir"] = entry
    scanned.append(built)

  old_apps = {}
  for r in conn.execute("SELECT * FROM apps WHERE resource='local'"):
    old_apps[r["key"]] = dict(r)
  old_details = {}
  ids = [v["id"] for v in old_apps.values() if "id" in v]
  if ids:
    q = "SELECT * FROM app_details WHERE app_id IN (%s)" % ",".join("?" for _ in ids)
    for r in conn.execute(q, ids):
      old_details.setdefault(r["app_id"], {})[r["version"]] = dict(r)
  tagmap = {}
  for r in conn.execute("SELECT id, key FROM tags"):
    tagmap[str(r["key"])] = r["id"]
  installs_tbl = "app_installs" in existing_tables

  def has_installs(aid):
    if not installs_tbl:
      return True
    try:
      return conn.execute("SELECT 1 FROM app_installs WHERE app_id=? LIMIT 1", (aid,)).fetchone() is not None
    except sqlite3.Error:
      return True

  info("数据库中本地应用  : %d 个" % len(old_apps))
  if not scanned and old_apps:
    warn("未扫描到任何有效应用, 但库中存在 %d 个本地应用; 为安全起见不改动任何数据" % len(old_apps))
    warn("请检查 data.yml / logo.png 是否齐全; 离线模式不会因此清空应用商店")
    conn.close()
    return

  plan_new, plan_upd, plan_down = [], [], []
  for s in scanned:
    k = s["values"]["key"]
    if k in old_apps:
      plan_upd.append((old_apps[k], s))
    else:
      plan_new.append(s)
  seen = set(s["values"]["key"] for s in scanned)
  for k, row in old_apps.items():
    if k not in seen:
      plan_down.append(row)

  info("扫描结果          : 目录有效应用 %d 个 (新增 %d / 更新 %d), 库中待下架 %d 个" %
      (len(scanned), len(plan_new), len(plan_upd), len(plan_down)))
  for s in plan_new:
    info("  [新增] %-28s 版本 %d" % (s["values"]["key"], len(s["versions"])))
  for row, s in plan_upd:
    info("  [更新] %-28s 版本 %d" % (s["values"]["key"], len(s["versions"])))
  for row in plan_down:
    info("  [下架] %-28s -> TakeDown%s" %
        (row.get("key"), " (--prune 且无安装实例时删除)" if PRUNE else ""))

  if not APPLY:
    warn("只读预览结束      : 未写入任何数据, 确认后传入 --apply 执行")
    if FORCED_RO:
      info("当前 --check 强制只读模式")
    conn.close()
    return

  bdir = BACKUP_DIR or os.path.dirname(DB) or "."
  try:
    os.makedirs(bdir, exist_ok=True)
  except Exception as e:
    die("备份目录不可用 %s: %s" % (bdir, e))
  bak = os.path.join(bdir, "agent.db.syncbak.%s" % datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
  try:
    bsrc, bdst = sqlite3.connect(DB), sqlite3.connect(bak)
    bsrc.backup(bdst)
    bdst.close()
    bsrc.close()
  except Exception as e:
    die("备份失败 (未写入任何数据): %s" % e)
  info("已备份            : %s" % bak)
  info("回滚              : cp -f %s %s" % (bak, DB))

  stat = dict(app_new=0, app_upd=0, app_down=0, app_del=0,
              det_new=0, det_upd=0, det_down=0, det_del=0, tag=0)
  try:
    conn.execute("BEGIN IMMEDIATE")
    id_of = {}
    for s in plan_new:
      id_of[s["values"]["key"]] = insert_row("apps", s["values"])
      stat["app_new"] += 1
    for row, s in plan_upd:
      aid = row["id"]
      update_row("apps", aid, s["values"])
      id_of[s["values"]["key"]] = aid
      stat["app_upd"] += 1
    for row in plan_down:
      aid = row["id"]
      if PRUNE and not has_installs(aid):
        conn.execute("DELETE FROM app_details WHERE app_id=?", (aid,))
        conn.execute("DELETE FROM app_tags WHERE app_id=?", (aid,))
        conn.execute("DELETE FROM apps WHERE id=?", (aid,))
        stat["app_del"] += 1
      else:
        update_row("apps", aid, {"status": "TakeDown"})
        stat["app_down"] += 1
    for aid in set([v["id"] for v in old_apps.values()] + list(id_of.values())):
      conn.execute("DELETE FROM app_tags WHERE app_id=?", (aid,))
    for s in scanned:
      aid = id_of.get(s["values"]["key"])
      if aid is None:
        continue
      oldd = old_details.get(aid, {})
      want = set()
      for ver, compose, vdata in s["versions"]:
        want.add(ver)
        row = oldd.get(ver)
        if row:
          vals = {"docker_compose": compose, "status": "Normal"}
          if REFRESH or not row.get("params"):
            p, why = gen_params(vdata)
            vals["params"] = p
            if why:
              warn("版本 %s/%s: %s" % (s["dir"], ver, why))
          update_row("app_details", row["id"], vals)
          stat["det_upd"] += 1
        else:
          p, why = gen_params(vdata)
          if why:
            warn("版本 %s/%s: %s" % (s["dir"], ver, why))
          insert_row("app_details", {"app_id": aid, "version": ver,
            "params": p, "docker_compose": compose, "status": "Normal"})
          stat["det_new"] += 1
      for ver, row in oldd.items():
        if ver not in want:
          if PRUNE:
            conn.execute("DELETE FROM app_details WHERE id=?", (row["id"],))
            stat["det_del"] += 1
          else:
            update_row("app_details", row["id"], {"status": "TakeDown"})
            stat["det_down"] += 1
    for s in scanned:
      aid = id_of.get(s["values"]["key"])
      if aid is None:
        continue
      for t in s["tags"]:
        tid = tagmap.get(t)
        if tid is None:
          continue
        insert_row("app_tags", {"app_id": aid, "tag_id": tid})
        stat["tag"] += 1
    conn.commit()
  except Exception as e:
    conn.rollback()
    die("事务失败已回滚 (agent.db 未改动): %s" % e)

  counts = (stat["app_new"], stat["app_upd"], stat["app_down"], stat["app_del"],
    stat["det_new"], stat["det_upd"], stat["det_down"], stat["det_del"], stat["tag"])
  info("事务已提交        : 应用 新增%d/更新%d/下架%d/删除%d; 版本 新增%d/更新%d/下架%d/删除%d; 标签重建%d" %
      counts)
  n = conn.execute("SELECT COUNT(*) FROM apps WHERE resource='local' AND status!='TakeDown'").fetchone()[0]
  keys = [r[0] for r in conn.execute(
      "SELECT key FROM apps WHERE resource='local' AND status!='TakeDown' ORDER BY key")]
  info("数据库验收        : 在线本地应用 %d 个 -> %s" % (n, ", ".join(keys) if keys else "<空>"))
  conn.close()
  info("当前节点本地应用同步完成")

try:
  main()
except SystemExit:
  raise
except Exception as e:
  err("离线同步引擎异常: %s" % e)
  sys.exit(1)
PYEOF

  if [ "$rc" -ne 0 ]; then
    err "离线同步引擎异常退出 (rc=$rc), agent.db 未改动或已回滚"
    return "$rc"
  fi
  return 0
}

auto_offline_banner() {
  warn "当前处于子节点, 将会直接写入数据库"
  local readonly_hint=""
  if [ "$CHECK_ONLY" = true ]; then
    readonly_hint=" (--check 强制只读, --apply 已忽略)"
  fi
  if [ "$OFFLINE_APPLY" = true ] && [ -z "$readonly_hint" ]; then
    info "将写入本机 agent.db"
  else
    info "当前为只读预览, 不会写入数据库"
  fi
}

clear_db_backup() {
  local bdir="" f
  local -a files=()
  if [ -n "$OFFLINE_BACKUP_DIR" ]; then
    bdir="$OFFLINE_BACKUP_DIR"
  else
    bdir="$(dirname "$AGENT_DB")"
  fi
  if [ ! -d "$bdir" ]; then
    warn "备份目录不存在: $bdir (无备份可清除)"
    return 0
  fi

  shopt -s nullglob
  files=("$bdir"/agent.db.syncbak.*)
  shopt -u nullglob

  if [ "${#files[@]}" -eq 0 ]; then
    info "未发现历史同步备份: $bdir 下无 agent.db.syncbak.* 文件"
    return 0
  fi

  info "备份目录: $bdir"
  info "将清除以下 ${#files[@]} 个备份文件:"
  for f in "${files[@]}"; do
    info "  $f"
  done

  if [ "$ASSUME_YES" = false ]; then
    printf '确认删除以上备份文件? [y/N] '
    read -r ans
    [[ "$ans" =~ ^[Yy] ]] || { info "已取消, 未删除任何备份"; return 0; }
  fi

  for f in "${files[@]}"; do
    rm -f -- "$f" || warn "删除失败: $f"
  done
  info "已清除 ${#files[@]} 个同步备份文件"
}

main() {
  local orc=0
  parse_args "$@"

  if [ "$CLEAR_DB_BAK" = true ]; then
    preflight_base
    clear_db_backup
    return 0
  fi

  if [ "$OFFLINE" = true ]; then
    preflight_base
    offline_run || orc=$?
    return "$orc"
  fi

  preflight_base
  detect_role

  if [ "$ROLE" = node ]; then
    OFFLINE=true
    auto_offline_banner
    offline_run || orc=$?
    return "$orc"
  fi

  if [ "$OFFLINE_APPLY" = true ]; then
    info "通过 1panel agent 写入数据库"
  fi
  if [ "$OFFLINE_PRUNE" = true ]; then
    warn "在线通道的下架/删除由官方 SyncAppListFromLocal 处理, --prune 无独立作用"
  fi
  if [ "$OFFLINE_REFRESH_PARAMS" = true ]; then
    warn "在线通道的 params 由官方 agent 全量重建, --refresh-params 无独立作用"
  fi
  if [ -n "$OFFLINE_BACKUP_DIR" ]; then
    warn "在线通道不产生脚本整库备份, --backup-dir 已忽略"
  fi

  preflight_channel
  scan_source
  verify_channel
  probe_task_query

  if [ "$CHECK_ONLY" = true ]; then
    exit 0
  fi

  if [ "$ASSUME_YES" = false ]; then
    printf '\n即将同步【当前节点】的本地应用, 是否继续? [y/N] '
    read -r ans
    [[ "$ans" =~ ^[Yy] ]] || { info "已取消"; exit 0; }
  fi

  local task_id rc=0 after
  task_id="$(gen_task_id)"

  DB_SNAPSHOT_BEFORE="$(db_local_apps "$AGENT_DB" || true)"
  DB_FP_BEFORE="$(db_fingerprint "$AGENT_DB" || true)"
  if [ -n "$DB_SNAPSHOT_BEFORE" ]; then
    info "同步前本地应用: ${DB_SNAPSHOT_BEFORE%%|*} 个 (agent.db)"
  else
    warn "无法只读查询 agent.db 的本地应用清单, 跳过清单验收"
  fi
  if [ -z "$DB_FP_BEFORE" ]; then
    warn "无法计算 agent.db 应用表指纹, 写入检测将不可用"
  fi

  step "触发同步"
  info "节点角色        : $ROLE"
  info "taskID          : $task_id"
  trigger_sync "$task_id" || die "同步任务提交失败"
  if [ "$TRIGGER_BODY_UNKNOWN" = true ]; then
    info "请求已送达"
  else
    info "已提交同步请求"
  fi

  if [ "$WAIT_SECS" -eq 0 ]; then
    step "结果"
    info "已提交, --wait 0 表示不等待结果; 可查 $TASK_DB 的 tasks 表按 id 查看"
    exit 0
  fi

  wait_task "$task_id" || rc=$?
  verify_result
  step "结果"
  case "$rc" in
    0) info "当前节点本地应用同步完成" ;;
    1) err "同步任务执行失败 (taskID=$task_id)"; exit 1 ;;
    2)
      if [ "$DB_CHANGED" = true ]; then
        info "任务终态未确认, 但 agent.db 应用表已发生写入 -> 同步实际已生效"
      else
        warn "任务终态未确认 (taskID=$task_id), 且 agent.db 未检测到写入"
        if [ "$TRIGGER_BODY_UNKNOWN" = true ]; then
          warn "触发响应为空/非 JSON: 请求可能未进入业务 handler, 请查看上方响应头与 agent 日志"
        fi
        exit 2
      fi ;;
  esac
}

main "$@" || exit $?
