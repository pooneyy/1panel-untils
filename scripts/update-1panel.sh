#!/usr/bin/env bash

set -Eeuo pipefail

_detected_self="${BASH_SOURCE[0]:-$0}"
case "$_detected_self" in
  /dev/fd/*|/proc/self/fd/*|*/dev/fd/*|/dev/stdin|/dev/tty|bash|sh|*/bash|*/sh|"")
    _SELF_NAME="update-1panel.sh" ;;
  *) _SELF_NAME="$(basename "$_detected_self")" ;;
esac
readonly SCRIPT_NAME="$_SELF_NAME"
readonly PCTL="/usr/local/bin/1pctl"
readonly BIN_DIR="/usr/local/bin"
readonly LANG_DIR="/usr/local/bin/lang"

BASE_DIR=""            # 安装根目录，来自 1pctl 的 BASE_DIR，默认 /opt
RUN_DIR=""             # $BASE_DIR/1panel
DB_DIR=""              # $RUN_DIR/db
GEO_DIR=""             # $RUN_DIR/geo
CUR_VERSION=""         # 当前版本 (1pctl ORIGINAL_VERSION)
TARGET_VERSION=""      # 目标版本
LANGUAGE="zh"          # 1pctl LANGUAGE
EDITION=""             # cn / intl
MODE="stable"          # stable / beta
ARCH=""
REPO_URL=""
PKG_FILE=""            # --file 指定的离线包
PKG_DIR=""             # 解包后的目录
TMP_DIR=""
BACKUP_DIR=""
SVC_DIR=""
INIT_SYS=""
CORE_SVC=""
AGENT_SVC=""
EXPECT_SHA256=""
PROXY=""
CURL_BIN=""

DRY_RUN=false
ASSUME_YES=false
CHECK_ONLY=false
NO_RESTART=false
AUTO_ROLLBACK=false
RESTORE_DB=false
DO_ROLLBACK=false
ROLLBACK_DIR=""
FORCE=false

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()   { printf '[%s] %s\n' "$(_ts)" "$*"; }
info()  { printf '[%s] [INFO]  %s\n' "$(_ts)" "$*"; }
warn()  { printf '[%s] [WARN]  %s\n' "$(_ts)" "$*" >&2; }
err()   { printf '[%s] [ERROR] %s\n' "$(_ts)" "$*" >&2; }
die()   { err "$*"; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
step()  { printf '\n[%s] ===== %s =====\n' "$(_ts)" "$*"; }

conf_get() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 1
  line="$(grep -m1 "^${key}=" "$file" 2>/dev/null || true)"
  [ -n "$line" ] || return 1
  printf '%s' "${line#*=}"
}

conf_set() {
  local file="$1" key="$2" value="$3" esc tmp
  esc="$(printf '%s' "$value" | sed 's/[\\&#]/\\&/g')"
  if grep -q "^${key}=" "$file"; then
    sed -i "s#^${key}=.*#${key}=${esc}#" "$file"
  else
    tmp="${file}.tmp.$$"
    awk -v kv="${key}=${value}" 'NR==1{print; print kv; next} {print}' "$file" > "$tmp"
    mv -f "$tmp" "$file"
  fi
}

escape_sed_repl() { printf '%s' "$1" | sed 's/[\\&#]/\\&/g'; }

version_gt() {
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

validate_version() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]
}

