#!/bin/bash

# ============================================================
#  PostgreSQL Download Script v1.3
#  - 폐쇄망 설치를 위한 패키지 다운로드
#  - single / HA(Patroni + etcd) 모드 지원
#  - v1.3: UI 디자인 통일 (박스 / 아이콘 / 색상)
# ============================================================

set -e

WORK_DIR="postgresql"
INSTALLER_DIR="${WORK_DIR}/installer"

# ── 색상 / 출력 함수 ─────────────────────────────────────────
BOLD='\033[1m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

info()  { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
error() { echo -e "  ${RED}✘${NC}  $*"; exit 1; }
step()  { echo -e "\n${CYAN}${BOLD}▶  $*${NC}"; }
div()   { echo -e "  ─────────────────────────────────────────────"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   PostgreSQL Download Script  v1.3           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── 사전 도구 확인 (tar / wget) ──────────────────────────────
MISSING_PKGS=()
command -v tar  &>/dev/null || MISSING_PKGS+=(tar)
command -v wget &>/dev/null || MISSING_PKGS+=(wget)

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}┌─ 사전 설치 필요 ───────────────────────────────────┐${NC}"
    for _p in "${MISSING_PKGS[@]}"; do
        echo -e "  ${YELLOW}│${NC}    - ${_p}"
    done
    echo -e "  ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  아래 명령어로 먼저 설치해 주세요:"
    echo -e "  ${YELLOW}│${NC}    sudo dnf install -y ${MISSING_PKGS[*]}"
    echo -e "  ${YELLOW}└────────────────────────────────────────────────────┘${NC}"
    echo ""
    if [[ " ${MISSING_PKGS[*]} " =~ " tar " ]]; then
        exit 1
    fi
fi

# ============================================================
#  입력값 수집
# ============================================================
step "다운로드 옵션 설정"
div

read -rp "  의존 패키지를 다운로드 하시겠습니까? [Y/n]: " DOWNLOAD_PKG
DOWNLOAD_PKG="${DOWNLOAD_PKG:-Y}"

# 2. PostgreSQL 버전 — 지원 버전 표 출력 후 입력
echo ""
echo -e "  ${BOLD}PostgreSQL 지원 버전 현황${NC}"
div

# PostgreSQL 공식 EOL 페이지에서 버전 정보 조회
_PG_EOL_URL="https://endoflife.date/api/postgresql.json"
_PG_JSON=""
if command -v curl &>/dev/null; then
    _PG_JSON=$(curl -sf --max-time 5 "${_PG_EOL_URL}" 2>/dev/null || true)
elif command -v wget &>/dev/null; then
    _PG_JSON=$(wget -qO- --timeout=5 "${_PG_EOL_URL}" 2>/dev/null || true)
fi

PG_VERSION_DEFAULT="16.9"  # fallback 기본값
if [[ -n "${_PG_JSON}" ]] && command -v python3 &>/dev/null; then
    # 표 출력(stdout) + 기본값을 마지막 줄에 출력 → mapfile로 분리
    mapfile -t _PG_LINES < <(python3 - <<PYEOF
import json
from datetime import date

data = json.loads('''${_PG_JSON}''')
today = date.today()

active = []
for entry in data:
    try:
        if date.fromisoformat(entry.get('eol', '')) >= today:
            active.append(entry)
    except Exception:
        pass
active.sort(key=lambda e: int(e.get('cycle', '0')), reverse=True)

print(f"  {'메이저':>4}  {'최신버전':<10}  {'지원 종료일':<12}")
print(f"  {'----':>4}  {'--------':<10}  {'----------':<12}")
for entry in active:
    print(f"  {entry['cycle']:>4}  {entry['latest']:<10}  {entry['eol']:<12}")

default = active[1]['latest'] if len(active) >= 2 else active[0]['latest']
print(f"__DEFAULT__:{default}")
PYEOF
    )
    # 마지막 줄에서 기본값 추출, 나머지는 화면 출력
    for _line in "${_PG_LINES[@]}"; do
        if [[ "${_line}" == __DEFAULT__:* ]]; then
            PG_VERSION_DEFAULT="${_line#__DEFAULT__:}"
        else
            echo "${_line}"
        fi
    done
else
    echo "  (버전 정보 자동 조회 실패 — 아래는 참고용 정보입니다)"
    echo ""
    echo "    메이저   최신버전     지원 종료일"
    echo "    ──────   ──────────   ────────────"
    echo "      17     17.10        2029-11-08"
    echo "      16     16.9         2028-11-09"
    echo "      15     15.13        2027-11-11"
    echo "      14     14.18        2026-11-12"
fi

echo "────────────────────────────────────────"
echo ""
read -rp "다운로드할 PostgreSQL 버전을 입력하세요 [${PG_VERSION_DEFAULT}]: " PG_VERSION
PG_VERSION="${PG_VERSION:-${PG_VERSION_DEFAULT}}"
PG_MAJOR="${PG_VERSION%%.*}"

# 3. HA 구성 여부
echo ""
div
read -rp "  HA 구성용 패키지(etcd + Patroni)도 다운로드 하시겠습니까? [y/N]: " DOWNLOAD_HA
DOWNLOAD_HA="${DOWNLOAD_HA:-N}"

ETCD_VERSION=""
if [[ "${DOWNLOAD_HA,,}" =~ ^(y|yes)$ ]]; then
    read -rp "    etcd 버전 [3.5.17]: " ETCD_VERSION
    ETCD_VERSION="${ETCD_VERSION:-3.5.17}"
fi
echo ""

# ============================================================
#  설정 확인
# ============================================================
echo -e "  ${BOLD}┌─ 설정 확인 ─────────────────────────────────────────┐${NC}"
echo -e "  ${BOLD}│${NC}  의존 패키지   : ${DOWNLOAD_PKG}"
echo -e "  ${BOLD}│${NC}  PostgreSQL    : v${PG_VERSION}  (메이저: ${PG_MAJOR})"
if [[ "${DOWNLOAD_HA,,}" =~ ^(y|yes)$ ]]; then
echo -e "  ${BOLD}│${NC}  HA 패키지     : Y  (etcd v${ETCD_VERSION} + Patroni)"
else
echo -e "  ${BOLD}│${NC}  HA 패키지     : N"
fi
echo -e "  ${BOLD}│${NC}  저장 위치     : $(pwd)/${WORK_DIR}/"
echo -e "  ${BOLD}└────────────────────────────────────────────────────┘${NC}"
echo ""

# ============================================================
#  디렉토리 생성
# ============================================================
mkdir -p "${WORK_DIR}"
mkdir -p "${INSTALLER_DIR}"

PKG_LOG="${WORK_DIR}/PKG_download.log"

# ============================================================
#  1. 의존 패키지 다운로드 (dnf)
# ============================================================
case "${DOWNLOAD_PKG,,}" in
    y|yes)
        PKG_TMP="${WORK_DIR}/PKG"
        mkdir -p "${PKG_TMP}"

        info "의존 패키지를 다운로드합니다..."
        info "다운로드 로그 → ${PKG_LOG}"

        PKG_LIST=(
            make gcc gcc-c++
            readline-devel zlib-devel openssl-devel
            libxml2-devel libxslt-devel libicu-devel
            libuuid-devel tcl tcl-devel
            bison flex perl python3-devel
            python3-pip
        )

        sudo dnf install -y \
            --downloadonly \
            --downloaddir="${PKG_TMP}" \
            --setopt=alwaysincludepkgs=1 \
            "${PKG_LIST[@]}" \
            >> "${PKG_LOG}" 2>&1 || true

        # 이미 설치된 패키지는 --downloadonly 로 안 받아지는 경우가 있으므로
        # download 서브커맨드로 의존성 포함 강제 다운로드
        sudo dnf download -y \
            --resolve \
            --destdir="${PKG_TMP}" \
            "${PKG_LIST[@]}" \
            >> "${PKG_LOG}" 2>&1 || true

        info "PKG 디렉토리를 tar.gz 으로 압축합니다..."
        tar -czf "${WORK_DIR}/PKG.tar.gz" -C "${WORK_DIR}" PKG
        rm -rf "${PKG_TMP}"
        info "압축 완료 → ${WORK_DIR}/PKG.tar.gz"
        ;;
    n|no)
        info "의존 패키지 다운로드를 건너뜁니다."
        ;;
    *)
        warn "알 수 없는 입력('${DOWNLOAD_PKG}') — 패키지 다운로드를 건너뜁니다."
        ;;
esac

# ============================================================
#  PKG 다운로드 후 python3-pip 로컬 설치
#  - PKG.tar.gz 안에 python3-pip rpm이 포함되어 있으므로
#    이 시점에 dnf install 하면 Primary/Standby 배포용 rpm도 확보되고
#    이후 Patroni wheel 다운로드에도 pip3를 바로 사용 가능
# ============================================================
if ! command -v pip3 &>/dev/null; then
    info "python3-pip 설치 중 (Patroni wheel 다운로드에 필요)..."
    sudo dnf install -y python3-pip >> "${PKG_LOG}" 2>&1 \
        && info "python3-pip 설치 완료" \
        || error "python3-pip 설치 실패. 로그: ${PKG_LOG}"
