#!/bin/bash

# ============================================================
#  PostgreSQL Download Script v0.5
#  - 폐쇄망 설치를 위한 패키지 다운로드
#  - single / HA(Patroni + etcd) 모드 지원
# ============================================================

set -e

WORK_DIR="postgresql"
INSTALLER_DIR="${WORK_DIR}/installer"

# ── 색상 정의 ─────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo "======================================"
echo "  PostgreSQL Download Script v0.5"
echo "======================================"
echo ""

# ── tar 설치 여부 자동 확인 ──────────────────────────────────
if ! command -v tar &>/dev/null; then
    echo "  [주의] 이 스크립트는 tar 패키지가 설치되어 있어야 합니다."
    echo "         tar 가 설치되어 있지 않습니다. 아래 명령어로 먼저 설치해 주세요."
    echo ""
    echo "         sudo dnf install -y tar"
    echo ""
    echo "======================================"
    exit 1
fi

echo "======================================"
echo ""

# ============================================================
#  입력값 수집
# ============================================================

# 1. 의존 패키지 다운로드 여부
read -rp "의존 패키지를 다운로드 하시겠습니까? [Y/n]: " DOWNLOAD_PKG
DOWNLOAD_PKG="${DOWNLOAD_PKG:-Y}"

# 2. PostgreSQL 버전
read -rp "다운로드할 PostgreSQL 버전을 입력하세요 [17.9]: " PG_VERSION
PG_VERSION="${PG_VERSION:-17.9}"
PG_MAJOR="${PG_VERSION%%.*}"

# 3. HA 구성 여부
echo ""
echo "----------------"
read -rp "HA 구성용 패키지(etcd + Patroni)도 다운로드 하시겠습니까? [y/N]: " DOWNLOAD_HA
DOWNLOAD_HA="${DOWNLOAD_HA:-N}"

ETCD_VERSION=""
if [[ "${DOWNLOAD_HA,,}" =~ ^(y|yes)$ ]]; then
    read -rp "  다운로드할 etcd 버전을 입력하세요 [3.5.17]: " ETCD_VERSION
    ETCD_VERSION="${ETCD_VERSION:-3.5.17}"
fi
echo "----------------"
echo ""

# ============================================================
#  설정 확인
# ============================================================
echo "────────────────────────────────────────"
echo "  설정 확인"
echo "  의존 패키지 다운로드 : ${DOWNLOAD_PKG}"
echo "  PostgreSQL 버전      : ${PG_VERSION} (메이저: ${PG_MAJOR})"
if [[ "${DOWNLOAD_HA,,}" =~ ^(y|yes)$ ]]; then
echo "  HA 패키지 다운로드   : Y (etcd v${ETCD_VERSION} + Patroni)"
else
echo "  HA 패키지 다운로드   : N"
fi
echo "  저장 디렉토리        : $(pwd)/${WORK_DIR}/"
echo "────────────────────────────────────────"
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
            "${PKG_LIST[@]}" \
            >> "${PKG_LOG}" 2>&1

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

    # pip3 설치 확인
    if ! command -v pip3 &>/dev/null; then
        error "pip3 가 없습니다. 'sudo dnf install -y python3-pip' 후 다시 실행해주세요."
    fi

    pip3 download \
        --dest "${PATRONI_TMP}" \
        "patroni[etcd]" \
        psycopg2-binary \
        >> "${PKG_LOG}" 2>&1 \
        && info "Patroni wheel 다운로드 완료" \
        || error "Patroni wheel 다운로드 실패. 로그: ${PKG_LOG}"

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
#  PostgreSQL Install Script v0.6
#  - single 모드: 로컬 서버에 PostgreSQL 설치
#  - ha 모드   : etcd 서버(local) + Primary/Standby(remote SSH)
#                PostgreSQL + Patroni 설치
# ============================================================

set -e

# ── 색상 정의 ─────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 서버 리소스 자동 조회 ────────────────────────────────────
DEFAULT_CPU=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "4")
DEFAULT_MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
DEFAULT_MEM_GB=$(( DEFAULT_MEM_KB / 1024 / 1024 ))
[[ "$DEFAULT_MEM_GB" -lt 1 ]] && DEFAULT_MEM_GB=1

HOME_DIR="${HOME:-$(eval echo ~$(whoami))}"

# ── 스크립트 위치 기준 installer/ 경로 확인 ─────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER_DIR="${SCRIPT_DIR}/installer"

echo "======================================"
echo "  PostgreSQL Install Script v0.6"
echo "======================================"
echo ""

# ============================================================
#  STEP 0. installer/ 디렉토리 확인
# ============================================================
if [[ ! -d "${INSTALLER_DIR}" ]]; then
    error "installer/ 디렉토리를 찾을 수 없습니다: ${INSTALLER_DIR}\ndownload 스크립트로 먼저 패키지를 다운로드 해주세요."
fi

# ── PostgreSQL 소스 tar.gz 탐색 ──────────────────────────────
PG_TARBALL=$(ls "${INSTALLER_DIR}"/postgresql-*.tar.gz 2>/dev/null | head -1)
if [[ -z "${PG_TARBALL}" ]]; then
    error "installer/ 디렉토리에서 postgresql-*.tar.gz 를 찾을 수 없습니다."
fi
PG_VERSION=$(basename "${PG_TARBALL}" | sed 's/postgresql-//;s/\.tar\.gz//')
PG_MAJOR="${PG_VERSION%%.*}"
info "PostgreSQL 소스 확인: ${PG_TARBALL} (버전: ${PG_VERSION})"