usage() {
  cat <<EOF
不依赖 Web 面板升级 1Panel v2

用法:
  bash ${SCRIPT_NAME} [选项]

版本选择
  -v, --version <vX.Y.Z>   指定目标版本 (默认查询官方 latest)
  -m, --mode <stable|beta> 发布通道，默认 stable；版本号含 beta 时自动切 beta
  -e, --edition <cn|intl>  发行版，默认从 1pctl 的 PANEL_EDITION 读取
      --repo-url <URL>     自定义资源站根地址 (企业版/私有源)
  -f, --file <path>        使用本地离线安装包 .tar.gz，跳过下载
      --sha256 <HEX>       校验安装包的 SHA256 (可选)

环境
  -b, --base-dir <dir>     覆盖安装根目录 (默认读 1pctl 的 BASE_DIR)
  -p, --proxy <URL>        下载代理，如 http://127.0.0.1:7890

行为
  -c, --check              只检查当前版本与最新版本，不做任何改动
  -n, --dry-run            打印将要执行的操作，不改动系统
  -y, --yes                跳过交互确认
      --force              允许降级 / 重装同版本
      --no-restart         替换文件后不自动重启服务
      --auto-rollback      升级失败或服务启动异常时自动回滚

回滚
      --rollback [dir]     回滚到指定备份目录；不指定则用最近一次备份
      --restore-db         回滚时同时恢复数据库 (默认只恢复程序文件)

  -h, --help               显示帮助
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      -v|--version)   TARGET_VERSION="${2:-}"; shift 2 ;;
      -m|--mode)      MODE="${2:-}"; shift 2 ;;
      -e|--edition)   EDITION="${2:-}"; shift 2 ;;
      --repo-url)     REPO_URL="${2:-}"; shift 2 ;;
      -f|--file)      PKG_FILE="${2:-}"; shift 2 ;;
      --sha256)       EXPECT_SHA256="${2:-}"; shift 2 ;;
      -b|--base-dir)  BASE_DIR="${2:-}"; shift 2 ;;
      -p|--proxy)     PROXY="${2:-}"
                      export http_proxy="$PROXY" https_proxy="$PROXY"
                      export HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
                      shift 2 ;;
      -c|--check)     CHECK_ONLY=true; shift ;;
      -n|--dry-run)   DRY_RUN=true; shift ;;
      -y|--yes)       ASSUME_YES=true; shift ;;
      --force)        FORCE=true; shift ;;
      --no-restart)   NO_RESTART=true; shift ;;
      --auto-rollback) AUTO_ROLLBACK=true; shift ;;
      --restore-db)   RESTORE_DB=true; shift ;;
      --rollback)
        DO_ROLLBACK=true
        if (($# > 1)) && [[ "$2" != -* ]]; then ROLLBACK_DIR="$2"; shift 2; else shift; fi
        ;;
      -h|--help)      usage; exit 0 ;;
      *)              die "未知参数: $1 (用 --help 查看用法) " ;;
    esac
  done

  case "$MODE" in
    stable|beta) ;;
    *) die "--mode 只能是 stable 或 beta" ;;
  esac
  if [ -n "$TARGET_VERSION" ] && ! validate_version "$TARGET_VERSION"; then
    die "版本号格式不合法: $TARGET_VERSION (示例 v2.4.2 / v2.4.0-beta.1) "
  fi
  if [[ "$TARGET_VERSION" == *beta* ]]; then MODE="beta"; fi
}