else
    info "python3-pip 이미 설치됨 ($(pip3 --version))"
fi

# ============================================================
#  2. PostgreSQL 소스 다운로드
# ============================================================
PG_TARBALL="postgresql-${PG_VERSION}.tar.gz"
PG_URL="https://ftp.postgresql.org/pub/source/v${PG_VERSION}/${PG_TARBALL}"
PG_DEST="${INSTALLER_DIR}/${PG_TARBALL}"

echo ""
info "PostgreSQL ${PG_VERSION} 소스를 다운로드합니다..."
echo "       URL : ${PG_URL}"

if command -v wget &>/dev/null; then
    wget -q --show-progress -O "${PG_DEST}" "${PG_URL}"
else
    info "wget 을 찾을 수 없어 curl 을 사용합니다."
    curl -L --progress-bar -o "${PG_DEST}" "${PG_URL}"
fi
info "PostgreSQL 소스 다운로드 완료 → ${PG_DEST}"

# ============================================================
#  3. HA 패키지 다운로드 (etcd + Patroni)
# ============================================================
if [[ "${DOWNLOAD_HA,,}" =~ ^(y|yes)$ ]]; then

    # ── 3-1. etcd 바이너리 다운로드 ──────────────────────────
    echo ""
    ETCD_TARBALL="etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
    ETCD_URL="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/${ETCD_TARBALL}"
    ETCD_DEST="${INSTALLER_DIR}/${ETCD_TARBALL}"

    info "etcd v${ETCD_VERSION} 바이너리를 다운로드합니다..."
    echo "       URL : ${ETCD_URL}"

    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "${ETCD_DEST}" "${ETCD_URL}"
    else
        curl -L --progress-bar -o "${ETCD_DEST}" "${ETCD_URL}"
    fi
    info "etcd 다운로드 완료 → ${ETCD_DEST}"

    # ── 3-2. Patroni pip wheel 다운로드 ──────────────────────
    echo ""
    info "Patroni pip wheel 다운로드를 시작합니다..."
    info "다운로드 로그 → ${PKG_LOG}"

    PATRONI_TMP="${WORK_DIR}/patroni_pkgs"
    mkdir -p "${PATRONI_TMP}"

    # ── Patroni 및 의존 패키지 다운로드 ─────────────────────
    # patroni[etcd]: ydiff 포함 의존성 자동 다운로드
    # etcd3gw     : patroni.yml etcd3 섹션 처리 (v3 API 클라이언트)
    # dnspython   : python-etcd 의존성 (import dns.resolver)
    # wcwidth     : prettytable 의존성 (patronictl list 출력)
    # psycopg2-binary: PostgreSQL Python 드라이버
    WHEEL_PKGS=(
        "patroni[etcd]"
        "psycopg2-binary"
        "etcd3gw"
        "dnspython"
        "wcwidth"
    )

    for _pkg in "${WHEEL_PKGS[@]}"; do
        pip3 download \
            --dest "${PATRONI_TMP}" \
            --prefer-binary \
            "${_pkg}" \
            >> "${PKG_LOG}" 2>&1 \
            && info "  ✔ ${_pkg} 다운로드 완료" \
            || warn "  ✘ ${_pkg} 다운로드 실패. 로그: ${PKG_LOG}"
    done

    # 핵심 패키지 존재 여부 확인
    MISSING_WHEELS=()
    ls "${PATRONI_TMP}"/patroni-*.whl &>/dev/null   || MISSING_WHEELS+=(patroni)
    ls "${PATRONI_TMP}"/etcd3gw-*.whl &>/dev/null   || MISSING_WHEELS+=(etcd3gw)
    if [[ ${#MISSING_WHEELS[@]} -gt 0 ]]; then
        error "필수 패키지가 없습니다: ${MISSING_WHEELS[*]}\n  다운로드 로그를 확인하세요: ${PKG_LOG}"
    fi
    _whl_count=$(ls "${PATRONI_TMP}"/*.whl 2>/dev/null | wc -l)
    _tar_count=$(ls "${PATRONI_TMP}"/*.tar.gz 2>/dev/null | wc -l)
    info "다운로드 완료 — wheel: ${_whl_count}개, tarball: ${_tar_count}개"

    info "Patroni 패키지를 tar.gz 으로 압축합니다..."
    tar -czf "${INSTALLER_DIR}/patroni_pkgs.tar.gz" -C "${WORK_DIR}" patroni_pkgs
    rm -rf "${PATRONI_TMP}"
    info "압축 완료 → ${INSTALLER_DIR}/patroni_pkgs.tar.gz"

fi

# ============================================================
#  4. postgresql_install.sh 생성 (installer/ 하위)
# ============================================================
INSTALL_DEST="${WORK_DIR}/postgresql_install.sh"
info "postgresql_install.sh 생성 중 → ${INSTALL_DEST}"


cat > "${INSTALL_DEST}" << 'INSTALL_EOF'
#!/bin/bash

# ============================================================
#  PostgreSQL Install Script v1.0
#  - single 모드 : 로컬 서버에 PostgreSQL 설치
#  - ha 모드     : etcd 서버(local)에서 빌드 후
#                  Primary / Standby 로 scp 배포
#                  Patroni + etcd 자동 구성
#
#  [사전 조건 - HA 모드]
#  1. /etc/hosts 에 etcd / primary / standby 호스트 등록
#  2. ssh-keygen + ssh-copy-id 로 키 교환 완료
#  3. Primary / Standby 의 실행 유저가 sudo NOPASSWD 설정
#     예) /etc/sudoers.d/postgres
#         postgres ALL=(ALL) NOPASSWD: ALL
# ============================================================

set -e

# ── 색상 / 출력 함수 ─────────────────────────────────────────
BOLD='\033[1m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

info()  { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
error() { echo -e "  ${RED}✘${NC}  $*"; exit 1; }
phase() { echo -e "\n${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
          echo -e "${CYAN}${BOLD}  $*${NC}"
          echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
div()   { echo -e "  ─────────────────────────────────────────────"; }

# ── 스크립트 위치 기준 경로 ───────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER_DIR="${SCRIPT_DIR}/installer"
HOME_DIR="${HOME:-$(eval echo ~"$(whoami)")}"

# ── 서버 리소스 자동 조회 (로컬) ─────────────────────────────
LOCAL_CPU=$(nproc 2>/dev/null || echo "4")
LOCAL_MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "4194304")
LOCAL_MEM_GB=$(( LOCAL_MEM_KB / 1024 / 1024 ))
[[ "$LOCAL_MEM_GB" -lt 1 ]] && LOCAL_MEM_GB=1

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   PostgreSQL Install Script  v1.3            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================
#  installer/ 디렉토리 및 패키지 확인
# ============================================================
[[ ! -d "${INSTALLER_DIR}" ]] && \
    error "installer/ 디렉토리를 찾을 수 없습니다: ${INSTALLER_DIR}"

PG_TARBALL=$(ls "${INSTALLER_DIR}"/postgresql-*.tar.gz 2>/dev/null | head -1)
[[ -z "${PG_TARBALL}" ]] && \
    error "installer/ 에서 postgresql-*.tar.gz 를 찾을 수 없습니다."

PG_VERSION=$(basename "${PG_TARBALL}" | sed 's/postgresql-//;s/\.tar\.gz//')
PG_MAJOR="${PG_VERSION%%.*}"

ETCD_TARBALL=$(ls "${INSTALLER_DIR}"/etcd-v*-linux-amd64.tar.gz 2>/dev/null | head -1)
PATRONI_PKGS="${INSTALLER_DIR}/patroni_pkgs.tar.gz"
PKG_TGZ="${SCRIPT_DIR}/PKG.tar.gz"

HA_PKGS_AVAILABLE=false
if [[ -n "${ETCD_TARBALL}" && -f "${PATRONI_PKGS}" ]]; then
    HA_PKGS_AVAILABLE=true
    ETCD_VERSION=$(basename "${ETCD_TARBALL}" | sed 's/etcd-v//;s/-linux-amd64\.tar\.gz//')
fi

info "PostgreSQL 소스: $(basename "${PG_TARBALL}") (v${PG_VERSION})"
[[ "${HA_PKGS_AVAILABLE}" == true ]] && \
    info "HA 패키지 확인: etcd v${ETCD_VERSION} / Patroni wheel"

# ============================================================
#  STEP 0. PostgreSQL 프로세스 구동 여부 확인
# ============================================================
if pgrep -x "postgres" > /dev/null 2>&1; then
    warn "PostgreSQL 프로세스가 이미 실행 중입니다."
    ps aux | grep "[p]ostgres" | head -5
    echo ""
    read -rp "계속 진행하시겠습니까? [y/N]: " PROC_CONTINUE
    [[ ! "${PROC_CONTINUE:-N,,}" =~ ^(y|yes)$ ]] && { info "설치 중단."; exit 0; }
else
    info "실행 중인 PostgreSQL 프로세스가 없습니다."
fi

# ============================================================
#  STEP 1. 기본 입력값 수집
# ============================================================
read -rp "PostgreSQL 을 설치하시겠습니까? [Y/n]: " DO_INSTALL
[[ ! "${DO_INSTALL:-Y,,}" =~ ^(y|yes)$ ]] && { info "설치 중단."; exit 0; }

# 설치 모드
echo ""
echo -e "  ${BOLD}┌─ 설치 모드 선택 ───────────────────────────────────┐${NC}"
echo -e "  ${BOLD}│${NC}   1)  single  —  로컬 서버에만 PostgreSQL 설치"
if [[ "${HA_PKGS_AVAILABLE}" == true ]]; then
echo -e "  ${BOLD}│${NC}   2)  ha      —  etcd + Primary / Standby HA 구성"
else
echo -e "  ${BOLD}│${NC}   2)  ha      —  ${YELLOW}[패키지 없음]${NC} download 시 HA 옵션 선택 필요"
fi
echo -e "  ${BOLD}└────────────────────────────────────────────────────┘${NC}"
read -rp "  선택 [1]: " MODE_SEL
case "${MODE_SEL:-1}" in
    1) INSTALL_MODE="single" ;;
    2) [[ "${HA_PKGS_AVAILABLE}" != true ]] && \
           error "HA 패키지가 없습니다. download 스크립트에서 HA 옵션 선택 후 재다운로드 하세요."
       INSTALL_MODE="ha" ;;
    *) error "잘못된 선택입니다." ;;
esac

# ============================================================
#  STEP 2. single 모드 입력
# ============================================================
if [[ "${INSTALL_MODE}" == "single" ]]; then

    read -rp "사용할 CPU core 수를 입력하세요 [${LOCAL_CPU}]: " CPU_CORES
    CPU_CORES="${CPU_CORES:-${LOCAL_CPU}}"

    read -rp "서버 Memory 를 입력하세요 (GB) [${LOCAL_MEM_GB}]: " MEM_GB
    MEM_GB="${MEM_GB:-${LOCAL_MEM_GB}}"

    read -rp "사용할 PostgreSQL Port 를 입력하세요 [5432]: " PG_PORT
    PG_PORT="${PG_PORT:-5432}"

fi

# ============================================================
#  STEP 3. HA 모드 입력
# ============================================================
HA_ETCD_HOST="" ; HA_PRIMARY_HOST="" ; HA_STANDBY_HOST=""
HA_SSH_PORT="" ; CLUSTER_NAME=""
REPL_USER_HA="" ; REPL_PASS_HA=""
PRI_CPU="" ; PRI_MEM_GB=""
SBY_CPU="" ; SBY_MEM_GB=""
PG_PORT=""

if [[ "${INSTALL_MODE}" == "ha" ]]; then

    echo ""
    echo -e "  ${BOLD}┌─ HA 구성 정보 입력 ────────────────────────────────┐${NC}"
    echo -e "  ${BOLD}└────────────────────────────────────────────────────┘${NC}"

    read -rp "  클러스터 이름 [pg-cluster]: " CLUSTER_NAME
    CLUSTER_NAME="${CLUSTER_NAME:-pg-cluster}"

    read -rp "  etcd 서버 IP 또는 호스트명 (현재 서버): " HA_ETCD_HOST
    [[ -z "${HA_ETCD_HOST}" ]] && error "etcd 호스트를 입력해야 합니다."

    read -rp "  Primary DB IP 또는 호스트명: " HA_PRIMARY_HOST
    [[ -z "${HA_PRIMARY_HOST}" ]] && error "Primary 호스트를 입력해야 합니다."

    read -rp "  Standby DB IP 또는 호스트명: " HA_STANDBY_HOST
    [[ -z "${HA_STANDBY_HOST}" ]] && error "Standby 호스트를 입력해야 합니다."

    read -rp "  SSH 포트 [22]: " HA_SSH_PORT
    HA_SSH_PORT="${HA_SSH_PORT:-22}"

    read -rp "  PostgreSQL Port [5432]: " PG_PORT
    PG_PORT="${PG_PORT:-5432}"

    read -rp "  복제 유저명 [replicator]: " REPL_USER_HA
    REPL_USER_HA="${REPL_USER_HA:-replicator}"

    read -rsp "  복제 유저 패스워드: " REPL_PASS_HA; echo ""
    [[ -z "${REPL_PASS_HA}" ]] && error "복제 유저 패스워드를 입력해야 합니다."

    echo ""
    echo -e "  ${BOLD}  ┌─ Primary DB 리소스 ─┐${NC}"
    read -rp "    CPU core 수 [${LOCAL_CPU}]: " PRI_CPU
    PRI_CPU="${PRI_CPU:-${LOCAL_CPU}}"
    read -rp "    Memory (GB)  [${LOCAL_MEM_GB}]: " PRI_MEM_GB
    PRI_MEM_GB="${PRI_MEM_GB:-${LOCAL_MEM_GB}}"

    echo ""
    echo -e "  ${BOLD}  ┌─ Standby DB 리소스 ─┐${NC}"
    read -rp "    CPU core 수 [${PRI_CPU}]: " SBY_CPU
    SBY_CPU="${SBY_CPU:-${PRI_CPU}}"
    read -rp "    Memory (GB)  [${PRI_MEM_GB}]: " SBY_MEM_GB
    SBY_MEM_GB="${SBY_MEM_GB:-${PRI_MEM_GB}}"

    # 빌드는 etcd 서버(로컬)에서 하므로 로컬 CPU 사용
    CPU_CORES="${LOCAL_CPU}"
    MEM_GB="${LOCAL_MEM_GB}"

fi

# ── 공통 경로 입력 ────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}┌─ 경로 설정 ─────────────────────────────────────────┐${NC}"
echo -e "  ${BOLD}└────────────────────────────────────────────────────┘${NC}"
read -rp "엔진 설치 경로 [/postgres]: " ENGINE_BASE
ENGINE_BASE="${ENGINE_BASE:-/postgres}"
ENGINE_PATH="${ENGINE_BASE}/app"

read -rp "Data 영역 경로 [/pgdata]: " DATA_BASE
DATA_BASE="${DATA_BASE:-/pgdata}"
DATA_PATH="${DATA_BASE}/data"
LOG_PATH="${DATA_BASE}/log"
echo "  Log 경로 : ${LOG_PATH}"

read -rp "Archive 영역을 사용하시겠습니까? [Y/n]: " USE_ARCHIVE
USE_ARCHIVE="${USE_ARCHIVE:-Y}"
ARC_PATH=""
if [[ "${USE_ARCHIVE,,}" =~ ^(y|yes)$ ]]; then
    read -rp "  Archive 상위 경로 [/pgbackup]: " ARC_BASE
    ARC_BASE="${ARC_BASE:-/pgbackup}"
    ARC_PATH="${ARC_BASE}/arc"
    echo "  Archive 경로 : ${ARC_PATH}"
fi

read -rp "Backup 영역을 사용하시겠습니까? [Y/n]: " USE_BACKUP
USE_BACKUP="${USE_BACKUP:-Y}"
BACK_PATH="" ; DUMP_PATH="" ; BACKUP_CRON="" ; BACKUP_KEEP="" ; REPL_USER=""
if [[ "${USE_BACKUP,,}" =~ ^(y|yes)$ ]]; then
    read -rp "  Backup 상위 경로 [/pgbackup]: " BACK_BASE
    BACK_BASE="${BACK_BASE:-/pgbackup}"
    BACK_PATH="${BACK_BASE}/back"
    DUMP_PATH="${BACK_BASE}/dump"
    echo "  Backup 경로 : ${BACK_PATH}"

    echo "  백업 주기:"
    echo "    1) 매일 새벽 2시"
    echo "    2) 매주 일요일 새벽 2시"
    echo "    3) 직접 입력"
    read -rp "  선택 [1]: " BACKUP_CRON_SEL
    case "${BACKUP_CRON_SEL:-1}" in
        1) BACKUP_CRON="0 2 * * *" ;;
        2) BACKUP_CRON="0 2 * * 0" ;;
        3) read -rp "  cron 표현식: " BACKUP_CRON ;;
        *) BACKUP_CRON="0 2 * * *" ;;
    esac
    echo "  백업 주기 : ${BACKUP_CRON}"

    read -rp "  백업 유지 개수 [7]: " BACKUP_KEEP
    BACKUP_KEEP="${BACKUP_KEEP:-7}"

    if [[ "${INSTALL_MODE}" == "ha" ]]; then
        REPL_USER="${REPL_USER_HA}"
        echo "  복제 유저 : ${REPL_USER} (HA 설정 상속)"
    else
        read -rp "  복제 유저명 [replicator]: " REPL_USER
        REPL_USER="${REPL_USER:-replicator}"
    fi
fi

# ── single 모드 기본 포트 설정 ────────────────────────────────
[[ "${INSTALL_MODE}" == "single" && -z "${PG_PORT}" ]] && PG_PORT="5432"

# ============================================================
#  설정 확인 출력
# ============================================================
echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║            설정 최종 확인                    ║${NC}"
echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}  ║${NC}  설치 모드  : ${INSTALL_MODE}"
if [[ "${INSTALL_MODE}" == "single" ]]; then
echo -e "${BOLD}  ║${NC}  CPU Cores  : ${CPU_CORES}"
echo -e "${BOLD}  ║${NC}  Memory     : ${MEM_GB} GB"
echo -e "${BOLD}  ║${NC}  Port       : ${PG_PORT}"
else
echo -e "${BOLD}  ║${NC}  클러스터   : ${CLUSTER_NAME}"
echo -e "${BOLD}  ║${NC}  etcd 서버  : ${HA_ETCD_HOST}"
echo -e "${BOLD}  ║${NC}  Primary    : ${HA_PRIMARY_HOST}  (CPU:${PRI_CPU} / MEM:${PRI_MEM_GB}GB)"
echo -e "${BOLD}  ║${NC}  Standby    : ${HA_STANDBY_HOST}  (CPU:${SBY_CPU} / MEM:${SBY_MEM_GB}GB)"
echo -e "${BOLD}  ║${NC}  SSH Port   : ${HA_SSH_PORT}"
echo -e "${BOLD}  ║${NC}  PG Port    : ${PG_PORT}"
echo -e "${BOLD}  ║${NC}  복제 유저  : ${REPL_USER_HA}"
fi
echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}  ║${NC}  엔진 경로  : ${ENGINE_PATH}"
echo -e "${BOLD}  ║${NC}  Data 경로  : ${DATA_PATH}"
echo -e "${BOLD}  ║${NC}  Log 경로   : ${LOG_PATH}"
[[ -n "${ARC_PATH}"  ]] && echo -e "${BOLD}  ║${NC}  Archive    : ${ARC_PATH}"
[[ -n "${BACK_PATH}" ]] && echo -e "${BOLD}  ║${NC}  Backup     : ${BACK_PATH}"
echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${NC}"
echo ""
read -rp "위 설정으로 설치를 진행하시겠습니까? [Y/n]: " CONFIRM
[[ ! "${CONFIRM:-Y,,}" =~ ^(y|yes)$ ]] && { info "설치 중단."; exit 0; }

# ============================================================
#  로그 초기화
# ============================================================
mkdir -p "${LOG_PATH}"
LOG_INSTALL="${LOG_PATH}/pg_install.log"
HA_LOG="${LOG_PATH}/ha_setup.log"

cat > "${LOG_INSTALL}" <<EOF
============================================================
  PostgreSQL Install Log
  Started : $(date '+%Y-%m-%d %H:%M:%S')
  Mode    : ${INSTALL_MODE}
  Version : ${PG_VERSION}
============================================================
EOF

# ============================================================
#  공통 함수 모음
# ============================================================

# ── postgresql.conf 생성 함수 ────────────────────────────────
# 인자: $1=출력파일 $2=CPU수 $3=메모리GB $4=모드(single|ha) $5=ARC_PATH
fn_gen_conf() {
    local OUT="$1" CPU="$2" MEM="$3" MODE="$4" ARC="$5"
    local MEM_KB=$(( MEM * 1024 * 1024 ))
    local SHR_MB=$(( MEM_KB / 4 / 1024 ))
    local EFF_MB=$(( MEM_KB * 3 / 4 / 1024 ))
    local MAX_CONN=150
    local WORK_MB=$(( (MEM_KB / 4) / MAX_CONN / 1024 ))
    [[ $WORK_MB -lt 4   ]] && WORK_MB=4
    local MAINT_MB=$(( MEM_KB / 20 / 1024 ))
    [[ $MAINT_MB -lt 64   ]] && MAINT_MB=64
    [[ $MAINT_MB -gt 2048 ]] && MAINT_MB=2048
    local WAL_BUF_MB=$(( SHR_MB * 3 / 100 ))
    [[ $WAL_BUF_MB -lt 1  ]] && WAL_BUF_MB=1
    [[ $WAL_BUF_MB -gt 64 ]] && WAL_BUF_MB=64
    local MIN_WAL=$(( MEM * 1024 / 16 ))
    [[ $MIN_WAL -lt 256  ]] && MIN_WAL=256
    local MAX_WAL=$(( MEM * 1024 / 4 ))
    [[ $MAX_WAL -lt 1024 ]] && MAX_WAL=1024
    local KEEP_WAL=$(( MAX_WAL / 2 ))
    [[ $KEEP_WAL -lt 512 ]] && KEEP_WAL=512
    local PARA=$(( CPU / 2 ))
    [[ $PARA -lt 1 ]] && PARA=1

    cat > "${OUT}" <<CONFEOF
# ============================================================
#  postgresql.conf  (Generated by postgresql_install.sh v1.0)
#  CPU: ${CPU}  MEM: ${MEM}GB  Mode: ${MODE}
# ============================================================

# ── 접속 설정 ──────────────────────────────────────────────
listen_addresses = '*'
port             = ${PG_PORT}
max_connections  = ${MAX_CONN}

# ── 메모리 설정 ────────────────────────────────────────────
shared_buffers          = ${SHR_MB}MB
effective_cache_size    = ${EFF_MB}MB
work_mem                = ${WORK_MB}MB
maintenance_work_mem    = ${MAINT_MB}MB

# ── WAL 설정 ───────────────────────────────────────────────
wal_buffers                  = ${WAL_BUF_MB}MB
checkpoint_completion_target = 0.9
wal_level                    = replica
min_wal_size                 = ${MIN_WAL}MB
max_wal_size                 = ${MAX_WAL}MB
wal_keep_size                = ${KEEP_WAL}MB
CONFEOF

    if [[ -n "${ARC}" ]]; then
        cat >> "${OUT}" <<CONFEOF
archive_mode    = on
archive_command = 'cp %p ${ARC}/%f'
CONFEOF
    else
        cat >> "${OUT}" <<CONFEOF
archive_mode    = off
# archive_command = ''
CONFEOF
    fi

    cat >> "${OUT}" <<CONFEOF

# ── 병렬 처리 ──────────────────────────────────────────────
max_worker_processes             = ${CPU}
max_parallel_workers_per_gather  = ${PARA}
max_parallel_workers             = ${CPU}

# ── 로그 설정 ──────────────────────────────────────────────
logging_collector = on
log_directory     = '${LOG_PATH}'
log_filename      = 'postgresql-%Y-%m-%d.log'
log_rotation_age  = 1d
log_rotation_size = 100MB
log_statement     = 'ddl'
log_min_duration_statement = 1000
log_line_prefix   = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints   = on
log_connections   = on
log_disconnections= on
log_lock_waits    = on

# ── 타임존 / 로케일 ────────────────────────────────────────
timezone          = 'Asia/Seoul'
lc_messages       = 'en_US.utf8'
lc_monetary       = 'ko_KR.utf8'
lc_numeric        = 'ko_KR.utf8'
lc_time           = 'ko_KR.utf8'
CONFEOF

    if [[ "${MODE}" == "ha" ]]; then
        cat >> "${OUT}" <<CONFEOF

# ── HA Replication 설정 ────────────────────────────────────
max_wal_senders       = 10
max_replication_slots = 10
CONFEOF
    fi
}

# ── PKG rpm 설치 함수 (로컬) ─────────────────────────────────
fn_install_pkg_local() {
    if [[ -f "${PKG_TGZ}" ]]; then
        info "의존 패키지(rpm) 설치 중..."
        local TMP
        TMP=$(mktemp -d)
        tar -zxf "${PKG_TGZ}" -C "${TMP}" >> "${LOG_INSTALL}" 2>&1
        sudo rpm -Uvh --force "${TMP}"/PKG/*.rpm >> "${LOG_INSTALL}" 2>&1 || true
        rm -rf "${TMP}"
        info "의존 패키지 설치 완료"
    else
        warn "PKG.tar.gz 없음. 의존패키지가 사전 설치되어 있어야 합니다."
    fi
}

# ── PG 빌드 함수 (로컬) ──────────────────────────────────────
fn_build_pg_local() {
    local BUILD_CPU="${1:-${CPU_CORES}}"
    info "PostgreSQL 소스 빌드 중 (make -j${BUILD_CPU})..."
    local TMP
    TMP=$(mktemp -d)
    tar -zxf "${PG_TARBALL}" -C "${TMP}" >> "${LOG_INSTALL}" 2>&1
    pushd "${TMP}/postgresql-${PG_VERSION}" > /dev/null
    ./configure \
        --prefix="${ENGINE_PATH}" \
        --with-openssl --with-libxml --with-libxslt \
        --enable-nls --with-python --with-tcl --with-perl \
        >> "${LOG_INSTALL}" 2>&1 || error "configure 실패. 로그: ${LOG_INSTALL}"
    make -j"${BUILD_CPU}" >> "${LOG_INSTALL}" 2>&1 || error "make 실패"
    make install          >> "${LOG_INSTALL}" 2>&1 || error "make install 실패"
    popd > /dev/null
    rm -rf "${TMP}"
    info "PostgreSQL 빌드 및 설치 완료 → ${ENGINE_PATH}"
}

# ── 디렉토리 생성 함수 (로컬) ────────────────────────────────
fn_create_dirs_local() {
    mkdir -p "${ENGINE_PATH}/etc" "${DATA_PATH}" "${LOG_PATH}"
    [[ -n "${ARC_PATH}"  ]] && mkdir -p "${ARC_PATH}"
    [[ -n "${BACK_PATH}" ]] && mkdir -p "${BACK_PATH}" "${DUMP_PATH}"
}

# ── sudo 권한 확인 함수 (원격) ───────────────────────────────
fn_check_sudo_remote() {
    local HOST="$1"
    local SSH_OPTS="$2"
    info "[${HOST}] sudo NOPASSWD 권한 확인 중..."
    if ssh ${SSH_OPTS} "${HOST}" "sudo -n true" >> "${HA_LOG}" 2>&1; then
        info "[${HOST}] sudo 권한 확인 완료"
    else
        error "[${HOST}] sudo NOPASSWD 권한이 없습니다.
  아래 명령어를 ${HOST} 서버에서 root 로 실행해주세요:
  echo '$(whoami) ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/$(whoami)
  chmod 440 /etc/sudoers.d/$(whoami)"
    fi
}

# ── .postgresrc 생성 함수 ────────────────────────────────────
fn_gen_postgresrc() {
    local OUT="$1"
    cat > "${OUT}" <<RCEOF
# PostgreSQL Environment
export PGHOME=${ENGINE_PATH}
export PATH=\${PGHOME}/bin:\${PATH}
export LD_LIBRARY_PATH=\${PGHOME}/lib:\${LD_LIBRARY_PATH}
export PGDATA=${DATA_PATH}
export PGPORT=${PG_PORT}
export PGUSER=postgres
RCEOF
}

# ============================================================
# ████████████████  SINGLE MODE  ████████████████████████████
# ============================================================
if [[ "${INSTALL_MODE}" == "single" ]]; then

    info "============================================================"
    info "  SINGLE 모드: 로컬 서버에 PostgreSQL 설치"
    info "============================================================"

    fn_install_pkg_local
    fn_create_dirs_local
    fn_build_pg_local "${CPU_CORES}"

    # 환경변수 설정
    POSTGRESRC="${HOME_DIR}/.postgresrc"
    fn_gen_postgresrc "${POSTGRESRC}"
    grep -q '.postgresrc' "${HOME_DIR}/.bashrc" 2>/dev/null \
        || printf '\n# PostgreSQL Environment\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' \
           >> "${HOME_DIR}/.bashrc"
    # shellcheck source=/dev/null
    source "${POSTGRESRC}"
    info ".postgresrc 설정 완료"

    # postgresql.conf 생성
    CONF_TMP=$(mktemp)
    fn_gen_conf "${CONF_TMP}" "${CPU_CORES}" "${MEM_GB}" "single" "${ARC_PATH}"

    # initdb
    info "initdb 실행 중..."
    "${ENGINE_PATH}/bin/initdb" \
        --pgdata="${DATA_PATH}" --encoding=UTF8 \
        --locale=ko_KR.utf8 --data-checksums \
        >> "${LOG_INSTALL}" 2>&1
    cp "${CONF_TMP}" "${DATA_PATH}/postgresql.conf"
    rm -f "${CONF_TMP}"
    info "initdb 완료"

    # 백업 스크립트
    if [[ -n "${BACK_PATH}" ]]; then
        BACKUP_SCRIPT="${ENGINE_PATH}/etc/pg_basebackup.sh"
        cat > "${BACKUP_SCRIPT}" <<BKEOF
#!/bin/bash
BKDIR="${BACK_PATH}/\$(date +%Y%m%d_%H%M%S)"
mkdir -p "\${BKDIR}"
${ENGINE_PATH}/bin/pg_basebackup -h 127.0.0.1 -p ${PG_PORT} -U ${REPL_USER} \
    -D "\${BKDIR}" -Fp -Xs -P -R >> "${LOG_PATH}/pg_basebackup.log" 2>&1
find "${BACK_PATH}" -maxdepth 1 -type d -mtime +${BACKUP_KEEP} \
    -exec rm -rf {} \; 2>/dev/null || true
BKEOF
        chmod 750 "${BACKUP_SCRIPT}"
        EXISTING_CRON=$(crontab -l 2>/dev/null || true)
        echo "${EXISTING_CRON}" | grep -qF "${BACKUP_SCRIPT}" \
            || ( echo "${EXISTING_CRON}"; \
                 echo "${BACKUP_CRON} ${BACKUP_SCRIPT} >> ${LOG_PATH}/cron_backup.log 2>&1" \
               ) | crontab -
        info "백업 스크립트 및 cron 등록 완료"
    fi

    # PostgreSQL 기동
    info "PostgreSQL 기동 중..."
    "${ENGINE_PATH}/bin/pg_ctl" -D "${DATA_PATH}" -l "${LOG_PATH}/startup.log" start
    sleep 3
    info "PostgreSQL 기동 완료 (Port: ${PG_PORT})"
    "${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres -c "SELECT version();"

    # 복제 유저 생성 (Backup 사용 시)
    if [[ -n "${REPL_USER}" ]]; then
        info "복제 유저 생성 중: ${REPL_USER}"
        "${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres \
            -c "CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN;" \
            >> "${LOG_INSTALL}" 2>&1 \
            && info "복제 유저 생성 완료" \
            || warn "복제 유저가 이미 존재하거나 생성 실패."
        cat >> "${DATA_PATH}/pg_hba.conf" <<EOF

# ── pg_basebackup replication ──────────────────────────
host    replication     ${REPL_USER}      127.0.0.1/32      trust
EOF
        "${ENGINE_PATH}/bin/pg_ctl" -D "${DATA_PATH}" reload
        info "pg_hba.conf 업데이트 및 reload 완료"
    fi

fi  # end single

# ============================================================
# ████████████████  HA MODE  █████████████████████████████████
# ============================================================
if [[ "${INSTALL_MODE}" == "ha" ]]; then

    SSH_OPTS="-o StrictHostKeyChecking=no -p ${HA_SSH_PORT}"
    SCP_OPTS="-P ${HA_SSH_PORT} -o StrictHostKeyChecking=no"

    phase "HA 모드 시작  |  etcd → 빌드 → Primary / Standby 배포"
    info "HA 구성 로그 → ${HA_LOG}"

    # ──────────────────────────────────────────────────────────
    #  PRE-FLIGHT CHECK
    # ──────────────────────────────────────────────────────────
    phase "PRE-FLIGHT CHECK  |  HA 사전 조건 점검"

    PREFLIGHT_OK=true

    # 1) etcd → Primary / Standby SSH 키 교환 확인
    info "[CHECK 1/4] SSH 키 교환 확인 (etcd → Primary / Standby)..."
    for _HOST in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        if ssh ${SSH_OPTS} -o BatchMode=yes "${_HOST}" "exit" >> "${HA_LOG}" 2>&1; then
            info "  ✔ etcd → ${_HOST} SSH 접속 가능"
        else
            warn "  ✘ etcd → ${_HOST} SSH 키 인증 실패"
            warn "    etcd 서버에서 아래 명령어를 실행해 키 교환을 완료해주세요:"
            warn "      ssh-keygen -t rsa -N \"\""
            warn "      ssh-copy-id -p ${HA_SSH_PORT} $(whoami)@${_HOST}"
            PREFLIGHT_OK=false
        fi
    done

    # 2) Primary → Standby / Standby → Primary SSH 키 교환 확인
    info "[CHECK 2/4] SSH 키 교환 확인 (Primary ↔ Standby)..."
    if ssh ${SSH_OPTS} -o BatchMode=yes "${HA_PRIMARY_HOST}" \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -p ${HA_SSH_PORT} \
         $(whoami)@${HA_STANDBY_HOST} exit" >> "${HA_LOG}" 2>&1; then
        info "  ✔ Primary → Standby SSH 접속 가능"
    else
        warn "  ✘ Primary → Standby SSH 키 인증 실패"
        warn "    Primary 서버에서 아래 명령어를 실행해주세요:"
        warn "      ssh-keygen -t rsa -N \"\""
        warn "      ssh-copy-id -p ${HA_SSH_PORT} $(whoami)@${HA_STANDBY_HOST}"
        PREFLIGHT_OK=false
    fi
    if ssh ${SSH_OPTS} -o BatchMode=yes "${HA_STANDBY_HOST}" \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -p ${HA_SSH_PORT} \
         $(whoami)@${HA_PRIMARY_HOST} exit" >> "${HA_LOG}" 2>&1; then
        info "  ✔ Standby → Primary SSH 접속 가능"
    else
        warn "  ✘ Standby → Primary SSH 키 인증 실패"
        warn "    Standby 서버에서 아래 명령어를 실행해주세요:"
        warn "      ssh-keygen -t rsa -N \"\""
        warn "      ssh-copy-id -p ${HA_SSH_PORT} $(whoami)@${HA_PRIMARY_HOST}"
        PREFLIGHT_OK=false
    fi

    # 3) sudo NOPASSWD 확인 (Primary / Standby)
    info "[CHECK 3/4] sudo NOPASSWD 권한 확인 (Primary / Standby)..."
    for _HOST in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        if ssh ${SSH_OPTS} -o BatchMode=yes "${_HOST}" "sudo -n true" >> "${HA_LOG}" 2>&1; then
            info "  ✔ ${_HOST} sudo NOPASSWD 정상"
        else
            warn "  ✘ ${_HOST} sudo NOPASSWD 권한 없음"
            warn "    ${_HOST} 서버에서 root 로 아래 명령어를 실행해주세요:"
            warn "      echo '$(whoami) ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/$(whoami)"
            warn "      chmod 440 /etc/sudoers.d/$(whoami)"
            PREFLIGHT_OK=false
        fi
    done

    # 4) /etc/hosts 항목 확인 (etcd / Primary / Standby 3개 노드)
    info "[CHECK 4/4] /etc/hosts 호스트명 등록 확인..."
    for _HOST in "${HA_ETCD_HOST}" "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        if grep -qw "${_HOST}" /etc/hosts; then
            info "  ✔ /etc/hosts 에 '${_HOST}' 등록됨"
        else
            warn "  ✘ /etc/hosts 에 '${_HOST}' 항목이 없습니다."
            warn "    /etc/hosts 에 아래 형식으로 추가해주세요:"
            warn "      <IP>  ${_HOST}"
            PREFLIGHT_OK=false
        fi
    done

    echo ""
    if [[ "${PREFLIGHT_OK}" != true ]]; then
        error "사전 조건 점검 실패. 위 항목을 모두 조치한 후 다시 실행해주세요."
    fi
    info "사전 조건 점검 완료 ✔ 모든 항목 정상"
    info "============================================================"

    # ── SSH 연결 및 sudo 권한 확인 ───────────────────────────
    info "SSH 연결 확인 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" "echo 'Primary SSH OK'" \
        || error "Primary SSH 연결 실패."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" "echo 'Standby SSH OK'" \
        || error "Standby SSH 연결 실패."

    fn_check_sudo_remote "${HA_PRIMARY_HOST}" "${SSH_OPTS}"
    fn_check_sudo_remote "${HA_STANDBY_HOST}" "${SSH_OPTS}"

    # ──────────────────────────────────────────────────────────
    #  PHASE 1. etcd 설치 (로컬: etcd 서버)
    # ──────────────────────────────────────────────────────────
    phase "PHASE 1  |  etcd 설치  (로컬: ${HA_ETCD_HOST})"

    ETCD_INSTALL_DIR="/usr/local/etcd"
    sudo mkdir -p "${ETCD_INSTALL_DIR}" /etc/etcd /var/lib/etcd
    sudo tar -zxf "${ETCD_TARBALL}" -C "${ETCD_INSTALL_DIR}" \
        --strip-components=1 >> "${HA_LOG}" 2>&1
    sudo ln -sf "${ETCD_INSTALL_DIR}/etcd"    /usr/local/bin/etcd
    sudo ln -sf "${ETCD_INSTALL_DIR}/etcdctl" /usr/local/bin/etcdctl
    info "etcd 바이너리 설치 완료"

    sudo bash -c "cat > /etc/etcd/etcd.conf" <<ETCDCONF
name: etcd-node
data-dir: /var/lib/etcd
listen-peer-urls: http://${HA_ETCD_HOST}:2380
listen-client-urls: http://${HA_ETCD_HOST}:2379,http://127.0.0.1:2379
initial-advertise-peer-urls: http://${HA_ETCD_HOST}:2380
advertise-client-urls: http://${HA_ETCD_HOST}:2379
initial-cluster: etcd-node=http://${HA_ETCD_HOST}:2380
initial-cluster-token: ${CLUSTER_NAME}-etcd
initial-cluster-state: new
ETCDCONF

    sudo bash -c "cat > /etc/systemd/system/etcd.service" <<ETCDSVC
[Unit]
Description=etcd key-value store
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd --config-file=/etc/etcd/etcd.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
ETCDSVC

    sudo systemctl daemon-reload
    sudo systemctl enable etcd >> "${HA_LOG}" 2>&1
    sudo systemctl start  etcd
    sleep 3
    etcdctl --endpoints="http://${HA_ETCD_HOST}:2379" endpoint health \
        && info "etcd 정상 기동 확인" \
        || error "etcd 기동 실패. 확인: journalctl -u etcd"

    # ──────────────────────────────────────────────────────────
    #  PHASE 2. etcd 서버에서 PostgreSQL 빌드 (로컬)
    # ──────────────────────────────────────────────────────────
    phase "PHASE 2  |  PostgreSQL 빌드  (etcd 서버 로컬)"

    fn_install_pkg_local
    mkdir -p "${ENGINE_PATH}/etc"
    fn_build_pg_local "${LOCAL_CPU}"

    # ──────────────────────────────────────────────────────────
    #  PHASE 3. Primary DB 서버 구성 (원격)
    # ──────────────────────────────────────────────────────────
    phase "PHASE 3  |  Primary DB 서버 구성  →  ${HA_PRIMARY_HOST}"

    # 3-1. 디렉토리 생성
    info "[Primary] 디렉토리 생성 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RMKDIR
mkdir -p "${ENGINE_BASE}" "${DATA_PATH}" "${LOG_PATH}"
${ARC_PATH:+mkdir -p "${ARC_PATH}"}
${BACK_PATH:+mkdir -p "${BACK_PATH}" "${DUMP_PATH}"}
RMKDIR
    info "[Primary] 디렉토리 생성 완료"

    # 3-2. 엔진 영역 scp 복사 (etcd → Primary)
    info "[Primary] 엔진 영역 scp 복사 중 (로그 → ${HA_LOG})..."
    scp ${SCP_OPTS} -r "${ENGINE_BASE}" \
        "${HA_PRIMARY_HOST}:$(dirname "${ENGINE_BASE}")/" \
        >> "${HA_LOG}" 2>&1
    info "[Primary] 엔진 영역 복사 완료"

    # 3-3. PKG rpm 설치 (Primary - 런타임 라이브러리용)
    if [[ -f "${PKG_TGZ}" ]]; then
        info "[Primary] 의존 패키지(rpm) 전송 및 설치 중..."
        scp ${SCP_OPTS} "${PKG_TGZ}" "${HA_PRIMARY_HOST}:/tmp/" >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RPKG
TMP=\$(mktemp -d)
tar -zxf /tmp/PKG.tar.gz -C "\${TMP}"
sudo rpm -Uvh --force --nodeps "\${TMP}"/PKG/*.rpm 2>/dev/null || true
rm -rf "\${TMP}" /tmp/PKG.tar.gz
RPKG
        info "[Primary] 의존 패키지 설치 완료"
    fi

    # 3-4. .postgresrc 설정
    POSTGRESRC_TMP=$(mktemp)
    fn_gen_postgresrc "${POSTGRESRC_TMP}"
    scp ${SCP_OPTS} "${POSTGRESRC_TMP}" \
        "${HA_PRIMARY_HOST}:${HOME_DIR}/.postgresrc" >> "${HA_LOG}" 2>&1
    rm -f "${POSTGRESRC_TMP}"
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<'RBASHRC_PRI'
# .bashrc 에 source 추가
grep -q '.postgresrc' ~/.bashrc 2>/dev/null \
    || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bashrc
# .bash_profile 에도 source 추가 (SSH 로그인 시 적용)
grep -q '.postgresrc' ~/.bash_profile 2>/dev/null \
    || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bash_profile
RBASHRC_PRI
    info "[Primary] .postgresrc 설정 완료"

    # 3-5. postgresql.conf 생성 (Primary 리소스 기준)
    info "[Primary] postgresql.conf 생성 중 (CPU:${PRI_CPU} / MEM:${PRI_MEM_GB}GB)..."
    PRI_CONF_TMP=$(mktemp)
    fn_gen_conf "${PRI_CONF_TMP}" "${PRI_CPU}" "${PRI_MEM_GB}" "ha" "${ARC_PATH}"
    scp ${SCP_OPTS} "${PRI_CONF_TMP}" \
        "${HA_PRIMARY_HOST}:/tmp/postgresql.conf.tmp" >> "${HA_LOG}" 2>&1
    rm -f "${PRI_CONF_TMP}"

    # 3-6. initdb (Primary)
    info "[Primary] initdb 실행 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RINITDB
${ENGINE_PATH}/bin/initdb \
    --pgdata="${DATA_PATH}" \
    --encoding=UTF8 \
    --locale=ko_KR.utf8 \
    --data-checksums
chmod 700 "${DATA_PATH}"
cp /tmp/postgresql.conf.tmp "${DATA_PATH}/postgresql.conf"
rm -f /tmp/postgresql.conf.tmp
RINITDB
    info "[Primary] initdb 완료"

    # 3-7. patroni.yml 생성 및 systemd 등록 (Primary)
    info "[Primary] patroni.yml 및 systemd 서비스 등록 중..."
    PATRONI_USER=$(whoami)

    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RPATRONI_CONF_PRI
sudo mkdir -p /etc/patroni
sudo bash -c "cat > /etc/patroni/patroni.yml" <<PYML
scope: ${CLUSTER_NAME}
namespace: /db/
name: primary

restapi:
  listen: ${HA_PRIMARY_HOST}:8008
  connect_address: ${HA_PRIMARY_HOST}:8008

etcd3:
  host: ${HA_ETCD_HOST}:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: on
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB

  initdb:
    - encoding: UTF8
    - locale: ko_KR.utf8
    - data-checksums

  pg_hba:
    - host replication ${REPL_USER_HA} ${HA_PRIMARY_HOST}/24 trust
    - host replication ${REPL_USER_HA} ${HA_STANDBY_HOST}/24 trust
    - host postgres    ${REPL_USER_HA} ${HA_PRIMARY_HOST}/24 trust
    - host postgres    ${REPL_USER_HA} ${HA_STANDBY_HOST}/24 trust
    - host all         all             ${HA_PRIMARY_HOST}/24 trust
    - host all         all             ${HA_STANDBY_HOST}/24 trust
    - host all         all             0.0.0.0/0             md5

  users:
    ${REPL_USER_HA}:
      password: ${REPL_PASS_HA}
      options:
        - replication

postgresql:
  listen: ${HA_PRIMARY_HOST}:${PG_PORT}
  connect_address: ${HA_PRIMARY_HOST}:${PG_PORT}
  data_dir: ${DATA_PATH}
  bin_dir: ${ENGINE_PATH}/bin
  pgpass: ${HOME_DIR}/.pgpass
  authentication:
    replication:
      username: ${REPL_USER_HA}
      password: ${REPL_PASS_HA}
    superuser:
      username: postgres
      password: postgres

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
PYML

sudo bash -c "cat > /etc/systemd/system/patroni.service" <<SVC
[Unit]
Description=Patroni PostgreSQL HA
After=network.target

[Service]
Type=simple
User=${PATRONI_USER}
ExecStart=${PATRONI_BIN_PRI} /etc/patroni/patroni.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC
sudo systemctl daemon-reload
sudo systemctl enable patroni
RPATRONI_CONF_PRI
    info "[Primary] patroni.yml 및 systemd 등록 완료"
    # ExecStart 경로는 PHASE 5 Patroni 설치 후 실제 경로로 업데이트됩니다.

    # ──────────────────────────────────────────────────────────
    #  PHASE 4. Standby DB 서버 구성 (원격)
    #  엔진: Primary → Standby scp (etcd 서버 거치지 않음)
    # ──────────────────────────────────────────────────────────
    phase "PHASE 4  |  Standby DB 서버 구성  →  ${HA_STANDBY_HOST}"

    # 4-1. 디렉토리 생성
    info "[Standby] 디렉토리 생성 중..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<SMKDIR
mkdir -p "${ENGINE_BASE}" "${DATA_PATH}" "${LOG_PATH}"
chmod 700 "${DATA_PATH}"
${ARC_PATH:+mkdir -p "${ARC_PATH}"}
${BACK_PATH:+mkdir -p "${BACK_PATH}" "${DUMP_PATH}"}
SMKDIR

    # 4-2. 엔진 영역 scp 복사 (Primary → Standby)
    info "[Standby] 엔진 영역 복사 중 (Primary → Standby, 로그 → ${HA_LOG})..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "scp ${SCP_OPTS} -r ${ENGINE_BASE} \
         ${HA_STANDBY_HOST}:$(dirname "${ENGINE_BASE}")/" \
        >> "${HA_LOG}" 2>&1
    info "[Standby] 엔진 영역 복사 완료"

    # 4-3. PKG rpm 설치 (Standby)
    if [[ -f "${PKG_TGZ}" ]]; then
        info "[Standby] 의존 패키지(rpm) 전송 및 설치 중..."
        scp ${SCP_OPTS} "${PKG_TGZ}" "${HA_STANDBY_HOST}:/tmp/" >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<SPKG
TMP=\$(mktemp -d)
tar -zxf /tmp/PKG.tar.gz -C "\${TMP}"
sudo rpm -Uvh --force --nodeps "\${TMP}"/PKG/*.rpm 2>/dev/null || true
rm -rf "\${TMP}" /tmp/PKG.tar.gz
SPKG
        info "[Standby] 의존 패키지 설치 완료"
    fi

    # 4-4. .postgresrc 설정
    POSTGRESRC_TMP2=$(mktemp)
    fn_gen_postgresrc "${POSTGRESRC_TMP2}"
    scp ${SCP_OPTS} "${POSTGRESRC_TMP2}" \
        "${HA_STANDBY_HOST}:${HOME_DIR}/.postgresrc" >> "${HA_LOG}" 2>&1
    rm -f "${POSTGRESRC_TMP2}"
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<'RBASHRC_SBY'
# .bashrc 에 source 추가
grep -q '.postgresrc' ~/.bashrc 2>/dev/null \
    || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bashrc
# .bash_profile 에도 source 추가 (SSH 로그인 시 적용)
grep -q '.postgresrc' ~/.bash_profile 2>/dev/null \
    || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bash_profile
RBASHRC_SBY
    info "[Standby] .postgresrc 설정 완료"

    # 4-5. postgresql.conf 생성 (Standby 리소스 기준)
    info "[Standby] postgresql.conf 생성 중 (CPU:${SBY_CPU} / MEM:${SBY_MEM_GB}GB)..."
    SBY_CONF_TMP=$(mktemp)
    fn_gen_conf "${SBY_CONF_TMP}" "${SBY_CPU}" "${SBY_MEM_GB}" "ha" "${ARC_PATH}"
    scp ${SCP_OPTS} "${SBY_CONF_TMP}" \
        "${HA_STANDBY_HOST}:/tmp/postgresql.conf.tmp" >> "${HA_LOG}" 2>&1
    rm -f "${SBY_CONF_TMP}"

    # 4-6. patroni.yml 생성 및 systemd 등록 (Standby)
    info "[Standby] patroni.yml 및 systemd 서비스 등록 중..."

    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RPATRONI_CONF_SBY
sudo mkdir -p /etc/patroni
sudo bash -c "cat > /etc/patroni/patroni.yml" <<PYML
scope: ${CLUSTER_NAME}
namespace: /db/
name: standby

restapi:
  listen: ${HA_STANDBY_HOST}:8008
  connect_address: ${HA_STANDBY_HOST}:8008

etcd3:
  host: ${HA_ETCD_HOST}:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true

postgresql:
  listen: ${HA_STANDBY_HOST}:${PG_PORT}
  connect_address: ${HA_STANDBY_HOST}:${PG_PORT}
  data_dir: ${DATA_PATH}
  bin_dir: ${ENGINE_PATH}/bin
  pgpass: ${HOME_DIR}/.pgpass
  authentication:
    replication:
      username: ${REPL_USER_HA}
      password: ${REPL_PASS_HA}
    superuser:
      username: postgres
      password: postgres

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
PYML

sudo bash -c "cat > /etc/systemd/system/patroni.service" <<SVC
[Unit]
Description=Patroni PostgreSQL HA
After=network.target

[Service]
Type=simple
User=${PATRONI_USER}
ExecStart=${PATRONI_BIN_SBY} /etc/patroni/patroni.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC
sudo systemctl daemon-reload
sudo systemctl enable patroni
RPATRONI_CONF_SBY
    info "[Standby] patroni.yml 및 systemd 등록 완료"

    # ──────────────────────────────────────────────────────────
    #  PHASE 5. Patroni 설치 및 기동
    #  Primary 설치 → 기동 → Leader 확인 → Standby 설치 → 기동 → 클러스터 확인
    # ──────────────────────────────────────────────────────────
    phase "PHASE 5  |  Patroni 설치 및 기동"

    [[ ! -f "${PATRONI_PKGS}" ]] && \
        error "patroni_pkgs.tar.gz 가 없습니다: ${PATRONI_PKGS}"

    # ── 공통 Patroni 설치 함수 (heredoc) ─────────────────────
    fn_install_patroni_remote() {
        local _HOST="$1"
        local _LABEL="$2"
        scp ${SCP_OPTS} "${PATRONI_PKGS}" "${_HOST}:/tmp/patroni_pkgs.tar.gz" >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${_HOST}" bash >> "${HA_LOG}" 2>&1 <<'PATRONI_INSTALL_EOF'
set -e
TMP=$(mktemp -d)
trap "rm -rf ${TMP} /tmp/patroni_pkgs.tar.gz" EXIT
tar -zxf /tmp/patroni_pkgs.tar.gz -C "${TMP}"

# ydiff 소스 tarball 제거 (빌드 불가)
rm -f "${TMP}"/patroni_pkgs/ydiff-*.tar.gz

# sudo pip3 시스템 전역 설치
# 1차: 일반 설치
sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
    patroni psycopg2-binary 2>/tmp/patroni_install.err && INST_OK=1 || INST_OK=0

# 2차: --no-deps + 개별 deps
if [[ ${INST_OK} -eq 0 ]]; then
    echo "[WARN] 1차 설치 실패. --no-deps 방식으로 재시도합니다..."
    sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
        --no-deps patroni psycopg2-binary
    for _pkg in python-etcd urllib3 pyyaml click prettytable psutil python-dateutil py-consul; do
        sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
            --no-deps "${_pkg}" 2>/dev/null || true
    done
fi

# Patroni 4.x 런타임 의존성 (etcd3gw, dnspython, wcwidth)
for _pkg in ydiff etcd3gw dnspython wcwidth; do
    sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
        "${_pkg}" 2>/dev/null \
    || sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
        --no-deps "${_pkg}" 2>/dev/null || true
done

# 설치 검증
if ! command -v patroni &>/dev/null; then
    echo "[ERROR] patroni 바이너리를 찾을 수 없습니다."
    pip3 show patroni 2>&1 || true
    exit 1
fi
echo "patroni 설치 경로: $(command -v patroni)"
PATRONI_INSTALL_EOF
        local _BIN
        _BIN=$(ssh ${SSH_OPTS} "${_HOST}" \
            "command -v patroni 2>/dev/null || echo /usr/local/bin/patroni")
        info "[${_LABEL}] Patroni 설치 완료 (bin: ${_BIN})"
        echo "${_BIN}"
    }

    # ── 5-1. Primary Patroni 설치 ────────────────────────────
    info "[Primary] Patroni 설치 중..."
    PATRONI_BIN_PRI=$(fn_install_patroni_remote "${HA_PRIMARY_HOST}" "Primary")

    # ── 5-2. Primary Patroni 기동 및 Leader 확인 ─────────────
    info "[Primary] Patroni 기동 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "sudo systemctl start patroni" >> "${HA_LOG}" 2>&1
    info "[Primary] Patroni 기동 요청 완료. Leader 초기화 대기 중 (30초)..."
    sleep 30

    # Leader 확인 (최대 60초 추가 대기)
    _PRI_LEADER=false
    for _i in $(seq 1 6); do
        _ROLE=$(ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
            "sudo systemctl is-active patroni 2>/dev/null" || true)
        if [[ "${_ROLE}" == "active" ]]; then
            _PRI_LEADER=true
            break
        fi
        info "[Primary] Patroni 아직 초기화 중... (${_i}/6, 10초 대기)"
        sleep 10
    done

    if [[ "${_PRI_LEADER}" != true ]]; then
        warn "[Primary] Patroni 가 active 상태가 아닙니다. 로그 확인:"
        ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
            "sudo journalctl -u patroni --no-pager -n 20" || true
        error "Primary Patroni 기동 실패. 위 로그를 확인하세요."
    fi
    info "[Primary] Patroni 기동 확인 ✔"

    # ── 5-3. Standby Patroni 설치 ────────────────────────────
    info "[Standby] Patroni 설치 중..."
    PATRONI_BIN_SBY=$(fn_install_patroni_remote "${HA_STANDBY_HOST}" "Standby")

    # systemd ExecStart 경로를 실제 설치 경로로 업데이트
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<SUPDATE_SVC
sudo sed -i "s|ExecStart=.*patroni |ExecStart=${PATRONI_BIN_SBY} |" \
    /etc/systemd/system/patroni.service
sudo systemctl daemon-reload
SUPDATE_SVC

    # ── 5-4. Standby Patroni 기동 (pg_basebackup 클론) ───────
    info "[Standby] Patroni 기동 중..."
    info "  ※ Patroni 가 pg_basebackup 으로 Primary 데이터를 자동 클론합니다."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
        "sudo systemctl start patroni" >> "${HA_LOG}" 2>&1
    info "[Standby] Patroni 기동 요청 완료. 클론 완료 대기 중 (60초)..."
    sleep 60

    # Standby 기동 확인 (최대 60초 추가 대기)
    _SBY_OK=false
    for _i in $(seq 1 6); do
        _ROLE=$(ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
            "sudo systemctl is-active patroni 2>/dev/null" || true)
        if [[ "${_ROLE}" == "active" ]]; then
            _SBY_OK=true
            break
        fi
        info "[Standby] Patroni 클론 진행 중... (${_i}/6, 10초 대기)"
        sleep 10
    done

    if [[ "${_SBY_OK}" != true ]]; then
        warn "[Standby] Patroni 가 active 상태가 아닙니다. 로그 확인:"
        ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
            "sudo journalctl -u patroni --no-pager -n 20" || true
        warn "Standby Patroni 기동 실패. 클러스터 상태를 수동으로 확인하세요."
    else
        info "[Standby] Patroni 기동 확인 ✔"
    fi

    # ── 5-5. 클러스터 최종 상태 확인 ────────────────────────
    info "클러스터 상태 확인 중..."
    PATRONICTL_BIN=$(ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "command -v patronictl 2>/dev/null || echo /usr/local/bin/patronictl")
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "${PATRONICTL_BIN} -c /etc/patroni/patroni.yml list" \
        || warn "클러스터 상태 조회 실패. Primary 서버에서 수동 확인:"

    # ──────────────────────────────────────────────────────────
    #  PHASE 6. etcd 서버의 엔진 영역 정리
    # ──────────────────────────────────────────────────────────
    phase "PHASE 6  |  etcd 서버 빌드 결과물 정리"
    info "etcd 서버에서 엔진 영역 삭제 중: ${ENGINE_BASE}"
    sudo rm -rf "${ENGINE_BASE}" && info "etcd 서버 정리 완료 (엔진 영역 삭제됨)" \
        || warn "엔진 영역 삭제 실패 (권한 부족). 수동으로 삭제하세요: sudo rm -rf ${ENGINE_BASE}"

    echo ""
    echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}  ║           HA 구성 완료!  🎉                  ║${NC}"
    echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}  ║${NC}  etcd      : ${HA_ETCD_HOST}:2379"
    echo -e "${BOLD}  ║${NC}  Primary   : ${HA_PRIMARY_HOST}:${PG_PORT}"
    echo -e "${BOLD}  ║${NC}  Standby   : ${HA_STANDBY_HOST}:${PG_PORT}"
    echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}  ║${NC}  클러스터 상태 확인 (Primary 서버에서):"
    echo -e "${BOLD}  ║${NC}    patronictl -c /etc/patroni/patroni.yml list"
    echo -e "${BOLD}  ║${NC}"
    echo -e "${BOLD}  ║${NC}  Switchover:"
    echo -e "${BOLD}  ║${NC}    patronictl -c /etc/patroni/patroni.yml switchover ${CLUSTER_NAME}"
    echo -e "${BOLD}  ║${NC}"
    echo -e "${BOLD}  ║${NC}  Failover 테스트:"
    echo -e "${BOLD}  ║${NC}    patronictl -c /etc/patroni/patroni.yml failover ${CLUSTER_NAME}"
    echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${NC}"
    echo ""

fi  # end ha

# ============================================================
#  완료 메시지
# ============================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              설치 완료! 🎉                   ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  설치 모드  : ${INSTALL_MODE}"
echo -e "${BOLD}║${NC}  엔진 경로  : ${ENGINE_PATH}"
echo -e "${BOLD}║${NC}  Data 경로  : ${DATA_PATH}"
echo -e "${BOLD}║${NC}  Log 경로   : ${LOG_PATH}"
[[ -n "${ARC_PATH}"  ]] && echo -e "${BOLD}║${NC}  Archive    : ${ARC_PATH}"
[[ -n "${BACK_PATH}" ]] && echo -e "${BOLD}║${NC}  Backup     : ${BACK_PATH}"
if [[ "${INSTALL_MODE}" == "ha" ]]; then
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  etcd       : ${HA_ETCD_HOST}"
echo -e "${BOLD}║${NC}  Primary    : ${HA_PRIMARY_HOST}:${PG_PORT}"
echo -e "${BOLD}║${NC}  Standby    : ${HA_STANDBY_HOST}:${PG_PORT}"
echo -e "${BOLD}║${NC}  복제 유저  : ${REPL_USER_HA}"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

INSTALL_END=$(date '+%Y-%m-%d %H:%M:%S')
cat >> "${LOG_INSTALL}" <<END_LOG

[완료]
  Finished : ${INSTALL_END}
  상태     : SUCCESS
============================================================
END_LOG
INSTALL_EOF

chmod +x "${INSTALL_DEST}"
echo "[INFO] postgresql_install.sh 생성 완료 → ${INSTALL_DEST}"

# ============================================================
#  최종 디렉토리 구조 출력
# ============================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           다운로드 완료!                     ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
find "${WORK_DIR}" -maxdepth 2 | sort | sed 's|[^/]*/|  |g' | while read -r line; do
    echo -e "${BOLD}║${NC}  ${line}"
done
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""