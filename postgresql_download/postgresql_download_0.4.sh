#!/bin/bash

# ============================================================
#  PostgreSQL Download Script
# ============================================================

set -e

WORK_DIR="postgresql"

echo "======================================"
echo "  PostgreSQL Download Script"
echo "======================================"
echo ""

# ── tar 설치 여부 자동 확인 ─────────────────────────────────
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

# ── 1. 모든 입력값 수집 ──────────────────────────────────────
read -rp "의존 패키지를 다운로드 하시겠습니까? [Y/n]: " DOWNLOAD_PKG
DOWNLOAD_PKG="${DOWNLOAD_PKG:-Y}"

read -rp "다운로드할 PostgreSQL 버전을 입력하세요 [17.9]: " PG_VERSION
PG_VERSION="${PG_VERSION:-17.9}"

# 버전에서 메이저 번호 추출 (예: 17.9 → 17)
PG_MAJOR="${PG_VERSION%%.*}"

# ── 2. 설정 확인 출력 ────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo "  설정 확인"
echo "  의존 패키지 다운로드 : ${DOWNLOAD_PKG}"
echo "  PostgreSQL 버전      : ${PG_VERSION} (메이저: ${PG_MAJOR})"
echo "  저장 디렉토리        : $(pwd)/${WORK_DIR}/"
echo "────────────────────────────────────────"
echo ""

# ── 3. 디렉토리 생성 ─────────────────────────────────────────
mkdir -p "${WORK_DIR}"

# ── 4. 의존 패키지 다운로드 ──────────────────────────────────
case "${DOWNLOAD_PKG,,}" in
    y|yes)
        PKG_TMP="${WORK_DIR}/PKG"
        mkdir -p "${PKG_TMP}"

        PKG_LOG="${WORK_DIR}/PKG_download.log"
        echo "[INFO] 의존 패키지를 다운로드합니다..."
        echo "[INFO] 다운로드 로그 → ${PKG_LOG}"
        sudo dnf install -y \
            --downloadonly \
            --downloaddir="${PKG_TMP}" \
            make gcc gcc-c++ \
            readline-devel zlib-devel openssl-devel \
            libxml2-devel libxslt-devel libicu-devel \
            libuuid-devel tcl tcl-devel \
            bison flex perl python3-devel \
            >> "${PKG_LOG}" 2>&1

        echo ""
        echo "[INFO] PKG 디렉토리를 tar.gz 으로 압축합니다..."
        tar -czf "${WORK_DIR}/PKG.tar.gz" -C "${WORK_DIR}" PKG
        rm -rf "${PKG_TMP}"
        echo "[INFO] 압축 완료 → ${WORK_DIR}/PKG.tar.gz"
        ;;
    n|no)
        echo "[INFO] 의존 패키지 다운로드를 건너뜁니다."
        ;;
    *)
        echo "[WARN] 알 수 없는 입력('${DOWNLOAD_PKG}') — 패키지 다운로드를 건너뜁니다."
        ;;
esac

# ── 5. PostgreSQL 소스 다운로드 ──────────────────────────────
PG_TARBALL="postgresql-${PG_VERSION}.tar.gz"
PG_URL="https://ftp.postgresql.org/pub/source/v${PG_VERSION}/${PG_TARBALL}"
PG_DEST="${WORK_DIR}/${PG_TARBALL}"

echo ""
echo "[INFO] PostgreSQL ${PG_VERSION} 소스를 다운로드합니다..."
echo "       URL : ${PG_URL}"

if command -v wget &>/dev/null; then
    wget -O "${PG_DEST}" "${PG_URL}"
else
    echo "[INFO] wget 을 찾을 수 없어 curl 을 사용합니다."
    curl -L -o "${PG_DEST}" "${PG_URL}"
fi

echo ""
echo "[INFO] 다운로드 완료!"
echo ""

