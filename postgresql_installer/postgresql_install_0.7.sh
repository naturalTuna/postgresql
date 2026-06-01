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

# 5. HA 구성 여부
echo "----------------"
read -rp "HA(Streaming Replication) 구성을 하시겠습니까? [y/N]: " USE_HA
USE_HA="${USE_HA:-N}"

HA_PRIMARY_HOST=""
HA_STANDBY_HOST=""
HA_SSH_PORT=""
REPL_USER_HA=""
REPL_PASS_HA=""

if [[ "${USE_HA,,}" =~ ^(y|yes)$ ]]; then
    read -rp "  Primary 호스트명 또는 IP를 입력하세요: " HA_PRIMARY_HOST
    [[ -z "${HA_PRIMARY_HOST}" ]] && { echo "[ERROR] Primary 호스트를 입력해야 합니다."; exit 1; }

    read -rp "  Standby 호스트명 또는 IP를 입력하세요: " HA_STANDBY_HOST
    [[ -z "${HA_STANDBY_HOST}" ]] && { echo "[ERROR] Standby 호스트를 입력해야 합니다."; exit 1; }

    read -rp "  SSH 포트를 입력하세요 [22]: " HA_SSH_PORT
    HA_SSH_PORT="${HA_SSH_PORT:-22}"

    read -rp "  복제 전용 유저명을 입력하세요 [replicator]: " REPL_USER_HA
    REPL_USER_HA="${REPL_USER_HA:-replicator}"

    read -rsp "  복제 전용 유저 패스워드를 입력하세요: " REPL_PASS_HA
    echo ""
    [[ -z "${REPL_PASS_HA}" ]] && { echo "[ERROR] 복제 유저 패스워드를 입력해야 합니다."; exit 1; }

    echo "  Primary  : ${HA_PRIMARY_HOST}"
    echo "  Standby  : ${HA_STANDBY_HOST}"
    echo "  SSH Port : ${HA_SSH_PORT}"
    echo "  복제유저 : ${REPL_USER_HA}"
fi
echo "----------------"

# 6. 엔진 경로
read -rp "엔진 설치 경로를 입력하세요 [/postgres]: " ENGINE_BASE
ENGINE_BASE="${ENGINE_BASE:-/postgres}"
ENGINE_PATH="${ENGINE_BASE}/app"

# 7. Data 경로
read -rp "Data 영역 경로를 입력하세요 [/pgdata]: " DATA_BASE
DATA_BASE="${DATA_BASE:-/pgdata}"
DATA_PATH="${DATA_BASE}/data"

# 8. Log 경로 (data 상위 하위 고정)
LOG_PATH="${DATA_BASE}/log"
echo "  Log 경로 : ${LOG_PATH}"

# 9. Archive 여부
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

# 10. Backup 여부 및 설정
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

    if [[ "${USE_HA,,}" =~ ^(y|yes)$ ]]; then
        REPL_USER="${REPL_USER_HA}"
        echo "  복제 유저 : ${REPL_USER} (HA 설정에서 상속)"
    else
        read -rp "  pg_basebackup 에 사용할 복제 유저명을 입력하세요 [replicator]: " REPL_USER
        REPL_USER="${REPL_USER:-replicator}"
        echo "  복제 유저 : ${REPL_USER}"
    fi
fi

# ── 설정 확인 ────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────"
echo "  설정 확인"
echo "  설치 여부      : ${DO_INSTALL}"
echo "  CPU Cores      : ${CPU_CORES}"
echo "  Memory         : ${MEM_GB} GB"
echo "  Port           : ${PG_PORT}"
if [[ "${USE_HA,,}" =~ ^(y|yes)$ ]]; then
echo "  HA 구성        : 사용"
echo "  Primary        : ${HA_PRIMARY_HOST}"
echo "  Standby        : ${HA_STANDBY_HOST}"
echo "  SSH Port       : ${HA_SSH_PORT}"
echo "  복제 유저      : ${REPL_USER_HA}"
else
echo "  HA 구성        : 사용 안 함"
fi
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
cat > "${LOG_INSTALL}" <<EOF
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
EOF
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
PG_TARBALL=$(ls postgresql/postgresql-*.tar.gz 2>/dev/null | head -1)
if [[ -z "$PG_TARBALL" ]]; then
    PG_TARBALL=$(ls postgresql-*.tar.gz 2>/dev/null | head -1)
fi
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

cat > "${POSTGRESRC}" <<EOF
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
EOF

if [[ -n "${ARC_PATH}" ]]; then
    echo "export PGALOG=${ARC_PATH}" >> "${POSTGRESRC}"
