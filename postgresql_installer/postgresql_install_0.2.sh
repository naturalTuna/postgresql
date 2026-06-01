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

# 7. Log 경로 (data 하위 고정)
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

# 9. Backup 여부
read -rp "Backup 영역을 사용하시겠습니까? [Y/n]: " USE_BACKUP
USE_BACKUP="${USE_BACKUP:-Y}"
BACK_BASE=""
BACK_PATH=""
DUMP_PATH=""
if [[ "${USE_BACKUP,,}" =~ ^(y|yes)$ ]]; then
    read -rp "Backup 상위 경로를 입력하세요 [/pgbackup]: " BACK_BASE
    BACK_BASE="${BACK_BASE:-/pgbackup}"
    BACK_PATH="${BACK_BASE}/back"
    DUMP_PATH="${BACK_BASE}/pg_dump"
    echo "  Backup 경로 : ${BACK_PATH}"
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
echo "────────────────────────────────────────────"
echo ""

case "${DO_INSTALL,,}" in
    n|no)
        info "설치를 건너뜁니다."
        exit 0
        ;;
esac

# ============================================================
#  STEP 2. 디렉토리 존재 확인 및 하위 디렉토리 생성
# ============================================================
info "디렉토리를 확인합니다..."

# 상위 경로는 이미 postgres 유저 권한으로 생성되어 있어야 함
[[ ! -d "${ENGINE_BASE}" ]] && error "엔진 상위 경로가 존재하지 않습니다: ${ENGINE_BASE}"
[[ ! -d "${DATA_BASE}"   ]] && error "Data 상위 경로가 존재하지 않습니다: ${DATA_BASE}"
[[ -n "${ARC_BASE}"  && ! -d "${ARC_BASE}"  ]] && error "Archive 상위 경로가 존재하지 않습니다: ${ARC_BASE}"
[[ -n "${BACK_BASE}" && ! -d "${BACK_BASE}" ]] && error "Backup 상위 경로가 존재하지 않습니다: ${BACK_BASE}"

# 하위 디렉토리 생성 (postgres 유저로 실행 중이므로 sudo 불필요)
mkdir -p "${ENGINE_PATH}"
mkdir -p "${DATA_PATH}"
mkdir -p "${LOG_PATH}"

[[ -n "${ARC_PATH}"  ]] && mkdir -p "${ARC_PATH}"
[[ -n "${BACK_PATH}" ]] && mkdir -p "${BACK_PATH}"
[[ -n "${DUMP_PATH}" ]] && mkdir -p "${DUMP_PATH}"

info "디렉토리 확인 및 생성 완료"

# ============================================================
#  STEP 3. 소스 압축 해제 및 빌드
# ============================================================

# postgresql-*.tar.gz 자동 탐색
PG_TARBALL=$(ls postgresql/postgresql-*.tar.gz 2>/dev/null | head -1)
if [[ -z "$PG_TARBALL" ]]; then
    PG_TARBALL=$(ls postgresql-*.tar.gz 2>/dev/null | head -1)
fi
[[ -z "$PG_TARBALL" ]] && error "postgresql-*.tar.gz 파일을 찾을 수 없습니다."

PG_DIR="${PG_TARBALL%.tar.gz}"
PG_DIR="${PG_DIR##*/}"   # 경로 제거, 파일명만 추출

info "소스 압축 해제: ${PG_TARBALL}"
tar -zxvf "${PG_TARBALL}"

info "소스 디렉토리로 이동: ${PG_DIR}"
cd "${PG_DIR}"

# ── configure ────────────────────────────────────────────────
info "./configure 실행 중..."
./configure \
    --prefix="${ENGINE_PATH}" \
    --with-openssl \
    --with-libxml \
    --with-libxslt \
    --enable-nls \
    --with-python \
    --with-tcl \
    --with-perl

# ── make && make install ──────────────────────────────────────
info "make -j${CPU_CORES} 실행 중... (시간이 걸릴 수 있습니다)"
make -j"${CPU_CORES}"

info "make install 실행 중..."
make install

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
    echo "export PGALOG=${ARC_PATH}"      >> "${POSTGRESRC}"
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

# ── 환경변수 적용 ────────────────────────────────────────────
info "환경변수 적용 중..."
# shellcheck source=/dev/null
. "${POSTGRESRC}"
# shellcheck source=/dev/null
. "${BASHRC}"

# ============================================================
#  STEP 6. postgresql.conf 생성 (pgtune 방식 계산)
# ============================================================
info "postgresql.conf 계산 및 생성 중..."

# ── pgtune 계산 ───────────────────────────────────────────────
MEM_KB=$(( MEM_GB * 1024 * 1024 ))

# shared_buffers = 전체 메모리의 25%
SHR_BUF_KB=$(( MEM_KB / 4 ))
SHR_BUF="${SHR_BUF_KB}kB"

# effective_cache_size = 전체 메모리의 75%
EFF_CACHE_KB=$(( MEM_KB * 3 / 4 ))
EFF_CACHE="${EFF_CACHE_KB}kB"

# work_mem = (전체 메모리 / 4) / max_connections  (최소 4MB)
MAX_CONN=100
WORK_MEM_KB=$(( (MEM_KB / 4) / MAX_CONN ))
[[ "$WORK_MEM_KB" -lt 4096 ]] && WORK_MEM_KB=4096
WORK_MEM="${WORK_MEM_KB}kB"

# maintenance_work_mem = 전체 메모리의 5% (최소 64MB, 최대 2GB)
MAINT_MEM_KB=$(( MEM_KB / 20 ))
[[ "$MAINT_MEM_KB" -lt 65536  ]] && MAINT_MEM_KB=65536
[[ "$MAINT_MEM_KB" -gt 2097152 ]] && MAINT_MEM_KB=2097152
MAINT_MEM="${MAINT_MEM_KB}kB"

# wal_buffers = shared_buffers의 3% (최소 1MB, 최대 64MB)
WAL_BUF_KB=$(( SHR_BUF_KB * 3 / 100 ))
[[ "$WAL_BUF_KB" -lt 1024  ]] && WAL_BUF_KB=1024
[[ "$WAL_BUF_KB" -gt 65536 ]] && WAL_BUF_KB=65536
WAL_BUF="${WAL_BUF_KB}kB"

# checkpoint_completion_target
CKPT_TARGET="0.9"

# max_worker_processes = CPU core 수
MAX_WORKERS="${CPU_CORES}"

# max_parallel_workers_per_gather = CPU core / 2 (최소 1)
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
log_filename      = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age  = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000
log_line_prefix   = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints   = on
log_connections   = on
log_disconnections= on
log_lock_waits    = on

# ── 타임존 / 로케일 ────────────────────────────────────────
timezone          = 'Asia/Seoul'
lc_messages       = 'ko_KR.utf8'
lc_monetary       = 'ko_KR.utf8'
lc_numeric        = 'ko_KR.utf8'
lc_time           = 'ko_KR.utf8'
EOF

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

# ── postgresql.conf 덮어쓰기 (initdb 가 기본 conf 생성하므로) ──
info "postgresql.conf 를 생성된 설정으로 덮어씁니다..."
cp "${CONF_FILE}" "${DATA_PATH}/postgresql.conf"
rm -f "${CONF_FILE}"
info "postgresql.conf 적용 완료 → ${DATA_PATH}/postgresql.conf"

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
echo ""
echo "  PostgreSQL 시작 명령어:"
echo "  \$ pg_ctl -D ${DATA_PATH} -l ${LOG_PATH}/startup.log start"
echo ""
echo "[DONE] 모든 작업이 완료되었습니다."
