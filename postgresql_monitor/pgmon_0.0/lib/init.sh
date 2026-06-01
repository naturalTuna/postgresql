#!/usr/bin/env bash
# =============================================================
# lib/init.sh  – 최초 초기화 및 DB 등록 관리
# =============================================================
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

CONF_FILE="${PGMON_HOME}/conf/pgmon.conf"
CONF_LOCK="${PGMON_HOME}/conf/.pgmon.lock"

# ── conf 로드 ─────────────────────────────────────────────────
conf_load() {
    [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
}

# ── conf 저장 ─────────────────────────────────────────────────
conf_save() {
    mkdir -p "$(dirname "$CONF_FILE")"
    cat > "$CONF_FILE" <<EOF
# pgmon configuration — auto generated $(date '+%Y-%m-%d %H:%M:%S')

# ── 모니터링 저장소 DB (pgmon 자체 DB) ──────────────────────
REPO_HOST="${REPO_HOST}"
REPO_PORT="${REPO_PORT}"
REPO_DBNAME="${REPO_DBNAME}"
REPO_USER="${REPO_USER}"
REPO_PASS="${REPO_PASS}"

# ── 등록된 대상 DB 수 ────────────────────────────────────────
TARGET_COUNT="${TARGET_COUNT:-0}"
EOF

    for i in $(seq 1 "${TARGET_COUNT:-0}"); do
        cat >> "$CONF_FILE" <<EOF

# ── 대상 DB #${i} ──────────────────────────────────────────
TARGET_${i}_NICKNAME="${!("TARGET_${i}_NICKNAME")}"
TARGET_${i}_HOST="${!("TARGET_${i}_HOST")}"
TARGET_${i}_PORT="${!("TARGET_${i}_PORT")}"
TARGET_${i}_DBNAME="${!("TARGET_${i}_DBNAME")}"
TARGET_${i}_USER="${!("TARGET_${i}_USER")}"
TARGET_${i}_PASS="${!("TARGET_${i}_PASS")}"
TARGET_${i}_RETENTION="${!("TARGET_${i}_RETENTION")}"
EOF
    done
    chmod 600 "$CONF_FILE"
}

# ── psql wrapper (repo DB) ────────────────────────────────────
repo_psql() {
    PGPASSWORD="$REPO_PASS" psql \
        -h "$REPO_HOST" -p "$REPO_PORT" \
        -U "$REPO_USER" -d "$REPO_DBNAME" \
        -v ON_ERROR_STOP=1 \
        "$@"
}

# ── psql wrapper (대상 DB) ─────────────────────────────────────
target_psql() {
    local idx=$1; shift
    local host port dbname user pass
    host="${!("TARGET_${idx}_HOST")}"
    port="${!("TARGET_${idx}_PORT")}"
    dbname="${!("TARGET_${idx}_DBNAME")}"
    user="${!("TARGET_${idx}_USER")}"
    pass="${!("TARGET_${idx}_PASS")}"
    PGPASSWORD="$pass" psql \
        -h "$host" -p "$port" \
        -U "$user" -d "$dbname" \
        -v ON_ERROR_STOP=1 \
        "$@"
}

# ── 연결 테스트 ───────────────────────────────────────────────
test_connection() {
    local host=$1 port=$2 dbname=$3 user=$4 pass=$5
    PGPASSWORD="$pass" psql \
        -h "$host" -p "$port" -U "$user" -d "$dbname" \
        -c "SELECT 1" -q --no-align -t 2>&1 | grep -q '^1$'
}

# ── 모니터링 repo DB 초기화 ───────────────────────────────────
init_repo_db() {
    ui_section "모니터링 저장소 DB 초기화"
    printf "\n"

    # role/db/schema 생성
    # postgres superuser로 init.sql 실행
    local pg_super="${1:-postgres}"
    local pg_pass="${2:-}"

    printf "  ${C_DIM}init.sql 실행 중...${C_RESET}\n"
    if PGPASSWORD="$pg_pass" psql \
        -h "$REPO_HOST" -p "$REPO_PORT" \
        -U "$pg_super" -d postgres \
        -f "${PGMON_HOME}/sql/init.sql" \
        -v ON_ERROR_STOP=1 -q 2>&1; then
        printf "  ${C_BGREEN}✔ 저장소 DB 초기화 완료${C_RESET}\n"
        return 0
    else
        printf "  ${C_BRED}✘ 초기화 실패 — SQL 오류 확인 필요${C_RESET}\n"
        return 1
    fi
}

# ── extension 설치 (대상 DB) ──────────────────────────────────
install_extensions() {
    local idx=$1
    local nickname="${!("TARGET_${idx}_NICKNAME")}"
    printf "\n  ${C_BCYAN}[%s]${C_RESET} extension 설치 확인...\n" "$nickname"

    local exts=("pg_stat_statements" "pg_buffercache" "pgstattuple")
    for ext in "${exts[@]}"; do
        local result
        result=$(target_psql "$idx" -Atc \
            "SELECT COUNT(*) FROM pg_extension WHERE extname='${ext}'" 2>/dev/null)
        if [[ "$result" == "1" ]]; then
            printf "    ${C_DIM}%-22s already installed${C_RESET}\n" "$ext"
        else
            if target_psql "$idx" -c "CREATE EXTENSION IF NOT EXISTS ${ext}" -q 2>/dev/null; then
                printf "    ${C_BGREEN}✔ %-22s installed${C_RESET}\n" "$ext"
            else
                printf "    ${C_BYELLOW}⚠ %-22s 설치 실패 (권한 부족 가능성)${C_RESET}\n" "$ext"
            fi
        fi
    done

    # pg_stat_statements 설정 안내
    local pss
    pss=$(target_psql "$idx" -Atc \
        "SELECT COUNT(*) FROM pg_extension WHERE extname='pg_stat_statements'" 2>/dev/null)
    if [[ "$pss" == "1" ]]; then
        local preload
        preload=$(target_psql "$idx" -Atc \
            "SHOW shared_preload_libraries" 2>/dev/null)
        if [[ "$preload" != *"pg_stat_statements"* ]]; then
            printf "\n  ${C_BYELLOW}⚠ pg_stat_statements 가 shared_preload_libraries 에 없습니다.${C_RESET}\n"
            printf "    postgresql.conf 에 아래 설정 추가 후 재시작 필요:\n"
            printf "    ${C_DIM}shared_preload_libraries = 'pg_stat_statements'${C_RESET}\n"
        fi
    fi
}

# ── DB 등록 입력 ──────────────────────────────────────────────
input_target_db() {
    local idx=$1
    local prefix="TARGET_${idx}"

    ui_section "대상 DB #${idx} 등록"
    printf "\n"

    local nick host port dbname user pass retention ans

    ui_prompt "닉네임 (영문, 공백없이)" nick ""
    [[ "$nick" == "__ESC__" ]] && return 1
    eval "${prefix}_NICKNAME='${nick}'"

    ui_prompt "호스트 / IP" host "127.0.0.1"
    [[ "$host" == "__ESC__" ]] && return 1
    eval "${prefix}_HOST='${host}'"

    ui_prompt "포트" port "5432"
    [[ "$port" == "__ESC__" ]] && return 1
    eval "${prefix}_PORT='${port}'"

    ui_prompt "DB명" dbname "postgres"
    [[ "$dbname" == "__ESC__" ]] && return 1
    eval "${prefix}_DBNAME='${dbname}'"

    ui_prompt "접속 유저" user "postgres"
    [[ "$user" == "__ESC__" ]] && return 1
    eval "${prefix}_USER='${user}'"

    printf "  ${C_BCYAN}패스워드${C_RESET}: "
    read -rs pass; printf "\n"
    eval "${prefix}_PASS='${pass}'"

    ui_prompt "데이터 보관 주기 (일)" retention "15"
    [[ "$retention" == "__ESC__" ]] && return 1
    eval "${prefix}_RETENTION='${retention}'"

    # 연결 테스트
    printf "\n  ${C_DIM}연결 테스트 중...${C_RESET}"
    if test_connection "${!("TARGET_${idx}_HOST")}" \
                       "${!("TARGET_${idx}_PORT")}" \
                       "${!("TARGET_${idx}_DBNAME")}" \
                       "${!("TARGET_${idx}_USER")}" \
                       "${!("TARGET_${idx}_PASS")}"; then
        printf "\r  ${C_BGREEN}✔ 연결 성공${C_RESET}                    \n"
        return 0
    else
        printf "\r  ${C_BRED}✘ 연결 실패 — 정보를 확인하세요${C_RESET}\n"
        if ui_confirm "다시 입력하시겠습니까?"; then
            input_target_db "$idx"
        fi
        return 1
    fi
}

# ── 최초 실행 (conf 없음) ────────────────────────────────────
init_first_run() {
    ui_header "pgmon — 최초 설정" "모니터링 환경을 구성합니다"

    ui_section "1. 모니터링 저장소 DB 정보"
    printf "  ${C_DIM}(이 서버에 설치된 PostgreSQL 정보를 입력하세요)${C_RESET}\n\n"

    ui_prompt "저장소 DB 호스트" REPO_HOST "127.0.0.1"
    [[ "$REPO_HOST" == "__ESC__" ]] && return 1
    ui_prompt "저장소 DB 포트"  REPO_PORT "5432"
    ui_prompt "저장소 DB명"     REPO_DBNAME "pgmon"
    ui_prompt "저장소 DB 유저"  REPO_USER "pgmon_writer"
    printf "  ${C_BCYAN}저장소 DB 패스워드${C_RESET}: "
    read -rs REPO_PASS; printf "\n"

    # init.sql 실행을 위해 superuser 정보 요청
    printf "\n  ${C_DIM}초기화를 위해 superuser 정보가 필요합니다 (일회성)${C_RESET}\n\n"
    local pg_super pg_pass
    ui_prompt "Superuser 유저명" pg_super "postgres"
    printf "  ${C_BCYAN}Superuser 패스워드${C_RESET}: "
    read -rs pg_pass; printf "\n"

    printf "\n"
    if ! init_repo_db "$pg_super" "$pg_pass"; then
        printf "\n  ${C_BRED}저장소 DB 초기화에 실패했습니다. 종료합니다.${C_RESET}\n"
        exit 1
    fi

    ui_section "2. 모니터링 대상 DB 등록"
    printf "\n"
    ui_prompt "등록할 DB 수" TARGET_COUNT "1"

    for i in $(seq 1 "$TARGET_COUNT"); do
        printf "\n"
        input_target_db "$i" || true
    done

    conf_save
    printf "\n  ${C_BGREEN}✔ 설정 저장 완료 → %s${C_RESET}\n" "$CONF_FILE"
    sleep 1

    # extension 설치
    for i in $(seq 1 "$TARGET_COUNT"); do
        install_extensions "$i"
    done

    # repo DB에 대상 DB 정보 INSERT
    _sync_targets_to_repo

    printf "\n  ${C_BGREEN}✔ 초기화 완료 — 모니터링을 시작합니다${C_RESET}\n\n"
    sleep 1
}

# ── conf → repo DB 동기화 ────────────────────────────────────
_sync_targets_to_repo() {
    for i in $(seq 1 "${TARGET_COUNT:-0}"); do
        local nick host port dbname user pass retention
        nick="${!("TARGET_${i}_NICKNAME")}"
        host="${!("TARGET_${i}_HOST")}"
        port="${!("TARGET_${i}_PORT")}"
        dbname="${!("TARGET_${i}_DBNAME")}"
        user="${!("TARGET_${i}_USER")}"
        pass="${!("TARGET_${i}_PASS")}"
        retention="${!("TARGET_${i}_RETENTION"):-15}"

        repo_psql -q -c "
INSERT INTO pgmon.registered_db
    (nickname, host, port, dbname, username, password, retention_days)
VALUES
    ('${nick}', '${host}', ${port}, '${dbname}', '${user}', '${pass}', ${retention})
ON CONFLICT (nickname) DO UPDATE SET
    host=EXCLUDED.host, port=EXCLUDED.port, dbname=EXCLUDED.dbname,
    username=EXCLUDED.username, password=EXCLUDED.password,
    retention_days=EXCLUDED.retention_days, updated_at=now();

-- 기본 수집 설정 삽입
INSERT INTO pgmon.collection_config (db_id, metric_name, interval_sec)
SELECT db_id, m.metric, m.secs
FROM pgmon.registered_db,
     (VALUES
        ('dashboard', 30),
        ('session',   15),
        ('statement', 60),
        ('vacuum',    120),
        ('object',    300),
        ('lock',      15)
     ) AS m(metric, secs)
WHERE nickname = '${nick}'
ON CONFLICT (db_id, metric_name) DO NOTHING;
" 2>/dev/null
    done
}

# ── DB 수정 메뉴 ─────────────────────────────────────────────
init_modify_menu() {
    while true; do
        ui_header "pgmon — DB 관리" "등록된 DB를 관리합니다"
        ui_section "등록된 DB 목록"
        printf "\n"

        for i in $(seq 1 "${TARGET_COUNT:-0}"); do
            local nick host port
            nick="${!("TARGET_${i}_NICKNAME")}"
            host="${!("TARGET_${i}_HOST")}"
            port="${!("TARGET_${i}_PORT"):-5432}"
            printf "  ${C_BYELLOW}%2d)${C_RESET}  ${C_BWHITE}%-20s${C_RESET} %s:%s\n" \
                "$i" "$nick" "$host" "$port"
        done

        printf "\n"
        local menu_items=(
            "a) 신규 DB 추가"
            "e) 기존 DB 정보 수정"
            "d) DB 삭제"
            "q) 뒤로 (DB 선택 화면)"
        )
        ui_menu menu_items

        local sel
        ui_prompt "선택" sel ""
        case "${sel,,}" in
            a)
                TARGET_COUNT=$(( ${TARGET_COUNT:-0} + 1 ))
                input_target_db "$TARGET_COUNT" && {
                    conf_save
                    install_extensions "$TARGET_COUNT"
                    _sync_targets_to_repo
                }
                ;;
            e)
                ui_prompt "수정할 번호" sel ""
                [[ "$sel" =~ ^[0-9]+$ ]] && \
                    input_target_db "$sel" && {
                        conf_save
                        _sync_targets_to_repo
                    }
                ;;
            d)
                ui_prompt "삭제할 번호" sel ""
                if [[ "$sel" =~ ^[0-9]+$ && $sel -le ${TARGET_COUNT:-0} ]]; then
                    local nick="${!("TARGET_${sel}_NICKNAME")}"
                    if ui_confirm "[$nick] 을 삭제하시겠습니까?"; then
                        repo_psql -q -c \
                            "UPDATE pgmon.registered_db SET active=false WHERE nickname='${nick}'" 2>/dev/null
                        # conf 에서 해당 항목 제거 후 재번호 부여
                        _remove_target_from_conf "$sel"
                        conf_save
                    fi
                fi
                ;;
            q|"__ESC__") return ;;
        esac
    done
}