else
    echo "# export PGALOG=            # archive 미사용" >> "${POSTGRESRC}"
fi

if [[ -n "${BACK_PATH}" ]]; then
    cat >> "${POSTGRESRC}" <<EOF
export PGBBAK=${BACK_PATH}
export PGBLOG=${LOG_PATH}
export HOSTUSER=postgres
export BACKUP_PATH=${BACK_PATH}
export PGDBAK=${DUMP_PATH}
EOF
else
    echo "# export PGBBAK=            # backup 미사용" >> "${POSTGRESRC}"
fi

cat >> "${POSTGRESRC}" <<EOF

# ── Aliases ─────────────────────────────────────────────────
alias pgbin='cd ${ENGINE_PATH}/bin'
alias pgdata='cd ${DATA_PATH}'
alias pglog='cd ${LOG_PATH}'
EOF

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
    cat >> "${BASHRC}" <<'EOF'

# PostgreSQL Environment
if [ -f ~/.postgresrc ]; then
  . ~/.postgresrc
fi
EOF
    info ".bashrc 에 .postgresrc 로드 구문 추가 완료"
else
    warn ".bashrc 에 이미 .postgresrc 로드 구문이 존재합니다. 건너뜁니다."
fi

info "환경변수 적용 중..."
# shellcheck source=/dev/null
. "${POSTGRESRC}"
# shellcheck source=/dev/null
. "${BASHRC}"

# ============================================================
#  STEP 6. postgresql.conf 생성 (pgtune 방식 계산)
# ============================================================
info "postgresql.conf 계산 및 생성 중..."

MEM_KB=$(( MEM_GB * 1024 * 1024 ))

SHR_BUF_KB=$(( MEM_KB / 4 ))
SHR_BUF_MB=$(( SHR_BUF_KB / 1024 ))
SHR_BUF="${SHR_BUF_MB}MB"

EFF_CACHE_MB=$(( MEM_KB * 3 / 4 / 1024 ))
EFF_CACHE="${EFF_CACHE_MB}MB"

MAX_CONN=150
WORK_MEM_MB=$(( (MEM_KB / 4) / MAX_CONN / 1024 ))
[[ "$WORK_MEM_MB" -lt 4 ]] && WORK_MEM_MB=4
WORK_MEM="${WORK_MEM_MB}MB"

MAINT_MEM_MB=$(( MEM_KB / 20 / 1024 ))
[[ "$MAINT_MEM_MB" -lt 64  ]] && MAINT_MEM_MB=64
[[ "$MAINT_MEM_MB" -gt 2048 ]] && MAINT_MEM_MB=2048
MAINT_MEM="${MAINT_MEM_MB}MB"

WAL_BUF_MB=$(( SHR_BUF_MB * 3 / 100 ))
[[ "$WAL_BUF_MB" -lt 1  ]] && WAL_BUF_MB=1
[[ "$WAL_BUF_MB" -gt 64 ]] && WAL_BUF_MB=64
WAL_BUF="${WAL_BUF_MB}MB"

# WAL 크기 설정 (메모리 기반 계산)
MIN_WAL_SIZE_MB=$(( MEM_GB * 1024 / 16 ))
[[ "$MIN_WAL_SIZE_MB" -lt 256  ]] && MIN_WAL_SIZE_MB=256

MAX_WAL_SIZE_MB=$(( MEM_GB * 1024 / 4 ))
[[ "$MAX_WAL_SIZE_MB" -lt 1024 ]] && MAX_WAL_SIZE_MB=1024

WAL_KEEP_SIZE_MB=$(( MAX_WAL_SIZE_MB / 2 ))
[[ "$WAL_KEEP_SIZE_MB" -lt 512 ]] && WAL_KEEP_SIZE_MB=512

CKPT_TARGET="0.9"
MAX_WORKERS="${CPU_CORES}"
PARA_WORKERS=$(( CPU_CORES / 2 ))
[[ "$PARA_WORKERS" -lt 1 ]] && PARA_WORKERS=1

CONF_FILE="/tmp/postgresql.conf.tmp"

cat > "${CONF_FILE}" <<EOF
# ============================================================
#  postgresql.conf
#  Generated by postgresql_install.sh (pgtune-style)
#  Server: ${CPU_CORES} CPU / ${MEM_GB} GB RAM
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
checkpoint_completion_target = ${CKPT_TARGET}
wal_level                    = replica
min_wal_size                 = ${MIN_WAL_SIZE_MB}MB
max_wal_size                 = ${MAX_WAL_SIZE_MB}MB
wal_keep_size                = ${WAL_KEEP_SIZE_MB}MB
EOF

