#!/usr/bin/env bash

set -u
umask 022

_detected_self="${BASH_SOURCE[0]:-$0}"
case "$_detected_self" in
  /dev/fd/*|/proc/self/fd/*|*/dev/fd/*|/dev/stdin|/dev/tty|bash|sh|*/bash|*/sh|"")
    _SELF_NAME="restore-1panel.sh" ;;
  *) _SELF_NAME=$(basename "$_detected_self") ;;
esac
SCRIPT_NAME="$_SELF_NAME"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[1Panel 还原] $*${NC}"; }
ok()   { echo -e "${GREEN}[OK] $*${NC}"; }
warn() { echo -e "${YELLOW}[警告] $*${NC}"; }
fail() { echo -e "${RED}[错误] $*${NC}" >&2; exit 1; }
_ts()  { date '+%Y-%m-%d %H:%M:%S'; }
step() { printf '\n[%s] ===== %s =====\n' "$(_ts)" "$*"; }

usage() {
  cat <<EOF
无需使用官方安装脚本先安装，仅凭 1Panel v2 快照文件还原 1Panel

用法:
  bash $SCRIPT_NAME -f <快照文件> [-p <压缩密码>] [选项]

选项:
  -f FILE             快照 .tar.gz 文件 (必填)
  -p PASSWORD         创建快照时设置的压缩密码 (未设置则省略)
  -y                  非交互模式，跳过确认
  --skip-apps         还原后不自动启动 compose 应用
  --install-docker    未安装 docker 时直接安装；未指定则询问
  --no-show-password  隐藏明文密码，显示 **********
  -h, --help          显示帮助
EOF
}

SNAP_FILE=""
SNAP_PASS=""
NON_INTERACTIVE=false
SKIP_APPS=false
INSTALL_DOCKER=false
SHOW_PASSWORD=true
case "$(printf '%s' "${PANEL_SHOW_PASSWORD:-}" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) SHOW_PASSWORD=false ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) SNAP_FILE="${2:? -f 需要文件路径}"; shift 2 ;;
    -p) SNAP_PASS="$2"; shift 2 ;;
    -y) NON_INTERACTIVE=true; shift ;;
    --skip-apps) SKIP_APPS=true; shift ;;
    --install-docker) INSTALL_DOCKER=true; shift ;;
    --no-show-password) SHOW_PASSWORD=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

[[ -n "$SNAP_FILE" ]] || { echo "缺少 -f 参数"; usage; exit 1; }
[[ -f "$SNAP_FILE" ]] || fail "快照文件不存在: $SNAP_FILE"

[[ $EUID -eq 0 ]] || fail "必须以 root 运行 (本脚本需要写入 /usr/local/bin、/etc/systemd/system 等) "

for c in tar gzip openssl; do
  command -v "$c" >/dev/null 2>&1 || fail "缺少依赖命令: $c"
done

SNAP_FILE=$(readlink -f "$SNAP_FILE")
SNAP_BASENAME=$(basename "$SNAP_FILE")
SNAP_NAME=${SNAP_BASENAME%.tar.gz}
if [[ "$SNAP_BASENAME" == "$SNAP_NAME" ]]; then
  fail "快照文件名必须以 .tar.gz 结尾"
fi

log "快照文件: $SNAP_FILE"
log "快照名称: $SNAP_NAME"

if [[ "$SNAP_NAME" =~ ^1panel_v[0-9] ]]; then
  fail "检测到 v1 格式快照 ($SNAP_NAME)。本脚本面向 1Panel v2 快照"
fi

if [[ "$SNAP_NAME" != *"-v2."* ]]; then
  fail "快照名称不含 -v2.，无法识别版本"
fi
SNAP_VERSION=$(echo "$SNAP_NAME" | sed -n 's/.*-\(v2\.[0-9][0-9.]*\)-linux-.*/\1/p')
log "快照版本: ${SNAP_VERSION:-未知}"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) LOCAL_ARCH="amd64" ;;
  aarch64|arm64) LOCAL_ARCH="arm64" ;;
  armv7l) LOCAL_ARCH="armv7" ;;
  ppc64le|s390x|riscv64) LOCAL_ARCH="$ARCH" ;;
  *) LOCAL_ARCH="$ARCH" ;;
esac
if [[ "$SNAP_NAME" != *"$LOCAL_ARCH"* ]]; then
  fail "架构不匹配: 当前机器为 $ARCH($LOCAL_ARCH)，快照为 $(echo "$SNAP_NAME" | grep -oE '(amd64|arm64|armv7|ppc64le|s390x|riscv64)' | head -1)。快照不支持跨架构恢复。"
fi

if [[ "$SNAP_NAME" == *"-core-"* ]]; then
  SNAP_SCOPE="core"
elif [[ "$SNAP_NAME" == *"-agent-"* ]]; then
  SNAP_SCOPE="agent"
else
  fail "快照名称不符合规范 (需包含 -core- 或 -agent-) "
fi
log "快照作用域: $SNAP_SCOPE 节点"

if command -v systemctl >/dev/null 2>&1; then
  INIT_MGR="systemd"
elif command -v rc-service >/dev/null 2>&1; then
  INIT_MGR="openrc"
else
  INIT_MGR="sysvinit"
fi
log "服务管理器: $INIT_MGR"