# ── 6. postgresql_install.sh 생성 ────────────────────────────
INSTALL_DEST="${WORK_DIR}/postgresql_install.sh"
echo "[INFO] postgresql_install.sh 생성 중 → ${INSTALL_DEST}"

cat > "${INSTALL_DEST}" << 'INSTALL_EOF'
#!/bin/bash

# ============================================================
#  PostgreSQL Source Build Install Script
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

# 현재 OS 홈 디렉토리
HOME_DIR="${HOME:-$(eval echo ~$(whoami))}"

echo "======================================"
echo "  PostgreSQL Install Script"
echo "======================================"
echo ""

# ============================================================
#  STEP 0. PostgreSQL 프로세스 구동 여부 확인
# ============================================================
if pgrep -x "postgres" > /dev/null 2>&1; then
    warn "PostgreSQL 프로세스가 이미 실행 중입니다."
    ps aux | grep "[p]ostgres" | head -5
    echo ""
    read -rp "계속 진행하시겠습니까? 진행 시 기존 프로세스에 영향을 줄 수 있습니다. [y/N]: " PROC_CONTINUE
    PROC_CONTINUE="${PROC_CONTINUE:-N}"
    if [[ ! "${PROC_CONTINUE,,}" =~ ^(y|yes)$ ]]; then
        info "설치를 중단합니다."
        exit 0
    fi
    warn "기존 프로세스가 실행 중인 상태로 설치를 진행합니다."
else
    info "실행 중인 PostgreSQL 프로세스가 없습니다."
fi

echo ""

# ============================================================
#  STEP 1. 모든 입력값 수집
# ============================================================

# 1. PG 설치 여부
read -rp "PostgreSQL 을 설치하시겠습니까? [Y/n]: " DO_INSTALL
DO_INSTALL="${DO_INSTALL:-Y}"

# 2. CPU core 수
read -rp "사용할 CPU core 수를 입력하세요 [${DEFAULT_CPU}]: " CPU_CORES
CPU_CORES="${CPU_CORES:-$DEFAULT_CPU}"

# 3. Memory (GB)
read -rp "서버 Memory 를 입력하세요 (GB) [${DEFAULT_MEM_GB}]: " MEM_GB
MEM_GB="${MEM_GB:-$DEFAULT_MEM_GB}"

# 4. Port
read -rp "사용할 PostgreSQL Port 를 입력하세요 [5432]: " PG_PORT
PG_PORT="${PG_PORT:-5432}"

# 5. 엔진 경로
read -rp "엔진 설치 경로를 입력하세요 [/postgres]: " ENGINE_BASE
ENGINE_BASE="${ENGINE_BASE:-/postgres}"
ENGINE_PATH="${ENGINE_BASE}/app"

# 6. Data 경로
read -rp "Data 영역 경로를 입력하세요 [/pgdata]: " DATA_BASE
DATA_BASE="${DATA_BASE:-/pgdata}"
DATA_PATH="${DATA_BASE}/data"

# 7. Log 경로 (data 상위 하위 고정)
LOG_PATH="${DATA_BASE}/log"
echo "  Log 경로 : ${LOG_PATH}"

# 8. Archive 여부
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

# 9. Backup 여부 및 설정
read -rp "Backup 영역을 사용하시겠습니까? [Y/n]: " USE_BACKUP
USE_BACKUP="${USE_BACKUP:-Y}"
BACK_BASE=""
BACK_PATH=""
DUMP_PATH=""
BACKUP_KEEP=""
BACKUP_CRON=""
REPL_USER=""