if [[ -n "${ARC_PATH}" ]]; then
    cat >> "${CONF_FILE}" <<EOF
archive_mode    = on
archive_command = 'cp %p ${ARC_PATH}/%f'
EOF
else
    cat >> "${CONF_FILE}" <<EOF
archive_mode    = off
# archive_command = ''
EOF
fi

cat >> "${CONF_FILE}" <<EOF

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

info "postgresql.conf 생성 완료 (임시 저장: ${CONF_FILE})"

# ── HA 구성 시 복제 파라미터 추가 ────────────────────────────
if [[ "${USE_HA,,}" =~ ^(y|yes)$ ]]; then
    cat >> "${CONF_FILE}" <<EOF

# ── HA Replication 설정 ────────────────────────────────────
max_wal_senders         = 10    # max number of walsender processes
max_replication_slots   = 10    # max number of replication slots
EOF
    info "postgresql.conf 에 HA 복제 파라미터 추가 완료"
fi

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

    cat > "${BACKUP_SCRIPT}" <<EOF
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

# pg_basebackup 실행
# -F tar  : tar 형식
# -X stream : WAL 스트리밍 방식으로 포함
# -P      : 진행률 표시
# -R      : standby.signal + recovery 설정 자동 생성
# -Z 9    : gzip 최대 압축
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

# 오래된 백업 삭제 (유지 개수 초과분)
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 오래된 백업 정리 (유지 개수: \${BACKUP_KEEP})" | tee -a "\${LOG_FILE}"
ls -dt "\${BACKUP_DIR}"/base_* 2>/dev/null | tail -n +\$(( BACKUP_KEEP + 1 )) | xargs rm -rf --
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 정리 완료" | tee -a "\${LOG_FILE}"
EOF

    chmod 750 "${BACKUP_SCRIPT}"
    info "백업 스크립트 생성 완료 → ${BACKUP_SCRIPT}"

    # ── cron 등록 ────────────────────────────────────────────
    info "cron 등록 중... (주기: ${BACKUP_CRON})"
    CRON_JOB="${BACKUP_CRON} ${BACKUP_SCRIPT} >> ${LOG_PATH}/cron_backup.log 2>&1"

    EXISTING_CRON=$(crontab -l 2>/dev/null || true)
    if echo "${EXISTING_CRON}" | grep -qF "${BACKUP_SCRIPT}"; then
        warn "cron 에 이미 백업 작업이 등록되어 있습니다. 건너뜁니다."
    else
        ( echo "${EXISTING_CRON}"; echo "${CRON_JOB}" ) | crontab -
        info "cron 등록 완료: ${CRON_JOB}"
    fi
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
#  STEP 10. 복제 유저 자동 생성 (Backup 또는 HA 사용 시)
# ============================================================
_REPL_TARGET_USER=""
_REPL_TARGET_PASS=""

if [[ "${USE_HA,,}" =~ ^(y|yes)$ ]]; then
    _REPL_TARGET_USER="${REPL_USER_HA}"
    _REPL_TARGET_PASS="${REPL_PASS_HA}"
elif [[ -n "${REPL_USER}" ]]; then
    _REPL_TARGET_USER="${REPL_USER}"
    _REPL_TARGET_PASS=""
fi

if [[ -n "${_REPL_TARGET_USER}" ]]; then
    info "복제 유저 생성 중: ${_REPL_TARGET_USER}"
    if [[ -n "${_REPL_TARGET_PASS}" ]]; then
        "${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres \
            -c "CREATE ROLE ${_REPL_TARGET_USER} WITH REPLICATION LOGIN PASSWORD '${_REPL_TARGET_PASS}';" \
            2>/dev/null \
            && info "복제 유저 생성 완료: ${_REPL_TARGET_USER}" \
            || warn "복제 유저 ${_REPL_TARGET_USER} 가 이미 존재하거나 생성 실패. 계속 진행합니다."
    else
        "${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres \
            -c "CREATE ROLE ${_REPL_TARGET_USER} WITH REPLICATION LOGIN;" \
            2>/dev/null \
            && info "복제 유저 생성 완료: ${_REPL_TARGET_USER}" \
            || warn "복제 유저 ${_REPL_TARGET_USER} 가 이미 존재하거나 생성 실패. 계속 진행합니다."
    fi

    # ── pg_hba.conf 에 replication 접속 허용 추가 ────────────
    PG_HBA="${DATA_PATH}/pg_hba.conf"
    info "pg_hba.conf 업데이트 중: ${PG_HBA}"

    if [[ "${USE_HA,,}" =~ ^(y|yes)$ ]]; then
        # HA 구성: primary/standby 양방향 허용
        cat >> "${PG_HBA}" <<EOF

