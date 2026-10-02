#!/bin/bash
# update-all.sh — atualização automática: pacman/yay + flatpak + docker
set -uo pipefail

RUN_DOCKER=${UPDATEALL_DOCKER:-0}
RUN_DOCKER_PRUNE=${UPDATEALL_DOCKER_PRUNE:-0}
RUN_DOCKER_REBUILD=${UPDATEALL_DOCKER_REBUILD:-0}
RUN_DOCKER_BUILDER_PRUNE=${UPDATEALL_DOCKER_BUILDER_PRUNE:-0}
RUN_HERMES_REINSTALL=${UPDATEALL_HERMES_REINSTALL:-0}
RUN_RKHUNTER_PROPUPD=${UPDATEALL_RKHUNTER_PROPUPD:-0}

usage() {
    cat <<'EOF'
Uso: updateAll [opções]

Padrão: atualização rápida e segura (Hermes git, mirrors, pacman/yay, Flatpak,
Calibre, auditoria rkhunter e verificações). Docker pesado é opt-in.

Opções:
  --quick         Modo rápido/seguro sem Docker pesado (equivale a desativar docker/rebuild/prune)
  --docker        Processa Docker Compose em execução (pull/up; sem rebuild por padrão)
  --docker-rebuild Rebuilda imagens locais junto com --docker (pesado)
  --docker-prune  Roda prune seguro de containers/imagens junto com --docker
  --docker-builder-prune  Inclui limpeza pesada do cache de build (opt-in)
  --full          Equivale a --docker --docker-rebuild --docker-prune --docker-builder-prune
  --hermes-reinstall  Reinstala o venv do Hermes mesmo sem mudança no git
  --rkhunter-propupd  Atualiza a baseline do rkhunter após revisão humana
  -h, --help      Mostra esta ajuda
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick) RUN_DOCKER=0; RUN_DOCKER_REBUILD=0; RUN_DOCKER_PRUNE=0 ;;
        --docker) RUN_DOCKER=1 ;;
        --docker-rebuild) RUN_DOCKER=1; RUN_DOCKER_REBUILD=1 ;;
        --docker-prune) RUN_DOCKER=1; RUN_DOCKER_PRUNE=1 ;;
        --docker-builder-prune) RUN_DOCKER=1; RUN_DOCKER_PRUNE=1; RUN_DOCKER_BUILDER_PRUNE=1 ;;
        --full) RUN_DOCKER=1; RUN_DOCKER_REBUILD=1; RUN_DOCKER_PRUNE=1; RUN_DOCKER_BUILDER_PRUNE=1 ;;
        --hermes-reinstall) RUN_HERMES_REINSTALL=1 ;;
        --rkhunter-propupd) RUN_RKHUNTER_PROPUPD=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Opção desconhecida: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

SUDO=""
SUDO_KEEPALIVE_PID=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

REAL_HOME="${REAL_HOME:-/home/pips}"
LOCK_DIR="$REAL_HOME/.cache/update-all"
LOCK_FILE="$LOCK_DIR/update-all.lock"
mkdir -p "$LOCK_DIR"
# Evita /tmp sticky + fs.protected_regular e mantém o lock utilizável tanto por systemd/root quanto pelo usuário.
if [[ $EUID -eq 0 && "$REAL_HOME" == "/home/pips" ]]; then
    chown pips:pips "$LOCK_DIR" 2>/dev/null || true
    [[ -e "$LOCK_FILE" ]] || install -o pips -g pips -m 664 /dev/null "$LOCK_FILE"
    chown pips:pips "$LOCK_FILE" 2>/dev/null || true
fi
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Já está rodando. Abortando."; exit 0; }

stop_sudo_keepalive() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi
}
trap stop_sudo_keepalive EXIT

start_sudo_session() {
    [[ $EUID -eq 0 ]] && return 0

    printf "🔐 Validando sudo do updateAll no começo; vou manter o cache até terminar...\n"
    if [[ -t 0 && -t 1 ]]; then
        sudo -v || { echo "Senha sudo não validada. Abortando."; exit 1; }
    else
        sudo -n -v 2>/dev/null || {
            echo "Sudo sem cache e sem TTY. Rode updateAll em um terminal interativo para digitar a senha no início."
            exit 1
        }
    fi

    ( while true; do sudo -n -v >/dev/null 2>&1 || exit; sleep 45; done ) &
    SUDO_KEEPALIVE_PID=$!
}

ensure_sudo_cmd() {
    # O updateAll valida sudo uma vez no começo e mantém o ticket vivo.
    # Esta função existe para preservar os call sites antigos sem executar comandos como "prova".
    [[ $EUID -eq 0 ]] && return 0
    sudo -n -v >/dev/null 2>&1
}

start_sudo_session

# Antes das atualizações, remove somente shells/tmux/Hermes com evidência objetiva
# de abandono. O script usa o ticket sudo já validado e não pede nova senha.
"$REAL_HOME/bin/cleanup-unused-processes.sh" --root-mode ||
    printf "Aviso: limpeza conservadora de processos falhou; continuando updateAll.\n"

LOG_DIR="$REAL_HOME/logs/update-all"
LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"
BREAKING_FILE="$LOG_DIR/breaking-changes.txt"
YAY_LOG="/tmp/yay-run-$$.log"
DOCKER_DIR="$REAL_HOME/Developer/docker"
AUR_NOTICES=""