preflight() {
  step "环境检查"

  [ "$(id -u)" -eq 0 ] || die "必须以 root 运行 (sudo bash $SCRIPT_NAME ...) "

  if [ "$DO_ROLLBACK" != true ]; then
    [ -f "$PCTL" ] || die "未找到 $PCTL，请确认这是 1Panel v2 主机；v1 不适用本脚本"
    [ -f "$BIN_DIR/1panel-core" ] || die "未找到 $BIN_DIR/1panel-core"
    [ -f "$BIN_DIR/1panel-agent" ] || die "未找到 $BIN_DIR/1panel-agent"
  fi

  [ -n "$BASE_DIR" ] || BASE_DIR="$(conf_get "$PCTL" BASE_DIR || true)"
  [ -n "$BASE_DIR" ] || die "无法从 $PCTL 读取 BASE_DIR，请用 --base-dir 指定安装根目录"
  [[ "$BASE_DIR" = /* ]] || die "BASE_DIR 必须是绝对路径: $BASE_DIR"
  RUN_DIR="$BASE_DIR/1panel"
  DB_DIR="$RUN_DIR/db"
  GEO_DIR="$RUN_DIR/geo"
  [ -d "$RUN_DIR" ] || die "安装目录不存在: $RUN_DIR"

  CUR_VERSION="$(conf_get "$PCTL" ORIGINAL_VERSION || true)"
  if [ -z "$CUR_VERSION" ]; then
    [ "$DO_ROLLBACK" = true ] || die "无法从 $PCTL 读取 ORIGINAL_VERSION"
    CUR_VERSION="unknown"
  fi
  LANGUAGE="$(conf_get "$PCTL" LANGUAGE || true)"; [ -n "$LANGUAGE" ] || LANGUAGE="zh"
  [ -n "$EDITION" ] || EDITION="$(conf_get "$PCTL" PANEL_EDITION || true)"
  [ -n "$EDITION" ] || EDITION="cn"

  case "$EDITION" in
    cn)   [ -n "$REPO_URL" ] || REPO_URL="https://resource.fit2cloud.com/1panel/package/v2" ;;
    intl) [ -n "$REPO_URL" ] || REPO_URL="https://resource.1panel.pro/v2" ;;
    *)    [ -n "$REPO_URL" ] || die "无法识别的发行版 '$EDITION' (企业版等请用 --repo-url 指定资源站) " ;;
  esac
  REPO_URL="${REPO_URL%/}"

  case "$(uname -m)" in
    x86_64|amd64)   ARCH="amd64" ;;
    aarch64|arm64)  ARCH="arm64" ;;
    armv7l)         ARCH="armv7" ;;
    ppc64le)        ARCH="ppc64le" ;;
    s390x)          ARCH="s390x" ;;
    riscv64)        ARCH="riscv64" ;;
    *) die "不支持的架构: $(uname -m) (官方支持 amd64/arm64/armv7/ppc64le/s390x/riscv64) " ;;
  esac

  if have systemctl && { [ -d /run/systemd/system ] || \
    [ -f /etc/systemd/system/1panel-core.service ] || \
    [ -f /etc/systemd/system/1panel-agent.service ]; }; then
    INIT_SYS="systemd"; SVC_DIR="/etc/systemd/system"
    CORE_SVC="1panel-core.service"; AGENT_SVC="1panel-agent.service"
  elif have rc-service; then
    INIT_SYS="openrc"; SVC_DIR="/etc/init.d"
    CORE_SVC="1panel-core"; AGENT_SVC="1panel-agent"
  else
    INIT_SYS="sysvinit"; SVC_DIR="/etc/init.d"
    CORE_SVC="1panel-core"; AGENT_SVC="1panel-agent"
  fi

  if have curl; then CURL_BIN="curl"; elif have wget; then CURL_BIN="wget"; else die "需要 curl 或 wget"; fi
  have tar || die "需要 tar"
  have sed || die "需要 sed"
  have awk || die "需要 awk"

  info "当前版本   : $CUR_VERSION"
  info "安装根目录 : $BASE_DIR"
  info "发行版/通道: $EDITION / $MODE"
  info "资源站     : $REPO_URL"
  info "架构       : $ARCH"
  info "服务管理   : $INIT_SYS ($SVC_DIR)"
}

check_space() {
  local avail_kb
  avail_kb="$(df -Pk "$BASE_DIR" | awk 'NR==2 {print $4}')"
  [ -n "$avail_kb" ] && [ "$avail_kb" -ge 512000 ] || \
    die "可用空间不足 500MB (当前 $((avail_kb / 1024))MB)，升级中止"
  info "磁盘可用空间    : $((avail_kb / 1024)) MB (要求 >= 500 MB) "
}

http_get() {
  local url="$1" out="${2:-}"
  if [ "$CURL_BIN" = "curl" ]; then
    if [ -n "$out" ]; then
      curl  -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 900 \
            -o "$out" "$url"
    else
      curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 30 "$url"
    fi
  else
    if [ -n "$out" ]; then
      wget -q --tries=3 --timeout=30 -O "$out" "$url"
    else
      wget -q --tries=3 --timeout=30 -O - "$url"
    fi
  fi
}

resolve_version() {
  step "确定目标版本"

  # 离线包: 从文件名推断版本 1panel-<ver>-linux-<arch>.tar.gz
  if [ -n "$PKG_FILE" ]; then
    [ -f "$PKG_FILE" ] || die "离线安装包不存在: $PKG_FILE"
    if [ -z "$TARGET_VERSION" ]; then
      local fname="${PKG_FILE##*/}" cand
      cand="${fname#1panel-}"
      cand="${cand%-linux-*}"
      if ! validate_version "$cand"; then
        local listfile pctl_entry
        listfile="$(mktemp)"
        tar -tzf "$PKG_FILE" > "$listfile" 2>/dev/null || true
        pctl_entry="$(grep -m1 '/1pctl$' "$listfile" || true)"
        rm -f "$listfile"
        if [ -n "$pctl_entry" ]; then
          cand="$(tar -xOf "$PKG_FILE" "$pctl_entry" 2>/dev/null \
                  | grep -m1 '^ORIGINAL_VERSION=' | cut -d= -f2- || true)"
        fi
      fi
      validate_version "$cand" || \
        die "无法从离线包解析版本 ($fname)，请用 --version 显式指定"
      TARGET_VERSION="$cand"
    fi
    info "使用离线安装包: $PKG_FILE"
  fi

  if [ -z "$TARGET_VERSION" ]; then
    info "查询官方最新版本: $REPO_URL/$MODE/latest"
    TARGET_VERSION="$(http_get "$REPO_URL/$MODE/latest" | tr -d '[:space:]')"
    validate_version "$TARGET_VERSION" || die "官方返回的版本号异常: '$TARGET_VERSION'"
  fi

  [[ "$TARGET_VERSION" == v2.* ]] || warn "目标版本不是 v2.x，脚本按 v2 流程处理，请自行确认兼容性"
  [[ "$TARGET_VERSION" == *beta* ]] && MODE="beta"

  info "目标版本        : $TARGET_VERSION ($MODE)"

  if [ "$CHECK_ONLY" = true ]; then
    if version_gt "$TARGET_VERSION" "$CUR_VERSION"; then
      info "有可用更新 $CUR_VERSION -> $TARGET_VERSION"
    else
      info "已是最新版本 ($CUR_VERSION) "
    fi
    exit 0
  fi

  if [ "$TARGET_VERSION" = "$CUR_VERSION" ] && [ "$FORCE" != true ]; then
    info "目标版本与当前版本相同，无需升级 (如需重装请加 --force) "
    exit 0
  fi
  if ! version_gt "$TARGET_VERSION" "$CUR_VERSION" && [ "$FORCE" != true ]; then
    die "目标版本 $TARGET_VERSION 不高于当前 $CUR_VERSION，拒绝降级 (如需强制请加 --force) "
  fi
}

prepare_package() {
  step "获取并校验发布包"
  TMP_DIR="$(mktemp -d /tmp/update-1panel.XXXXXX)"
  mkdir -p "$TMP_DIR/extract"

  local tarball="$TMP_DIR/1panel-$TARGET_VERSION-linux-$ARCH.tar.gz"
  if [ -n "$PKG_FILE" ]; then
    cp -f "$PKG_FILE" "$tarball"
  else
    local url="$REPO_URL/$MODE/$TARGET_VERSION/release/1panel-$TARGET_VERSION-linux-$ARCH.tar.gz"
    info "下载地址: $url"
    http_get "$url" "$tarball" || die "下载失败: $url"
  fi

  [ -s "$tarball" ] || die "安装包为空或下载不完整"
  info "包大小: $(du -h "$tarball" | awk '{print $1}')"
  info "SHA256: $(sha256sum "$tarball" | awk '{print $1}')"
  if [ -n "$EXPECT_SHA256" ]; then
    local actual; actual="$(sha256sum "$tarball" | awk '{print $1}')"
    [ "${actual,,}" = "${EXPECT_SHA256,,}" ] || die "SHA256 校验失败: 期望 $EXPECT_SHA256 实际 $actual"
    info "SHA256 校验通过"
  fi
  gzip -t "$tarball" 2>/dev/null || die "安装包 gzip 校验失败，文件已损坏"
  tar -tzf "$tarball" >/dev/null || die "安装包 tar 校验失败，文件已损坏"

  local listing="$TMP_DIR/tar.list" top
  tar -tzf "$tarball" > "$listing"
  top="$(head -n1 "$listing" | cut -d/ -f1)"
  [ -n "$top" ] || die "无法识别安装包顶层目录"
  tar -xzf "$tarball" -C "$TMP_DIR/extract" || die "解包失败"
  PKG_DIR="$TMP_DIR/extract/$top"
  for f in 1panel-core 1panel-agent 1pctl GeoIP.mmdb initscript lang; do
    [ -e "$PKG_DIR/$f" ] || die "安装包缺少 $f，不是有效的 1Panel v2 发布包"
  done
  info "解包完成: $PKG_DIR"
}

service_active() {
  local name="$1"
  case "$INIT_SYS" in
    systemd)  systemctl is-active --quiet "$name" ;;
    openrc)   rc-service "$name" status >/dev/null 2>&1 ;;
    *)        service "$name" status >/dev/null 2>&1 ;;
  esac
}