# ── HA Streaming Replication ─────────────────────────────
# replication
host    replication     ${_REPL_TARGET_USER}      ${HA_PRIMARY_HOST}/24      trust
host    replication     ${_REPL_TARGET_USER}      ${HA_STANDBY_HOST}/24      trust
# for rewind
host    postgres        ${_REPL_TARGET_USER}      ${HA_PRIMARY_HOST}/24      trust
host    postgres        ${_REPL_TARGET_USER}      ${HA_STANDBY_HOST}/24      trust
EOF
    else
        # Backup 전용: localhost만 허용
        cat >> "${PG_HBA}" <<EOF

# ── pg_basebackup replication user ──────────────────────
host    replication     ${_REPL_TARGET_USER}      127.0.0.1/32      trust
EOF
    fi

    # pg_hba.conf 반영을 위해 reload
    info "pg_hba.conf reload 중..."
    "${ENGINE_PATH}/bin/pg_ctl" -D "${DATA_PATH}" reload
    info "pg_hba.conf reload 완료"
fi

# ============================================================
#  STEP 11. HA Standby 구성
#  방식: Primary 엔진 영역 scp 복사 + pg_basebackup 데이터 복제
# ============================================================
if [[ "${USE_HA,,}" =~ ^(y|yes)$ ]]; then
    SSH_OPTS="-o StrictHostKeyChecking=no -p ${HA_SSH_PORT}"
    SCP_OPTS="-P ${HA_SSH_PORT} -o StrictHostKeyChecking=no"
    SCRIPT_DIR_ABS="$(cd "$(dirname "$0")" && pwd)"
    HA_LOG="${LOG_DIR}/ha_setup.log"

    info "============================================================"
    info "  HA Standby 구성 시작 → ${HA_STANDBY_HOST}"
    info "  방식: 엔진 영역 scp 복사 + pg_basebackup 데이터 복제"
    info "  HA 구성 로그 → ${HA_LOG}"
    info "============================================================"

    # ── SSH 연결 확인 ────────────────────────────────────────
    info "Standby SSH 연결 확인 중..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" "echo 'SSH OK'" \
        || error "Standby(${HA_STANDBY_HOST}) SSH 연결 실패. 키 교환 및 방화벽을 확인하세요."

    # ── Standby 디렉토리 생성 ────────────────────────────────
    info "Standby 디렉토리 생성 중..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash <<REMOTE_MKDIR >> "${HA_LOG}" 2>&1
set -e
mkdir -p "${ENGINE_BASE}"
mkdir -p "${DATA_PATH}"
mkdir -p "${LOG_PATH}"
${ARC_PATH:+mkdir -p "${ARC_PATH}"}
${BACK_PATH:+mkdir -p "${BACK_PATH}"}
${DUMP_PATH:+mkdir -p "${DUMP_PATH}"}
REMOTE_MKDIR
    info "Standby 디렉토리 생성 완료"

    # ── Primary 엔진 영역 → Standby scp 복사 ────────────────
    info "Primary 엔진 영역을 Standby 로 복사 중: ${ENGINE_BASE} → ${HA_STANDBY_HOST}:${ENGINE_BASE}"
    info "  (파일 크기에 따라 수 분 소요될 수 있습니다... 로그 → ${HA_LOG})"
    scp ${SCP_OPTS} -r "${ENGINE_BASE}" "${HA_STANDBY_HOST}:$(dirname "${ENGINE_BASE}")/" \
        >> "${HA_LOG}" 2>&1 \
        && info "엔진 영역 복사 완료" \
        || error "엔진 영역 scp 복사 실패. 로그: ${HA_LOG}"

    # ── Standby .postgresrc 전송 ─────────────────────────────
    info "Standby .postgresrc 설정 중..."
    scp ${SCP_OPTS} "${HOME_DIR}/.postgresrc" \
        "${HA_STANDBY_HOST}:${HOME_DIR}/.postgresrc" \
        >> "${HA_LOG}" 2>&1

    # ── Standby .bashrc 업데이트 ─────────────────────────────
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
        "grep -q '.postgresrc' ~/.bashrc 2>/dev/null \
         || printf '\n# PostgreSQL Environment\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bashrc" \
        >> "${HA_LOG}" 2>&1
    info ".bashrc 업데이트 완료"

    # ── Standby DATA 영역 초기화 (pg_basebackup 전) ──────────
    info "Standby DATA 영역 초기화: ${DATA_PATH}"
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
        "rm -rf ${DATA_PATH:?}/* ${DATA_PATH:?}/.[!.]* 2>/dev/null || true" \
        >> "${HA_LOG}" 2>&1

    # ── Primary → Standby pg_basebackup ─────────────────────
    info "pg_basebackup 실행 중 (Primary → Standby 데이터 복제)..."
    info "  Primary : ${HA_PRIMARY_HOST}:${PG_PORT}  /  복제유저 : ${_REPL_TARGET_USER}"
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
        "${ENGINE_PATH}/bin/pg_basebackup \
            -h ${HA_PRIMARY_HOST} \
            -p ${PG_PORT} \
            -U ${_REPL_TARGET_USER} \
            -D ${DATA_PATH} \
            -Fp -Xs -P -R" \
        >> "${HA_LOG}" 2>&1 \
        && info "pg_basebackup 완료" \
        || error "pg_basebackup 실패. 로그: ${HA_LOG}"

    # ── DATA 디렉토리 권한 수정 (0700 필수) ──────────────────
    info "Standby DATA 디렉토리 권한 설정 중 (chmod 700)..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
        "chmod 700 ${DATA_PATH}" \
        >> "${HA_LOG}" 2>&1
    info "권한 설정 완료"

    # ── standby.signal 생성 확인 (-R 로 자동 생성되나 보험) ──
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
        "touch ${DATA_PATH}/standby.signal" \
        >> "${HA_LOG}" 2>&1
    info "standby.signal 확인 완료"

    # ── Standby postgresql.conf 에 primary_conninfo 추가 ─────
    info "Standby postgresql.conf 에 primary_conninfo 추가 중..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<REMOTE_CONF