if [[ "${USE_BACKUP,,}" =~ ^(y|yes)$ ]]; then
    read -rp "Backup 상위 경로를 입력하세요 [/pgbackup]: " BACK_BASE
    BACK_BASE="${BACK_BASE:-/pgbackup}"
    BACK_PATH="${BACK_BASE}/back"
    DUMP_PATH="${BACK_BASE}/pg_dump"
    echo "  Backup 경로 : ${BACK_PATH}"

    echo ""
    echo "  백업 주기를 선택하세요:"
    echo "    1) 매일 새벽 2시"
    echo "    2) 매주 일요일 새벽 2시"
    echo "    3) 직접 입력 (cron 형식: 분 시 일 월 요일)"
    read -rp "  선택 [1]: " BACKUP_CYCLE
    BACKUP_CYCLE="${BACKUP_CYCLE:-1}"
    case "${BACKUP_CYCLE}" in
        1) BACKUP_CRON="0 2 * * *" ;;
        2) BACKUP_CRON="0 2 * * 0" ;;
        3)
            read -rp "  cron 표현식 입력 (예: 0 2 * * *): " BACKUP_CRON
            BACKUP_CRON="${BACKUP_CRON:-0 2 * * *}"
            ;;
        *) BACKUP_CRON="0 2 * * *" ;;
    esac
    echo "  백업 주기 : ${BACKUP_CRON}"

    read -rp "  백업 유지 개수를 입력하세요 [7]: " BACKUP_KEEP
    BACKUP_KEEP="${BACKUP_KEEP:-7}"
    echo "  백업 유지 개수 : ${BACKUP_KEEP}"

    read -rp "  pg_basebackup 에 사용할 복제 유저명을 입력하세요 [replicator]: " REPL_USER
    REPL_USER="${REPL_USER:-replicator}"
    echo "  복제 유저 : ${REPL_USER}"
fi

# ── 설정 확인 ────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────"
echo "  설정 확인"
echo "  설치 여부      : ${DO_INSTALL}"
echo "  CPU Cores      : ${CPU_CORES}"
echo "  Memory         : ${MEM_GB} GB"
echo "  Port           : ${PG_PORT}"
echo "  엔진 경로      : ${ENGINE_PATH}"
echo "  Data 경로      : ${DATA_PATH}"
echo "  Log 경로       : ${LOG_PATH}"
echo "  Archive 경로   : ${ARC_PATH:-사용 안 함}"
echo "  Backup 경로    : ${BACK_PATH:-사용 안 함}"
if [[ -n "${BACK_PATH}" ]]; then
echo "  백업 주기      : ${BACKUP_CRON}"
echo "  백업 유지 수   : ${BACKUP_KEEP}"
echo "  복제 유저      : ${REPL_USER}"
fi
echo "────────────────────────────────────────────"
echo ""

case "${DO_INSTALL,,}" in
    n|no)
        info "설치를 건너뜁니다."
        exit 0
        ;;
esac

# ============================================================
#  STEP 1-1. 의존 패키지 설치 여부 확인
# ============================================================
REQUIRED_PKGS=(
    make gcc gcc-c++
    readline-devel zlib-devel openssl-devel
    libxml2-devel libxslt-devel libicu-devel
    libuuid-devel tcl tcl-devel
    bison flex perl python3-devel
)

info "의존 패키지 설치 여부를 확인합니다..."
MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! rpm -q "${pkg}" > /dev/null 2>&1; then
        MISSING_PKGS+=("${pkg}")
    fi
done