ask_yes_no() {
  local msg="$1" ans=""
  [[ "$NON_INTERACTIVE" == true ]] && return 1
  if [[ -r /dev/tty ]]; then
    read -r -p "$msg [y/N] " ans < /dev/tty || return 1
  else
    read -r -p "$msg [y/N] " ans || return 1
  fi
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

install_docker() {
  log "开始自动安装 docker (get.docker.com) ..."
  if ! curl -fsSL --connect-timeout 10 --max-time 300 https://get.docker.com -o /tmp/get-docker.sh; then
    fail "无法下载 docker 安装脚本，请手动安装 docker 后重试"
  fi
  sh /tmp/get-docker.sh || fail "docker 安装失败，请手动安装后重试"
  command -v docker >/dev/null 2>&1 || fail "docker 安装后仍未就绪"
  HAS_DOCKER=true
  ok "docker 安装完成"
}

HAS_DOCKER=true
if ! command -v docker >/dev/null 2>&1; then
  HAS_DOCKER=false
  if [[ "$INSTALL_DOCKER" == true ]]; then
    install_docker
  elif ask_yes_no "未检测到 docker，是否现在自动安装 (get.docker.com) ？"; then
    install_docker
  else
    log "跳过 docker 安装: 面板本体可还原，应用容器/镜像加载将不可用"
  fi
fi
if [[ "$HAS_DOCKER" == true ]]; then
  docker info >/dev/null 2>&1 || fail "docker 未运行，请先启动 docker 服务 (systemctl start docker) "
fi
if [[ "$HAS_DOCKER" == true ]] && docker compose version >/dev/null 2>&1; then
  HAS_COMPOSE=true
else
  HAS_COMPOSE=false
  if [[ "$HAS_DOCKER" == true ]]; then
    warn "未检测到 docker compose 插件，面板可正常还原，但已安装的应用将不会自动拉起"
  fi
fi

confirm_or_abort() {
  local msg="$1" ans=""
  if [[ "$NON_INTERACTIVE" == true ]]; then
    return 0
  fi
  if [[ -r /dev/tty ]]; then
    read -r -p "$msg [y/N] " ans < /dev/tty
  else
    read -r -p "$msg [y/N] " ans
  fi
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "已取消"
}

RUNTIME_SRC=""
RUNTIME_MISSING=false
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || SCRIPT_DIR=""
case "${BASH_SOURCE[0]:-$0}" in
  /dev/fd/*|/proc/self/fd/*|*/dev/fd/*|/dev/stdin) SCRIPT_DIR="$PWD" ;;
esac
[[ -d "$SCRIPT_DIR" ]] || SCRIPT_DIR="$PWD"

normalize_runtime_src() {
  local d="$1"
  [[ -d "$d" ]] || return 1
  if [[ -f "$d/lang/zh.sh" ]]; then
    printf '%s' "$d"
    return 0
  fi
  if [[ -f "$d/zh.sh" ]]; then
    mkdir -p "$WORK_DIR/runtime/lang" || return 1
    cp -a "$d/." "$WORK_DIR/runtime/lang/" || return 1
    printf '%s' "$WORK_DIR/runtime"
    return 0
  fi
  return 1
}

fetch_official_package() {
  local pkg="1panel-${SNAP_VERSION}-linux-${LOCAL_ARCH}.tar.gz"
  local base="https://resource.fit2cloud.com/1panel/package/v2/stable/${SNAP_VERSION}/release"
  local pkg_path="$WORK_DIR/$pkg"
  local sum_path="$WORK_DIR/checksums.txt"

  log "尝试从官方下载软件包 $pkg ..."
  if ! curl -fsSL --connect-timeout 10 --max-time 600 "$base/$pkg" -o "$pkg_path"; then
    warn "官方软件包下载失败"
    rm -f "$pkg_path"
    return 1
  fi
  if curl -fsSL --connect-timeout 10 --max-time 60 "$base/checksums.txt" -o "$sum_path" 2>/dev/null; then
    local expected actual
    expected=$(awk -v n="$pkg" '$2 == n { print $1 }' "$sum_path" | head -1)
    actual=$(sha256sum "$pkg_path" | awk '{ print $1 }')
    if [[ -z "$expected" ]]; then
      warn "checksums.txt 中没有 $pkg 的记录，跳过校验"
    elif [[ "$expected" != "$actual" ]]; then
      warn "软件包 sha256 校验不通过 (期望 $expected，实际 $actual) ，拒绝使用"
      rm -f "$pkg_path"
      return 1
    else
      ok "软件包 sha256 校验通过"
    fi
  else
    warn "未能获取 checksums.txt，跳过校验 (建议把官方安装包解包到脚本同目录以便离线使用) "
  fi
  if ! tar -zxf "$pkg_path" -C "$WORK_DIR" 2>/dev/null; then
    warn "软件包解压失败"
    rm -f "$pkg_path"
    return 1
  fi
  local d
  d=$(find "$WORK_DIR" -maxdepth 1 -type d -name "1panel-${SNAP_VERSION}-linux-${LOCAL_ARCH}" | head -1)
  if [[ -z "$d" || ! -f "$d/lang/zh.sh" ]]; then
    warn "软件包内未找到 lang/zh.sh"
    return 1
  fi
  RUNTIME_SRC="$d"
  ok "官方软件包就绪: $d"
  return 0
}

fetch_lang_only() {
  local url="https://resource.fit2cloud.com/1panel/package/v2/language/lang.tar.gz"
  log "尝试下载官方轻量语言包 lang.tar.gz ..."
  if ! curl -fsSL --connect-timeout 10 --max-time 180 "$url" -o "$WORK_DIR/lang.tar.gz"; then
    warn "语言包下载失败"
    return 1
  fi
  if ! tar -zxf "$WORK_DIR/lang.tar.gz" -C "$WORK_DIR" 2>/dev/null; then
    warn "语言包解压失败"
    return 1
  fi
  if [[ ! -f "$WORK_DIR/lang/zh.sh" ]]; then
    warn "语言包内未找到 lang/zh.sh"
    return 1
  fi
  RUNTIME_SRC="$WORK_DIR"
  ok "官方语言包就绪: $WORK_DIR/lang"
  return 0
}

prepare_runtime_src() {
  local snap_dir="" d cand
  snap_dir=$(dirname "$SNAP_FILE" 2>/dev/null) || snap_dir=""
  local -a candidates=()
  for d in "${SCRIPT_DIR:-}" "$snap_dir" "${SNAP_ROOT:-}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    candidates+=("$d" "$d/1panel-${SNAP_VERSION}-linux-${LOCAL_ARCH}")
    for cand in "$d"/1panel-*-linux-"${LOCAL_ARCH}"; do
      [[ -d "$cand" ]] && candidates+=("$cand")
    done
  done
  if [[ ${#candidates[@]} -gt 0 ]]; then
    for cand in "${candidates[@]}"; do
      [[ -d "$cand" ]] || continue
      if RUNTIME_SRC=$(normalize_runtime_src "$cand"); then
        ok "探测到运行环境文件: $cand"
        return 0
      fi
    done
  fi
  if fetch_official_package; then return 0; fi
  if fetch_lang_only; then return 0; fi
  return 1
}

deploy_1pctl_runtime() {
  local lang_dir="/usr/local/bin/lang"
  if [[ -f "$lang_dir/zh.sh" ]]; then
    ok "$lang_dir 已存在且完整，跳过"
    return 0
  fi
  if [[ -z "$RUNTIME_SRC" ]]; then
    prepare_runtime_src || true
  fi
  if [[ -z "$RUNTIME_SRC" || ! -f "$RUNTIME_SRC/lang/zh.sh" ]]; then
    RUNTIME_MISSING=true
    warn "无法获取 1pctl 语言文件: 标题将为空、version 输出为英文 (面板本体不受影响) "
    return 0
  fi

  mkdir -p "$lang_dir" || { warn "创建 $lang_dir 失败"; RUNTIME_MISSING=true; return 0; }
  if ! cp -a "$RUNTIME_SRC/lang/." "$lang_dir/"; then
    warn "拷贝 lang/ 到 $lang_dir 失败"
    RUNTIME_MISSING=true
    return 0
  fi
  chmod 0644 "$lang_dir"/*.sh 2>/dev/null || true
  ok "已部署 1pctl 语言文件: $lang_dir ($(find "$lang_dir" -maxdepth 1 -name '*.sh' | wc -l) 个语言脚本) "
}

fix_1pctl_placeholders() {
  local ctl="/usr/local/bin/1pctl"
  [[ -f "$ctl" ]] || return 0
  grep -qE '^ORIGINAL_PORT=port[[:space:]]*$' "$ctl" || return 0
  command -v python3 >/dev/null 2>&1 || { warn "未安装 python3，跳过 1pctl 占位值回填"; return 0; }

  local db="$SNAP_ROOT/db/core.db"
  [[ -f "$db" ]] || { warn "快照中无 core.db，跳过 1pctl 占位值回填"; return 0; }

  local rc=0
  python3 - "$ctl" "$db" <<'PY' || rc=$?
import re, sqlite3, sys
ctl, db = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
def setting(key):
  row = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
  return row[0] if row and row[0] is not None else ""
mapping = {
  "ORIGINAL_PORT":      setting("ServerPort"),
  "ORIGINAL_USERNAME":  setting("UserName"),
  "ORIGINAL_ENTRANCE":  setting("SecurityEntrance"),
  "ORIGINAL_PASSWORD":  "**********",
}
with open(ctl, encoding="utf-8") as f:
  lines = f.readlines()
out = []
for line in lines:
  m = re.match(r"^([A-Z_]+)=(.*)$", line.rstrip("\n"))
  if m and m.group(1) in mapping and mapping[m.group(1)]:
    out.append("%s=%s\n" % (m.group(1), mapping[m.group(1)]))
  else:
    out.append(line)
with open(ctl, "w", encoding="utf-8") as f:
  f.writelines(out)
PY
  if [[ "$rc" -ne 0 ]]; then
    warn "1pctl 占位值回填失败 (不影响面板本体) "
    return 0
  fi
  ok "已按 core.db 回填 1pctl 的 ORIGINAL_* 安装期配置"
}

deploy_extra_runtime_files() {
  local need_src=false
  [[ -f "$DATA_DIR/geo/GeoIP.mmdb" ]] || need_src=true
  [[ -d "$DATA_DIR/resource/initscript" ]] || need_src=true
  if [[ "$need_src" == false ]]; then
    ok "GeoIP.mmdb / initscript 已随快照数据还原"
    return 0
  fi
  if [[ -z "$RUNTIME_SRC" ]]; then
    prepare_runtime_src || true
  fi
  if [[ -z "$RUNTIME_SRC" ]]; then
    RUNTIME_MISSING=true
    warn "缺少 GeoIP.mmdb / initscript 且无法获取官方软件包 (不影响面板启动，IP 归属与非 systemd 初始化会受限) "
    return 0
  fi
  local added=0
  if [[ ! -f "$DATA_DIR/geo/GeoIP.mmdb" && -f "$RUNTIME_SRC/GeoIP.mmdb" ]]; then
    mkdir -p "$DATA_DIR/geo"
    if cp -a "$RUNTIME_SRC/GeoIP.mmdb" "$DATA_DIR/geo/GeoIP.mmdb"; then
      ok "已补齐 $DATA_DIR/geo/GeoIP.mmdb"
      added=$((added + 1))
    fi
  fi
  if [[ ! -d "$DATA_DIR/resource/initscript" && -d "$RUNTIME_SRC/initscript" ]]; then
    mkdir -p "$DATA_DIR/resource"
    if cp -a "$RUNTIME_SRC/initscript" "$DATA_DIR/resource/"; then
      ok "已补齐 $DATA_DIR/resource/initscript/"
      added=$((added + 1))
    fi
  fi
  if [[ "$added" -eq 0 ]]; then
    warn "来源目录中缺少 GeoIP.mmdb / initscript，未补齐；请把官方安装包解包到脚本同目录后重新运行"
  fi
}

# 登录地址
PANEL_PORT=""
PANEL_ENTRANCE=""
PANEL_USER=""
PANEL_SSL=""
PANEL_IPV6=""
PANEL_PASSWORD_ENC=""
PANEL_ENCRYPT_KEY=""
PANEL_PASSWORD_PLAIN=""
PANEL_PASSWORD_SOURCE=""
PUBLIC_IP=""
LOCAL_IP=""

read_db_setting() {
  local db="$1" key="$2" val=""
  [[ -f "$db" ]] || { printf ''; return 0; }
  if command -v python3 >/dev/null 2>&1; then
    val=$(python3 - "$db" "$key" <<'PY' 2>/dev/null
import sqlite3, sys
try:
  conn = sqlite3.connect(sys.argv[1])
  row = conn.execute("SELECT value FROM settings WHERE key=?", (sys.argv[2],)).fetchone()
  print(row[0] if row and row[0] is not None else "")
except Exception:
  print("")
PY
)
  elif command -v sqlite3 >/dev/null 2>&1; then
    val=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='$key';" 2>/dev/null | head -1)
  fi
  printf '%s' "$val"
}

decrypt_panel_password() {
  local b64="$1" key="$2" algo="" out=""
  [[ -n "$b64" && -n "$key" ]] || { printf ''; return 0; }
  case "${#key}" in
    16) algo="aes-128-cbc" ;;
    24) algo="aes-192-cbc" ;;
    32) algo="aes-256-cbc" ;;
    *)  printf ''; return 0 ;;
  esac

  if command -v python3 >/dev/null 2>&1; then
    out=$(python3 - "$b64" "$key" "$algo" <<'PY' 2>/dev/null
import base64, subprocess, sys
try:
  b64, key, algo = sys.argv[1], sys.argv[2], sys.argv[3]
  raw = base64.b64decode(b64, validate=True)
  if len(raw) < 32 or (len(raw) - 16) % 16 != 0:
    sys.exit(1)
  iv, ct = raw[:16], raw[16:]
  p = subprocess.run(
    [
      "openssl", "enc", "-d", "-" + algo, "-K",
      key.encode().hex(), "-iv", iv.hex()
    ],
    input=ct, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
  if p.returncode != 0:
    sys.exit(1)
  text = p.stdout.decode("utf-8")
except Exception:
  sys.exit(1)
if not text or any(ord(c) < 32 or ord(c) == 127 for c in text):
  sys.exit(1)
print(text)
PY
    ) || out=""
  fi

  if [[ -z "$out" ]] && command -v dd >/dev/null 2>&1 && command -v od >/dev/null 2>&1; then
    local tmp="" key_hex="" iv_hex=""
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/1panel-pwd.XXXXXX" 2>/dev/null) || tmp=""
    if [[ -n "$tmp" ]] && printf '%s' "$b64" | base64 -d > "$tmp/ct.bin" 2>/dev/null; then
      if dd if="$tmp/ct.bin" of="$tmp/iv.bin" bs=16 count=1 2>/dev/null \
          && dd if="$tmp/ct.bin" of="$tmp/body.bin" bs=16 skip=1 2>/dev/null; then
        key_hex=$(printf '%s' "$key" | od -An -tx1 -v | tr -d ' \n')
        iv_hex=$(od -An -tx1 -v "$tmp/iv.bin" | tr -d ' \n')
        if [[ -n "$key_hex" && -n "$iv_hex" ]]; then
          out=$(openssl enc -d "-$algo" -K "$key_hex" -iv "$iv_hex" \
                -in "$tmp/body.bin" 2>/dev/null) || out=""
        fi
      fi
    fi
    [[ -n "$tmp" ]] && rm -rf "$tmp"
    [[ "$out" =~ ^[[:print:]]+$ ]] || out=""
  fi
  printf '%s' "$out"
}

collect_panel_access() {
  local core_db="$DB_DIR/core.db"
  PANEL_PORT=$(read_db_setting "$core_db" "ServerPort")
  PANEL_ENTRANCE=$(read_db_setting "$core_db" "SecurityEntrance")
  PANEL_USER=$(read_db_setting "$core_db" "UserName")
  PANEL_SSL=$(read_db_setting "$core_db" "SSL")
  PANEL_IPV6=$(read_db_setting "$core_db" "Ipv6")

  PANEL_PASSWORD_ENC=$(read_db_setting "$core_db" "Password")
  PANEL_ENCRYPT_KEY=$(read_db_setting "$core_db" "EncryptKey")
  PANEL_PASSWORD_PLAIN=""
  PANEL_PASSWORD_SOURCE=""
  if [[ -n "$PANEL_PASSWORD_ENC" && -n "$PANEL_ENCRYPT_KEY" ]]; then
    PANEL_PASSWORD_PLAIN=$(decrypt_panel_password "$PANEL_PASSWORD_ENC" "$PANEL_ENCRYPT_KEY")
    [[ -n "$PANEL_PASSWORD_PLAIN" ]] && PANEL_PASSWORD_SOURCE="core.db"
  fi

  if [[ -z "$PANEL_PORT" ]] && command -v ss >/dev/null 2>&1; then
    PANEL_PORT=$(ss -tlnp 2>/dev/null | grep -E '1panel|1panel-core' | grep -oE ':[0-9]+' | head -1 | tr -d ':')
  fi
}

get_panel_ips() {
  local active_interface="" lan_ip=""
  if command -v ip >/dev/null 2>&1; then
    active_interface=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1 {print $5}')
  fi

  if command -v curl >/dev/null 2>&1; then
    PUBLIC_IP=$(curl -s --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')
    [[ "$PUBLIC_IP" =~ ^[0-9a-fA-F.:]+$ ]] || PUBLIC_IP=""
    if [[ -z "$PUBLIC_IP" ]]; then
      PUBLIC_IP=$(curl -s --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
      [[ "$PUBLIC_IP" =~ ^[0-9a-fA-F.:]+$ ]] || PUBLIC_IP=""
    fi
  fi

  if [[ -n "$active_interface" ]] && command -v ip >/dev/null 2>&1; then
    LOCAL_IP=$(ip -4 addr show dev "$active_interface" 2>/dev/null \
      | grep -oE 'inet[[:space:]]+([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | awk 'NR==1 {print $2}')
  fi
  if [[ -z "$LOCAL_IP" ]] && command -v hostname >/dev/null 2>&1; then
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  [[ -n "$LOCAL_IP" ]] || LOCAL_IP="127.0.0.1"

  if [[ "$active_interface" =~ pppoe ]] && command -v ip >/dev/null 2>&1; then
    lan_ip=$(ip -4 addr show 2>/dev/null | grep -E 'br-lan.*' \
      | grep -oE 'inet[[:space:]]+([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | awk 'NR==1 {print $2}' | cut -d/ -f1)
    [[ -n "$lan_ip" ]] && LOCAL_IP="$lan_ip"
    PUBLIC_IP=$(ip -4 addr show dev "$active_interface" 2>/dev/null \
      | grep -oE 'inet[[:space:]]+([0-9]{1,3}\.){3}[0-9]{1,3}' | awk 'NR==1 {print $2}')
  fi

  [[ -n "${PANEL_PUBLIC_IP:-}" ]] && PUBLIC_IP="$PANEL_PUBLIC_IP"
  [[ -n "${PANEL_LOCAL_IP:-}" ]] && LOCAL_IP="$PANEL_LOCAL_IP"

  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="N/A"
  elif [[ "$PUBLIC_IP" == *:* ]]; then
    PUBLIC_IP="[${PUBLIC_IP}]"
  fi
}

show_panel_access() {
  local scheme="http" port path_suffix="" port_hint=""
  case "$(printf '%s' "$PANEL_SSL" | tr '[:upper:]' '[:lower:]')" in
    enable|enabled|true|1|yes) scheme="https" ;;
  esac
  if [[ -n "$PANEL_PORT" ]]; then
    port="$PANEL_PORT"
  else
    port="<端口>"
    port_hint=" (端口未识别，请执行 1pctl user-info 查看) "
  fi
  [[ -n "$PANEL_ENTRANCE" ]] && path_suffix="/$PANEL_ENTRANCE"

  echo
  log "================= 1Panel 还原完成 ================="
  log "请使用您的浏览器访问面板: "
  if [[ "$PUBLIC_IP" == "N/A" ]]; then
    log "外部地址: 无法自动获取公网 IP (服务器可能无外网) "
    log "          请在云厂商控制台查看公网 IP 后访问 ${scheme}://<公网IP>:${port}${path_suffix}"
  else
    log "外部地址: ${scheme}://${PUBLIC_IP}:${port}${path_suffix}"
  fi
  log "内部地址: ${scheme}://${LOCAL_IP}:${port}${path_suffix}"
  log "面板用户: ${PANEL_USER:-<请执行 1pctl user-info 查看>}"
  if [[ "$SHOW_PASSWORD" == true && -n "$PANEL_PASSWORD_PLAIN" ]]; then
    printf '%b%s%b\n' "${BLUE}[1Panel 还原] 面板密码: " "$PANEL_PASSWORD_PLAIN" "$NC"
    log "为了您的服务器安全，离开此屏幕后您将无法再次看到您的密码，请记住您的密码。"
    log "      若本次输出被重定向到日志文件，请删除该行；或加 --no-show-password 隐藏。"
  elif [[ "$SHOW_PASSWORD" == false ]]; then
    log "面板密码: ********** (已按 --no-show-password 隐藏；可执行 1pctl user-info 查看或 1pctl update password 重置) "
  else
    log "面板密码: ********** (未能从 core.db 解密，请用 1pctl update password 重置) "
    log "          请确认还原后的 core.db 完整 (含 Password / EncryptKey 两项设置) "
    log "          若该面板从未成功登录过，执行 1pctl user-info 也可查看初始密码"
  fi
  echo
  log "说明: 端口 / 安全入口 / 账号密码均为【原服务器】的配置${port_hint}"
  if [[ "$scheme" == "http" ]]; then
    log "      若原面板开启了 HTTPS，请改用 https:// 或执行 1pctl reset https"
  fi
  if [[ "$PUBLIC_IP" == *:* ]]; then
    log "      检测到 IPv6 公网地址；当前面板 IPv6 监听为 ${PANEL_IPV6:-未知}，如未启用请执行 1pctl listen-ip ipv6"
  fi
  log "      如果您使用的是云服务器，请在安全组中打开端口 ${port}"
  echo
  log "若无法登录，可执行: "
  log "  1pctl reset entrance   # 取消安全入口"
  log "  1pctl reset https      # 取消 https"
  log "  1pctl reset mfa        # 取消两步验证"
  log "  1pctl update password  # 修改面板密码"
}

WORK_DIR="${PANEL_RESTORE_DIR:-${TMPDIR:-/tmp}/1panel-restore-$$}"
rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"

step "1/12 解压快照到 $WORK_DIR"
extract_plain()  { tar -zxf "$SNAP_FILE" -C "$WORK_DIR" 2>/dev/null; }
extract_encrypt() {
  BACKUP_SECRET="$SNAP_PASS" openssl enc -d -aes-256-cbc -salt \
    -pass env:BACKUP_SECRET -in "$SNAP_FILE" | tar -zxf - -C "$WORK_DIR" 2>/dev/null
}

if [[ -n "$SNAP_PASS" ]]; then
  extract_encrypt || fail "解密/解压失败，请确认压缩密码是否正确"
  [[ -d "$WORK_DIR/$SNAP_NAME" ]] || fail "解密成功但未在包内找到目录 $SNAP_NAME"
else
  if ! extract_plain; then
    warn "普通解压失败，尝试按加密快照处理 (需要 -p 密码) ..."
    confirm_or_abort "是否尝试以加密方式解压 (需提供 -p 密码，当前未提供将失败) ？"
    extract_encrypt || fail "解压失败: 文件可能损坏或需要压缩密码 (-p) "
    [[ -d "$WORK_DIR/$SNAP_NAME" ]] || fail "解压后未在包内找到目录 $SNAP_NAME"
  elif [[ ! -d "$WORK_DIR/$SNAP_NAME" ]]; then
    warn "包内未找到目录 $SNAP_NAME，尝试按加密快照处理..."
    rm -rf "$WORK_DIR"/*; mkdir -p "$WORK_DIR"
    [[ -n "$SNAP_PASS" ]] || fail "请确认该快照是否设置了压缩密码，并用 -p 重新执行"
    extract_encrypt || fail "解密/解压失败"
    [[ -d "$WORK_DIR/$SNAP_NAME" ]] || fail "解压后未在包内找到目录 $SNAP_NAME"
  fi
fi

SNAP_ROOT="$WORK_DIR/$SNAP_NAME"
ok "快照解压完成，目录: $SNAP_ROOT"

step "2/12 读取快照元数据 base/snapshot.json"
SNAP_JSON="$SNAP_ROOT/base/snapshot.json"
[[ -f "$SNAP_JSON" ]] || fail "快照缺少 base/snapshot.json，文件可能不是有效的 1Panel v2 快照"

read_json() {
  local key="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json,sys
d=json.load(open('$SNAP_JSON'))
v=d.get('$key')
print(v if v is not None else '')
" 2>/dev/null && return
  fi
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$SNAP_JSON" | head -1
}

BASE_DIR=$(read_json baseDir)
BACKUP_DATA_DIR=$(read_json backupDataDir)
WWW_DIR=$(read_json operestyDir)
[[ -n "$BASE_DIR" ]] || fail "snapshot.json 中缺少 baseDir 字段"

DATA_DIR="$BASE_DIR/1panel"
DB_DIR="$DATA_DIR/db"

[[ -n "$BACKUP_DATA_DIR" ]] || BACKUP_DATA_DIR="$DATA_DIR/backup"

log "安装数据目录(baseDir/1panel): $DATA_DIR"
log "备份数据目录:                 $BACKUP_DATA_DIR"
[[ -z "$WWW_DIR" ]] && log "网站目录:                     未单独设置 (包含在数据目录内) " \
                    || log "网站目录:                     $WWW_DIR"

if [[ -d "$DATA_DIR" && -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
  step "3/12 清除现有数据 $DATA_DIR"
  rm -rf "$DATA_DIR" || fail "清除现有数据失败"
else
  step "3/12 无现有数据，跳过"
fi

step "4/12 还原 1Panel 本体与相关服务"
BASE_SRC="$SNAP_ROOT/base"

install_bin() {
  local src="$BASE_SRC/$1" dst="/usr/local/bin/$2"
  if [[ -f "$src" ]]; then
    install -m 0755 "$src" "$dst" || fail "安装 $dst 失败"
    ok "已安装 $dst"
  else
    [[ "$3" == "required" ]] && fail "快照 base/ 中缺少必需文件 $1"
    warn "快照 base/ 中不存在 $1，跳过"
  fi
}

install_bin 1panel-core 1panel-core
install_bin 1panel-agent 1panel-agent
install_bin 1pctl 1pctl

for lnk in "1panel:1panel-core" "1panel-core:1panel-core" "1panel-agent:1panel-agent" "1pctl:1pctl"; do
  lname="${lnk%%:*}"; tgt="${lnk##*:}"
  if [[ -e "/usr/local/bin/$tgt" ]]; then
    rm -f "/usr/bin/$lname"
    ln -s "/usr/local/bin/$tgt" "/usr/bin/$lname" 2>/dev/null || true
  fi
done

case "$INIT_MGR" in
  systemd)
    SVC_DIR=/etc/systemd/system
    for svc in 1panel-core 1panel-agent; do
      src=""
      [[ -f "$BASE_SRC/$svc.service" ]] && src="$BASE_SRC/$svc.service"
      [[ -z "$src" && -f "$BASE_SRC/initscript/$svc.service" ]] && src="$BASE_SRC/initscript/$svc.service"
      if [[ -n "$src" ]]; then
        install -m 0644 "$src" "$SVC_DIR/$svc.service" || fail "安装 $svc.service 失败"
        ok "已安装 $SVC_DIR/$svc.service"
      fi
    done
    ;;
  openrc)
    SVC_DIR=/etc/init.d
    for svc in 1panel-core 1panel-agent; do
      src="$BASE_SRC/$svc.openrc"
      [[ -f "$src" ]] || src="$BASE_SRC/initscript/$svc.openrc"
      if [[ -f "$src" ]]; then
        install -m 0755 "$src" "$SVC_DIR/$svc" || fail "安装 $svc 失败"
        ok "已安装 $SVC_DIR/$svc"
      fi
    done
    ;;
  sysvinit)
    SVC_DIR=/etc/init.d
    for svc in 1panel-core 1panel-agent; do
      for variant in procd init; do
        src="$BASE_SRC/$svc.$variant"
        [[ -f "$src" ]] || src="$BASE_SRC/initscript/$svc.$variant"
        if [[ -f "$src" ]]; then
          install -m 0755 "$src" "$SVC_DIR/$svc" || fail "安装 $svc 失败"
          ok "已安装 $SVC_DIR/$svc"
          break
        fi
      done
    done
    ;;
esac

if [[ -f "$BASE_SRC/daemon.json" ]]; then
  mkdir -p /etc/docker
  install -m 0644 "$BASE_SRC/daemon.json" /etc/docker/daemon.json
  ok "已还原 /etc/docker/daemon.json"
  if [[ "$HAS_DOCKER" == true ]]; then
    log "重启 docker 使 daemon.json 生效..."
    systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || warn "docker 重启失败，请手动重启"
  fi
fi

step "5/12 部署 1pctl 运行环境"
deploy_1pctl_runtime
fix_1pctl_placeholders

if [[ -f "$SNAP_ROOT/images.tar.gz" && "$HAS_DOCKER" != true ]]; then
  step "6/12 未安装 docker，跳过应用镜像加载"
elif [[ -f "$SNAP_ROOT/images.tar.gz" ]]; then
  step "6/12 加载应用镜像 docker load (可能耗时较长)"
  docker load -i "$SNAP_ROOT/images.tar.gz" || warn "docker load 部分镜像失败 (可能是架构/损坏导致) ，继续后续步骤"
  ok "应用镜像加载完成"
else
  step "6/12 快照不包含应用镜像 (images.tar.gz) ，跳过"
fi

step "7/12 还原备份数据到 $BACKUP_DATA_DIR"
mkdir -p "$BACKUP_DATA_DIR"
if [[ -f "$SNAP_ROOT/1panel_backup.tar.gz" ]]; then
  tar -zxf "$SNAP_ROOT/1panel_backup.tar.gz" -C "$BACKUP_DATA_DIR" || fail "解压 1panel_backup.tar.gz 失败"
  ok "备份数据还原完成"
else
  warn "快照中不存在 1panel_backup.tar.gz"
fi

if [[ -f "$SNAP_ROOT/website.tar.gz" && -n "$WWW_DIR" ]]; then
  step "8/12 还原网站数据到 $WWW_DIR"
  mkdir -p "$WWW_DIR"
  tar -zxf "$SNAP_ROOT/website.tar.gz" -C "$WWW_DIR" || fail "解压 website.tar.gz 失败"
  ok "网站数据还原完成"
else
  step "8/12 无独立网站数据包 (网站目录包含在数据目录内) ，跳过"
fi

step "9/12 还原 1Panel 核心数据到 $DATA_DIR"
mkdir -p "$DATA_DIR"
[[ -f "$SNAP_ROOT/1panel_data.tar.gz" ]] || fail "快照缺少 1panel_data.tar.gz，无法还原"
tar -zxf "$SNAP_ROOT/1panel_data.tar.gz" -C "$DATA_DIR" || fail "解压 1panel_data.tar.gz 失败"
ok "核心数据还原完成"

deploy_extra_runtime_files

step "10/12 还原数据库到 $DB_DIR"
[[ -d "$SNAP_ROOT/db" ]] || fail "快照缺少 db/ 目录"
rm -rf "$DB_DIR"; mkdir -p "$DB_DIR"
cp -a "$SNAP_ROOT/db/." "$DB_DIR/" || fail "复制数据库失败"

for f in "$DB_DIR"/*.db-wal "$DB_DIR"/*.db-shm; do
  [[ -e "$f" ]] || continue
  main="${f%-wal}"; main="${main%-shm}"
  [[ -e "$main" ]] || { rm -f "$f"; warn "清理孤儿 SQLite 侧车文件: $f"; }
done
ok "数据库还原完成: $(ls -1 "$SNAP_ROOT/db/" 2>/dev/null | tr '\n' ' ')"

if [[ "$SKIP_APPS" == true || "$HAS_COMPOSE" != true ]]; then
  step "11/12 跳过应用拉起 (--skip-apps 或 docker/compose 不可用)"
else
  step "11/12 拉起已安装的应用 (docker compose up -d)"
  COMPOSE_DIR="$DATA_DIR/docker/compose"
  if [[ -d "$COMPOSE_DIR" ]]; then
    for f in "$COMPOSE_DIR"/*/docker-compose.yml; do
      [[ -f "$f" ]] || continue
      app=$(basename "$(dirname "$f")")
      log "启动应用: $app"
      docker compose -f "$f" up -d >/dev/null 2>&1 \
        && ok "  $app 已启动" \
        || warn "  $app 启动失败，稍后请在面板内手动处理"
    done
  else
    warn "未找到 $COMPOSE_DIR，跳过应用拉起"
  fi
fi

step "12/12 启动 1Panel 服务"
mkdir -p /etc/1panel
case "$INIT_MGR" in
  systemd)
    systemctl daemon-reload
    [[ "$SNAP_SCOPE" == "core" ]] && systemctl enable 1panel-core.service >/dev/null 2>&1
    systemctl enable 1panel-agent.service >/dev/null 2>&1
    [[ "$SNAP_SCOPE" == "core" ]] && { systemctl restart 1panel-core || fail "1panel-core 启动失败，请查看 systemctl status 1panel-core"; }
    systemctl restart 1panel-agent || fail "1panel-agent 启动失败，请查看 systemctl status 1panel-agent"
    ;;
  openrc)
    [[ "$SNAP_SCOPE" == "core" ]] && rc-update add 1panel-core default >/dev/null 2>&1
    rc-update add 1panel-agent default >/dev/null 2>&1
    [[ "$SNAP_SCOPE" == "core" ]] && rc-service 1panel-core start
    rc-service 1panel-agent start
    ;;
  sysvinit)
    [[ "$SNAP_SCOPE" == "core" ]] && /etc/init.d/1panel-core start
    /etc/init.d/1panel-agent start
    ;;