mkdir -p "$LOG_DIR"

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[1;34m' C='\033[0;36m' W='\033[1;37m' N='\033[0m'

log() {
    local plain="[$(date +%H:%M:%S)] $*"
    echo "$plain" >> "$LOG_FILE"
    printf "${C}[$(date +%H:%M:%S)]${N} %s\n" "$*"
}

run_streamed() {
    local tmp="$1"
    shift
    : > "$tmp"
    "$@" 2>&1 | tee -a "$LOG_FILE" | tee -a "$tmp"
    local rc=${PIPESTATUS[0]}
    return "$rc"
}

run_logged() {
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}
    return "$rc"
}

run_timed_logged() {
    local label="$1" start rc elapsed
    shift
    start=$(date +%s)
    log "→ $label"
    run_logged "$@"
    rc=$?
    elapsed=$(( $(date +%s) - start ))
    if [[ $rc -eq 0 ]]; then
        log "✓ $label concluído em ${elapsed}s"
    else
        log "⚠ $label falhou (rc=$rc) após ${elapsed}s"
    fi
    return "$rc"
}

run_in_dir_logged() {
    local dir="$1"
    shift
    (cd "$dir" && "$@") 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}
    return "$rc"
}

run_yay() {
    # updateAll é uma manutenção unattended: testes de AUR longos/flaky (ex.: lib32-gstreamer)
    # podem estourar o timeout sem indicar pacote quebrado. Pula check() e deixa a instalação
    # ser validada pelas verificações pós-update.
    local cmd=(yay -Syu --noconfirm --answerdiff=None --answerclean=None --answerupgrade=None --removemake --mflags "--nocheck" --ignore jack2,lib32-jack2)
    local rc attempts max_attempts backoff
    attempts=1
    max_attempts=3
    backoff=5
    : > "$YAY_LOG"
    while (( attempts <= max_attempts )); do
        log "→ yay -Syu iniciado (tentativa $attempts/$max_attempts; saída ao vivo)"
        if [[ $EUID -eq 0 ]]; then
            run_streamed "$YAY_LOG" runuser -u pips -- timeout 1800 "${cmd[@]}"
        else
            run_streamed "$YAY_LOG" timeout 1800 "${cmd[@]}"
        fi
        rc=$?
        if [[ $rc -eq 0 ]]; then
            return 0
        fi
        if grep -qE 'unexpected EOF|request failed: Get "https://aur\.archlinux\.org/rpc|dial tcp|TLS handshake timeout|i/o timeout|connection reset by peer|temporary failure in name resolution' "$YAY_LOG"; then
            log "⚠ yay/AUR falhou por rede transitória (tentativa $attempts/$max_attempts)"
            if (( attempts < max_attempts )); then
                sleep "$backoff"
                attempts=$((attempts + 1))
                backoff=$((backoff * 2))
                continue
            fi
        fi
        return "$rc"
    done
    return "$rc"
}

run_pacman() {
    local cmd=(pacman -Syu --noconfirm)
    local rc attempts max_attempts backoff
    attempts=1
    max_attempts=3
    backoff=5
    : > "$YAY_LOG"
    while (( attempts <= max_attempts )); do
        log "→ pacman -Syu iniciado (tentativa $attempts/$max_attempts; saída ao vivo)"
        if [[ -n "$SUDO" ]]; then
            run_streamed "$YAY_LOG" timeout 1800 sudo pacman -Syu --noconfirm
        else
            run_streamed "$YAY_LOG" timeout 1800 pacman -Syu --noconfirm
        fi
        rc=$?
        if [[ $rc -eq 0 ]]; then
            return 0
        fi
        if grep -qE 'failed retrieving file|erro: falha ao sincronizar|error: failed to synchronize|download library error|SSL connection timeout|Connection timed out|connection reset by peer|temporary failure in name resolution' "$YAY_LOG"; then
            log "⚠ pacman falhou por rede transitória (tentativa $attempts/$max_attempts)"
            if (( attempts < max_attempts )); then
                sleep "$backoff"
                attempts=$((attempts + 1))
                backoff=$((backoff * 2))
                : > "$YAY_LOG"
                continue
            fi
        fi
        return "$rc"
    done
    return "$rc"
}

fix_pacman_lock() {
    [[ -f /var/lib/pacman/db.lck ]] || return
    log "→ Lock do pacman detectado. Removendo..."
    $SUDO rm -f /var/lib/pacman/db.lck
}

fix_gpg() {
    log "→ Atualizando chaves GPG..."
    $SUDO pacman-key --refresh-keys >> "$LOG_FILE" 2>&1
}

fix_file_conflicts() {
    local packages
    packages=$(grep -oP '^\S+(?=: /\S+ existe no sistema de arquivos)' "$YAY_LOG" | sort -u | tr '\n' ' ')
    [[ -z "$packages" ]] && return 1
    local files
    files=$(grep -oP '(?<=: )\S+(?= existe no sistema de arquivos)' "$YAY_LOG" | tr '\n' ',' | sed 's/,$//')
    log "→ Conflitos: $packages — sobrescrevendo..."
    $SUDO pacman -S $packages --overwrite "$files" --noconfirm >> "$LOG_FILE" 2>&1
}

analyze_and_fix() {
    local fixed=0
    if grep -qE "Invalid operation|ConditionNeedsUpdate|Enqueuing marked" "$YAY_LOG"; then
        $SUDO systemctl daemon-reload; fixed=1
    fi
    if grep -q "db.lck" "$YAY_LOG"; then
        fix_pacman_lock; fixed=1
    fi
    if grep -qE "invalid or corrupted package|signature from|unknown trust|marginal trust" "$YAY_LOG"; then
        fix_gpg; fixed=1
    fi
    if grep -q "existe no sistema de arquivos" "$YAY_LOG"; then
        fix_file_conflicts; fixed=1
    fi
    if grep -qE "has been removed|renamed to|manual intervention|must be installed before|break dependency" "$YAY_LOG"; then
        log "⚠ BREAKING CHANGE — requer atenção manual"
        { echo "[$(date)]"; grep -E "has been removed|renamed to|manual intervention" "$YAY_LOG"; echo "---"; } >> "$BREAKING_FILE"
    fi
    > "$YAY_LOG"
    return $((1 - fixed))
}

update_mirrors() {
    printf "\n${B}━━━ ${W}Reflector — mirrors${B} ━━━${N}\n"
    log "--- Reflector mirrors ---"
    if ! command -v reflector >/dev/null 2>&1; then
        printf "  ${Y}⚠${N}  reflector não instalado — pulado\n"
        log "⚠ reflector não instalado"
        return 0
    fi

    local mirror_tmp
    mirror_tmp=$(mktemp /tmp/mirrorlist.update-all.XXXXXX)
    if timeout 180 reflector --country Brazil,Argentina --protocol https --latest 20 --sort rate --download-timeout 15 --save "$mirror_tmp" >> "$LOG_FILE" 2>&1 && [[ -s "$mirror_tmp" ]]; then
        if $SUDO install -m 644 "$mirror_tmp" /etc/pacman.d/mirrorlist >> "$LOG_FILE" 2>&1; then
            printf "  ${G}✔${N}  Mirrorlist atualizada via reflector\n"
            log "✓ Mirrorlist atualizada via reflector"
        else
            printf "  ${Y}⚠${N}  reflector gerou lista, mas não consegui instalar em /etc/pacman.d/mirrorlist\n"
            log "⚠ falha ao instalar mirrorlist gerada pelo reflector"
        fi
    else
        printf "  ${Y}⚠${N}  reflector falhou — mantendo mirrorlist atual\n"
        log "⚠ reflector falhou; mantendo mirrorlist atual"
    fi
    rm -f "$mirror_tmp"
}

audit_rkhunter() {
    local rk_tmp rk_clean rc mode
    printf "\n${B}━━━ ${W}rkhunter — auditoria${B} ━━━${N}\n"

    if ! command -v rkhunter >/dev/null 2>&1; then
        printf "  ${C}·${N}  rkhunter não instalado — pulado\n"
        log "rkhunter não instalado; auditoria pulada"
        return 0
    fi

    rk_tmp=$(mktemp /tmp/rkhunter-check.XXXXXX)
    rk_clean=$(mktemp /tmp/rkhunter-check.clean.XXXXXX)
    if (( RUN_RKHUNTER_PROPUPD )); then
        mode="propupd explícito"
        log "--- rkhunter propupd (solicitado explicitamente) ---"
        if ensure_sudo_cmd && $SUDO rkhunter --propupd > "$rk_tmp" 2>&1; then rc=0; else rc=$?; fi
    else
        mode="check"
        log "--- rkhunter check (baseline preservada) ---"
        if ensure_sudo_cmd && $SUDO rkhunter --check --skip-keypress > "$rk_tmp" 2>&1; then rc=0; else rc=$?; fi
    fi

    python - "$rk_tmp" "$rk_clean" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text(errors='replace').splitlines()
out = []
for line in src:
    # rkhunter invokes grep/egrep with patterns that trigger localized
    # warnings on newer grep. These are tool-noise, not rkhunter findings.
    if line.startswith(('grep:', 'egrep:')) and ('perdida antes de' in line or 'warning: egrep is obsolescent' in line):
        continue
    if line == 'egrep: warning: egrep is obsolescent; using grep -E':
        continue
    out.append(line)
Path(sys.argv[2]).write_text("\n".join(out) + ("\n" if out else ""))
PY
    cat "$rk_clean" >> "$LOG_FILE"
    rm -f "$rk_tmp" "$rk_clean"

    if [[ $rc -eq 0 ]]; then
        printf "  ${G}✔${N}  rkhunter %s concluído\n" "$mode"
        log "✓ rkhunter $mode concluído"
    else
        printf "  ${Y}⚠${N}  rkhunter %s encontrou alertas/falhou; veja o log\n" "$mode"
        log "⚠ rkhunter $mode retornou código $rc; baseline preservada"
    fi
}

cleanup_arch_caches() {
    printf "\n${B}━━━ ${W}Arch/Pacman/AUR — caches${B} ━━━${N}\n"
    log "--- Arch/Pacman/AUR cache cleanup ---"

    local before after yay_before yay_after
    before=$(du -sh /var/cache/pacman/pkg 2>/dev/null | awk '{print $1}' || true)
    yay_before=$(du -sh "$REAL_HOME/.cache/yay" 2>/dev/null | awk '{print $1}' || true)

    if command -v paccache >/dev/null 2>&1; then
        # Mantém 1 versão dos pacotes instalados e remove cache de pacotes não instalados.
        if ! ensure_sudo_cmd paccache -rk1; then
            log "⚠ sudo para paccache -rk1 indisponível; pulando"
        elif ! $SUDO paccache -rk1 >> "$LOG_FILE" 2>&1; then
            log "⚠ paccache -rk1 falhou"
        fi
        if ! ensure_sudo_cmd paccache -ruk0; then
            log "⚠ sudo para paccache -ruk0 indisponível; pulando"
        elif ! $SUDO paccache -ruk0 >> "$LOG_FILE" 2>&1; then
            log "⚠ paccache -ruk0 falhou"
        fi
    else
        log "⚠ paccache não instalado; pulando cache do pacman"
    fi

    # Limpeza conservadora do AUR/yay: apaga só artefatos de build antigos, não remove pacotes instalados.
    if [[ -d "$REAL_HOME/.cache/yay" ]]; then
        # Repara permissões estreitas/root-owned deixadas por builds interrompidos (ex.: pkg com modo 111),
        # senão o find gera "Permissão negada" e polui o log mesmo sem problema real de atualização.
        $SUDO chown -R pips:pips "$REAL_HOME/.cache/yay" >> "$LOG_FILE" 2>&1 || log "⚠ não consegui corrigir owner do cache yay"
        chmod -R u+rwX "$REAL_HOME/.cache/yay" >> "$LOG_FILE" 2>&1 || log "⚠ não consegui normalizar permissões de diretórios yay"
        find "$REAL_HOME/.cache/yay" -mindepth 2 -maxdepth 2 -type d \( -name pkg -o -name src \) -mtime +7 -prune -exec rm -rf {} + >> "$LOG_FILE" 2>&1 || log "⚠ limpeza de src/pkg do yay falhou"
        find "$REAL_HOME/.cache/yay" -type f \( -name '*.pkg.tar.*' -o -name '*.log' \) -mtime +14 -delete >> "$LOG_FILE" 2>&1 || log "⚠ limpeza de arquivos antigos do yay falhou"
    fi

    after=$(du -sh /var/cache/pacman/pkg 2>/dev/null | awk '{print $1}' || true)
    yay_after=$(du -sh "$REAL_HOME/.cache/yay" 2>/dev/null | awk '{print $1}' || true)
    printf "  ${G}✔${N}  Pacman cache: ${W}${before:-?}${N} → ${W}${after:-?}${N}\n"
    printf "  ${G}✔${N}  Yay/AUR cache: ${W}${yay_before:-0}${N} → ${W}${yay_after:-0}${N}\n"
    log "✓ caches limpos: pacman ${before:-?}->${after:-?}; yay ${yay_before:-0}->${yay_after:-0}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

printf "\n${W}╔══════════════════════════════════════════════╗${N}\n"
printf "${W}║  UPDATE-ALL — $(date '+%Y-%m-%d %H:%M:%S')  ║${N}\n"
printf "${W}╚══════════════════════════════════════════════╝${N}\n\n"
log "=== update-all iniciado ==="
SCRIPT_START_EPOCH=$(date +%s)
if (( RUN_DOCKER )); then
    log "Modo: Docker=${RUN_DOCKER} rebuild=${RUN_DOCKER_REBUILD} prune=${RUN_DOCKER_PRUNE} builder_prune=${RUN_DOCKER_BUILDER_PRUNE}"
else
    log "Modo: rápido (Docker pesado pulado; use --docker ou --full para atualizar stacks)"
fi
> "$YAY_LOG"

find "$LOG_DIR" -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}\.log' -mtime +30 -delete 2>/dev/null

update_hermes() {
    printf "\n${B}━━━ ${W}Hermes Agent${B} ━━━${N}\n"
    log "--- Hermes Agent update ---"

    local hermes_dir="$REAL_HOME/.hermes/hermes-agent"
    local hermes_py="$hermes_dir/venv/bin/python"
    local hermes_bin="$hermes_dir/venv/bin/hermes"

    if [[ ! -d "$hermes_dir/.git" ]]; then
        printf "  ${Y}⚠${N}  Hermes git checkout não encontrado em ${W}$hermes_dir${N} — pulado\n"
        log "⚠ Hermes checkout não encontrado; update pulado"
        return 0
    fi

    if [[ ! -x "$hermes_py" ]]; then
        printf "  ${Y}⚠${N}  Python do Hermes não encontrado em ${W}$hermes_py${N} — pulado\n"
        log "⚠ Hermes python não encontrado; update pulado"
        return 0
    fi

    local before after upstream status_file stash_label stash_ref stash_apply_target stash_created restore_ok
    before=$(git -C "$hermes_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    stash_created=0
    restore_ok=1

    if ! git -C "$hermes_dir" fetch origin main >> "$LOG_FILE" 2>&1; then
        printf "  ${Y}⚠${N}  Falha no fetch do Hermes — mantendo versão atual\n"
        log "⚠ fetch do Hermes falhou"
        return 0
    fi

    upstream=$(git -C "$hermes_dir" rev-parse --short origin/main 2>/dev/null || echo "unknown")
    status_file=$(git -C "$hermes_dir" status --porcelain 2>/dev/null || true)
    if [[ -n "$status_file" ]]; then
        stash_label="hermes-update-autostash-$(date +%Y%m%d-%H%M%S)"
        if git -C "$hermes_dir" stash push --include-untracked -m "$stash_label" >> "$LOG_FILE" 2>&1; then
            stash_ref=$(git -C "$hermes_dir" stash list --format='%gd %gs' | awk -v label="$stash_label" '$0 ~ label {print $1; exit}')
            stash_apply_target=$(git -C "$hermes_dir" stash list --format='%H %gs' | awk -v label="$stash_label" '$0 ~ label {print $1; exit}')
            stash_created=1
            printf "  ${C}·${N}  Hermes com mudanças locais; fazendo stash temporário para pull\n"
            log "Hermes com mudanças locais; stash temporário criado: ${stash_ref:-$stash_label}"
        else
            printf "  ${Y}⚠${N}  Não consegui fazer stash temporário do Hermes — mantendo checkout atual\n"
            log "⚠ falha ao criar stash temporário do Hermes"
            return 0
        fi
    fi

    # O fetch acima já trouxe origin/main; merge local evita uma segunda chamada remota.
    if git -C "$hermes_dir" merge --ff-only origin/main >> "$LOG_FILE" 2>&1; then
        if [[ "$before" != "$upstream" ]]; then
            log "✓ Hermes atualizado no git: $before -> $upstream"
        else
            log "Hermes já estava em dia no git ($before)"
        fi
    else
        printf "  ${Y}⚠${N}  fast-forward do Hermes falhou — mantendo checkout atual\n"
        log "⚠ fast-forward do Hermes falhou"
        if (( stash_created )); then
            if [[ -n "$stash_apply_target" ]] && git -C "$hermes_dir" stash apply "$stash_apply_target" >> "$LOG_FILE" 2>&1; then
                [[ -n "$stash_ref" ]] && git -C "$hermes_dir" stash drop "$stash_ref" >> "$LOG_FILE" 2>&1 || true
                log "✓ stash local do Hermes reaplicado após falha no fast-forward"
            else
                log "⚠ não consegui reaplicar automaticamente o stash do Hermes após falha no fast-forward"
            fi
        fi
        return 0
    fi

    if (( stash_created )); then
        if [[ -n "$stash_apply_target" ]] && git -C "$hermes_dir" stash apply "$stash_apply_target" >> "$LOG_FILE" 2>&1; then
            [[ -n "$stash_ref" ]] && git -C "$hermes_dir" stash drop "$stash_ref" >> "$LOG_FILE" 2>&1 || true
            printf "  ${G}✔${N}  Hermes pull aplicado; mudanças locais reaplicadas por cima\n"
            log "✓ stash local do Hermes reaplicado por cima do pull"
        else
            printf "  ${Y}⚠${N}  Hermes fez pull, mas houve conflito ao reaplicar mudanças locais; stash preservado\n"
            log "⚠ pull do Hermes OK, mas reaplicação do stash falhou; stash preservado"
            restore_ok=0
        fi
    fi

    if [[ "$before" == "$upstream" && $RUN_HERMES_REINSTALL -eq 0 ]]; then
        if [[ -x "$hermes_bin" ]]; then
            local version_line
            version_line=$("$hermes_bin" --version | head -n 1)
            printf "  ${G}✔${N}  Hermes já em dia: ${W}${before}${N}\n"
            printf "  ${C}·${N}  ${version_line}\n"
            (( restore_ok )) && log "✓ Hermes já em dia; reinstall do venv pulado: $version_line"
        fi
        return 0
    fi

    if [[ "$before" == "$upstream" ]]; then
        log "Reinstall do Hermes forçado por --hermes-reinstall"
    fi

    if command -v uv >/dev/null 2>&1; then
        if ! (cd "$hermes_dir" && uv pip install --python "$hermes_py" -e '.[all,dev]') >> "$LOG_FILE" 2>&1; then
            printf "  ${Y}⚠${N}  uv pip install do Hermes falhou; tentando ensurepip + pip\n"
            log "⚠ uv pip install do Hermes falhou; fallback para pip"
            if ! "$hermes_py" -m ensurepip --upgrade >> "$LOG_FILE" 2>&1; then
                printf "  ${Y}⚠${N}  ensurepip do Hermes falhou — mantendo instalação atual\n"
                log "⚠ ensurepip do Hermes falhou"
                return 0
            fi
            if ! "$hermes_py" -m pip install -e "$hermes_dir[all,dev]" >> "$LOG_FILE" 2>&1; then
                printf "  ${Y}⚠${N}  pip install do Hermes falhou — veja o log\n"
                log "⚠ pip install do Hermes falhou"
                return 0
            fi
        fi
    else
        if ! "$hermes_py" -m ensurepip --upgrade >> "$LOG_FILE" 2>&1; then
            printf "  ${Y}⚠${N}  ensurepip do Hermes falhou — mantendo instalação atual\n"
            log "⚠ ensurepip do Hermes falhou"
            return 0
        fi
        if ! "$hermes_py" -m pip install -e "$hermes_dir[all,dev]" >> "$LOG_FILE" 2>&1; then
            printf "  ${Y}⚠${N}  pip install do Hermes falhou — veja o log\n"
            log "⚠ pip install do Hermes falhou"
            return 0
        fi
    fi

    after=$(git -C "$hermes_dir" rev-parse --short HEAD 2>/dev/null || echo "$upstream")
    if [[ -x "$hermes_bin" ]]; then
        local version_line
        version_line=$("$hermes_bin" --version | head -n 1)
        printf "  ${G}✔${N}  Hermes: ${W}${before}${N} → ${W}${after}${N}\n"
        printf "  ${C}·${N}  ${version_line}\n"
        printf "  ${C}·${N}  Sessões já abertas continuam rodando até você reiniciar cada processo\n"
        log "✓ Hermes pronto no disco/venv: $version_line"
    else
        printf "  ${G}✔${N}  Hermes atualizado: ${W}${before}${N} → ${W}${after}${N}\n"
        log "✓ Hermes atualizado, mas binário não encontrado para verificar versão"
    fi
}

fix_pacman_lock
update_hermes

update_mirrors

# ── Pacman/Yay ────────────────────────────────────────────────────────────────
MAX_ATTEMPTS=3
for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
    printf "${B}━━━ ${W}Pacman/Yay — tentativa $attempt/$MAX_ATTEMPTS${B} ━━━${N}\n"
    log "--- Pacman/Yay tentativa $attempt/$MAX_ATTEMPTS ---"

    run_pacman
    PACMAN_EXIT_CODE=$?
    if [[ $PACMAN_EXIT_CODE -ne 0 ]]; then
        if [[ $PACMAN_EXIT_CODE -eq 124 ]]; then
            log "✗ pacman timeout (30min). Continuando..."
            break
        fi
        log "✗ pacman código $PACMAN_EXIT_CODE"
        analyze_and_fix || break
        continue
    fi

    run_yay
    YAY_EXIT_CODE=$?
    # Preserva alertas acionáveis do AUR para o resumo, sem remover/alterar pacotes automaticamente.
    # Only package-maintenance notices belong in the final summary. A missing
    # source PGP signature is a PKGBUILD/repository metadata advisory already
    # validated by checksums, not an update failure; keep it in the full log.
    AUR_NOTICES=$(grep -E 'Pacotes AUR órfãos|AUR marcados como desatualizados' "$YAY_LOG" 2>/dev/null || true)

    if [[ $YAY_EXIT_CODE -eq 0 ]]; then
        printf "  ${G}✔${N}  Pacman -Syu + yay -Syu concluídos\n"
        log "✓ Pacman -Syu + yay -Syu concluídos"
        break
    elif [[ $YAY_EXIT_CODE -eq 124 ]]; then
        log "✗ yay timeout (15min). Continuando..."
        break
    fi

    log "✗ yay código $YAY_EXIT_CODE"
    analyze_and_fix || break
done
rm -f "$YAY_LOG"

# ── Integridade (só pacotes com 5+ arquivos faltando) ─────────────────────────
printf "\n${B}━━━ ${W}Integridade${B} ━━━${N}\n"
BROKEN_PKGS=$(LC_ALL=C $SUDO pacman -Qk 2>&1 | grep -E '[1-9][0-9]* missing files' | awk -F': ' '{n=$2; sub(/.*,\s*/,"",n); sub(/ missing files/,"",n); if(n+0>=5) print $1}' | sort -u)
if [[ -n "$BROKEN_PKGS" ]]; then
    BROKEN_COUNT=$(echo "$BROKEN_PKGS" | wc -l)
    printf "  ${Y}⚠${N}  ${Y}$BROKEN_COUNT${N} pacotes com 5+ arquivos faltando\n"
    log "⚠ $BROKEN_COUNT pacotes corrompidos"
    STILL_BROKEN=()
    for pkg in $BROKEN_PKGS; do
        if ! pacman -Si "$pkg" >/dev/null 2>&1; then
            printf "  ${Y}⚠${N}  Pacote fora dos repos, pulando reinstalação: ${W}$pkg${N}\n"
            log "⚠ pacote fora dos repos, pulando reinstalação: $pkg"
            STILL_BROKEN+=("$pkg")
            continue
        fi
        printf "  ${C}→${N}  Reinstalando: ${W}$pkg${N}\n"
        reinstall_out=$($SUDO pacman -S "$pkg" --noconfirm --overwrite '*' --needed 2>&1)
        reinstall_rc=$?
        printf "%s\n" "$reinstall_out" | tee -a "$LOG_FILE"
        if (( reinstall_rc != 0 )); then
            log "⚠ reinstalação de $pkg falhou com rc=$reinstall_rc"
            STILL_BROKEN+=("$pkg")
            continue
        fi
        if grep -q "nada para fazer" <<< "$reinstall_out"; then
            log "ℹ reinstalação de $pkg ignorada pelo pacman (nada para fazer); mantendo alerta de integridade"
            STILL_BROKEN+=("$pkg")
            continue
        fi
        if LC_ALL=C $SUDO pacman -Qk "$pkg" 2>&1 | grep -qE '[1-9][0-9]* missing files'; then
            log "⚠ $pkg continua com arquivos faltando após reinstalação"
            STILL_BROKEN+=("$pkg")
        else
            log "✓ $pkg sem arquivos faltando após reinstalação"
        fi
    done
    if (( ${#STILL_BROKEN[@]} > 0 )); then
        printf "  ${Y}⚠${N}  Persistem com arquivos faltando: ${W}%s${N}\n" "$(printf '%s ' "${STILL_BROKEN[@]}")"
        log "⚠ persistem com arquivos faltando: ${STILL_BROKEN[*]}"
    else
        printf "  ${G}✔${N}  Integridade corrigida após reinstalação\n"
        log "✓ integridade corrigida após reinstalação"
    fi
else
    printf "  ${G}✔${N}  OK\n"
fi

cleanup_flatpak() {
    printf "\n${B}━━━ ${W}Flatpak${B} ━━━${N}\n"
    log "--- Flatpak ---"

    local flatpak_tmp flatpak_system_before flatpak_system_after flatpak_user_before flatpak_user_after
    flatpak_tmp=$(mktemp /tmp/update-all-flatpak.XXXXXX)
    flatpak_system_before=$(du -sh /var/lib/flatpak 2>/dev/null | awk '{print $1}' || true)
    flatpak_user_before=$(du -sh "$REAL_HOME/.local/share/flatpak" 2>/dev/null | awk '{print $1}' || true)

    : > "$flatpak_tmp"

    if timeout 300 $SUDO flatpak update --system --noninteractive >> "$flatpak_tmp" 2>&1; then
        :
    else
        cat "$flatpak_tmp" | tee -a "$LOG_FILE"
        rm -f "$flatpak_tmp"
        printf "  ${Y}⚠${N}  Flatpak system update falhou; veja o log\n"
        log "⚠ flatpak system update falhou"
        return 0
    fi

    if timeout 300 flatpak update --user --noninteractive >> "$flatpak_tmp" 2>&1; then
        :
    else
        cat "$flatpak_tmp" | tee -a "$LOG_FILE"
        rm -f "$flatpak_tmp"
        printf "  ${Y}⚠${N}  Flatpak user update falhou; veja o log\n"
        log "⚠ flatpak user update falhou"
        return 0
    fi

    grep -Ev '^Info: .*está em fim de vida, com motivo: We strongly recommend moving to the latest stable version of the Platform and SDK$' "$flatpak_tmp" | tee -a "$LOG_FILE"
    if grep -q '^Info: .*está em fim de vida, com motivo: We strongly recommend moving to the latest stable version of the Platform and SDK$' "$flatpak_tmp"; then
        flatpak_eol=$(grep '^Info: .*está em fim de vida, com motivo: We strongly recommend moving to the latest stable version of the Platform and SDK$' "$flatpak_tmp" | sed -E 's/^Info: ([^ ]+) .*/\1/' | sort -u | tr '\n' ' ')
        log "ℹ runtimes Flatpak em fim de vida detectados (sem update disponível agora): ${flatpak_eol%% }"
    fi
    printf "  ${G}✔${N}  Flatpak system+user update concluído\n"

    if ! ensure_sudo_cmd flatpak uninstall --unused --system -y; then
        log "⚠ sudo para flatpak uninstall --unused --system indisponível; pulando cleanup system"
    else
        $SUDO flatpak uninstall --unused --system -y >> "$LOG_FILE" 2>&1 || log "⚠ flatpak uninstall --unused --system falhou"
    fi
    flatpak uninstall --unused --user -y >> "$LOG_FILE" 2>&1 || log "⚠ flatpak uninstall --unused --user falhou"
    flatpak repair --user >> "$LOG_FILE" 2>&1 || log "⚠ flatpak repair --user falhou"

    flatpak_system_after=$(du -sh /var/lib/flatpak 2>/dev/null | awk '{print $1}' || true)
    flatpak_user_after=$(du -sh "$REAL_HOME/.local/share/flatpak" 2>/dev/null | awk '{print $1}' || true)
    printf "  ${G}✔${N}  Flatpak system: ${W}${flatpak_system_before:-0}${N} → ${W}${flatpak_system_after:-0}${N}\n"
    printf "  ${G}✔${N}  Flatpak user: ${W}${flatpak_user_before:-0}${N} → ${W}${flatpak_user_after:-0}${N}\n"
    log "✓ flatpak cleanup: system ${flatpak_system_before:-0}->${flatpak_system_after:-0}; user ${flatpak_user_before:-0}->${flatpak_user_after:-0}"
    rm -f "$flatpak_tmp"
}

# ── Flatpak ───────────────────────────────────────────────────────────────────
cleanup_flatpak

# ── Calibre oficial (/opt) ────────────────────────────────────────────────────
printf "\n${B}━━━ ${W}Calibre${B} ━━━${N}\n"
log "--- Calibre ---"
if [[ -x /opt/calibre/calibre ]]; then
    CURRENT_CALIBRE=$(/opt/calibre/calibre --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)
    LATEST_CALIBRE=$(curl -fsSL https://calibre-ebook.com/download_linux 2>/dev/null | grep -oE 'The latest release of calibre is [0-9]+\.[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    CURRENT_CALIBRE_NORM=$(printf '%s' "$CURRENT_CALIBRE" | sed 's/\.0$//')
    LATEST_CALIBRE_NORM=$(printf '%s' "$LATEST_CALIBRE" | sed 's/\.0$//')
    if [[ -n "$LATEST_CALIBRE" && "$CURRENT_CALIBRE_NORM" != "$LATEST_CALIBRE_NORM" ]]; then
        printf "  ${C}→${N}  Atualizando Calibre: ${W}${CURRENT_CALIBRE:-?}${N} → ${W}$LATEST_CALIBRE${N}\n"
        if curl -fsSL https://download.calibre-ebook.com/linux-installer.sh -o /tmp/calibre-linux-installer.sh && $SUDO sh /tmp/calibre-linux-installer.sh install_dir=/opt isolated=n 2>&1 | tee -a "$LOG_FILE"; then
            NEW_CALIBRE=$(/opt/calibre/calibre --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)
            NEW_CALIBRE_NORM=$(printf '%s' "$NEW_CALIBRE" | sed 's/\.0$//')
            if [[ "$NEW_CALIBRE_NORM" == "$LATEST_CALIBRE_NORM" ]]; then
                printf "  ${G}✔${N}  Calibre oficial atualizado (${NEW_CALIBRE})\n"
                log "✓ Calibre oficial atualizado para ${NEW_CALIBRE}"
            else
                printf "  ${Y}⚠${N}  Calibre oficial continua em ${NEW_CALIBRE:-?}; Docker/Calibre pode já estar mais novo\n"
                log "⚠ Calibre oficial não confirmou update: atual=${NEW_CALIBRE:-?} esperado=$LATEST_CALIBRE"
            fi
        else
            printf "  ${Y}⚠${N}  Installer do Calibre falhou; mantendo versão atual\n"
            log "⚠ Calibre installer falhou; mantendo /opt/calibre atual"
        fi
    else
        printf "  ${G}✔${N}  Calibre atual (${CURRENT_CALIBRE:-desconhecido})\n"
    fi
else
    printf "  ${C}·${N}  Calibre oficial não instalado em /opt\n"
fi


DOCKER_UPDATED=0
DOCKER_SKIPPED=0
LOCAL_BUILD_IMAGES=()

# O updateAll pode recriar containers, mas nunca deve transformar uma atualização
# Docker em atualização Git nem sobrescrever customizações locais do repositório.
# Se os arquivos críticos do PipsBot estiverem modificados, registra o gate e
# mantém qualquer futura operação Git do Docker explicitamente bloqueada.
guard_docker_worktree() {
    local protected status_file
    protected=(
        "n8n/docker-compose.yaml"
        "n8n/shared/books-search.js"
        "n8n/shared/books-bot.sh"
    )
    status_file=$(git -C "$DOCKER_DIR" status --porcelain -- "${protected[@]}" 2>/dev/null || true)
    if [[ -n "$status_file" ]]; then
        DOCKER_GIT_UPDATE_BLOCKED=1
        log "⚠ Docker: mudanças locais protegidas detectadas; nenhuma operação Git será permitida neste ciclo"
        printf '%s\n' "$status_file" >> "$LOG_FILE"
    else
        DOCKER_GIT_UPDATE_BLOCKED=0
    fi
}
DOCKER_GIT_UPDATE_BLOCKED=0
guard_docker_worktree

# ── Docker: pull/build/up por stack ───────────────────────────────────────────
if (( RUN_DOCKER )); then
printf "\n${B}━━━ ${W}Docker — Pull/Build/Up${B} ━━━${N}\n"
log "--- Docker pull/build/up ---"

# Buildx às vezes fica com arquivos root:root quando alguma manutenção Docker roda via sudo/root.
# Isso quebra imagens locais (calibre-pcmanfm, n8n-custom) com:
#   open /home/pips/.docker/buildx/current: permission denied
repair_buildx_permissions() {
    local bx="$REAL_HOME/.docker/buildx"
    [[ -d "$bx" ]] || return 0
    if find "$bx" -maxdepth 5 \( -user root -o -group root \) -print -quit 2>/dev/null | grep -q .; then
        log "→ Corrigindo permissões do Docker Buildx em $bx"
        if $SUDO chown -R pips:pips "$bx" >> "$LOG_FILE" 2>&1 && chmod -R u+rwX,go-rwx "$bx" >> "$LOG_FILE" 2>&1; then
            log "✓ Permissões do Buildx corrigidas"
        else
            log "⚠ Não consegui corrigir permissões do Buildx automaticamente"
        fi
    fi
}
repair_buildx_permissions

# O PipsBot usa o token próprio de /home/pips/.config/telegram-bot.env;
# nunca herda o token do Hermes durante atualizações. Após um compose up,
# validamos o runtime antes de declarar o stack recuperado.
verify_pipsbot_after_update() {
    local deadline now health username heartbeat_age
    deadline=$(( $(date +%s) + 90 ))
    while :; do
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' pipsbot-telegram 2>/dev/null || true)
        username=$(docker exec pipsbot-telegram sh -c 'curl -fsS -m 5 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null' \
            | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",{}).get("username", ""))' 2>/dev/null || true)
        heartbeat_age=$(docker exec pipsbot-telegram sh -c 'test -f /shared/.telegram-bot-heartbeat && echo $(( $(date +%s) - $(stat -c %Y /shared/.telegram-bot-heartbeat) ))' 2>/dev/null || true)
        if [[ "$health" == "healthy" && "$username" == "pips_server_bot" && "$heartbeat_age" =~ ^[0-9]+$ && "$heartbeat_age" -le 30 ]]; then
            log "✓ pipsbot-worker recuperado: @pips_server_bot healthy, heartbeat ${heartbeat_age}s"
            return 0
        fi
        now=$(date +%s)
        (( now >= deadline )) && break
        sleep 3
    done
    log "⚠ pipsbot-worker falhou no gate pós-update: health=${health:-missing} bot=@${username:-missing} heartbeat=${heartbeat_age:-missing}s"
    return 1
}

mapfile -t COMPOSE_DIRS < <(
    docker compose ls --format json 2>/dev/null | python -c 'import json,os,sys; data=json.load(sys.stdin); [print(os.path.dirname((s.get("ConfigFiles") or "").split(",")[0])) for s in data if "running" in (s.get("Status") or "") and s.get("ConfigFiles")]' | sort -u
)

# Calibre primeiro (pedido explícito); DNS/proxy por último.
if (( ${#COMPOSE_DIRS[@]} > 0 )); then
    mapfile -t COMPOSE_DIRS < <(printf '%s\n' "${COMPOSE_DIRS[@]}" | awk '
        /\/calibre$/ {print "000 " $0; next}
        /\/caddy$/ {print "900 " $0; next}
        /\/pihole-unbound$/ {print "999 " $0; next}
        {print "100 " $0}
    ' | sort | cut -d" " -f2-)
fi

# Inventaria imagens realmente buildáveis antes de atualizar os stacks. Assim um
# consumidor de imagem local não depende da ordem de COMPOSE_DIRS.
for build_dir in "${COMPOSE_DIRS[@]}"; do
    [[ -d "$build_dir" ]] || continue
    if grep -qE '^[[:space:]]+build:' "$build_dir"/docker-compose.y* "$build_dir"/compose.y* 2>/dev/null; then
        mapfile -t build_images < <(
            (cd "$build_dir" && docker compose config --format json 2>/dev/null) \
                | python -c 'import json, sys; data=json.load(sys.stdin); [print(s.get("image", "")) for s in data.get("services", {}).values() if s.get("build") and s.get("image")]'
        )
        for img in "${build_images[@]}"; do
            [[ -n "$img" ]] && LOCAL_BUILD_IMAGES+=("$img")
        done
    fi
done

for cd in "${COMPOSE_DIRS[@]}"; do
    [[ -d "$cd" ]] || continue
    sn=$(basename "$cd")
    [[ "$sn" == "stirling-pdf" || "$cd" == *archive* ]] && continue

    if [[ "$sn" == "syncthing" ]]; then
        if systemctl --user -q is-active syncthing.service 2>/dev/null || ss -H -lunp 2>/dev/null | grep -qE ':21027\b.*users:\(\("syncthing"'; then
            printf "  ${C}·${N}  Docker: ${W}$sn${N} ... ${C}pulado${N} (Syncthing host/systemd já ativo)\n"
            log "  · $sn: pulado porque syncthing.service do usuário já está ativo e ocupa a discovery LAN (21027/udp)"
            continue
        fi
    fi

    printf "  ${C}→${N}  Docker: ${W}$sn${N} ... "
    log "  → $sn"

    if ! (cd "$cd" && docker compose config --quiet) >> "$LOG_FILE" 2>&1; then
        printf "${Y}config inválida — pulado${N}\n"
        log "  ⚠ $sn: config inválida"
        DOCKER_SKIPPED=$((DOCKER_SKIPPED + 1))
        continue
    fi

    # Consulta as imagens declaradas pelo stack para decidir se há algo remoto a baixar.
    stack_images=$(cd "$cd" && docker compose config --images 2>/dev/null || true)

    all_images_managed_local=0
    if [[ -n "$stack_images" ]]; then
        all_images_managed_local=1
        for img in $stack_images; do
            managed_local=0
            for local_img in "${LOCAL_BUILD_IMAGES[@]}"; do
                [[ "$img" == "$local_img" ]] && { managed_local=1; break; }
            done
            (( managed_local )) || { all_images_managed_local=0; break; }
        done
    fi

    # Rodar dentro do diretório do stack preserva .env local; --ignore-buildable evita
    # falha em imagens locais como n8n-custom/calibre-pcmanfm. Registry/Docker Hub
    # às vezes dá timeout transitório; uma segunda tentativa evita falso "pulado".
    if (( all_images_managed_local )); then
        log "  · $sn: pull pulado; usa somente imagens locais gerenciadas por outro stack"
    else
        log "  → $sn: docker compose pull --ignore-buildable (saída ao vivo)"
        if ! run_in_dir_logged "$cd" ionice -c3 nice -n 19 docker compose pull --ignore-buildable; then
            log "  ⚠ $sn: pull falhou; tentando novamente em 5s"
            sleep 5
            if ! run_in_dir_logged "$cd" ionice -c3 nice -n 19 docker compose pull --ignore-buildable; then
                printf "${Y}pull falhou — mantendo atual${N}\n"
                log "  ⚠ $sn: pull falhou 2x; mantendo containers atuais"
                DOCKER_SKIPPED=$((DOCKER_SKIPPED + 1))
                continue
            fi
        fi
    fi

    if (( RUN_DOCKER_REBUILD )) && grep -qE '^[[:space:]]+build:' "$cd"/docker-compose.y* "$cd"/compose.y* 2>/dev/null; then
        image_ids=$(cd "$cd" && docker compose config --images 2>/dev/null | sort -u | tr '\n' ' ')
        missing_local_image=0
        for img in $image_ids; do
            [[ -z "$img" ]] && continue
            if ! docker image inspect "$img" >/dev/null 2>&1; then
                missing_local_image=1
                break
            fi
        done

        if [[ "$sn" == "n8n" || "$sn" == "calibre" ]]; then
            # n8n/calibre usam imagem local buildável; `pull --ignore-buildable` pula essas imagens.
            # Em --full/--docker-rebuild, força `build --pull` para baixar base nova e recriar a imagem custom.
            log "  → $sn: docker compose build --pull (imagem local; saída ao vivo)"
            if run_in_dir_logged "$cd" ionice -c3 nice -n 19 docker compose build --pull; then
                log "  ✓ $sn: imagem local rebuildada com base atualizada"
            elif grep -qiE "429 Too Many Requests|toomanyrequests|pull rate limit" "$LOG_FILE"; then
                printf "${Y}build adiado — registry rate-limit; usando imagem atual${N}\n"
                log "  ⚠ $sn: registry rate-limit; rebuild adiado, mantendo imagem atual"
            else
                printf "${Y}build pulado — usando imagem atual${N}\n"
                log "  ⚠ $sn: build falhou; mantendo imagem atual"
            fi
        elif (( missing_local_image == 0 )); then
            log "  · $sn: imagem local já existe; build automático pulado"
        elif ! run_in_dir_logged "$cd" ionice -c3 nice -n 19 docker compose build; then
            printf "${Y}build pulado — usando imagem atual${N}\n"
            log "  ⚠ $sn: build falhou; tentando manter/subir imagem atual"
        fi
    fi

    log "  → $sn: docker compose up -d --remove-orphans (saída ao vivo)"
    if run_in_dir_logged "$cd" ionice -c3 nice -n 19 docker compose up -d --remove-orphans; then
        if [[ "$sn" == "pipsbot-worker" ]] && ! verify_pipsbot_after_update; then
            printf "${Y}PipsBot não recuperou — update marcado como falho${N}\n"
            log "⚠ $sn: compose up terminou, mas gate pós-update falhou"
            DOCKER_SKIPPED=$((DOCKER_SKIPPED + 1))
            continue
        fi
        printf "${G}ok${N}\n"
        DOCKER_UPDATED=$((DOCKER_UPDATED + 1))
    else
        printf "${Y}up falhou${N}\n"
        log "  ⚠ $sn: up falhou"
        DOCKER_SKIPPED=$((DOCKER_SKIPPED + 1))
    fi
done

# ── Limpeza Docker ────────────────────────────────────────────────────────────
collect_docker_df() {
    local label="$1" tmp start elapsed
    local -a values
    tmp=$(mktemp /tmp/update-all-docker-df.XXXXXX)
    start=$(date +%s)
    log "→ docker system df ($label)"
    # `docker system df` já bloqueou por minutos neste host; métricas são úteis,
    # mas nunca devem atrasar manutenção. O timeout não afeta containers em execução.
    if timeout 30 docker system df --format '{{json .}}' > "$tmp" 2>> "$LOG_FILE"; then
        mapfile -t values < <(/usr/bin/python -c '
import json, sys
rows = {}
for line in sys.stdin:
    try: row = json.loads(line)
    except Exception: continue
    rows[row.get("Type")] = f"{row.get("Size", "?")}|{row.get("Reclaimable", "?") }"
print(rows.get("Images", "?|?"))
print(rows.get("Local Volumes", "?|?"))
' < "$tmp")
        DOCKER_DF_IMAGES="${values[0]:-?|?}"
        DOCKER_DF_VOLUMES="${values[1]:-?|?}"
        elapsed=$(( $(date +%s) - start ))
        log "✓ docker system df ($label) concluído em ${elapsed}s"
    else
        DOCKER_DF_IMAGES="?|?"
        DOCKER_DF_VOLUMES="?|?"
        log "⚠ docker system df ($label) falhou ou excedeu 30s"
    fi
    rm -f "$tmp"
}

if (( RUN_DOCKER_PRUNE )); then
    printf "\n${B}━━━ ${W}Docker — Prune${B} ━━━${N}\n"
    log "--- Docker prune ---"
    collect_docker_df "antes"
    docker_images_before="$DOCKER_DF_IMAGES"
    docker_volumes_before="$DOCKER_DF_VOLUMES"

    if [[ ${UPDATEALL_DOCKER_CONTAINER_PRUNE:-0} == 1 ]]; then
        run_timed_logged "docker container prune -f (opt-in UPDATEALL_DOCKER_CONTAINER_PRUNE=1)" timeout 180 ionice -c3 docker container prune -f || true
    else
        log "· docker container prune pulado por segurança (use UPDATEALL_DOCKER_CONTAINER_PRUNE=1 se quiser)"
    fi
    run_timed_logged "docker image prune -f --filter until=168h (somente dangling; preserva imagens locais on-demand)" timeout 180 ionice -c3 docker image prune -f --filter "until=168h" || true
    if (( RUN_DOCKER_BUILDER_PRUNE )); then
        run_timed_logged "docker builder prune -af --filter until=168h" timeout 300 ionice -c3 docker builder prune -af --filter "until=168h" || true
    else
        log "· docker builder prune pulado (use --docker-builder-prune ou --full)"
    fi
    if [[ ${UPDATEALL_DOCKER_VOLUME_PRUNE:-0} == 1 ]]; then
        run_timed_logged "docker volume prune -f (opt-in UPDATEALL_DOCKER_VOLUME_PRUNE=1)" timeout 180 ionice -c3 docker volume prune -f || true
    else
        log "· docker volume prune pulado por segurança (use UPDATEALL_DOCKER_VOLUME_PRUNE=1 se quiser)"
    fi

    collect_docker_df "depois"
    docker_images_after="$DOCKER_DF_IMAGES"
    docker_volumes_after="$DOCKER_DF_VOLUMES"
    printf "  ${G}✔${N}  Docker prune concluído\n"
    printf "  ${G}✔${N}  Imagens: ${W}%s${N} → ${W}%s${N} (reclaimable ${W}%s${N})\n" "${docker_images_before%%|*}" "${docker_images_after%%|*}" "${docker_images_after#*|}"
    printf "  ${G}✔${N}  Volumes: ${W}%s${N} → ${W}%s${N} (reclaimable ${W}%s${N})\n" "${docker_volumes_before%%|*}" "${docker_volumes_after%%|*}" "${docker_volumes_after#*|}"
    log "✓ docker prune: imagens ${docker_images_before:-?}->${docker_images_after:-?}; volumes ${docker_volumes_before:-?}->${docker_volumes_after:-?}"
else
    log "Docker prune pulado; use --docker-prune ou --full"
fi
else
    printf "\n${B}━━━ ${W}Docker${B} ━━━${N}\n"
    printf "  ${C}·${N}  Docker pesado pulado no modo rápido; use ${W}updateAll --docker${N} ou ${W}updateAll --full${N}\n"
    log "Docker pull/build/up pulado no modo rápido"
fi

cleanup_arch_caches
audit_rkhunter

# ── Verificação pós-update ────────────────────────────────────────────────────
printf "\n${B}━━━ ${W}Verificação pós-update${B} ━━━${N}\n"
log "--- Verificação pós-update ---"
ISSUES=0

check_ok() {
    local name="$1"
    shift
    if "$@" >> "$LOG_FILE" 2>&1; then
        printf "  ${G}✔${N}  %s\n" "$name"
        printf "[%s] ✓ %s\n" "$(date +%H:%M:%S)" "$name" >> "$LOG_FILE"
    else
        printf "  ${R}✗${N}  %s\n" "$name"
        log "  ✗ $name"
        ISSUES=$((ISSUES + 1))
    fi
}

list_on_demand_services() {
    systemctl list-unit-files --type=service --no-pager 2>/dev/null \
        | awk '/-on-demand\.service/ {sub(/-on-demand\.service$/, "", $1); print $1}' \
        || true
}

should_ignore_container_issue() {
    local mode="$1"
    local line="$2"
    local name status on_demand_services svc

    name=${line%% *}
    status=${line#* }
    [[ -z "$name" || -z "$status" ]] && return 1

    on_demand_services=$(list_on_demand_services)
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        [[ "$name" == "$svc" ]] || continue

        case "$mode" in
            exited)
                [[ "$status" =~ ^Exited\ \(0\) ]] && return 0
                ;;
            dead)
                [[ "$status" =~ ^Dead ]] && return 0
                ;;
        esac
    done <<< "$on_demand_services"

    return 1
}

list_container_issues() {
    local mode="$1"
    local raw filtered line
    case "$mode" in
        unhealthy)
            raw=$(docker ps -a --filter health=unhealthy --format '{{.Names}} {{.Status}}' 2>/dev/null || true)
            ;;
        exited)
            raw=$(docker ps -a --filter status=exited --format '{{.Names}} {{.Status}}' 2>/dev/null || true)
            ;;
        dead)
            raw=$(docker ps -a --filter status=dead --format '{{.Names}} {{.Status}}' 2>/dev/null || true)
            ;;
        *)
            return 1
            ;;
    esac

    filtered=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        should_ignore_container_issue "$mode" "$line" && continue
        filtered+="$line"$'\n'
    done <<< "$raw"

    printf "%s" "${filtered%$'\n'}"
}

UNHEALTHY=$(list_container_issues unhealthy)
EXITED=$(list_container_issues exited)
DEAD=$(list_container_issues dead)
if [[ -n "$UNHEALTHY" ]]; then
    printf "  ${R}✗${N}  Containers unhealthy:\n%s\n" "$UNHEALTHY"
    log "  ✗ Containers unhealthy: $UNHEALTHY"
    ISSUES=$((ISSUES + 1))
else
    printf "  ${G}✔${N}  Nenhum container unhealthy\n"
fi
if [[ -n "$EXITED" ]]; then
    printf "  ${Y}⚠${N}  Containers exited:\n%s\n" "$EXITED"
    log "  ⚠ Containers exited: $EXITED"
    ISSUES=$((ISSUES + 1))
else
    printf "  ${G}✔${N}  Nenhum container exited\n"
fi
if [[ -n "$DEAD" ]]; then
    printf "  ${Y}⚠${N}  Containers dead:\n%s\n" "$DEAD"
    log "  ⚠ Containers dead: $DEAD"
    ISSUES=$((ISSUES + 1))
else
    printf "  ${G}✔${N}  Nenhum container dead\n"
fi

collect_failed_systemd() {
    local failed_now actionable stale unit state_ts state_epoch unit_file_state active_state sub_state line
    actionable=""
    stale=""
    failed_now=$(systemctl --failed --no-legend --plain 2>/dev/null || true)

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        unit=${line%% *}
        [[ "$unit" =~ ^(docker-stacks\.service|docker-stacks\.timer)$ ]] && continue

        state_ts=$(systemctl show "$unit" -p StateChangeTimestamp --value 2>/dev/null || true)
        state_epoch=0
        if [[ -n "$state_ts" ]]; then
            state_epoch=$(date -d "$state_ts" +%s 2>/dev/null || echo 0)
        fi

        unit_file_state=$(systemctl show "$unit" -p UnitFileState --value 2>/dev/null || true)
        active_state=$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)
        sub_state=$(systemctl show "$unit" -p SubState --value 2>/dev/null || true)

        if (( state_epoch > 0 && state_epoch < SCRIPT_START_EPOCH )); then
            stale+="$line\n"
            continue
        fi

        if [[ "$unit_file_state" =~ ^(disabled|static|masked)$ ]]; then
            stale+="$line\n"
            continue
        fi

        if [[ "$active_state" == "failed" && "$sub_state" == "failed" ]]; then
            actionable+="$line\n"
        fi
    done <<< "$failed_now"

    if [[ -n "$actionable" ]]; then
        printf "  ${R}✗${N}  systemd failed units (novas/relevantes):\n%s\n" "${actionable%$'\n'}"
        log "  ✗ systemd failed units (novas/relevantes): ${actionable%$'\n'}"
        ISSUES=$((ISSUES + 1))
    else
        printf "  ${G}✔${N}  systemd sem units com falha novas/relevantes\n"
    fi

    if [[ -n "$stale" ]]; then
        printf "  ${C}·${N}  systemd failed pré-existentes/não acionáveis ignoradas:\n%s\n" "${stale%$'\n'}"
        log "  · systemd failed pré-existentes/ignoradas: ${stale%$'\n'}"
    fi
}

ensure_required_service_active() {
    local unit="$1"
    local label="$2"
    local enabled active restartable

    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    [[ "$enabled" == "enabled" ]] || return 0

    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    if [[ "$active" == "active" ]]; then
        printf "  ${G}✔${N}  %s\n" "$label"
        return 0
    fi

    restartable=0
    case "$active" in
        inactive|failed)
            restartable=1
            ;;
    esac

    if (( restartable )); then
        printf "  ${Y}⚠${N}  %s parado; tentando auto-heal (%s)\n" "$label" "$unit"
        log "  ⚠ $label parado; tentando auto-heal ($unit)"
        if $SUDO systemctl start "$unit" >> "$LOG_FILE" 2>&1; then
            sleep 2
            active=$(systemctl is-active "$unit" 2>/dev/null || true)
            if [[ "$active" == "active" ]]; then
                printf "  ${G}✔${N}  %s recuperado automaticamente\n" "$label"
                log "  ✓ $label recuperado automaticamente"
                return 0
            fi
        fi
    fi

    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    printf "  ${R}✗${N}  %s (enabled=%s active=%s)\n" "$label" "$enabled" "${active:-unknown}"
    log "  ✗ $label (enabled=$enabled active=${active:-unknown})"
    ISSUES=$((ISSUES + 1))
    return 1
}

collect_failed_systemd
ensure_required_service_active "NetworkManager.service" "NetworkManager ativo"
ensure_required_service_active "sshd.service" "OpenSSH ativo"
ensure_required_service_active "tailscaled.service" "Tailscale ativo"
ensure_required_service_active "docker.service" "Docker ativo"

check_http() {
    local name="$1"
    local url="$2"
    local ok_codes="$3"
    check_ok "$name" bash -lc "code=\$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 '$url'); [[ \"\$code\" =~ ^($ok_codes)$ ]]"
}

check_ok "DNS Pi-hole/Unbound responde" bash -lc '[[ -n "$(dig +short @127.0.0.1 -p 53 cloudflare.com)" ]]'
if systemctl is-active --quiet calibre-on-demand.service; then
    check_http "Calibre on-demand proxy responde" "http://127.0.0.1:8180/__calibre_on_demand_status" "200"
else
    if docker inspect calibre >/dev/null 2>&1; then
        calibre_state=$(docker inspect -f '{{.State.Status}}' calibre 2>/dev/null || true)
        if [[ "$calibre_state" != "running" ]]; then
            printf "  ${C}·${N}  Calibre Xpra pulado (container não está rodando: %s)\n" "${calibre_state:-desconhecido}"
            log "· calibre xpra pulado: container não está rodando (${calibre_state:-desconhecido})"
        elif timeout 180 bash -lc 'while :; do status=$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" calibre 2>/dev/null || true); [[ "$status" == "healthy" || "$status" == "running" ]] && exit 0; sleep 2; done'; then
            log "✓ calibre pronto antes da verificação HTTP"
            check_http "Calibre Xpra responde" "http://127.0.0.1:18180/" "200|401"
        else
            log "⚠ calibre não ficou healthy/running dentro do timeout antes da verificação HTTP"
        fi
    else
        printf "  ${C}·${N}  Calibre Xpra pulado (container/on-demand inativo)\n"
        log "· calibre xpra pulado: container/on-demand inativo"
    fi
fi
if docker inspect calibre-web >/dev/null 2>&1; then
    calibre_web_state=$(docker inspect -f '{{.State.Status}}' calibre-web 2>/dev/null || true)
    if [[ "$calibre_web_state" != "running" ]]; then
        printf "  ${C}·${N}  Calibre-Web pulado (container não está rodando: %s)\n" "${calibre_web_state:-desconhecido}"
        log "· calibre-web pulado: container não está rodando (${calibre_web_state:-desconhecido})"
    elif timeout 180 bash -lc 'while :; do status=$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" calibre-web 2>/dev/null || true); [[ "$status" == "healthy" || "$status" == "running" ]] && exit 0; sleep 2; done'; then
        log "✓ calibre-web pronto antes da verificação HTTP"
        check_http "Calibre-Web responde" "http://192.168.0.120:8083/" "200|302|401"
    else
        log "⚠ calibre-web não ficou healthy/running dentro do timeout antes da verificação HTTP"
    fi
else
    printf "  ${C}·${N}  Calibre-Web pulado (stack inativo)\n"
    log "· calibre-web pulado: stack inativo"
fi
check_http "Stremio responde" "http://192.168.0.120:11470/" "200|301|302|307"
check_http "AIOStreams responde" "http://192.168.0.120:3020/" "200|301|302|307"

for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    n=$(docker logs --since 6h "$c" 2>&1 | grep -ciE "fatal|panic|killed|segfault|out of memory" || true)
    if (( n > 5 )); then
        printf "  ${Y}⚠${N}  $c: ${Y}$n critical${N} (6h)\n"
        log "  ⚠ $c: $n critical (6h)"
        ISSUES=$((ISSUES + 1))
    fi
done
(( ISSUES == 0 )) && printf "  ${G}✔${N}  Nada quebrado detectado\n"

# ── Resumo ────────────────────────────────────────────────────────────────────
printf "\n${W}╔══════════════════════════════════════════════╗${N}\n"
printf "${W}║  RESUMO${N}\n"
printf "${W}╚══════════════════════════════════════════════╝${N}\n"
printf "  ${C}•${N}  Docker stacks processados: ${W}$DOCKER_UPDATED${N}\n"
[[ "${DOCKER_SKIPPED:-0}" -gt 0 ]] && printf "  ${Y}⚠${N}  Docker stacks pulados/falharam: ${Y}$DOCKER_SKIPPED${N}\n"
(( ISSUES > 0 )) && printf "  ${Y}⚠${N}  Containers com issues: ${Y}$ISSUES${N}\n"
(( ISSUES == 0 )) && printf "  ${G}✔${N}  Containers: ${G}OK${N}\n"
if [[ -n "$AUR_NOTICES" ]]; then
    printf "  ${Y}·${N}  Informações AUR para revisão manual (não são falhas do update):\n"
    while IFS= read -r notice; do
        [[ -n "$notice" ]] && printf "      %s\n" "$notice"
    done <<< "$AUR_NOTICES"
fi
UPDATE_DURATION=$(( $(date +%s) - SCRIPT_START_EPOCH ))
printf "  ${C}•${N}  Duração: ${W}%sm %ss${N}\n" "$((UPDATE_DURATION / 60))" "$((UPDATE_DURATION % 60))"
printf "  ${C}•${N}  Log: ${C}$LOG_FILE${N}\n"
log "=== update-all concluído em ${UPDATE_DURATION}s ==="

[[ -f "$BREAKING_FILE" ]] && grep -q "\[$(date +%Y)" "$BREAKING_FILE" && printf "  ${R}⚠${N}  Breaking: ${Y}$BREAKING_FILE${N}\n"

# Propaga falhas relevantes para quem chamou o updateAll (shell, timer ou automação).
FINAL_RC=0
if (( DOCKER_SKIPPED > 0 || ISSUES > 0 )); then
    FINAL_RC=1
fi
exit "$FINAL_RC"
