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
echo "  [주의] 이 스크립트는 tar 패키지가 설치되어 있어야 합니다."
echo "         tar 가 없을 경우 아래 명령어로 먼저 설치해 주세요."
echo ""
echo "         sudo dnf install -y tar"
echo ""
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

        echo "[INFO] 의존 패키지를 다운로드합니다..."
        sudo dnf install -y \
            --downloadonly \
            --downloaddir="${PKG_TMP}" \
            make gcc gcc-c++ \
            readline-devel zlib-devel openssl-devel \
            libxml2-devel libxslt-devel libicu-devel \
            libuuid-devel tcl tcl-devel \
            bison flex perl python3-devel

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
echo "======================================"
echo "  최종 디렉토리 구조"
echo "======================================"
find "${WORK_DIR}" -maxdepth 1 | sort | sed 's|[^/]*/|  |g'
echo ""
echo "[DONE] 모든 작업이 완료되었습니다."