esac

log "等待服务就绪..."
sleep 5

echo
echo "========================================================================"
ok "1Panel 还原流程执行完毕"

if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active 1panel-core 2>/dev/null | grep -q active && ok "1panel-core 运行中" || warn "1panel-core 状态异常"
  systemctl is-active 1panel-agent 2>/dev/null | grep -q active && ok "1panel-agent 运行中" || warn "1panel-agent 状态异常"
fi

if [[ -f /usr/local/bin/lang/zh.sh ]]; then
  ok "1pctl 就绪"
  if [[ -x /usr/local/bin/1pctl ]]; then
    log "1pctl version 自检: "
    /usr/local/bin/1pctl version 2>/dev/null || true
  fi
else
  RUNTIME_MISSING=true
  warn "1pctl 语言环境缺失: 标题/命令说明将为空，version 输出为英文"
fi

collect_panel_access
get_panel_ips
show_panel_access
echo "========================================================================"

if [[ "$RUNTIME_MISSING" == true ]]; then
  echo
  warn "运行环境文件未完整部署。可联网后执行以下命令补齐 (不影响已还原的面板) : "
  echo "  curl -fsSL https://resource.fit2cloud.com/1panel/package/v2/language/lang.tar.gz -o /tmp/lang.tar.gz"
  echo "  tar -zxf /tmp/lang.tar.gz -C /usr/local/bin/          # 补齐 1pctl 语言文件"
  echo "  或把官方安装包解包到本脚本所在目录后重新运行 (脚本会自动探测并部署到官方位置) : "
  echo "    /usr/local/bin/lang/、$DATA_DIR/geo/、$DATA_DIR/resource/initscript/"
fi

rm -rf "$WORK_DIR"
exit 0