# ── etcd / Patroni 패키지 탐색 ───────────────────────────────
ETCD_TARBALL=$(ls "${INSTALLER_DIR}"/etcd-v*-linux-amd64.tar.gz 2>/dev/null | head -1)
PATRONI_PKGS="${INSTALLER_DIR}/patroni_pkgs.tar.gz"

HA_PKGS_AVAILABLE=false
if [[ -n "${ETCD_TARBALL}" && -f "${PATRONI_PKGS}" ]]; then
    HA_PKGS_AVAILABLE=true
    ETCD_VERSION=$(basename "${ETCD_TARBALL}" | sed 's/etcd-v//;s/-linux-amd64\.tar\.gz//')
    info "etcd 패키지 확인: ${ETCD_TARBALL} (버전: ${ETCD_VERSION})"
    info "Patroni 패키지 확인: ${PATRONI_PKGS}"
fi

# ============================================================
#  STEP 0-1. PostgreSQL 프로세스 구동 여부 확인
# ============================================================
if pgrep -x "postgres" > /dev/null 2>&1; then
    warn "PostgreSQL 프로세스가 이미 실행 중입니다."
    ps aux | grep "[p]ostgres" | head -5
    echo ""
    read -rp "계속 진행하시겠습니까? [y/N]: " PROC_CONTINUE
    PROC_CONTINUE="${PROC_CONTINUE:-N}"
    [[ ! "${PROC_CONTINUE,,}" =~ ^(y|yes)$ ]] && { info "설치를 중단합니다."; exit 0; }
    warn "기존 프로세스가 실행 중인 상태로 진행합니다."
else
    info "실행 중인 PostgreSQL 프로세스가 없습니다."
fi

# ============================================================
#  STEP 1. 입력값 수집
# ============================================================
read -rp "PostgreSQL 을 설치하시겠습니까? [Y/n]: " DO_INSTALL
DO_INSTALL="${DO_INSTALL:-Y}"
[[ ! "${DO_INSTALL,,}" =~ ^(y|yes)$ ]] && { info "설치를 중단합니다."; exit 0; }

read -rp "사용할 CPU core 수를 입력하세요 [${DEFAULT_CPU}]: " CPU_CORES
CPU_CORES="${CPU_CORES:-${DEFAULT_CPU}}"

read -rp "서버 Memory 를 입력하세요 (GB) [${DEFAULT_MEM_GB}]: " MEM_GB
MEM_GB="${MEM_GB:-${DEFAULT_MEM_GB}}"

read -rp "사용할 PostgreSQL Port 를 입력하세요 [5432]: " PG_PORT
PG_PORT="${PG_PORT:-5432}"

# ── 설치 모드 선택 ───────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo "  설치 모드를 선택하세요"
echo "    1) single  - 로컬 서버에만 PostgreSQL 설치"
if [[ "${HA_PKGS_AVAILABLE}" == true ]]; then
echo "    2) ha      - etcd(local) + Primary/Standby(remote) 구성"
else
echo "    2) ha      - [패키지 없음] download 시 HA 옵션 선택 필요"
fi
echo "────────────────────────────────────────"
read -rp "  선택 [1]: " MODE_SEL
MODE_SEL="${MODE_SEL:-1}"

case "${MODE_SEL}" in
    1) INSTALL_MODE="single" ;;
    2)
        if [[ "${HA_PKGS_AVAILABLE}" != true ]]; then
            error "HA 패키지(etcd/Patroni)가 installer/ 에 없습니다.\ndownload 스크립트에서 HA 옵션을 선택 후 다시 다운로드 해주세요."
        fi
        INSTALL_MODE="ha"
        ;;
    *) error "잘못된 선택입니다." ;;
esac

# ── HA 모드 추가 입력 ────────────────────────────────────────
HA_ETCD_HOST=""
HA_PRIMARY_HOST=""
HA_STANDBY_HOST=""
HA_SSH_PORT=""
REPL_USER_HA=""
REPL_PASS_HA=""
CLUSTER_NAME=""

if [[ "${INSTALL_MODE}" == "ha" ]]; then
    echo ""
    echo "────────────────────────────────────────"
    echo "  HA 구성 정보 입력"
    echo "────────────────────────────────────────"
    read -rp "  클러스터 이름을 입력하세요 [pg-cluster]: " CLUSTER_NAME
    CLUSTER_NAME="${CLUSTER_NAME:-pg-cluster}"

    read -rp "  etcd 서버 호스트명 또는 IP (현재 서버): " HA_ETCD_HOST
    [[ -z "${HA_ETCD_HOST}" ]] && error "etcd 호스트를 입력해야 합니다."

    read -rp "  Primary DB 호스트명 또는 IP: " HA_PRIMARY_HOST
    [[ -z "${HA_PRIMARY_HOST}" ]] && error "Primary 호스트를 입력해야 합니다."

    read -rp "  Standby DB 호스트명 또는 IP: " HA_STANDBY_HOST
    [[ -z "${HA_STANDBY_HOST}" ]] && error "Standby 호스트를 입력해야 합니다."

    read -rp "  SSH 포트 [22]: " HA_SSH_PORT
    HA_SSH_PORT="${HA_SSH_PORT:-22}"

    read -rp "  복제 유저명 [replicator]: " REPL_USER_HA
    REPL_USER_HA="${REPL_USER_HA:-replicator}"

    read -rsp "  복제 유저 패스워드: " REPL_PASS_HA
    echo ""
    [[ -z "${REPL_PASS_HA}" ]] && error "복제 유저 패스워드를 입력해야 합니다."

    read -rsp "  postgres OS 유저 패스워드 (원격 sudo용): " REMOTE_SUDO_PASS
    echo ""

    echo ""
    echo "  클러스터명  : ${CLUSTER_NAME}"
    echo "  etcd 서버   : ${HA_ETCD_HOST}"
    echo "  Primary     : ${HA_PRIMARY_HOST}"
    echo "  Standby     : ${HA_STANDBY_HOST}"
    echo "  SSH Port    : ${HA_SSH_PORT}"
    echo "  복제 유저   : ${REPL_USER_HA}"
    echo "────────────────────────────────────────"