stop_services() {
  info "停止 1panel-agent / 1panel-core (保证数据库备份一致)"
  case "$INIT_SYS" in
    systemd)
      systemctl stop "$AGENT_SVC" >/dev/null 2>&1 || warn "停止 $AGENT_SVC 失败 (可能未运行)"
      systemctl stop "$CORE_SVC"  >/dev/null 2>&1 || warn "停止 $CORE_SVC 失败 (可能未运行)"
      ;;
    openrc)
      rc-service 1panel-agent stop >/dev/null 2>&1 || warn "停止 agent 失败 (可能未运行)"
      rc-service 1panel-core  stop >/dev/null 2>&1 || warn "停止 core 失败 (可能未运行)"
      ;;
    *)
      service 1panel-agent stop >/dev/null 2>&1 || warn "停止 agent 失败 (可能未运行)"
      service 1panel-core  stop >/dev/null 2>&1 || warn "停止 core 失败 (可能未运行)"
      ;;
  esac
}

restart_services() {
  info "重启 1Panel 服务 (顺序: daemon-reload -> agent -> core)"
  case "$INIT_SYS" in
    systemd)
      systemctl daemon-reload || warn "daemon-reload 失败"
      systemctl enable "$AGENT_SVC" >/dev/null 2>&1 || true
      systemctl enable "$CORE_SVC"  >/dev/null 2>&1 || true
      systemctl restart "$AGENT_SVC" || die "重启 $AGENT_SVC 失败"
      systemctl restart "$CORE_SVC"  || die "重启 $CORE_SVC 失败"
      ;;
    openrc)
      rc-service 1panel-agent restart || die "重启 agent 失败"
      rc-service 1panel-core  restart || die "重启 core 失败"
      ;;
    *)
      service 1panel-agent restart || die "重启 agent 失败"
      service 1panel-core  restart || die "重启 core 失败"
      ;;
  esac
}