# ── conf에서 대상 DB 제거 및 재번호 ──────────────────────────
_remove_target_from_conf() {
    local rm_idx=$1
    local new_count=$(( TARGET_COUNT - 1 ))
    local j=1
    for i in $(seq 1 "$TARGET_COUNT"); do
        [[ $i -eq $rm_idx ]] && continue
        for key in NICKNAME HOST PORT DBNAME USER PASS RETENTION; do
            local src="TARGET_${i}_${key}"
            local dst="TARGET_${j}_${key}"
            eval "$dst='${!src}'"
        done
        (( j++ ))
    done
    TARGET_COUNT=$new_count
}

# ── DB 선택 화면 ─────────────────────────────────────────────
#  반환: 선택된 인덱스를 SELECTED_TARGET_IDX 에 설정
select_target_db() {
    while true; do
        ui_header "pgmon — DB 선택" "모니터링할 DB를 선택하세요"

        for i in $(seq 1 "${TARGET_COUNT:-0}"); do
            local nick host port
            nick="${!("TARGET_${i}_NICKNAME")}"
            host="${!("TARGET_${i}_HOST")}"
            port="${!("TARGET_${i}_PORT"):-5432}"
            # 연결 상태 간단 확인
            local status
            if test_connection "${!("TARGET_${i}_HOST")}" "$port" \
                    "${!("TARGET_${i}_DBNAME")}" \
                    "${!("TARGET_${i}_USER")}" \
                    "${!("TARGET_${i}_PASS")}" 2>/dev/null; then
                status="${C_BGREEN}● 연결됨${C_RESET}"
            else
                status="${C_BRED}✘ 연결 불가${C_RESET}"
            fi
            printf "  ${C_BYELLOW}%2d)${C_RESET}  ${C_BWHITE}%-20s${C_RESET}  %-20s  %b\n" \
                "$i" "$nick" "${host}:${port}" "$status"
        done

        printf "\n"
        local menu_items=("m) DB 관리 (추가/수정/삭제)" "q) pgmon 종료")
        ui_menu menu_items

        local sel
        ui_prompt "번호 선택 (ESC=종료)" sel ""

        case "${sel,,}" in
            q|"__ESC__")
                printf "\n  ${C_DIM}pgmon을 종료합니다.${C_RESET}\n\n"
                exit 0
                ;;
            m) init_modify_menu ;;
            *)
                if [[ "$sel" =~ ^[0-9]+$ && $sel -ge 1 && $sel -le ${TARGET_COUNT:-0} ]]; then
                    SELECTED_TARGET_IDX=$sel
                    return 0
                fi
                ;;
        esac
    done
}

# ── 진입점 ────────────────────────────────────────────────────
init_run() {
    if [[ ! -f "$CONF_FILE" ]]; then
        init_first_run
    fi
    conf_load
}