fi

# 5. 경로 입력
read -rp "엔진 설치 경로를 입력하세요 [/postgres]: " ENGINE_BASE
ENGINE_BASE="${ENGINE_BASE:-/postgres}"
ENGINE_PATH="${ENGINE_BASE}/app"

read -rp "Data 영역 경로를 입력하세요 [/pgdata]: " DATA_BASE
DATA_BASE="${DATA_BASE:-/pgdata}"
DATA_PATH="${DATA_BASE}/data"

LOG_PATH="${DATA_BASE}/log"
echo "  Log 경로 : ${LOG_PATH}"

read -rp "Archive 영역을 사용하시겠습니까? [Y/n]: " USE_ARCHIVE
USE_ARCHIVE="${USE_ARCHIVE:-Y}"
ARC_BASE=""
ARC_PATH=""
if [[ "${USE_ARCHIVE,,}" =~ ^(y|yes)$ ]]; then
    read -rp "Archive 상위 경로를 입력하세요 [/pgbackup]: " ARC_BASE
    ARC_BASE="${ARC_BASE:-/pgbackup}"
    ARC_PATH="${ARC_BASE}/arc"
    echo "  Archive 경로 : ${ARC_PATH}"
fi

read -rp "Backup 영역을 사용하시겠습니까? [Y/n]: " USE_BACKUP
USE_BACKUP="${USE_BACKUP:-Y}"
BACK_BASE=""
BACK_PATH=""
DUMP_PATH=""
BACKUP_CRON=""
BACKUP_KEEP=""
REPL_USER=""

if [[ "${USE_BACKUP,,}" =~ ^(y|yes)$ ]]; then
    read -rp "  Backup 상위 경로를 입력하세요 [/pgbackup]: " BACK_BASE
    BACK_BASE="${BACK_BASE:-/pgbackup}"
    BACK_PATH="${BACK_BASE}/back"
    DUMP_PATH="${BACK_BASE}/dump"
    echo "  Backup 경로 : ${BACK_PATH}"

    echo "  백업 주기를 선택하세요:"
    echo "    1) 매일 새벽 2시"
    echo "    2) 매주 일요일 새벽 2시"
    echo "    3) 직접 입력 (cron 형식: 분 시 일 월 요일)"
    read -rp "  선택 [1]: " BACKUP_CRON_SEL
    BACKUP_CRON_SEL="${BACKUP_CRON_SEL:-1}"
    case "${BACKUP_CRON_SEL}" in
        1) BACKUP_CRON="0 2 * * *" ;;
        2) BACKUP_CRON="0 2 * * 0" ;;
        3) read -rp "  cron 표현식 입력: " BACKUP_CRON ;;
        *) BACKUP_CRON="0 2 * * *" ;;
    esac
    echo "  백업 주기 : ${BACKUP_CRON}"

    read -rp "  백업 유지 개수를 입력하세요 [7]: " BACKUP_KEEP
    BACKUP_KEEP="${BACKUP_KEEP:-7}"
    echo "  백업 유지 개수 : ${BACKUP_KEEP}"

    if [[ "${INSTALL_MODE}" == "ha" ]]; then
        REPL_USER="${REPL_USER_HA}"
        echo "  복제 유저 : ${REPL_USER} (HA 설정에서 상속)"
    else
        read -rp "  pg_basebackup 에 사용할 복제 유저명을 입력하세요 [replicator]: " REPL_USER
        REPL_USER="${REPL_USER:-replicator}"
        echo "  복제 유저 : ${REPL_USER}"
    fi
fi

# ============================================================
#  설정 최종 확인
# ============================================================
echo ""
echo "────────────────────────────────────────────"
echo "  설정 확인"
echo "  설치 모드      : ${INSTALL_MODE}"
echo "  CPU Cores      : ${CPU_CORES}"
echo "  Memory         : ${MEM_GB} GB"
echo "  Port           : ${PG_PORT}"
if [[ "${INSTALL_MODE}" == "ha" ]]; then
echo "  클러스터명     : ${CLUSTER_NAME}"
echo "  etcd 서버      : ${HA_ETCD_HOST}"
echo "  Primary        : ${HA_PRIMARY_HOST}"
echo "  Standby        : ${HA_STANDBY_HOST}"
echo "  복제 유저      : ${REPL_USER_HA}"
fi
echo "  엔진 경로      : ${ENGINE_PATH}"
echo "  Data 경로      : ${DATA_PATH}"
echo "  Log 경로       : ${LOG_PATH}"
[[ -n "${ARC_PATH}"  ]] && echo "  Archive        : ${ARC_PATH}"
[[ -n "${BACK_PATH}" ]] && echo "  Backup         : ${BACK_PATH}"
echo "────────────────────────────────────────────"
echo ""
read -rp "위 설정으로 설치를 진행하시겠습니까? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ ! "${CONFIRM,,}" =~ ^(y|yes)$ ]] && { info "설치를 중단합니다."; exit 0; }