backup_current() {
  step "备份当前版本"
  local ts; ts="$(date '+%Y%m%d-%H%M%S')"
  BACKUP_DIR="$RUN_DIR/backup/update-1panel-${CUR_VERSION}-${ts}"
  local orig="$BACKUP_DIR/original"
  mkdir -p "$orig"

  cp -a "$BIN_DIR/1panel-core"  "$orig/1panel-core"
  cp -a "$BIN_DIR/1panel-agent" "$orig/1panel-agent"
  cp -a "$PCTL"                 "$orig/1pctl"
  [ -d "$LANG_DIR" ] && cp -a "$LANG_DIR" "$orig/lang"
  [ -f "$GEO_DIR/GeoIP.mmdb" ] && cp -a "$GEO_DIR/GeoIP.mmdb" "$orig/GeoIP.mmdb"
  if [ -d "$DB_DIR" ]; then
    cp -a "$DB_DIR" "$orig/db"
    chmod -R 700 "$orig/db"
  fi
  [ -f "$SVC_DIR/$CORE_SVC" ]  && cp -a "$SVC_DIR/$CORE_SVC"  "$orig/service-$CORE_SVC"
  [ -f "$SVC_DIR/$AGENT_SVC" ] && cp -a "$SVC_DIR/$AGENT_SVC" "$orig/service-$AGENT_SVC"

  cat > "$BACKUP_DIR/manifest.txt" <<EOF
TIMESTAMP=$ts
OLD_VERSION=$CUR_VERSION
NEW_VERSION=$TARGET_VERSION
BASE_DIR=$BASE_DIR
INIT_SYS=$INIT_SYS
SVC_DIR=$SVC_DIR
CORE_SVC=$CORE_SVC
AGENT_SVC=$AGENT_SVC
ARCH=$ARCH
MODE=$MODE
EDITION=$EDITION
REPO_URL=$REPO_URL
EOF
  info "备份完成: $BACKUP_DIR"
  info "回滚命令: bash $SCRIPT_NAME --rollback $BACKUP_DIR"
}

replace_file() {
  local src="$1" dst="$2" mode="${3:-755}"
  [ -f "$src" ] || die "待替换文件不存在: $src"
  cp -f "$src" "${dst}.tmp.$$" || die "复制到 $dst 失败"
  chmod "$mode" "${dst}.tmp.$$"
  mv -f "${dst}.tmp.$$" "$dst" || die "替换 $dst 失败"
  info "已替换 $dst"
}

build_new_1pctl() {
  local out="$TMP_DIR/1pctl.merged"
  cp -f "$PKG_DIR/1pctl" "$out"
  local key val
  for key in ORIGINAL_PORT ORIGINAL_ENTRANCE ORIGINAL_USERNAME ORIGINAL_PASSWORD LANGUAGE PANEL_EDITION; do
    val="$(conf_get "$PCTL" "$key" || true)"
    [ -n "$val" ] || continue
    conf_set "$out" "$key" "$val"
  done
  conf_set "$out" "BASE_DIR" "$BASE_DIR"
  conf_set "$out" "ORIGINAL_VERSION" "$TARGET_VERSION"
  sed -i '/^CHANGE_USER_INFO=/d' "$out"
  chmod 755 "$out"
  printf '%s' "$out"
}