grep -q "primary_conninfo" "${DATA_PATH}/postgresql.conf" \
    && sed -i "/primary_conninfo/d" "${DATA_PATH}/postgresql.conf"

cat >> "${DATA_PATH}/postgresql.conf" <<EOF

# ── Standby Recovery 설정 ──────────────────────────────────
# connection info
primary_conninfo = 'host=${HA_PRIMARY_HOST} port=${PG_PORT} user=${_REPL_TARGET_USER} password=${_REPL_TARGET_PASS} application_name=${HA_STANDBY_HOST}_standby'
EOF
REMOTE_CONF
    info "primary_conninfo 추가 완료"

    # ── Standby PostgreSQL 기동 ──────────────────────────────
    info "Standby PostgreSQL 기동 중..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
        "${ENGINE_PATH}/bin/pg_ctl -D ${DATA_PATH} -l ${LOG_PATH}/startup.log start" \
        >> "${HA_LOG}" 2>&1 \
        && info "Standby PostgreSQL 기동 완료" \
        || error "Standby PostgreSQL 기동 실패. 로그: ${LOG_PATH}/startup.log"
    sleep 5

    # ── 복제 상태 확인 (Primary에서) ────────────────────────
    info "복제 상태 확인 중 (Primary pg_stat_replication)..."
    "${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres \
        -c "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn, sync_state FROM pg_stat_replication;" \
        || warn "pg_stat_replication 조회 실패. Standby 연결을 수동으로 확인하세요."

    info "============================================================"
    info "  HA Standby 구성 완료!"
    info "  Primary  : ${HA_PRIMARY_HOST}:${PG_PORT}"
    info "  Standby  : ${HA_STANDBY_HOST}:${PG_PORT}"
    info "  복제유저 : ${_REPL_TARGET_USER}"
    info "  HA 구성 로그 : ${HA_LOG}"
    info "============================================================"
fi

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
if [[ "${USE_HA,,}" =~ ^(y|yes)$ ]]; then
echo ""
echo "  [HA 구성]"
echo "  Primary  : ${HA_PRIMARY_HOST}:${PG_PORT}"
echo "  Standby  : ${HA_STANDBY_HOST}:${PG_PORT}"
echo "  복제유저 : ${_REPL_TARGET_USER}"
fi
echo ""
echo "  PostgreSQL 시작 명령어:"
echo "  \$ pg_ctl -D ${DATA_PATH} -l ${LOG_PATH}/startup.log start"
echo ""
echo "[DONE] 모든 작업이 완료되었습니다."

# ── pg_install.log 완료 시각 기록 ───────────────────────────
INSTALL_END=$(date '+%Y-%m-%d %H:%M:%S')
cat >> "${LOG_INSTALL}" <<EOF

[완료]
  Finished : ${INSTALL_END}
  상태     : SUCCESS
============================================================
EOF