if [[ ${#MISSING_PKGS[@]} -eq 0 ]]; then
    info "모든 의존 패키지가 설치되어 있습니다."
else
    warn "아래 패키지가 설치되어 있지 않습니다:"
    for pkg in "${MISSING_PKGS[@]}"; do
        echo "    - ${pkg}"
    done
    echo ""
    echo "  아래 명령어로 설치해주세요:"
    echo ""
    echo "  dnf install -y ${MISSING_PKGS[*]}"
    echo ""
    error "의존 패키지 설치 후 다시 실행해주세요."
fi

# ── 로그 파일 경로 정의 ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/pg_install_log"
mkdir -p "${LOG_DIR}"
LOG_CONFIG="${LOG_DIR}/pg_config.log"
LOG_MAKE="${LOG_DIR}/pg_make.log"
LOG_MAKE_INSTALL="${LOG_DIR}/pg_make_install.log"
LOG_INSTALL="${LOG_DIR}/pg_install.log"
INSTALL_START=$(date '+%Y-%m-%d %H:%M:%S')

# ── pg_install.log : 입력값 요약 기록 ───────────────────────
cat > "${LOG_INSTALL}" << LOGEOF
============================================================
  PostgreSQL Install Summary
  Started : ${INSTALL_START}
============================================================

[설치 설정]
  CPU Cores      : ${CPU_CORES}
  Memory         : ${MEM_GB} GB
  Port           : ${PG_PORT}

[경로 설정]
  엔진 경로      : ${ENGINE_PATH}
  Data 경로      : ${DATA_PATH}
  Log 경로       : ${LOG_PATH}
  Archive 경로   : ${ARC_PATH:-사용 안 함}
  Backup 경로    : ${BACK_PATH:-사용 안 함}
  Dump 경로      : ${DUMP_PATH:-사용 안 함}

[백업 설정]
  백업 주기      : ${BACKUP_CRON:-사용 안 함}
  백업 유지 수   : ${BACKUP_KEEP:-사용 안 함}
  복제 유저      : ${REPL_USER:-사용 안 함}

[로그 파일]
  configure 로그 : ${LOG_CONFIG}
  make 로그      : ${LOG_MAKE}
  make install   : ${LOG_MAKE_INSTALL}
  설치 요약      : ${LOG_INSTALL}

------------------------------------------------------------
LOGEOF
info "설치 요약 로그 시작 → ${LOG_INSTALL}"

# ============================================================
#  STEP 2. 디렉토리 존재 확인 및 하위 디렉토리 생성
# ============================================================
info "디렉토리를 확인합니다..."

[[ ! -d "${ENGINE_BASE}" ]] && error "엔진 상위 경로가 존재하지 않습니다: ${ENGINE_BASE}"
[[ ! -d "${DATA_BASE}"   ]] && error "Data 상위 경로가 존재하지 않습니다: ${DATA_BASE}"
[[ -n "${ARC_BASE}"  && ! -d "${ARC_BASE}"  ]] && error "Archive 상위 경로가 존재하지 않습니다: ${ARC_BASE}"
[[ -n "${BACK_BASE}" && ! -d "${BACK_BASE}" ]] && error "Backup 상위 경로가 존재하지 않습니다: ${BACK_BASE}"

# ── data 디렉토리 비어있는지 확인 ───────────────────────────
if [[ -d "${DATA_PATH}" ]] && [[ -n "$(ls -A "${DATA_PATH}" 2>/dev/null)" ]]; then
    warn "${DATA_PATH} 디렉토리가 비어있지 않습니다."
    ls -la "${DATA_PATH}"
    echo ""
    read -rp "  해당 디렉토리를 삭제하고 계속 진행하시겠습니까? [y/N]: " CLEAN_DATA
    CLEAN_DATA="${CLEAN_DATA:-N}"
    if [[ "${CLEAN_DATA,,}" =~ ^(y|yes)$ ]]; then
        rm -rf "${DATA_PATH:?}"/*
        rm -rf "${DATA_PATH:?}"/.[!.]* 2>/dev/null || true
        info "${DATA_PATH} 디렉토리를 비웠습니다."
    else
        error "설치를 중단합니다. 데이터 디렉토리를 직접 정리 후 재실행해주세요."
    fi
fi

# 하위 디렉토리 생성
mkdir -p "${ENGINE_PATH}"
mkdir -p "${ENGINE_PATH}/etc"
mkdir -p "${DATA_PATH}"
mkdir -p "${LOG_PATH}"

[[ -n "${ARC_PATH}"  ]] && mkdir -p "${ARC_PATH}"
[[ -n "${BACK_PATH}" ]] && mkdir -p "${BACK_PATH}"
[[ -n "${DUMP_PATH}" ]] && mkdir -p "${DUMP_PATH}"

info "디렉토리 확인 및 생성 완료"

# ============================================================
#  STEP 3. 소스 압축 해제 및 빌드
# ============================================================
PG_TARBALL=$(ls postgresql-*.tar.gz 2>/dev/null | head -1)
[[ -z "$PG_TARBALL" ]] && error "postgresql-*.tar.gz 파일을 찾을 수 없습니다."

PG_DIR="${PG_TARBALL%.tar.gz}"
PG_DIR="${PG_DIR##*/}"

info "소스 압축 해제: ${PG_TARBALL}"
tar -zxf "${PG_TARBALL}"

info "소스 디렉토리로 이동: ${PG_DIR}"
cd "${PG_DIR}"

# ── configure ────────────────────────────────────────────────
info "./configure 실행 중... (로그: ${LOG_CONFIG})"
./configure \
    --prefix="${ENGINE_PATH}" \
    --with-openssl \
    --with-libxml \
    --with-libxslt \
    --enable-nls \
    --with-python \
    --with-tcl \
    --with-perl \
    >> "${LOG_CONFIG}" 2>&1 || { echo "[ERROR] configure 실패. 로그: ${LOG_CONFIG}"; exit 1; }
info "configure 완료"

# ── make ─────────────────────────────────────────────────────
info "make -j${CPU_CORES} 실행 중... (로그: ${LOG_MAKE})"
make -j"${CPU_CORES}" >> "${LOG_MAKE}" 2>&1 || { echo "[ERROR] make 실패. 로그: ${LOG_MAKE}"; exit 1; }
info "make 완료"

# ── make install ─────────────────────────────────────────────
info "make install 실행 중... (로그: ${LOG_MAKE_INSTALL})"
make install >> "${LOG_MAKE_INSTALL}" 2>&1 || { echo "[ERROR] make install 실패. 로그: ${LOG_MAKE_INSTALL}"; exit 1; }
info "make install 완료"

cd ..
info "빌드 및 설치 완료 → ${ENGINE_PATH}"

# ============================================================
#  STEP 4. .postgresrc 생성
# ============================================================
POSTGRESRC="${HOME_DIR}/.postgresrc"
info ".postgresrc 생성 중: ${POSTGRESRC}"

cat > "${POSTGRESRC}" << RCEOF
# ============================================================
#  PostgreSQL Environment
# ============================================================

export PGHOME=${ENGINE_PATH}
export PGBIN=\$PGHOME/bin
export PGLIB=\$PGHOME/lib
export PGPORT=${PG_PORT}
export PGDATA=${DATA_PATH}
export LD_LIBRARY_PATH=\$PGLIB:\$LD_LIBRARY_PATH
export PGUSER=postgres
export PGDATABASE=postgres
export PGLOG=${LOG_PATH}
export SRVLOG=\$PGLOG
export PATH=\$PGBIN:\$PATH
export LANG=C
RCEOF

if [[ -n "${ARC_PATH}" ]]; then
    echo "export PGALOG=${ARC_PATH}" >> "${POSTGRESRC}"
else
    echo "# export PGALOG=            # archive 미사용" >> "${POSTGRESRC}"
fi

if [[ -n "${BACK_PATH}" ]]; then
    cat >> "${POSTGRESRC}" << BKEOF
export PGBBAK=${BACK_PATH}
export PGBLOG=${LOG_PATH}
export HOSTUSER=postgres
export BACKUP_PATH=${BACK_PATH}
export PGDBAK=${DUMP_PATH}
BKEOF
else
    echo "# export PGBBAK=            # backup 미사용" >> "${POSTGRESRC}"
fi

cat >> "${POSTGRESRC}" << ALIASEOF

# ── Aliases ─────────────────────────────────────────────────
alias pgbin='cd ${ENGINE_PATH}/bin'
alias pgdata='cd ${DATA_PATH}'
alias pglog='cd ${LOG_PATH}'
ALIASEOF

if [[ -n "${BACK_PATH}" ]]; then
    echo "alias pgbackup='cd ${BACK_PATH}'" >> "${POSTGRESRC}"
fi

info ".postgresrc 생성 완료"

# ============================================================
#  STEP 5. .bashrc 에 .postgresrc 로드 추가
# ============================================================
BASHRC="${HOME_DIR}/.bashrc"
info ".bashrc 업데이트 중: ${BASHRC}"

if ! grep -q ".postgresrc" "${BASHRC}" 2>/dev/null; then
    cat >> "${BASHRC}" << 'BASHEOF'

# PostgreSQL Environment
if [ -f ~/.postgresrc ]; then
  . ~/.postgresrc
fi
BASHEOF
    info ".bashrc 에 .postgresrc 로드 구문 추가 완료"
else
    warn ".bashrc 에 이미 .postgresrc 로드 구문이 존재합니다. 건너뜁니다."
fi

info "환경변수 적용 중..."
. "${POSTGRESRC}"
. "${BASHRC}"

# ============================================================
#  STEP 6. postgresql.conf 생성 (pgtune 방식 계산)
# ============================================================
info "postgresql.conf 계산 및 생성 중..."

MEM_KB=$(( MEM_GB * 1024 * 1024 ))
SHR_BUF_KB=$(( MEM_KB / 4 ))
SHR_BUF="${SHR_BUF_KB}kB"
EFF_CACHE_KB=$(( MEM_KB * 3 / 4 ))
EFF_CACHE="${EFF_CACHE_KB}kB"
MAX_CONN=100
WORK_MEM_KB=$(( (MEM_KB / 4) / MAX_CONN ))
[[ "$WORK_MEM_KB" -lt 4096 ]] && WORK_MEM_KB=4096
WORK_MEM="${WORK_MEM_KB}kB"
MAINT_MEM_KB=$(( MEM_KB / 20 ))
[[ "$MAINT_MEM_KB" -lt 65536  ]] && MAINT_MEM_KB=65536
[[ "$MAINT_MEM_KB" -gt 2097152 ]] && MAINT_MEM_KB=2097152
MAINT_MEM="${MAINT_MEM_KB}kB"
WAL_BUF_KB=$(( SHR_BUF_KB * 3 / 100 ))
[[ "$WAL_BUF_KB" -lt 1024  ]] && WAL_BUF_KB=1024
[[ "$WAL_BUF_KB" -gt 65536 ]] && WAL_BUF_KB=65536
WAL_BUF="${WAL_BUF_KB}kB"
CKPT_TARGET="0.9"
MAX_WORKERS="${CPU_CORES}"
PARA_WORKERS=$(( CPU_CORES / 2 ))
[[ "$PARA_WORKERS" -lt 1 ]] && PARA_WORKERS=1

CONF_FILE="/tmp/postgresql.conf.tmp"

cat > "${CONF_FILE}" << CONFEOF
# ============================================================
#  postgresql.conf  (pgtune-style)
#  Server: ${CPU_CORES} CPU / ${MEM_GB} GB RAM
# ============================================================

listen_addresses = '*'
port             = ${PG_PORT}
max_connections  = ${MAX_CONN}

shared_buffers          = ${SHR_BUF}
effective_cache_size    = ${EFF_CACHE}
work_mem                = ${WORK_MEM}
maintenance_work_mem    = ${MAINT_MEM}

wal_buffers                  = ${WAL_BUF}
checkpoint_completion_target = ${CKPT_TARGET}
wal_level                    = replica
CONFEOF

if [[ -n "${ARC_PATH}" ]]; then
    cat >> "${CONF_FILE}" << ARCEOF
archive_mode    = on
archive_command = 'cp %p ${ARC_PATH}/%f'
ARCEOF
else
    cat >> "${CONF_FILE}" << ARCEOF
archive_mode    = off
# archive_command = ''
ARCEOF
fi

cat >> "${CONF_FILE}" << CONFEOF2

max_worker_processes             = ${MAX_WORKERS}
max_parallel_workers_per_gather  = ${PARA_WORKERS}
max_parallel_workers             = ${CPU_CORES}

logging_collector = on
log_directory     = '${LOG_PATH}'
log_filename      = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age  = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000
log_line_prefix   = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints   = on
log_connections   = on
log_disconnections= on
log_lock_waits    = on

timezone          = 'Asia/Seoul'
lc_messages       = 'en_US.utf8'
lc_monetary       = 'ko_KR.utf8'
lc_numeric        = 'ko_KR.utf8'
lc_time           = 'ko_KR.utf8'
CONFEOF2

info "postgresql.conf 생성 완료 (임시 저장: ${CONF_FILE})"

# ============================================================
#  STEP 7. initdb
# ============================================================
info "initdb 실행 중..."
"${ENGINE_PATH}/bin/initdb" \
    --pgdata="${DATA_PATH}" \
    --encoding=UTF8 \
    --locale=ko_KR.utf8 \
    --data-checksums

info "initdb 완료"

info "postgresql.conf 를 생성된 설정으로 덮어씁니다..."
cp "${CONF_FILE}" "${DATA_PATH}/postgresql.conf"
rm -f "${CONF_FILE}"
info "postgresql.conf 적용 완료 → ${DATA_PATH}/postgresql.conf"

# ============================================================
#  STEP 8. 백업 스크립트 생성 및 cron 등록
# ============================================================
if [[ -n "${BACK_PATH}" ]]; then
    BACKUP_SCRIPT="${ENGINE_PATH}/etc/pg_basebackup.sh"
    info "백업 스크립트 생성 중: ${BACKUP_SCRIPT}"

    cat > "${BACKUP_SCRIPT}" << BSEOF
#!/bin/bash
# ============================================================
#  PostgreSQL Base Backup Script
#  - 압축 형식 고정: tar + gzip (레벨 9)
#  - 백업 유지 개수: ${BACKUP_KEEP}
# ============================================================

PGBIN="${ENGINE_PATH}/bin"
BACKUP_DIR="${BACK_PATH}"
BACKUP_KEEP=${BACKUP_KEEP}
REPL_USER="${REPL_USER}"
PG_PORT="${PG_PORT}"
TIMESTAMP=\$(date '+%Y%m%d_%H%M%S')
BACKUP_NAME="base_\${TIMESTAMP}"
BACKUP_DEST="\${BACKUP_DIR}/\${BACKUP_NAME}"
LOG_FILE="${LOG_PATH}/backup_\${TIMESTAMP}.log"

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 백업 시작: \${BACKUP_DEST}" | tee -a "\${LOG_FILE}"

\${PGBIN}/pg_basebackup \\
    -D "\${BACKUP_DEST}" \\
    -F tar \\
    -X stream \\
    -P \\
    -R \\
    -U "\${REPL_USER}" \\
    -p "\${PG_PORT}" \\
    -Z 9 \\
    >> "\${LOG_FILE}" 2>&1

if [[ \$? -eq 0 ]]; then
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 백업 완료: \${BACKUP_DEST}" | tee -a "\${LOG_FILE}"
else
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 백업 실패. 로그: \${LOG_FILE}" | tee -a "\${LOG_FILE}"
    exit 1
fi

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 오래된 백업 정리 (유지 개수: \${BACKUP_KEEP})" | tee -a "\${LOG_FILE}"
ls -dt "\${BACKUP_DIR}"/base_* 2>/dev/null | tail -n +\$(( BACKUP_KEEP + 1 )) | xargs rm -rf --
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 정리 완료" | tee -a "\${LOG_FILE}"
BSEOF

    chmod 750 "${BACKUP_SCRIPT}"
    info "백업 스크립트 생성 완료 → ${BACKUP_SCRIPT}"

    info "cron 등록 중... (주기: ${BACKUP_CRON})"
    CRON_JOB="${BACKUP_CRON} ${BACKUP_SCRIPT} >> ${LOG_PATH}/cron_backup.log 2>&1"
    EXISTING_CRON=$(crontab -l 2>/dev/null || true)
    if echo "${EXISTING_CRON}" | grep -qF "${BACKUP_SCRIPT}"; then
        warn "cron 에 이미 백업 작업이 등록되어 있습니다. 건너뜁니다."
    else
        ( echo "${EXISTING_CRON}"; echo "${CRON_JOB}" ) | crontab -
        info "cron 등록 완료: ${CRON_JOB}"
    fi

    echo ""
    warn "pg_basebackup 사용을 위해 아래 작업을 추가로 진행해주세요:"
    echo ""
    echo "  1) 복제 유저 생성 (DB 기동 후 psql 에서 실행):"
    echo "     CREATE USER ${REPL_USER} REPLICATION LOGIN;"
    echo ""
    echo "  2) pg_hba.conf 에 replication 접속 허용 추가:"
    echo "     host  replication  ${REPL_USER}  127.0.0.1/32  trust"
    echo ""
fi

# ============================================================
#  STEP 9. PostgreSQL 서비스 시작 및 확인
# ============================================================
info "PostgreSQL 서비스를 시작합니다..."
"${ENGINE_PATH}/bin/pg_ctl" -D "${DATA_PATH}" -l "${LOG_PATH}/startup.log" start

MAX_WAIT=10
COUNT=0
echo -n "  Starting PostgreSQL"
while ! "${ENGINE_PATH}/bin/pg_isready" -p "${PG_PORT}" > /dev/null 2>&1; do
    if [ $COUNT -ge $MAX_WAIT ]; then
        echo ""
        error "PostgreSQL 시작 확인 실패. ${LOG_PATH}/startup.log 를 확인하세요."
    fi
    echo -n "."
    sleep 1
    (( COUNT++ ))
done
echo ""
info "PostgreSQL 서버가 정상적으로 시작되었습니다. (Port: ${PG_PORT})"

"${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres -c "SELECT version();"

# ============================================================
#  완료
# ============================================================
echo ""
echo "======================================"
echo "  설치 완료!"
echo "======================================"
echo ""
echo "  엔진 경로  : ${ENGINE_PATH}"
echo "  Data 경로  : ${DATA_PATH}"
echo "  Log 경로   : ${LOG_PATH}"
[[ -n "${ARC_PATH}"  ]] && echo "  Archive    : ${ARC_PATH}"
[[ -n "${BACK_PATH}" ]] && echo "  Backup     : ${BACK_PATH}"
[[ -n "${BACK_PATH}" ]] && echo "  백업 스크립트 : ${ENGINE_PATH}/etc/pg_basebackup.sh"
[[ -n "${BACK_PATH}" ]] && echo "  백업 주기  : ${BACKUP_CRON}"
echo ""
echo "  PostgreSQL 시작 명령어:"
echo "  \$ pg_ctl -D ${DATA_PATH} -l ${LOG_PATH}/startup.log start"
echo ""
echo "[DONE] 모든 작업이 완료되었습니다."

INSTALL_END=$(date '+%Y-%m-%d %H:%M:%S')
cat >> "${LOG_INSTALL}" << END_LOG

[완료]
  Finished : \${INSTALL_END}
  상태     : SUCCESS
============================================================
END_LOG
INSTALL_EOF

chmod 750 "${INSTALL_DEST}"
echo "[INFO] postgresql_install.sh 생성 완료 → ${INSTALL_DEST}"

echo ""
echo "======================================"
echo "  최종 디렉토리 구조"
echo "======================================"
find "${WORK_DIR}" -maxdepth 1 | sort | sed 's|[^/]*/|  |g'
echo ""
echo "[DONE] 모든 작업이 완료되었습니다."