install_files() {
  step "替换程序文件"

  replace_file "$PKG_DIR/1panel-core"  "$BIN_DIR/1panel-core"  755
  replace_file "$PKG_DIR/1panel-agent" "$BIN_DIR/1panel-agent" 755
  local merged; merged="$(build_new_1pctl)"
  replace_file "$merged" "$PCTL" 755

  ln -sf "$BIN_DIR/1panel-core"  /usr/bin/1panel-core
  ln -sf "$BIN_DIR/1panel-core"  /usr/bin/1panel
  ln -sf "$BIN_DIR/1panel-agent" /usr/bin/1panel-agent
  ln -sf "$PCTL"                 /usr/bin/1pctl

  mkdir -p "$LANG_DIR"
  cp -f "$PKG_DIR"/lang/*.sh "$LANG_DIR"/
  info "已更新 $LANG_DIR"

  mkdir -p "$GEO_DIR"
  cp -f "$PKG_DIR/GeoIP.mmdb" "$GEO_DIR/GeoIP.mmdb" || warn "GeoIP.mmdb 更新失败 (不影响主程序) "
  info "已更新 $GEO_DIR/GeoIP.mmdb"

  mkdir -p "$SVC_DIR"
  case "$INIT_SYS" in
    systemd)
      cp -f "$PKG_DIR/initscript/1panel-core.service"  "$SVC_DIR/1panel-core.service"
      cp -f "$PKG_DIR/initscript/1panel-agent.service" "$SVC_DIR/1panel-agent.service"
      chmod 644 "$SVC_DIR/1panel-core.service" "$SVC_DIR/1panel-agent.service"
      ;;
    openrc)
      cp -f "$PKG_DIR/initscript/1panel-core.openrc"  "$SVC_DIR/1panel-core"
      cp -f "$PKG_DIR/initscript/1panel-agent.openrc" "$SVC_DIR/1panel-agent"
      chmod 755 "$SVC_DIR/1panel-core" "$SVC_DIR/1panel-agent"
      ;;
    *)
      local suffix="init"; [ -f /etc/rc.common ] && suffix="procd"
      cp -f "$PKG_DIR/initscript/1panel-core.$suffix"  "$SVC_DIR/1panel-core"
      cp -f "$PKG_DIR/initscript/1panel-agent.$suffix" "$SVC_DIR/1panel-agent"
      chmod 755 "$SVC_DIR/1panel-core" "$SVC_DIR/1panel-agent"
      ;;
  esac
  info "已更新服务脚本 ($INIT_SYS)"

  mkdir -p "$RUN_DIR/resource/initscript"
  cp -a "$PKG_DIR/initscript/." "$RUN_DIR/resource/initscript/"
  info "已更新 $RUN_DIR/resource/initscript"
}

sync_db_version() {
  step "同步数据库版本号"
  [ -d "$DB_DIR" ] || { warn "数据库目录不存在: $DB_DIR，跳过"; return 0; }

  local updated=0 db
  if have sqlite3; then
    for db in core.db agent.db; do
      [ -f "$DB_DIR/$db" ] || continue
      if sqlite3 "$DB_DIR/$db" \
        "UPDATE settings SET value='${TARGET_VERSION}' WHERE key='SystemVersion';" 2>/dev/null; then
        info "$db SystemVersion -> $TARGET_VERSION"
        updated=$((updated + 1))
      else
        warn "更新 $db 失败 (表结构可能不同)，交由启动 hook 同步"
      fi
    done
  fi

  if [ "$updated" -eq 0 ] && [ -x "$BIN_DIR/1panel-core" ]; then
    if "$BIN_DIR/1panel-core" -l "$LANGUAGE" update version "$TARGET_VERSION" >/dev/null 2>&1; then
      info "已通过 1panel-core update version 更新 core.db"
      updated=1
    else
      warn "CLI 更新版本号未成功，将在服务启动时由 hook 自动同步"
    fi
  fi
  [ "$updated" -gt 0 ] || warn "未能直接写库；新版 core/agent 启动时会依据 1pctl 的 ORIGINAL_VERSION 自动同步"
  info "1pctl ORIGINAL_VERSION 已设为 $TARGET_VERSION"
}

health_check() {
  step "升级后检查"
  local i ok=true
  for i in $(seq 1 15); do
    if service_active "$AGENT_SVC" && service_active "$CORE_SVC"; then break; fi
    sleep 2
  done
  if service_active "$CORE_SVC";  then info "1panel-core  运行中"; else err "1panel-core  未运行"; ok=false; fi
  if service_active "$AGENT_SVC"; then info "1panel-agent 运行中"; else err "1panel-agent 未运行"; ok=false; fi

  local shown; shown="$(conf_get "$PCTL" ORIGINAL_VERSION || true)"
  [ "$shown" = "$TARGET_VERSION" ] && info "1pctl 版本号: $shown" || { err "1pctl 版本号异常: $shown"; ok=false; }

  if have 1pctl; then
    local vout; vout="$(1pctl version 2>/dev/null || true)"
    if printf '%s' "$vout" | grep -qF "$TARGET_VERSION"; then
      info "1pctl version 已返回 $TARGET_VERSION"
    else
      warn "1pctl version 暂未显示 $TARGET_VERSION (core.db 可能由启动 hook 延迟同步) "
    fi
  fi

  if [ "$ok" = false ]; then
    err "服务状态异常！请先查看日志: journalctl -u 1panel-core -u 1panel-agent -n 100"
    err "如需回滚: bash $SCRIPT_NAME --rollback $BACKUP_DIR"
    return 1
  fi
  info "升级完成: $CUR_VERSION -> $TARGET_VERSION"
  info "备份保留在: $BACKUP_DIR"
  return 0
}

do_rollback() {
  step "回滚 1Panel"

  local dir="$ROLLBACK_DIR"
  if [ -z "$dir" ]; then
    dir="$(ls -1dt "$RUN_DIR"/backup/update-1panel-* 2>/dev/null | head -n1 || true)"
  fi
  [ -n "$dir" ] && [ -d "$dir/original" ] || die "没有可用的备份目录 (可用 --rollback <dir> 指定) "
  [ -f "$dir/manifest.txt" ] || die "备份缺少 manifest.txt: $dir"

  INIT_SYS="$(conf_get "$dir/manifest.txt" INIT_SYS || echo "$INIT_SYS")"
  SVC_DIR="$(conf_get "$dir/manifest.txt" SVC_DIR || echo "$SVC_DIR")"
  CORE_SVC="$(conf_get "$dir/manifest.txt" CORE_SVC || echo "$CORE_SVC")"
  AGENT_SVC="$(conf_get "$dir/manifest.txt" AGENT_SVC || echo "$AGENT_SVC")"
  local old_ver; old_ver="$(conf_get "$dir/manifest.txt" OLD_VERSION || echo '?')"
  local orig="$dir/original"

  info "备份版本: $old_ver"
  info "备份目录: $dir"
  if [ "$ASSUME_YES" != true ]; then
    ans=""
    if [ -r /dev/tty ]; then
      read -r -p "确认回滚？[y/N] " ans < /dev/tty || ans=""
    else
      read -r -p "确认回滚？[y/N] " ans || ans=""
    fi
    [[ "$ans" == y || "$ans" == Y ]] || { info "已取消"; exit 0; }
  fi

  stop_services

  replace_file "$orig/1panel-core"  "$BIN_DIR/1panel-core"  755
  replace_file "$orig/1panel-agent" "$BIN_DIR/1panel-agent" 755
  replace_file "$orig/1pctl"        "$PCTL"                 755
  [ -d "$orig/lang" ] && { mkdir -p "$LANG_DIR"; cp -a "$orig/lang/." "$LANG_DIR"/; info "已还原语言包"; }
  [ -f "$orig/GeoIP.mmdb" ] && { mkdir -p "$GEO_DIR"; cp -f "$orig/GeoIP.mmdb" "$GEO_DIR"/; info "已还原 GeoIP"; }
  [ -f "$orig/service-$CORE_SVC" ]  && { cp -a "$orig/service-$CORE_SVC"  "$SVC_DIR/$CORE_SVC";  info "已还原 $CORE_SVC"; }
  [ -f "$orig/service-$AGENT_SVC" ] && { cp -a "$orig/service-$AGENT_SVC" "$SVC_DIR/$AGENT_SVC"; info "已还原 $AGENT_SVC"; }

  if [ "$RESTORE_DB" = true ]; then
    if [ -d "$orig/db" ]; then
      rm -f "$DB_DIR"/*.db-wal "$DB_DIR"/*.db-shm 2>/dev/null || true
      cp -a "$orig/db/." "$DB_DIR"/
      chmod -R 700 "$DB_DIR"
      info "已还原数据库"
    else
      warn "备份中没有 db 目录，跳过数据库还原"
    fi
  else
    warn "按默认策略未还原数据库。若新版本已执行过数据库迁移，"
    warn "旧版程序可能无法读取新库，可追加 --restore-db --rollback $dir 重试"
  fi

  if [ "$NO_RESTART" != true ]; then
    restart_services
  fi
  info "回滚完成，版本应恢复为 $old_ver (可执行 1pctl version 确认) "
}

on_error() {
  local line="$1" cmd="$2"
  trap - ERR
  err "执行失败 (第 ${line} 行): ${cmd}"
  [ -n "$BACKUP_DIR" ] && err "本次备份: $BACKUP_DIR"
  if [ "$AUTO_ROLLBACK" = true ] && [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR/original" ]; then
    warn "尝试自动回滚..."
    ROLLBACK_DIR="$BACKUP_DIR"
    ASSUME_YES=true
    do_rollback || err "自动回滚也失败了，请人工检查上面的备份目录"
  else
    [ -n "$BACKUP_DIR" ] && err "手动回滚: bash $SCRIPT_NAME --rollback $BACKUP_DIR"
  fi
  exit 1
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

cleanup() {
  [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
  return 0
}
trap cleanup EXIT

confirm() {
  [ "$ASSUME_YES" = true ] && return 0
  cat <<EOF

即将执行:
  当前版本 : $CUR_VERSION
  目标版本 : $TARGET_VERSION ($MODE)
  安装目录 : $BASE_DIR
  资源站   : $REPO_URL
  备份位置 : $RUN_DIR/backup/
  升级过程会短暂停止 1panel-core / 1panel-agent 服务。
EOF
  ans=""
  if [ -r /dev/tty ]; then
    read -r -p "确认继续？[y/N] " ans < /dev/tty || ans=""
  else
    read -r -p "确认继续？[y/N] " ans || ans=""
  fi
  [[ "$ans" == y || "$ans" == Y ]] || { info "已取消"; exit 0; }
}

main() {
  parse_args "$@"
  preflight

  if [ "$DO_ROLLBACK" = true ]; then
    do_rollback
    exit 0
  fi

  resolve_version
  check_space

  if [ "$DRY_RUN" = true ]; then
    step "dry-run"
    if [ -n "$PKG_FILE" ]; then
      info "1. 使用离线包 $PKG_FILE"
    else
      info "1. 下载 $REPO_URL/$MODE/$TARGET_VERSION/release/1panel-$TARGET_VERSION-linux-$ARCH.tar.gz"
    fi
    info "2. 停止 1panel-agent / 1panel-core"
    info "3. 备份到 $RUN_DIR/backup/update-1panel-${CUR_VERSION}-<时间戳>/original"
    info "4. 替换 1panel-core / 1panel-agent / 1pctl / lang / GeoIP.mmdb / $INIT_SYS 服务脚本"
    info "5. 同步 core.db / agent.db 的 SystemVersion 为 $TARGET_VERSION"
    info "6. daemon-reload 并重启 agent、core，检查服务状态"
    exit 0
  fi

  if [ -z "$PKG_FILE" ]; then
    local url="$REPO_URL/$MODE/$TARGET_VERSION/release/1panel-$TARGET_VERSION-linux-$ARCH.tar.gz"
    info "探测发布包      : $url"
    if [ "$CURL_BIN" = "curl" ]; then
      curl -fsSI --connect-timeout 15 --max-time 30 "$url" >/dev/null 2>&1 || \
        die "目标发布包不存在或不可访问: $url (检查版本号、通道、架构、网络) "
    fi
  fi

  confirm
  prepare_package
  stop_services
  backup_current
  install_files
  sync_db_version
  if [ "$NO_RESTART" = true ]; then
    warn "传入 --no-restart 将会跳过重启，请手动执行: 1pctl restart"
    exit 0
  fi
  restart_services
  if ! health_check; then
    if [ "$AUTO_ROLLBACK" = true ]; then
      ROLLBACK_DIR="$BACKUP_DIR"; ASSUME_YES=true; do_rollback
    fi
    exit 1
  fi
}

main "$@"