# ============================================================
#  공통 함수: PostgreSQL 빌드 및 설치 (로컬)
# ============================================================
fn_install_pg_local() {
    local TARGET_HOST="${1:-local}"
    info "[${TARGET_HOST}] PKG 의존 패키지 설치 중..."
    PKG_TGZ="${SCRIPT_DIR}/PKG.tar.gz"
    if [[ -f "${PKG_TGZ}" ]]; then
        PKG_TMP="${SCRIPT_DIR}/PKG_tmp"
        mkdir -p "${PKG_TMP}"
        tar -zxf "${PKG_TGZ}" -C "${PKG_TMP}"
        sudo rpm -Uvh --force "${PKG_TMP}"/PKG/*.rpm >> "${LOG_INSTALL}" 2>&1 || true
        rm -rf "${PKG_TMP}"
        info "[${TARGET_HOST}] 의존 패키지 설치 완료"
    else
        warn "PKG.tar.gz 없음. 의존패키지가 사전 설치되어 있어야 합니다."
    fi

    info "[${TARGET_HOST}] PostgreSQL 소스 압축 해제 중..."
    BUILD_TMP="/tmp/pg_build_$$"
    mkdir -p "${BUILD_TMP}"
    tar -zxf "${PG_TARBALL}" -C "${BUILD_TMP}"
    PG_DIR="${BUILD_TMP}/postgresql-${PG_VERSION}"

    info "[${TARGET_HOST}] configure 실행 중..."
    cd "${PG_DIR}"
    ./configure \
        --prefix="${ENGINE_PATH}" \
        --with-openssl \
        --with-libxml \
        --with-libxslt \
        --enable-nls \
        --with-python \
        --with-tcl \
        --with-perl \
        >> "${LOG_INSTALL}" 2>&1 || error "configure 실패. 로그: ${LOG_INSTALL}"

    info "[${TARGET_HOST}] make -j${CPU_CORES} 실행 중..."
    make -j"${CPU_CORES}" >> "${LOG_INSTALL}" 2>&1 || error "make 실패"
    make install >> "${LOG_INSTALL}" 2>&1 || error "make install 실패"

    rm -rf "${BUILD_TMP}"
    cd "${SCRIPT_DIR}"
    info "[${TARGET_HOST}] PostgreSQL 빌드 및 설치 완료 → ${ENGINE_PATH}"
}

# ============================================================
#  공통 함수: 디렉토리 생성 (로컬)
# ============================================================
fn_create_dirs_local() {
    mkdir -p "${ENGINE_PATH}" "${ENGINE_PATH}/etc"
    mkdir -p "${DATA_PATH}" "${LOG_PATH}"
    [[ -n "${ARC_PATH}"  ]] && mkdir -p "${ARC_PATH}"
    [[ -n "${BACK_PATH}" ]] && mkdir -p "${BACK_PATH}" "${DUMP_PATH}"
    info "디렉토리 생성 완료"
}

# ============================================================
#  공통 함수: postgresql.conf 생성
# ============================================================
fn_gen_postgresql_conf() {
    local CONF_OUT="${1}"
    local EXTRA_MODE="${2:-single}"

    MEM_KB=$(( MEM_GB * 1024 * 1024 ))

    SHR_BUF_MB=$(( MEM_KB / 4 / 1024 ))
    SHR_BUF="${SHR_BUF_MB}MB"

    EFF_CACHE_MB=$(( MEM_KB * 3 / 4 / 1024 ))
    EFF_CACHE="${EFF_CACHE_MB}MB"

    MAX_CONN=150
    WORK_MEM_MB=$(( (MEM_KB / 4) / MAX_CONN / 1024 ))
    [[ "$WORK_MEM_MB" -lt 4 ]] && WORK_MEM_MB=4
    WORK_MEM="${WORK_MEM_MB}MB"

    MAINT_MEM_MB=$(( MEM_KB / 20 / 1024 ))
    [[ "$MAINT_MEM_MB" -lt 64   ]] && MAINT_MEM_MB=64
    [[ "$MAINT_MEM_MB" -gt 2048 ]] && MAINT_MEM_MB=2048
    MAINT_MEM="${MAINT_MEM_MB}MB"

    WAL_BUF_MB=$(( SHR_BUF_MB * 3 / 100 ))
    [[ "$WAL_BUF_MB" -lt 1  ]] && WAL_BUF_MB=1
    [[ "$WAL_BUF_MB" -gt 64 ]] && WAL_BUF_MB=64
    WAL_BUF="${WAL_BUF_MB}MB"

    MIN_WAL_SIZE_MB=$(( MEM_GB * 1024 / 16 ))
    [[ "$MIN_WAL_SIZE_MB" -lt 256  ]] && MIN_WAL_SIZE_MB=256
    MAX_WAL_SIZE_MB=$(( MEM_GB * 1024 / 4 ))
    [[ "$MAX_WAL_SIZE_MB" -lt 1024 ]] && MAX_WAL_SIZE_MB=1024
    WAL_KEEP_SIZE_MB=$(( MAX_WAL_SIZE_MB / 2 ))
    [[ "$WAL_KEEP_SIZE_MB" -lt 512 ]] && WAL_KEEP_SIZE_MB=512

    MAX_WORKERS="${CPU_CORES}"
    PARA_WORKERS=$(( CPU_CORES / 2 ))
    [[ "$PARA_WORKERS" -lt 1 ]] && PARA_WORKERS=1

    cat > "${CONF_OUT}" <<EOF
# ============================================================
#  postgresql.conf  (Generated by postgresql_install.sh)
#  Server: ${CPU_CORES} CPU / ${MEM_GB} GB RAM / Mode: ${EXTRA_MODE}
# ============================================================

# ── 접속 설정 ──────────────────────────────────────────────
listen_addresses = '*'
port             = ${PG_PORT}
max_connections  = ${MAX_CONN}

# ── 메모리 설정 ────────────────────────────────────────────
shared_buffers          = ${SHR_BUF}
effective_cache_size    = ${EFF_CACHE}
work_mem                = ${WORK_MEM}
maintenance_work_mem    = ${MAINT_MEM}

# ── WAL 설정 ───────────────────────────────────────────────
wal_buffers                  = ${WAL_BUF}
checkpoint_completion_target = 0.9
wal_level                    = replica
min_wal_size                 = ${MIN_WAL_SIZE_MB}MB
max_wal_size                 = ${MAX_WAL_SIZE_MB}MB
wal_keep_size                = ${WAL_KEEP_SIZE_MB}MB
EOF

    if [[ -n "${ARC_PATH}" ]]; then
        cat >> "${CONF_OUT}" <<EOF
archive_mode    = on
archive_command = 'cp %p ${ARC_PATH}/%f'
EOF
    else
        cat >> "${CONF_OUT}" <<EOF
archive_mode    = off
# archive_command = ''
EOF
    fi

    cat >> "${CONF_OUT}" <<EOF

# ── 병렬 처리 ──────────────────────────────────────────────
max_worker_processes             = ${MAX_WORKERS}
max_parallel_workers_per_gather  = ${PARA_WORKERS}
max_parallel_workers             = ${CPU_CORES}

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
EOF

    if [[ "${EXTRA_MODE}" == "ha" ]]; then
        cat >> "${CONF_OUT}" <<EOF

# ── HA Replication 설정 ────────────────────────────────────
max_wal_senders       = 10
max_replication_slots = 10
EOF
    fi
}

# ============================================================
#  로그 디렉토리 및 설치 로그 초기화
# ============================================================
LOG_DIR="${DATA_BASE}/log"
mkdir -p "${LOG_DIR}"
LOG_INSTALL="${LOG_DIR}/pg_install.log"
HA_LOG="${LOG_DIR}/ha_setup.log"

cat > "${LOG_INSTALL}" <<EOF
============================================================
  PostgreSQL Install Log
  Started : $(date '+%Y-%m-%d %H:%M:%S')
  Mode    : ${INSTALL_MODE}
============================================================
EOF

# ============================================================
# ██████████████  SINGLE MODE  ██████████████████████████████
# ============================================================
if [[ "${INSTALL_MODE}" == "single" ]]; then

    # STEP 1. 빌드 및 설치
    info "============================================================"
    info "  SINGLE 모드: 로컬 서버에 PostgreSQL 설치"
    info "============================================================"

    fn_create_dirs_local
    fn_install_pg_local "local"

    # STEP 2. .postgresrc 환경변수 설정
    POSTGRESRC="${HOME_DIR}/.postgresrc"
    info ".postgresrc 환경변수 설정 중..."
    cat > "${POSTGRESRC}" <<EOF
# PostgreSQL Environment
export PGHOME=${ENGINE_PATH}
export PATH=\${PGHOME}/bin:\${PATH}
export LD_LIBRARY_PATH=\${PGHOME}/lib:\${LD_LIBRARY_PATH}
export PGDATA=${DATA_PATH}
export PGPORT=${PG_PORT}
export PGUSER=postgres
EOF
    grep -q '.postgresrc' "${HOME_DIR}/.bashrc" 2>/dev/null \
        || printf '\n# PostgreSQL Environment\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> "${HOME_DIR}/.bashrc"
    # shellcheck source=/dev/null
    source "${POSTGRESRC}"
    info ".postgresrc 설정 완료"

    # STEP 3. postgresql.conf 생성
    info "postgresql.conf 생성 중..."
    CONF_TMP="/tmp/postgresql.conf.tmp"
    fn_gen_postgresql_conf "${CONF_TMP}" "single"

    # STEP 4. initdb
    info "initdb 실행 중..."
    "${ENGINE_PATH}/bin/initdb" \
        --pgdata="${DATA_PATH}" \
        --encoding=UTF8 \
        --locale=ko_KR.utf8 \
        --data-checksums \
        >> "${LOG_INSTALL}" 2>&1
    cp "${CONF_TMP}" "${DATA_PATH}/postgresql.conf"
    rm -f "${CONF_TMP}"
    info "initdb 완료"

    # STEP 5. 백업 스크립트 생성
    if [[ -n "${BACK_PATH}" ]]; then
        BACKUP_SCRIPT="${ENGINE_PATH}/etc/pg_basebackup.sh"
        info "백업 스크립트 생성 중: ${BACKUP_SCRIPT}"
        cat > "${BACKUP_SCRIPT}" <<BKEOF
#!/bin/bash
BACKUP_DIR="${BACK_PATH}/\$(date +%Y%m%d_%H%M%S)"
mkdir -p "\${BACKUP_DIR}"
${ENGINE_PATH}/bin/pg_basebackup \\
    -h 127.0.0.1 \\
    -p ${PG_PORT} \\
    -U ${REPL_USER} \\
    -D "\${BACKUP_DIR}" \\
    -Fp -Xs -P -R \\
    >> "${LOG_PATH}/pg_basebackup.log" 2>&1
find "${BACK_PATH}" -maxdepth 1 -type d -mtime +${BACKUP_KEEP} -exec rm -rf {} \; 2>/dev/null || true
BKEOF
        chmod 750 "${BACKUP_SCRIPT}"
        EXISTING_CRON=$(crontab -l 2>/dev/null || true)
        if echo "${EXISTING_CRON}" | grep -qF "${BACKUP_SCRIPT}"; then
            warn "cron 에 이미 백업 작업이 등록되어 있습니다."
        else
            ( echo "${EXISTING_CRON}"; echo "${BACKUP_CRON} ${BACKUP_SCRIPT} >> ${LOG_PATH}/cron_backup.log 2>&1" ) | crontab -
            info "cron 등록 완료: ${BACKUP_CRON}"
        fi
    fi

    # STEP 6. PostgreSQL 기동
    info "PostgreSQL 기동 중..."
    "${ENGINE_PATH}/bin/pg_ctl" -D "${DATA_PATH}" -l "${LOG_PATH}/startup.log" start
    sleep 3
    "${ENGINE_PATH}/bin/pg_ctl" status
    info "PostgreSQL 서버가 정상적으로 시작되었습니다. (Port: ${PG_PORT})"
    "${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres -c "SELECT version();"

    # STEP 7. 복제 유저 생성
    if [[ -n "${REPL_USER}" ]]; then
        info "복제 유저 생성 중: ${REPL_USER}"
        "${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres \
            -c "CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN;" \
            2>/dev/null \
            && info "복제 유저 생성 완료" \
            || warn "복제 유저가 이미 존재하거나 생성 실패."

        PG_HBA="${DATA_PATH}/pg_hba.conf"
        cat >> "${PG_HBA}" <<EOF

# ── pg_basebackup replication user ──────────────────────
host    replication     ${REPL_USER}      127.0.0.1/32      trust
EOF
        "${ENGINE_PATH}/bin/pg_ctl" -D "${DATA_PATH}" reload
        info "pg_hba.conf 업데이트 및 reload 완료"
    fi

fi  # end single mode

# ============================================================
# ██████████████  HA MODE  ██████████████████████████████████
# ============================================================
if [[ "${INSTALL_MODE}" == "ha" ]]; then

    SSH_OPTS="-o StrictHostKeyChecking=no -p ${HA_SSH_PORT}"
    SCP_OPTS="-P ${HA_SSH_PORT} -o StrictHostKeyChecking=no"

    info "============================================================"
    info "  HA 모드: etcd(local) + Primary/Standby(remote) 구성"
    info "  HA 구성 로그 → ${HA_LOG}"
    info "============================================================"

    # ── SSH 연결 확인 ────────────────────────────────────────
    info "Primary SSH 연결 확인 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" "echo 'Primary SSH OK'" \
        || error "Primary(${HA_PRIMARY_HOST}) SSH 연결 실패."
    info "Standby SSH 연결 확인 중..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" "echo 'Standby SSH OK'" \
        || error "Standby(${HA_STANDBY_HOST}) SSH 연결 실패."

    # ──────────────────────────────────────────────────────────
    #  PHASE 1. etcd 설치 (로컬: etcd 서버)
    # ──────────────────────────────────────────────────────────
    info "============================================================"
    info "  PHASE 1. etcd 설치 (로컬)"
    info "============================================================"

    ETCD_INSTALL_DIR="/usr/local/etcd"
    sudo mkdir -p "${ETCD_INSTALL_DIR}"
    sudo tar -zxf "${ETCD_TARBALL}" -C "${ETCD_INSTALL_DIR}" --strip-components=1 \
        >> "${HA_LOG}" 2>&1
    sudo ln -sf "${ETCD_INSTALL_DIR}/etcd"     /usr/local/bin/etcd
    sudo ln -sf "${ETCD_INSTALL_DIR}/etcdctl"  /usr/local/bin/etcdctl
    info "etcd 바이너리 설치 완료: /usr/local/bin/etcd"

    # etcd 설정 및 systemd 서비스 등록
    sudo mkdir -p /etc/etcd /var/lib/etcd
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
Documentation=https://etcd.io/docs
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
        || error "etcd 기동 실패. 로그: journalctl -u etcd"

    # ──────────────────────────────────────────────────────────
    #  PHASE 2. Primary DB 서버 구성 (원격)
    # ──────────────────────────────────────────────────────────
    info "============================================================"
    info "  PHASE 2. Primary DB 서버 구성 → ${HA_PRIMARY_HOST}"
    info "============================================================"

    # 파일 전송
    info "Primary 로 패키지 전송 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" "mkdir -p ${SCRIPT_DIR}/installer"
    scp ${SCP_OPTS} \
        "${SCRIPT_DIR}/PKG.tar.gz" \
        "${PATRONI_PKGS}" \
        "${PG_TARBALL}" \
        "${HA_PRIMARY_HOST}:${INSTALLER_DIR}/" \
        >> "${HA_LOG}" 2>&1
    info "Primary 파일 전송 완료"

    # 원격 빌드 및 설치
    info "Primary PostgreSQL 빌드 및 설치 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<REMOTE_PRI_BUILD
set -e
# 의존 패키지 설치
PKG_TMP=\$(mktemp -d)
tar -zxf "${SCRIPT_DIR}/PKG.tar.gz" -C "\${PKG_TMP}"
sudo rpm -Uvh --force "\${PKG_TMP}"/PKG/*.rpm 2>/dev/null || true
rm -rf "\${PKG_TMP}"

# 빌드
BUILD_TMP=\$(mktemp -d)
tar -zxf "${PG_TARBALL}" -C "\${BUILD_TMP}"
cd "\${BUILD_TMP}/postgresql-${PG_VERSION}"
./configure --prefix="${ENGINE_PATH}" --with-openssl --with-libxml --with-libxslt --enable-nls --with-python --with-tcl --with-perl
make -j"${CPU_CORES}"
make install
rm -rf "\${BUILD_TMP}"

# 디렉토리 생성
mkdir -p "${ENGINE_PATH}/etc" "${DATA_PATH}" "${LOG_PATH}"
${ARC_PATH:+mkdir -p "${ARC_PATH}"}
${BACK_PATH:+mkdir -p "${BACK_PATH}" "${DUMP_PATH}"}
echo "Primary PG 설치 완료"
REMOTE_PRI_BUILD
    info "Primary PostgreSQL 설치 완료"

    # postgresql.conf 생성 및 전송
    info "Primary postgresql.conf 생성 및 전송 중..."
    CONF_TMP="/tmp/pg_primary.conf.$$"
    fn_gen_postgresql_conf "${CONF_TMP}" "ha"
    scp ${SCP_OPTS} "${CONF_TMP}" "${HA_PRIMARY_HOST}:/tmp/postgresql.conf.tmp" >> "${HA_LOG}" 2>&1
    rm -f "${CONF_TMP}"

    # initdb
    info "Primary initdb 실행 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "${ENGINE_PATH}/bin/initdb --pgdata=${DATA_PATH} --encoding=UTF8 --locale=ko_KR.utf8 --data-checksums" \
        >> "${HA_LOG}" 2>&1
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "cp /tmp/postgresql.conf.tmp ${DATA_PATH}/postgresql.conf" \
        >> "${HA_LOG}" 2>&1
    info "Primary initdb 완료"

    # .postgresrc 설정
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<REMOTE_PRI_RC
cat > "${HOME_DIR}/.postgresrc" <<RCEOF
export PGHOME=${ENGINE_PATH}
export PATH=\${PGHOME}/bin:\${PATH}
export LD_LIBRARY_PATH=\${PGHOME}/lib:\${LD_LIBRARY_PATH}
export PGDATA=${DATA_PATH}
export PGPORT=${PG_PORT}
export PGUSER=postgres
RCEOF
grep -q '.postgresrc' "${HOME_DIR}/.bashrc" 2>/dev/null \
    || printf '\n# PostgreSQL Environment\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> "${HOME_DIR}/.bashrc"
REMOTE_PRI_RC

    # Patroni 설치 (Primary)
    info "Primary Patroni 설치 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<REMOTE_PRI_PATRONI
set -e
PATRONI_TMP=\$(mktemp -d)
tar -zxf "${PATRONI_PKGS}" -C "\${PATRONI_TMP}"
pip3 install --no-index --find-links="\${PATRONI_TMP}/patroni_pkgs" patroni psycopg2-binary
rm -rf "\${PATRONI_TMP}"
echo "Patroni 설치 완료: \$(patroni --version 2>/dev/null || echo 'ok')"
REMOTE_PRI_PATRONI
    info "Primary Patroni 설치 완료"

    # Patroni 설정 파일 생성 (Primary)
    info "Primary patroni.yml 생성 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<REMOTE_PRI_PATRONI_CONF
sudo mkdir -p /etc/patroni
cat > /etc/patroni/patroni.yml <<PYML
scope: ${CLUSTER_NAME}
namespace: /db/
name: primary

restapi:
  listen: ${HA_PRIMARY_HOST}:8008
  connect_address: ${HA_PRIMARY_HOST}:8008

etcd:
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
        max_connections: 150
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
echo "patroni.yml 생성 완료"
REMOTE_PRI_PATRONI_CONF

    # Patroni systemd 서비스 (Primary)
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<REMOTE_PRI_SVC
PATRONI_BIN=\$(which patroni 2>/dev/null || echo "/usr/local/bin/patroni")
sudo bash -c "cat > /etc/systemd/system/patroni.service" <<SVC
[Unit]
Description=Patroni PostgreSQL HA
After=network.target etcd.service
Wants=etcd.service

[Service]
Type=simple
User=$(whoami)
ExecStart=\${PATRONI_BIN} /etc/patroni/patroni.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC
sudo systemctl daemon-reload
sudo systemctl enable patroni
echo "Patroni systemd 등록 완료"
REMOTE_PRI_SVC
    info "Primary Patroni 설정 완료"

    # ──────────────────────────────────────────────────────────
    #  PHASE 3. Standby DB 서버 구성 (원격)
    # ──────────────────────────────────────────────────────────
    info "============================================================"
    info "  PHASE 3. Standby DB 서버 구성 → ${HA_STANDBY_HOST}"
    info "============================================================"

    # 파일 전송 (엔진은 Primary에서 scp로 복사)
    info "Standby 로 패키지 전송 중..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" "mkdir -p ${SCRIPT_DIR}/installer ${ENGINE_BASE}"
    scp ${SCP_OPTS} \
        "${PATRONI_PKGS}" \
        "${HA_STANDBY_HOST}:${INSTALLER_DIR}/" \
        >> "${HA_LOG}" 2>&1

    # 엔진 영역: Primary → Standby scp 복사
    info "엔진 영역 Primary → Standby 복사 중 (로그 → ${HA_LOG})..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "scp ${SCP_OPTS} -r ${ENGINE_BASE} ${HA_STANDBY_HOST}:$(dirname "${ENGINE_BASE}")/" \
        >> "${HA_LOG}" 2>&1
    info "엔진 영역 복사 완료"

    # 디렉토리 및 환경변수 설정
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<REMOTE_SBY_DIRS
mkdir -p "${ENGINE_PATH}/etc" "${DATA_PATH}" "${LOG_PATH}"
${ARC_PATH:+mkdir -p "${ARC_PATH}"}
${BACK_PATH:+mkdir -p "${BACK_PATH}" "${DUMP_PATH}"}
cat > "${HOME_DIR}/.postgresrc" <<RCEOF
export PGHOME=${ENGINE_PATH}
export PATH=\${PGHOME}/bin:\${PATH}
export LD_LIBRARY_PATH=\${PGHOME}/lib:\${LD_LIBRARY_PATH}
export PGDATA=${DATA_PATH}
export PGPORT=${PG_PORT}
export PGUSER=postgres
RCEOF
grep -q '.postgresrc' "${HOME_DIR}/.bashrc" 2>/dev/null \
    || printf '\n# PostgreSQL Environment\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> "${HOME_DIR}/.bashrc"
REMOTE_SBY_DIRS

    # Patroni 설치 (Standby)
    info "Standby Patroni 설치 중..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<REMOTE_SBY_PATRONI
set -e
PATRONI_TMP=\$(mktemp -d)
tar -zxf "${PATRONI_PKGS}" -C "\${PATRONI_TMP}"
pip3 install --no-index --find-links="\${PATRONI_TMP}/patroni_pkgs" patroni psycopg2-binary
rm -rf "\${PATRONI_TMP}"
echo "Standby Patroni 설치 완료"
REMOTE_SBY_PATRONI
    info "Standby Patroni 설치 완료"

    # Patroni 설정 파일 (Standby)
    info "Standby patroni.yml 생성 중..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<REMOTE_SBY_PATRONI_CONF
sudo mkdir -p /etc/patroni
cat > /etc/patroni/patroni.yml <<PYML
scope: ${CLUSTER_NAME}
namespace: /db/
name: standby

restapi:
  listen: ${HA_STANDBY_HOST}:8008
  connect_address: ${HA_STANDBY_HOST}:8008

etcd:
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

PATRONI_BIN=\$(which patroni 2>/dev/null || echo "/usr/local/bin/patroni")
sudo bash -c "cat > /etc/systemd/system/patroni.service" <<SVC
[Unit]
Description=Patroni PostgreSQL HA
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
ExecStart=\${PATRONI_BIN} /etc/patroni/patroni.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC
sudo systemctl daemon-reload
sudo systemctl enable patroni
echo "Standby patroni.yml 및 systemd 등록 완료"
REMOTE_SBY_PATRONI_CONF
    info "Standby Patroni 설정 완료"

    # ──────────────────────────────────────────────────────────
    #  PHASE 4. Patroni 기동 (Primary → Standby 순서)
    # ──────────────────────────────────────────────────────────
    info "============================================================"
    info "  PHASE 4. Patroni 기동"
    info "============================================================"

    info "Primary Patroni 기동 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "sudo systemctl start patroni" >> "${HA_LOG}" 2>&1
    info "Primary Patroni 기동 요청 완료. 초기화 대기 중 (20초)..."
    sleep 20

    info "Standby Patroni 기동 중..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
        "sudo systemctl start patroni" >> "${HA_LOG}" 2>&1
    info "Standby Patroni 기동 요청 완료. 클론 대기 중 (30초)..."
    sleep 30

    # ── 클러스터 상태 확인 ───────────────────────────────────
    info "클러스터 상태 확인 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "patronictl -c /etc/patroni/patroni.yml list" \
        || warn "클러스터 상태 조회 실패. 잠시 후 수동 확인 해주세요: patronictl -c /etc/patroni/patroni.yml list"

    info "============================================================"
    info "  HA 구성 완료!"
    info "  etcd    : ${HA_ETCD_HOST}:2379"
    info "  Primary : ${HA_PRIMARY_HOST}:${PG_PORT}"
    info "  Standby : ${HA_STANDBY_HOST}:${PG_PORT}"
    info ""
    info "  클러스터 상태 확인:"
    info "  patronictl -c /etc/patroni/patroni.yml list"
    info ""
    info "  Switchover:"
    info "  patronictl -c /etc/patroni/patroni.yml switchover ${CLUSTER_NAME}"
    info "============================================================"

fi  # end ha mode

# ============================================================
#  완료
# ============================================================
echo ""
echo "======================================"
echo "  설치 완료!"
echo "======================================"
echo ""
echo "  설치 모드  : ${INSTALL_MODE}"
echo "  엔진 경로  : ${ENGINE_PATH}"
echo "  Data 경로  : ${DATA_PATH}"
echo "  Log 경로   : ${LOG_PATH}"
[[ -n "${ARC_PATH}"  ]] && echo "  Archive    : ${ARC_PATH}"
[[ -n "${BACK_PATH}" ]] && echo "  Backup     : ${BACK_PATH}"
if [[ "${INSTALL_MODE}" == "ha" ]]; then
echo ""
echo "  [HA 구성]"
echo "  etcd     : ${HA_ETCD_HOST}"
echo "  Primary  : ${HA_PRIMARY_HOST}:${PG_PORT}"
echo "  Standby  : ${HA_STANDBY_HOST}:${PG_PORT}"
echo "  복제유저 : ${REPL_USER_HA}"
fi
echo ""
echo "[DONE] 모든 작업이 완료되었습니다."

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
echo "======================================"
echo "  최종 디렉토리 구조"
echo "======================================"
find "${WORK_DIR}" -maxdepth 2 | sort | sed 's|[^/]*/|  |g'
echo ""
echo "[DONE] 모든 작업이 완료되었습니다."
