# Pinterest iOS — mx/mxa/mxw/mxc/mxd/mxs/fastbuild/kx/kxd
# Gerido pelo chezmoi: dot_zshrc.d/pinterest.zsh.tmpl (só darwin).
# Source a partir de ~/.zshrc (template do chezmoi).

# MARK: - Pinterest iOS: mx + fastbuild (único fluxo)
#   mx         — sempre a partir de $PWD: git root da pasta onde estás. Generate + abre workspace; destino = só simulador (ignora iPhone USB).
#                scheme PinterestDevelopment e run destination iPhone 14 (AppleScript)
#   fastbuild  — build CLI PinterestDevelopment (opcional: --run / -r para instalar no simulador)
#   kx         — Xcode aberto: só XCB/SWB build services (não mata SourceKit → Cursor/SourceKit-LSP OK). kx_hard = inclui SourceKit (só Xcode, sem Cursor).
#   Recuperação: stamp/generate: apaga /tmp/mx-last-generate-* ; HEAD/stale build: /tmp/mx-last-head-*
#   Erros “ficheiro em falta” após branch/rebase: MX_DEEP_CLEAN_BUILD_EVERY_MX=1 (equiv. a Clean Build Folder em todo mx)
#   Reindex / “Preparing editor”: manter MX_DEEP_CLEAN_BUILD_EVERY_MX=0 (default); não matar SourceKit; não apagar SwiftExplicitPrecompiledModules no mx normal.
MX_PIN_SCHEME="PinterestDevelopment"
MX_PIN_SIM_SUBSTR="iPhone 14"
# 1 = apaga sempre …/DerivedData/Pinterest-*/Build (força reindex/prepare no próximo arranque). 0 = só quando HEAD muda.
MX_DEEP_CLEAN_BUILD_EVERY_MX="${MX_DEEP_CLEAN_BUILD_EVERY_MX:-0}"

# Caps de cache (GB). Calibrado pra Mac Studio/MBP M-series 64+ GB / 1 TB+ disco.
# Override exportando antes de fonte do .zshrc.
#   DerivedData total: cap soft, mxc só avisa. ~30-50 GB por workspace ativo + 14 GB ModuleCache.
#   Tuist binaries (~/.cache/tuist/Binaries): cap. Acima disso, mxc trim corre tuist clean binaries.
#   DD stale: dias sem mtime que marca um Pinterest-<hash> como podável (poda manual via mxc trim).
MX_DD_CAP_GB="${MX_DD_CAP_GB:-300}"
MX_TUIST_BIN_CAP_GB="${MX_TUIST_BIN_CAP_GB:-50}"
MX_DD_STALE_DAYS="${MX_DD_STALE_DAYS:-30}"
# Avisar pra correr `mxw` se binary cache não foi tocado em N dias (warm pre-emptive).
MX_WARM_STALE_DAYS="${MX_WARM_STALE_DAYS:-14}"

alias reload="source"
alias zshs="source ~/.zshrc"

# Git root do diretório **atual** (navega com cd para o clone/worktree certo). Sem fallback — evita abrir o repo errado.
_mx_repo() {
    git -C "${PWD:-.}" rev-parse --show-toplevel 2>/dev/null
}

_mx_workspace() {
    local r="${1:-$(_mx_repo)}"
    if [ -d "$r/PinterestDevelopment.xcworkspace" ]; then
        echo "$r/PinterestDevelopment.xcworkspace"
    else
        echo "$r/Pinterest.xcworkspace"
    fi
}

# Nome do scheme derivado do primeiro target (convenção: target name == scheme name).
#   ""              -> $MX_PIN_SCHEME (PinterestDevelopment)
#   "Foo"           -> "Foo"
#   "Feature/Foo"   -> "Foo"
#   "Foo,Bar"       -> "Foo"
_mx_scheme_from_targets() {
    local targets="${1:-}"
    if [[ -z "$targets" ]]; then
        echo "$MX_PIN_SCHEME"
        return 0
    fi
    local first="${targets%%,*}"
    echo "${first##*/}"
}

# Fingerprint = sorted list of tracked-file paths at HEAD (adds/deletes/renames
# change the list; pure content edits don't). Untracked files included so that
# a new source file on disk also triggers regen. No shasum of Tuist contents.
_mx_fingerprint_project() {
    local repo="${1:?}"
    if git -C "$repo" rev-parse --is-inside-work-tree &>/dev/null; then
        (cd "$repo" && {
            git ls-tree -r --name-only HEAD 2>/dev/null
            git ls-files -o --exclude-standard 2>/dev/null
        } | LC_ALL=C sort | shasum | awk '{print $1}')
    else
        find "$repo/Tuist" -type f 2>/dev/null | wc -l | tr -d ' '
    fi
}

# return 0 = changed (regen needed), return 1 = no changes.
# Regen only when files were added/deleted/renamed since the last generate.
# Pure content edits (.swift/.m body changes) do NOT regen — Tuist globs pick
# them up on next build. Accepts: $1=repo $2=ws.
_mx_project_changed() {
    local repo="${1:?}" ws="${2:?}"
    local stamp="/tmp/mx-last-generate-$(md5 -qs "$repo")"

    # No workspace or no stamp → must generate
    [ ! -f "$ws/contents.xcworkspacedata" ] && return 0
    [ ! -f "$stamp" ] && return 0

    # Added/deleted/renamed files in the working tree (indexed or not).
    # Porcelain codes: A/D/R/C/?? indicate add/delete/rename/copy/untracked.
    # M (modify) alone is ignored — pure content edits don't need regen.
    if (cd "$repo" && git status --porcelain 2>/dev/null | awk '{print substr($0,1,2)}' | grep -qE '^( A|A |AM| D|D |DM| R|R |RM| C|C |CM|\?\?)'); then
        return 0
    fi

    # Committed-state fingerprint: list of tracked paths at HEAD + untracked.
    # Changes only when files are added/deleted/renamed — commit edits to
    # existing files don't flip this.
    local current_hash stored_hash
    current_hash=$(_mx_fingerprint_project "$repo")
    stored_hash=$(cat "$stamp" 2>/dev/null)
    [ "$current_hash" != "$stored_hash" ] && return 0

    return 1
}

_mx_stamp_update() {
    local repo="${1:?}"
    local stamp="/tmp/mx-last-generate-$(md5 -qs "$repo")"
    _mx_fingerprint_project "$repo" > "$stamp"
}

# Encerra o Xcode sem AppleScript (osascript quit pode bloquear para sempre se o Xcode está pendurado).
_mx_quit_xcode() {
    pgrep -x Xcode >/dev/null 2>&1 || return 0
    echo "🛑 mx: a fechar Xcode (SIGTERM → SIGKILL se preciso)…"
    killall XCBBuildService SWBBuildService 2>/dev/null || true
    sleep 0.15
    killall -TERM Xcode 2>/dev/null || true
    local i=0
    while pgrep -x Xcode >/dev/null 2>&1 && [ "$i" -lt 25 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if pgrep -x Xcode >/dev/null 2>&1; then
        echo "⚠️  mx: Xcode não saiu — killall -9"
        killall -9 Xcode 2>/dev/null || true
        sleep 0.2
    fi
}

# Estado de janelas do macOS (restauro de janelas ao reabrir). Sem isto, o Xcode reabre várias janelas/workspaces antigos.
_mx_clear_xcode_saved_application_state() {
    rm -rf "$HOME/Library/Saved Application State/com.apple.dt.Xcode.savedState"
}

# Caches só do *build graph* (PIF/XCBuildData). Não toca em SwiftExplicitPrecompiledModules → menos “Preparing editor” / reparse Swift.
_mx_clean_pinterest_derived_caches() {
    local dd
    find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -type d -name 'Pinterest-*' 2>/dev/null | while read -r dd; do
        rm -rf \
            "$dd/Build/Intermediates.noindex/XCBuildData" \
            "$dd/Build/Intermediates.noindex/PIFCache" \
            "$dd/Build/Intermediates.noindex/BuildDescriptionCache" \
            2>/dev/null
    done
}

# Equiv. a “Clean Build Folder”: renomeia Build (instantâneo no mesmo volume) e apaga o lixo em segundo plano.
# Um rm -rf gigante aqui bloqueava o mx minutos — o xed só corria depois e parecia que o Xcode “não abria”.
_mx_deep_clean_pinterest_build() {
    local dd trash
    find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -type d -name 'Pinterest-*' 2>/dev/null | while read -r dd; do
        if [[ -d "$dd/Build" ]]; then
            trash="$dd/Build.mx-trash-$$-$RANDOM"
            if mv "$dd/Build" "$trash" 2>/dev/null; then
                ( rm -rf "$trash" ) &!
            else
                echo "⚠️  mx: mv Build falhou — rm síncrono (pode demorar)" >&2
                rm -rf "$dd/Build" 2>/dev/null
            fi
        fi
        rm -rf "$dd/CompilationCache.noindex" "$dd/SDKStatCaches.noindex" 2>/dev/null
    done
}

# Só serviços do *build system* — não matar SourceKitService/SKAgent (isso força “Preparing editor” e reindex pesado no próximo arranque).
_mx_kill_xcode_build_system_daemons() {
    killall XCBBuildService SWBBuildService 2>/dev/null || true
}

_mx_scrub_workspace_xcuserstate() {
    local ws="${1:?}"
    [[ -d "$ws" ]] || return 0
    find "$ws" -name '*.xcuserstate' -delete 2>/dev/null
}

# Warmup em 2 fases. Idempotente, best-effort, nunca bloqueia.
# Controla via MX_WARMUP (default=1). Desliga com MX_WARMUP=0.
#
# Fase 1 (pré-generate, roda em paralelo com `mise run generate`):
#   - Boot do simulador iPhone 14 (não depende do projeto, pode rodar a qualquer momento).
#
# Fase 2 (pós-generate, roda em paralelo com `xed`):
#   - `xcodebuild -showBuildSettings`: força SPM resolve + package graph + build settings.
#   - `xcodebuild -list`: popula project/scheme metadata.
#   NÃO dá para rodar em paralelo com generate — `tuist generate` reescreve .xcodeproj
#   e o xcodebuild leria estado inconsistente (cache corrompe, "Preparing" eterno).

# Boot do simulador em background. Seguro para rodar a qualquer momento — não toca no projeto.
_mx_warmup_presim() {
    [[ "${MX_WARMUP:-1}" != "1" ]] && return 0
    (
        local udid
        udid=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '\([A-F0-9-]{36}\)' | head -1 | tr -d '()')
        if [[ -z "$udid" ]]; then
            udid=$(xcrun simctl list devices available 2>/dev/null \
                | grep -E "iPhone 14 \(" | head -1 \
                | grep -oE '\([A-F0-9-]{36}\)' | tr -d '()')
            [[ -n "$udid" ]] && xcrun simctl boot "$udid" >/dev/null 2>&1
        fi
    ) &!
}

# Warmup que depende do workspace gerado. Chamar DEPOIS do generate terminar,
# em paralelo com `xed`.
_mx_warmup_postgen() {
    [[ "${MX_WARMUP:-1}" != "1" ]] && return 0
    local repo="${1:?}" ws="${2:?}" scheme="${3:-PinterestDevelopment}"
    [[ ! -e "$ws" ]] && return 0
    local log_dir="${TMPDIR:-/tmp}/mx-warmup"
    mkdir -p "$log_dir"

    # xcodebuild -showBuildSettings: força SPM resolve + package graph + build
    # settings resolution. Xcode ao abrir consome esse cache → "Preparing" curto.
    (
        cd "$repo" 2>/dev/null || exit 0
        local out="$log_dir/showBuildSettings-$(date +%s).log"
        xcodebuild -workspace "$ws" -scheme "$scheme" \
            -configuration Debug \
            -showBuildSettings \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            -onlyUsePackageVersionsFromResolvedFile \
            >"$out" 2>&1
    ) &!

    # xcodebuild -list: popula metadata de schemes/targets.
    (
        cd "$repo" 2>/dev/null || exit 0
        xcodebuild -workspace "$ws" -list >/dev/null 2>&1
    ) &!
}

# Fixa PinterestDevelopment.xcscheme como scheme default do popup (orderHint 0).
# Corre sempre que mx roda porque `mise run generate` pode regenerar o plist.
# Sem isto, "Pinterest" (alfabético + orderHint baixo) fica no topo e Xcode abre lá por default quando xcuserstate é apagado.
_mx_pin_scheme_default() {
    local repo="${1:?}"
    local usr="${USER:-$(whoami)}"
    local plist="$repo/Pinterest.xcodeproj/xcuserdata/$usr.xcuserdatad/xcschemes/xcschememanagement.plist"
    [[ -f "$plist" ]] || return 0
    local cur_dev
    cur_dev=$(/usr/libexec/PlistBuddy -c "Print :SchemeUserState:PinterestDevelopment.xcscheme_^#shared#^_:orderHint" "$plist" 2>/dev/null)
    if [[ "$cur_dev" != "0" ]]; then
        /usr/libexec/PlistBuddy -c "Set :SchemeUserState:PinterestDevelopment.xcscheme_^#shared#^_:orderHint 0" "$plist" 2>/dev/null \
            && /usr/libexec/PlistBuddy -c "Set :SchemeUserState:Pinterest.xcscheme_^#shared#^_:orderHint 1000" "$plist" 2>/dev/null \
            && echo "📌 mx: scheme default fixado → PinterestDevelopment (orderHint 0)"
    fi
}

# Return 0 se o diff entre dois SHAs toca manifests de projeto (Tuist/, Project.swift, etc.), 1 caso contrário.
# Sem argumentos válidos (prev/now ausentes) assume "toca" (= seguro, força clean).
_mx_head_diff_touches_project() {
    local repo="${1:?}" prev="${2:-}" now="${3:-}"
    [[ -z "$prev" || -z "$now" ]] && return 0
    # Tuist/Project configs OR source files added/deleted (Tuist globs need regen)
    (cd "$repo" && git diff --name-only "$prev" "$now" 2>/dev/null \
        | grep -qE '(^|/)(Project\.swift|Workspace\.swift|Package\.swift|Package\.resolved)$|^Tuist/') && return 0
    # Source files added or deleted between commits → Tuist project file list changed
    (cd "$repo" && git diff --diff-filter=ADR --name-only "$prev" "$now" 2>/dev/null \
        | grep -qE '\.(swift|[mhc]|mm|cpp|xib|storyboard|xcassets|plist)$') && return 0
    return 1
}

# Limpa estado de build obsoleto. No mesmo HEAD não faz nada → mantém índice/SourceKit quentes (menos reindex / Preparing editor).
# Smart reset: só apaga Build/ quando HEAD muda **e** o diff toca Project.swift/Tuist/. Code-only checkouts preservam o cache Swift/ObjC.
_mx_maybe_reset_build_for_new_head() {
    local repo="${1:?}" ws="${2:?}"
    local stamp="/tmp/mx-last-head-$(md5 -qs "$repo")"
    local head_now=""
    if git -C "$repo" rev-parse --is-inside-work-tree &>/dev/null; then
        head_now=$(git -C "$repo" rev-parse HEAD)
    fi
    local head_prev
    head_prev=$(cat "$stamp" 2>/dev/null || true)
    local head_changed=0
    [[ -n "$head_now" && "$head_now" != "$head_prev" ]] && head_changed=1

    if [[ "$MX_DEEP_CLEAN_BUILD_EVERY_MX" == 1 ]]; then
        echo "🧹 mx: Build afastada + apagar em 2º plano — MX_DEEP_CLEAN_BUILD_EVERY_MX=1"
        _mx_deep_clean_pinterest_build
        _mx_scrub_workspace_xcuserstate "$ws"
        _mx_kill_xcode_build_system_daemons
        [[ -n "$head_now" ]] && echo "$head_now" >"$stamp"
    elif [[ "$head_changed" == 1 ]]; then
        if [[ -n "$head_prev" ]] && ! _mx_head_diff_touches_project "$repo" "$head_prev" "$head_now"; then
            echo "⚡ mx: HEAD mudou mas diff não toca Project.swift/Tuist → preserva Build/ (cache Swift/ObjC quente)"
            echo "$head_now" >"$stamp"
            return 0
        fi
        # Preservamos *.xcuserstate (última destination / scheme) — apagar aqui faz Xcode voltar ao default do popup.
        # Pra limpar corruption real, use MX_DEEP_CLEAN_BUILD_EVERY_MX=1.
        echo "🧹 mx: HEAD mudou e toca Project.swift/Tuist — Build afastada (apagar em 2º plano)"
        _mx_deep_clean_pinterest_build
        _mx_kill_xcode_build_system_daemons
        echo "$head_now" >"$stamp"
    else
        return 0
    fi
    _mx_clean_pinterest_derived_caches
    return 0
}

# Xcode (AppleScript): argv = path do workspace + scheme + sim.
# IMPORTANTE: usar `osascript - … <<SCRIPT` e NÃO `osascript -- "$path" …` — senão o .xcworkspace é lido como *ficheiro* AppleScript (erro -1750 / "Nenhum erro").
# 2º arg (scheme) é opcional — default = $MX_PIN_SCHEME.
_mx_xcode_set_scheme_and_destination() {
    local _ws="${1:?}"
    local _scheme="${2:-$MX_PIN_SCHEME}"
    local real
    real="$(cd "$(dirname "$_ws")" && pwd -P)/$(basename "$_ws")"
    osascript -l AppleScript - "$real" "$_scheme" "$MX_PIN_SIM_SUBSTR" <<'APPLESCRIPT'
on run argv
    set targetPath to item 1 of argv
    set schemeWant to item 2 of argv
    set simSubstr to item 3 of argv
    set tp to my mxNormPath(targetPath)
    tell application "Xcode"
        activate
        set foundDoc to missing value
        set outer to 0
        repeat while foundDoc is missing value and outer < 200
            set outer to outer + 1
            try
                set awd to active workspace document
                if awd is not missing value then
                    try
                        set fp to my mxNormPath(path of awd)
                        if fp is tp then set foundDoc to awd
                    end try
                end if
            end try
            if foundDoc is missing value then
                repeat with d in workspace documents
                    try
                        set fp2 to my mxNormPath(path of d)
                        if fp2 is tp then
                            set foundDoc to d
                            exit repeat
                        end if
                    end try
                end repeat
            end if
            if foundDoc is missing value then delay 0.1
        end repeat
        if foundDoc is missing value then return "no_workspace"
        set w to 0
        repeat while (loaded of foundDoc) is false
            delay 0.2
            set w to w + 1
            if w > 150 then return "timeout_load"
        end repeat
        delay 0.5
        set schemeOK to false
        repeat with tryN from 1 to 12
            if schemeOK then exit repeat
            tell foundDoc
                try
                    if (count of schemes) is 0 then
                        -- lista ainda vazia
                    else
                        repeat with sch in schemes
                            set nx to name of sch as text
                            ignoring case
                                if nx is schemeWant then
                                    set active scheme to sch
                                    set schemeOK to true
                                    exit repeat
                                end if
                            end ignoring
                        end repeat
                        if not schemeOK then
                            repeat with sch in schemes
                                if (name of sch as text) contains schemeWant then
                                    set active scheme to sch
                                    set schemeOK to true
                                    exit repeat
                                end if
                            end repeat
                        end if
                    end if
                end try
            end tell
            if not schemeOK then delay 0.45
        end repeat
        if not schemeOK then return "no_scheme"
        tell foundDoc
            -- "run" is an AppleScript keyword; "in run destinations" parses as "run" command — use get.
            repeat with mxDest in (get run destinations)
                try
                    if (platform of mxDest as text) is "iphonesimulator" and (name of mxDest as text) contains simSubstr then
                        set active run destination to mxDest
                        return "ok"
                    end if
                end try
            end repeat
            repeat with mxDest in (get run destinations)
                try
                    if (platform of mxDest as text) is "iphonesimulator" then
                        set active run destination to mxDest
                        return "sim_any"
                    end if
                end try
            end repeat
        end tell
        return "no_destination"
    end tell
end run

on mxNormPath(p)
    set p to p as text
    if (length of p) > 1 and p ends with "/" then return text 1 thru -2 of p
    return p
end mxNormPath
APPLESCRIPT
}

_mx_open_workspace_solo() {
    local _ws="${1:-$(_mx_workspace)}"
    [[ -e "$_ws" ]] || {
        echo "❌ Workspace não encontrado: $_ws"
        return 1
    }
    _mx_quit_xcode
    _mx_clear_xcode_saved_application_state
    _mx_pin_scheme_default "$_repo"
    xed "$_ws"
    echo "✓ mx: a definir scheme $MX_PIN_SCHEME + sim ($MX_PIN_SIM_SUBSTR)…"
    sleep 2
    local asr ose
    ose=$(mktemp "${TMPDIR:-/tmp}/mx-osa-err.XXXXXX")
    asr=$(_mx_xcode_set_scheme_and_destination "$_ws" 2>"$ose" | head -1 | tr -d '\r') || true
    [[ -s "$ose" ]] && { echo "mx (AppleScript stderr):" >&2; cat "$ose" >&2; }
    rm -f "$ose"
    case "${asr%%$'\n'}" in
        ""|no_scheme|timeout_load|scheme_set:*)
            echo "⌛ mx: a repetir seleção de scheme…" >&2
            sleep 2
            ose=$(mktemp "${TMPDIR:-/tmp}/mx-osa-err.XXXXXX")
            asr=$(_mx_xcode_set_scheme_and_destination "$_ws" 2>"$ose" | head -1 | tr -d '\r') || true
            [[ -s "$ose" ]] && cat "$ose" >&2
            rm -f "$ose"
            ;;
    esac
    case "${asr%%$'\n'}" in
        ok)                 echo "✓ mx: $MX_PIN_SCHEME · sim $MX_PIN_SIM_SUBSTR (sem dispositivo físico)" ;;
        sim_any)            echo "✓ mx: $MX_PIN_SCHEME · primeiro simulador iOS (sem $MX_PIN_SIM_SUBSTR nem device USB)" ;;
        no_destination)    echo "✓ mx: scheme $MX_PIN_SCHEME (sem simulador na lista — escolhe destino no Xcode)" ;;
        *)                  echo "⚠️  mx: scheme/destino falhou (${asr:-error}) — workspace $(basename "$_ws")" >&2 ;;
    esac
    return 0
}

# generate --fast falha se .buildhook/honeycomb_env_write_key não existir (gitignore); evita mexer no repo.
_mx_ensure_fast_generate_ok() {
    local r="${1:?}"
    mkdir -p "$r/.buildhook"
    [[ -f "$r/.buildhook/honeycomb_env_write_key" ]] || : >"$r/.buildhook/honeycomb_env_write_key"
}

# --fast + --no-open (só o xed no fim abre). Aceita targets opcionais.
# mise run generate --fast: Tuist Cloud binary cache + skip checks.
# Se não houver login no Tuist Cloud, tenta `tuist auth login` automaticamente;
# se falhar/o user cancelar, cai em --optional-auth (sem cache).
# Recover from tuist 4.181+ manifest cache rename conflict.
# Parses stderr for `Can't rename '.../Manifests/.tmp-XXX' to '.../Manifests/1.<hash>'`
# plus `File exists` / `renamex_np`, then deletes the offending file. Returns 0 if
# recovery was applied (caller should retry), 1 otherwise.
_mx_recover_manifest_conflict() {
    local log="${1:?}"
    local hash
    hash=$(grep -oE "Manifests/1\.[a-f0-9]{32}" "$log" 2>/dev/null | head -1 | sed 's|Manifests/||')
    [[ -z "$hash" ]] && return 1
    local target="$HOME/.cache/tuist/Manifests/$hash"
    [[ -e "$target" ]] || return 1
    echo "🧹 mx: manifest cache conflict em $hash — a apagar e tentar de novo…" >&2
    rm -f "$target" "$HOME/.cache/tuist/Manifests/.tmp-"*(N) 2>/dev/null
    return 0
}

_mx_mise_generate_fast() {
    local r="${1:?}" targets="${2:-}"
    _mx_ensure_fast_generate_ok "$r"

    if [[ ! -f "$HOME/.config/tuist/credentials/tuist.dev.json" ]]; then
        echo "🔑 mx: sem login Tuist Cloud — a correr \`tuist auth login\` automaticamente (abre o browser)…"
        if ! (cd "$r" && tuist auth login); then
            echo "⚠️  mx: tuist auth login falhou/foi cancelado — a continuar sem binary cache (--optional-auth)."
        fi
    fi

    if _mx_package_resolved_changed "$r"; then
        echo "📦 mx: Package.resolved mudou — a correr \`tuist install\`…"
        (cd "$r" && tuist install) || echo "⚠️  mx: tuist install falhou — a tentar generate na mesma."
    fi

    local cmd="mise run generate --fast --no-open --close-xcode"
    if [[ ! -f "$HOME/.config/tuist/credentials/tuist.dev.json" ]]; then
        cmd+=" --optional-auth"
    fi
    [[ -n "$targets" ]] && cmd+=" --targets $targets"

    local log
    log=$(mktemp "${TMPDIR:-/tmp}/mx-generate.XXXXXX")
    local rc
    (cd "$r" && command $=cmd) 2>&1 | tee "$log"
    rc=${pipestatus[1]}
    if [[ $rc -ne 0 ]] && _mx_recover_manifest_conflict "$log"; then
        echo "🔁 mx: a repetir mise generate após recuperação do cache…" >&2
        (cd "$r" && command $=cmd) 2>&1 | tee "$log"
        rc=${pipestatus[1]}
    fi
    rm -f "$log"
    return $rc
}

# Auto-detecta estado partido e auto-repara antes de gerar/abrir Xcode.
# Checks rápidos (<200ms típico):
#   1. Tuist manifests `.tmp-*` orphan → apagar silenciosamente.
#   2. build.db: sqlite3 integrity_check — se falhar, kxd automático (graph + zombies).
#   3. Frameworks zombie (module.modulemap com -Swift.h mas sem o header) → apagar.
# Se houver corrupção grave, o mx não falha; só avisa e corrige o suficiente.
_mx_auto_fix_broken_state() {
    _mx_cache_clean_tuist_manifest_orphans

    local dd db bad=0 zombies=0
    while IFS= read -r dd; do
        [[ -z "$dd" ]] && continue
        db="$dd/Build/Intermediates.noindex/XCBuildData/build.db"
        if [[ -f "$db" ]]; then
            if ! sqlite3 "$db" "PRAGMA integrity_check;" 2>/dev/null | grep -q "^ok$"; then
                echo "⚠️  mx: build.db corrompida em $(basename "$dd") — auto-fix…"
                _mx_kill_xcode_build_system_daemons
                rm -rf \
                    "$dd/Build/Intermediates.noindex/XCBuildData" \
                    "$dd/Build/Intermediates.noindex/PIFCache" \
                    "$dd/Build/Intermediates.noindex/BuildDescriptionCache" \
                    2>/dev/null
                bad=$((bad+1))
            fi
        fi
        local fw
        while IFS= read -r fw; do
            [[ -z "$fw" ]] && continue
            rm -rf "$fw"
            zombies=$((zombies+1))
        done < <(_mx_find_broken_frameworks "$dd")
    done < <(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -type d -name 'Pinterest-*' 2>/dev/null)

    (( zombies > 0 )) && echo "⚠️  mx: $zombies framework(s) zombie apagados (module.modulemap sem -Swift.h)"
    (( bad + zombies > 0 )) && echo "💡 mx: se o build voltar a falhar em cascata → \`mxc db --deep\`"
    return 0
}

_mx_fn() {
    local _force=0 _targets=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force) _force=1; shift ;;
            *) _targets="$1"; shift ;;
        esac
    done

    local _repo _ws
    _repo=$(_mx_repo)
    if [[ -z "$_repo" ]]; then
        echo "❌ mx: corre dentro da pasta do clone (git). PWD=$PWD" >&2
        return 1
    fi
    _ws=$(_mx_workspace "$_repo")

    echo "🛑 mx: $(basename "$_repo") → $(basename "$_ws" .xcworkspace)"
    _mx_cache_warn_if_over
    _mx_warn_warm_stale

    # Auto-detect build.db corruption (disk I/O error) + Tuist manifest orphans.
    # Se houver, auto-fix antes de qualquer coisa — senão generate/build falha em cascata.
    _mx_auto_fix_broken_state

    local _needs_generate=0
    if [[ "$_force" == 1 ]] || _mx_project_changed "$_repo" "$_ws"; then
        _needs_generate=1
    fi

    if [[ "$_needs_generate" == 1 ]]; then
        # Só mata Xcode se vamos regenerar — evita reindex desnecessário.
        _mx_quit_xcode

        # Fase 1 warmup: boot sim em paralelo ao generate (não depende do projeto).
        _mx_warmup_presim

        [[ "$_force" == 1 ]] && echo "📦 mx --force — regenerating…" || echo "📦 Project changed — mise generate --fast --no-open…"
        if _mx_mise_generate_fast "$_repo" "$_targets"; then
            _mx_stamp_update "$_repo"
        else
            echo "❌ mx failed. Run \`make tuist\` in $_repo or fix the error above."
            return 1
        fi
    else
        echo "⚡ No project changes — skipping generate, keeping Xcode alive"
        # Warmup do sim mesmo sem generate (idempotente).
        _mx_warmup_presim
    fi

    [[ -e "$_ws" ]] || {
        echo "❌ Workspace não encontrado: $_ws"
        return 1
    }

    # Se não regenerou, mas o workspace foi regenerado externamente (ex: make tuist_sandbox),
    # o Xcode precisa reabrir para pegar o projeto novo.
    if [[ "$_needs_generate" == 0 ]] && pgrep -x Xcode >/dev/null 2>&1; then
        local _ws_mtime _stamp_file _stamp_mtime
        _stamp_file="/tmp/mx-last-xcode-open-$(md5 -qs "$_repo")"
        _ws_mtime=$(stat -f %m "$_ws/contents.xcworkspacedata" 2>/dev/null || echo 0)
        _stamp_mtime=$(stat -f %m "$_stamp_file" 2>/dev/null || echo 0)
        if [[ "$_ws_mtime" -gt "$_stamp_mtime" ]]; then
            echo "🔄 mx: workspace regenerado externamente — reabrindo Xcode"
            _mx_quit_xcode
        else
            echo "✓ mx: Xcode já aberto, index preservado — nada a fazer"
            return 0
        fi
    fi

    _mx_clear_xcode_saved_application_state
    # Mata SourceKitService antes de abrir — Xcode relança-o com estado limpo.
    # Cura "red lines fantasma" / erros de editor stale sem apagar Index.noindex.
    killall SourceKitService 2>/dev/null && echo "🧹 mx: SourceKit reset — editor errors limpos"
    # Apaga build logs antigos → Issue Navigator abre vazio (sem erros stale da sessão anterior).
    # Logs/Build é recriado no próximo Cmd+B. Não toca em Build/ nem Index.noindex.
    find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -type d -name 'Pinterest-*' -exec rm -rf {}/Logs/Build \; 2>/dev/null
    _mx_pin_scheme_default "$_repo"

    local _scheme
    _scheme=$(_mx_scheme_from_targets "$_targets")

    # Fase 2 warmup: SPM resolve + package graph + scheme metadata em paralelo com xed.
    # Precisa do workspace já pronto (por isso não rodou em paralelo com generate).
    _mx_warmup_postgen "$_repo" "$_ws" "$_scheme"

    xed "$_ws"
    touch "/tmp/mx-last-xcode-open-$(md5 -qs "$_repo")"

    _mx_maybe_reset_build_for_new_head "$_repo" "$_ws"

    echo "✓ mx: a definir scheme $_scheme + sim ($MX_PIN_SIM_SUBSTR)…"
    sleep 2
    local asr ose
    ose=$(mktemp "${TMPDIR:-/tmp}/mx-osa-err.XXXXXX")
    asr=$(_mx_xcode_set_scheme_and_destination "$_ws" "$_scheme" 2>"$ose" | head -1 | tr -d '\r') || true
    [[ -s "$ose" ]] && { echo "mx (AppleScript stderr):" >&2; cat "$ose" >&2; }
    rm -f "$ose"
    case "${asr%%$'\n'}" in
        ""|no_scheme|timeout_load|scheme_set:*)
            echo "⌛ mx: a repetir seleção de scheme…" >&2
            sleep 2
            ose=$(mktemp "${TMPDIR:-/tmp}/mx-osa-err.XXXXXX")
            asr=$(_mx_xcode_set_scheme_and_destination "$_ws" "$_scheme" 2>"$ose" | head -1 | tr -d '\r') || true
            [[ -s "$ose" ]] && cat "$ose" >&2
            rm -f "$ose"
            ;;
    esac
    case "${asr%%$'\n'}" in
        ok)                 echo "✓ mx: $_scheme · sim $MX_PIN_SIM_SUBSTR (sem dispositivo físico)" ;;
        sim_any)            echo "✓ mx: $_scheme · primeiro simulador iOS (sem $MX_PIN_SIM_SUBSTR nem device USB)" ;;
        no_destination)    echo "✓ mx: scheme $_scheme (sem simulador na lista — escolhe destino no Xcode)" ;;
        *)                  echo "⚠️  mx: scheme/destino falhou (${asr:-error}) — workspace $(basename "$_ws")" >&2 ;;
    esac
    return 0
}

mx() { time (_mx_fn "$@"); }

# Detecta o módulo ativo a partir de git status.
# Ecoa a lista única de prefixos `(Feature|FeatureLibrary|Library|Platform)/<Name>` (1 por linha).
# Vazio se não houver mudanças / não casarem com um módulo.
_mx_detect_active_module() {
    local repo="${1:?}"
    (cd "$repo" && git status --porcelain 2>/dev/null) \
        | awk '{print $NF}' \
        | grep -oE '^(Feature|FeatureLibrary|Library|Platform)/[^/]+' \
        | sort -u
}

# mxa — mx com auto-detecção do módulo ativo a partir de git status.
#   0 módulos detectados -> fallback mx (PinterestDevelopment)
#   1 módulo detectado   -> mx <Modulo>
#   N módulos detectados -> lista candidatos e pede escolha (fallback mx sem arg se o user não escolher)
# Flags `-f`/`--force` são passadas a mx.
unalias mxa 2>/dev/null
_mxa_fn() {
    local _forwarded=()
    while [[ $# -gt 0 ]]; do
        _forwarded+=("$1"); shift
    done
    local repo
    repo=$(_mx_repo)
    if [[ -z "$repo" ]]; then
        echo "❌ mxa: corre dentro da pasta do clone (git). PWD=$PWD" >&2
        return 1
    fi
    local modules
    modules=$(_mx_detect_active_module "$repo")
    local count
    count=$(echo "$modules" | sed '/^$/d' | wc -l | tr -d ' ')
    case "$count" in
        0)
            echo "ℹ️  mxa: sem módulo ativo detectado no git status → fallback mx (PinterestDevelopment)"
            _mx_fn "${_forwarded[@]}"
            ;;
        1)
            echo "🎯 mxa: módulo ativo = $modules"
            _mx_fn "${_forwarded[@]}" "$modules"
            ;;
        *)
            echo "⚠️  mxa: múltiplos módulos modificados:"
            echo "$modules" | sed 's/^/  - /'
            echo -n "→ escolhe um (Enter = fallback PinterestDevelopment): "
            local choice
            read -r choice
            if [[ -n "$choice" ]]; then
                _mx_fn "${_forwarded[@]}" "$choice"
            else
                _mx_fn "${_forwarded[@]}"
            fi
            ;;
    esac
}
mxa() { time (_mxa_fn "$@"); }

# mxw — pre-aquece o binary cache do Tuist e depois corre mx.
# Útil uma vez por semana ou após rebase/merge pesado em master.
#   mxw                     -> cache warm only-external (deps externas) + mx
#   mxw all                 -> cache warm all-possible (tudo cacheável)  + mx
#   mxw Feature/Foo         -> warm only-external + mx Feature/Foo
#   mxw all Feature/Foo     -> warm all-possible  + mx Feature/Foo
unalias mxw 2>/dev/null
_mxw_fn() {
    local _profile="only-external"
    local _mx_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            all|--all) _profile="all-possible"; shift ;;
            external|--external|only-external) _profile="only-external"; shift ;;
            *) _mx_args+=("$1"); shift ;;
        esac
    done
    local repo
    repo=$(_mx_repo)
    if [[ -z "$repo" ]]; then
        echo "❌ mxw: corre dentro da pasta do clone (git). PWD=$PWD" >&2
        return 1
    fi
    # Garante credenciais antes do warm (reusa a lógica do mx).
    if [[ ! -f "$HOME/.config/tuist/credentials/tuist.dev.json" ]]; then
        echo "🔑 mxw: sem login Tuist Cloud — a correr \`tuist auth login\`…"
        if ! (cd "$repo" && tuist auth login); then
            echo "❌ mxw: sem cache sem login. Abortar."
            return 1
        fi
    fi
    echo "🔥 mxw: tuist cache warm --cache-profile $_profile PinterestDevelopment @ $(basename "$repo")"
    if ! (cd "$repo" && tuist cache warm --cache-profile "$_profile" PinterestDevelopment); then
        echo "⚠️  mxw: warm falhou — a seguir para mx (ainda assim)."
    else
        echo "✅ mxw: warm ($_profile) concluído."
    fi
    _mx_fn "${_mx_args[@]}"
}
mxw() { time (_mxw_fn "$@"); }

# ─── mxc — cache hygiene (DerivedData + Tuist binaries) ────────────────────────
# Caps configuráveis: MX_DD_CAP_GB (default 80), MX_TUIST_BIN_CAP_GB (default 8),
# MX_DD_STALE_DAYS (default 14).
#   mxc            -> mxc status
#   mxc status     -> mostra tamanhos vs caps + workspaces stale
#   mxc trim       -> apaga Pinterest-* DerivedData stale (> MX_DD_STALE_DAYS) +
#                     se Tuist binaries > cap, corre `tuist clean binaries`
#   mxc nuke       -> apaga TUDO de DerivedData/Pinterest-* + tuist clean binaries
#                     (com confirmação). Não toca em ModuleCache.noindex.
#   mxc nuke --all -> + ModuleCache.noindex (rebuild caro a seguir).
_mx_size_bytes() {
    local p="${1:?}"
    [[ -e "$p" ]] || { echo 0; return; }
    du -sk "$p" 2>/dev/null | awk '{print $1*1024}'
}
_mx_human_gb() {
    awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b/1024/1024/1024 }'
}
_mx_cache_summary() {
    local dd="$HOME/Library/Developer/Xcode/DerivedData"
    local tb="$HOME/.cache/tuist/Binaries"
    local dd_b tb_b mc_b
    dd_b=$(_mx_size_bytes "$dd")
    tb_b=$(_mx_size_bytes "$tb")
    mc_b=$(_mx_size_bytes "$dd/ModuleCache.noindex")
    local dd_gb tb_gb mc_gb
    dd_gb=$(_mx_human_gb "$dd_b")
    tb_gb=$(_mx_human_gb "$tb_b")
    mc_gb=$(_mx_human_gb "$mc_b")
    local dd_warn="" tb_warn=""
    awk -v g="$dd_gb" -v c="$MX_DD_CAP_GB" 'BEGIN{exit !(g+0 > c+0)}' && dd_warn="  ⚠️  > cap (${MX_DD_CAP_GB} GB)"
    awk -v g="$tb_gb" -v c="$MX_TUIST_BIN_CAP_GB" 'BEGIN{exit !(g+0 > c+0)}' && tb_warn="  ⚠️  > cap (${MX_TUIST_BIN_CAP_GB} GB)"
    echo "📦 Cache status:"
    printf "  DerivedData total:   %6s GB / cap %s GB%s\n" "$dd_gb" "$MX_DD_CAP_GB" "$dd_warn"
    printf "    └─ ModuleCache:    %6s GB  (não tocar — regenera caro)\n" "$mc_gb"
    printf "  Tuist binaries:      %6s GB / cap %s GB%s\n" "$tb_gb" "$MX_TUIST_BIN_CAP_GB" "$tb_warn"
    if [[ -d "$dd" ]]; then
        echo "  Workspaces (Pinterest-*):"
        local now_ts ws ts age_days size_h
        now_ts=$(date +%s)
        for ws in "$dd"/Pinterest-*; do
            [[ -d "$ws" ]] || continue
            ts=$(stat -f %m "$ws" 2>/dev/null || echo "$now_ts")
            age_days=$(( (now_ts - ts) / 86400 ))
            size_h=$(du -sh "$ws" 2>/dev/null | awk '{print $1}')
            local stale=""
            (( age_days > MX_DD_STALE_DAYS )) && stale=" 💤 STALE (${age_days}d)"
            printf "    • %-50s %6s   touched ${age_days}d ago%s\n" "$(basename "$ws")" "$size_h" "$stale"
        done
    fi
}
_mx_cache_warn_if_over() {
    local dd_gb tb_gb
    dd_gb=$(_mx_human_gb "$(_mx_size_bytes "$HOME/Library/Developer/Xcode/DerivedData")")
    tb_gb=$(_mx_human_gb "$(_mx_size_bytes "$HOME/.cache/tuist/Binaries")")
    awk -v g="$dd_gb" -v c="$MX_DD_CAP_GB" 'BEGIN{exit !(g+0 > c+0)}' \
        && echo "💡 mx: DerivedData ${dd_gb} GB > cap ${MX_DD_CAP_GB} GB — corre \`mxc trim\`."
    awk -v g="$tb_gb" -v c="$MX_TUIST_BIN_CAP_GB" 'BEGIN{exit !(g+0 > c+0)}' \
        && echo "💡 mx: Tuist binaries ${tb_gb} GB > cap ${MX_TUIST_BIN_CAP_GB} GB — corre \`mxc trim\`."
    return 0
}
_mx_cache_trim() {
    local dd="$HOME/Library/Developer/Xcode/DerivedData"
    local now_ts ws ts age_days trimmed=0
    now_ts=$(date +%s)
    if [[ -d "$dd" ]]; then
        for ws in "$dd"/Pinterest-*; do
            [[ -d "$ws" ]] || continue
            ts=$(stat -f %m "$ws" 2>/dev/null || echo "$now_ts")
            age_days=$(( (now_ts - ts) / 86400 ))
            if (( age_days > MX_DD_STALE_DAYS )); then
                echo "🗑  trim: $(basename "$ws") (${age_days}d sem mtime)"
                rm -rf "$ws"
                trimmed=1
            fi
        done
    fi
    (( trimmed == 0 )) && echo "✅ trim: nenhum workspace DD stale (> ${MX_DD_STALE_DAYS}d)."
    local tb_gb
    tb_gb=$(_mx_human_gb "$(_mx_size_bytes "$HOME/.cache/tuist/Binaries")")
    if awk -v g="$tb_gb" -v c="$MX_TUIST_BIN_CAP_GB" 'BEGIN{exit !(g+0 > c+0)}'; then
        local repo
        repo=$(_mx_repo)
        if [[ -n "$repo" ]]; then
            echo "🗑  trim: Tuist binaries ${tb_gb} GB > cap ${MX_TUIST_BIN_CAP_GB} GB → tuist clean binaries"
            (cd "$repo" && tuist clean binaries) || echo "⚠️  trim: tuist clean binaries falhou."
        else
            echo "⚠️  trim: tuist binaries excedem cap mas estás fora de um repo Pinterest — corre \`tuist clean binaries\` dentro do repo."
        fi
    else
        echo "✅ trim: Tuist binaries ${tb_gb} GB ≤ cap ${MX_TUIST_BIN_CAP_GB} GB."
    fi
}
# Limpa manifest cache orphan do Tuist (rename conflict `.tmp-XXX` → `1.<hash>`).
# Quando `tuist` morre a meio (Ctrl-C ou crash do build), deixa `.tmp-*` + `1.<hash>` parcial.
# Chamado pelo mxc db + kxd + auto-recovery no mx.
_mx_cache_clean_tuist_manifest_orphans() {
    local mdir="$HOME/.cache/tuist/Manifests"
    [[ -d "$mdir" ]] || return 0
    local removed=0
    local f
    for f in "$mdir"/.tmp-*(N); do
        rm -f "$f" 2>/dev/null && removed=$((removed+1))
    done
    (( removed > 0 )) && echo "   ✓ Tuist manifests: $removed .tmp-* orphan(s) apagado(s)"
    return 0
}

# Detecta frameworks "broken" em Build/Products: têm module.modulemap mas falta -Swift.h
# ou .swiftmodule. Quando build.db corrompe a meio de escrever, fica este estado zombie:
# próximas builds falham infinitamente com "header 'X-Swift.h' not found".
# Retorna lista de paths de frameworks a apagar (um por linha).
# Detecta DerivedData duplicados para o mesmo workspace e remove os mais antigos
# (preserva o de maior mtime). Causa nº 1 de re-indexação total e "falsos erros"
# em cascata: Xcode oscila entre 2+ Pinterest-<hash> conforme abres
# Pinterest.xcworkspace vs PinterestDevelopment.xcworkspace vs tuist regen —
# cada flip invalida Index.noindex inteiro, SourceKit mostra erros fantasma até
# reindexar (pode demorar horas num repo de 13 GB de index).
_mx_dd_dedupe() {
    local base="$HOME/Library/Developer/Xcode/DerivedData"
    [[ -d "$base" ]] || return 0
    local dd newest_mtime=0 newest=""
    local -a pin_dds
    while IFS= read -r dd; do
        [[ -z "$dd" ]] && continue
        pin_dds+=("$dd")
    done < <(find "$base" -maxdepth 1 -type d -name 'Pinterest-*' 2>/dev/null)

    local n=${#pin_dds[@]}
    if (( n <= 1 )); then
        echo "ℹ️  mxc dd-dedupe: $n Pinterest-* DerivedData. Nada a fazer."
        return 0
    fi

    # Encontra o mais recente por mtime.
    for dd in "${pin_dds[@]}"; do
        local m
        m=$(stat -f %m "$dd" 2>/dev/null)
        [[ -z "$m" ]] && m=0
        if (( m > newest_mtime )); then
            newest_mtime=$m
            newest=$dd
        fi
    done

    echo "🔍 mxc dd-dedupe: $n Pinterest-* DerivedData encontrados."
    echo "   manter: $(basename "$newest") ($(du -sh "$newest" 2>/dev/null | cut -f1))"
    local victim removed=0 freed_total=0
    for dd in "${pin_dds[@]}"; do
        [[ "$dd" == "$newest" ]] && continue
        victim=$dd
        local size_h size_b
        size_h=$(du -sh "$victim" 2>/dev/null | cut -f1)
        size_b=$(du -sk "$victim" 2>/dev/null | awk '{print $1}')
        echo "   remover: $(basename "$victim") ($size_h)"
        rm -rf "$victim" 2>/dev/null
        removed=$((removed+1))
        freed_total=$((freed_total + ${size_b:-0}))
    done
    local freed_gb
    freed_gb=$(awk -v k=$freed_total 'BEGIN{printf "%.1f", k/1024/1024}')
    echo "✅ mxc dd-dedupe: $removed duplicado(s) removido(s), ${freed_gb} GB libertados."
    echo "   Abre SÓ um workspace (preferencialmente PinterestDevelopment.xcworkspace)"
    echo "   para evitar recriar duplicados."
}

# Reset SÓ do index-store (Index.noindex) sem tocar no build. Usa quando:
#   - Xcode fica eternamente "Indexing" / "Processing files"
#   - SourceKit mostra erros vermelhos mas Cmd+B compila OK (red lines fantasma)
#   - autocomplete quebrado, jump-to-definition falha
# Preserva: Build/ (products + intermediates + swiftmodules), ModuleCache,
# SourcePackages, Manifests. Re-index demora minutos (não horas) porque os
# .swiftmodule já existem e o IndexStoresByPath é reconstruído a partir deles.
_mx_cache_reset_index() {
    echo "🔧 mxc index-reset: apagar Index.noindex (mantém Build/ModuleCache/SourcePackages)…"
    local dd count=0 freed_kb=0
    while IFS= read -r dd; do
        [[ -z "$dd" ]] && continue
        if [[ -d "$dd/Index.noindex" ]]; then
            local sz
            sz=$(du -sk "$dd/Index.noindex" 2>/dev/null | awk '{print $1}')
            freed_kb=$((freed_kb + ${sz:-0}))
            rm -rf "$dd/Index.noindex" 2>/dev/null
            echo "   ✓ $(basename "$dd") — Index.noindex apagado"
            count=$((count+1))
        fi
    done < <(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -type d -name 'Pinterest-*' 2>/dev/null)

    if (( count == 0 )); then
        echo "ℹ️  nenhum Index.noindex encontrado."
        return 0
    fi
    local freed_gb
    freed_gb=$(awk -v k=$freed_kb 'BEGIN{printf "%.1f", k/1024/1024}')
    echo "✅ mxc index-reset: $count workspace(s), ${freed_gb} GB libertados."
    echo "   Próximo Cmd+B é normal; index popula em background em poucos minutos."
}

# Aplica defaults do Xcode que reduzem falsos positivos do editor.
# Chamado uma vez manualmente (mxc xcprefs) ou implícito via `mxc doctor --fix`.
# Nota: IDEIndexDisable=YES **não** desliga o index — só desliga "live issues"
# (erros em tempo real enquanto escreves). Build issues (Cmd+B) continuam a
# aparecer. Isto é a cura real para o 90% dos falsos-erros em monorepos.
_mx_apply_xcode_prefs() {
    echo "🔧 mxc xcprefs: aplicar defaults que reduzem falsos erros…"
    # Desliga "Live Issues" (analysis inline enquanto escreves). Cmd+B continua normal.
    defaults write com.apple.dt.Xcode IDEIndexDisable -bool NO
    defaults write com.apple.dt.Xcode IDEIndexShowLog -bool NO
    defaults write com.apple.dt.Xcode IDEIndexEnableBuildArena -bool YES
    # Prioriza .swiftmodule sobre re-parse quando disponível (menos fantasmas).
    defaults write com.apple.dt.Xcode IDEIndexerActivityShowNumericProgress -bool YES
    # Reduz número de targets indexados em paralelo (menos contenção no disco).
    defaults write com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks -int 16
    # Desliga "Show Live Issues" toggle (source of 90% dos falsos vermelhos).
    defaults write com.apple.dt.Xcode IDEIssueNavigatorShowsLiveIssues -bool NO
    # Mantém os warnings de build (os que interessam) no Issue Navigator.
    defaults write com.apple.dt.Xcode IDEIssueNavigatorShowsAllIssues -bool YES
    echo "✅ mxc xcprefs aplicado. Fecha/reabre o Xcode para pegar."
    echo "   Para reverter: mxc xcprefs-reset"
}

_mx_reset_xcode_prefs() {
    echo "↩️  mxc xcprefs-reset: repor defaults de Live Issues…"
    defaults delete com.apple.dt.Xcode IDEIssueNavigatorShowsLiveIssues 2>/dev/null
    defaults delete com.apple.dt.Xcode IDEIndexShowLog 2>/dev/null
    defaults delete com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks 2>/dev/null
    echo "✅ defaults de Live Issues removidos."
}

_mx_find_broken_frameworks() {
    local dd="${1:?}"
    local products="$dd/Build/Products"
    [[ -d "$products" ]] || return 0
    local fw mm name
    find "$products" -maxdepth 3 -type d -name '*.framework' 2>/dev/null | while read -r fw; do
        mm="$fw/Modules/module.modulemap"
        [[ -f "$mm" ]] || continue
        name=$(basename "$fw" .framework)
        if grep -q "${name}-Swift.h" "$mm" 2>/dev/null && [[ ! -f "$fw/Headers/${name}-Swift.h" ]]; then
            echo "$fw"
        fi
    done
}

# Fix para: error: accessing build database "…/XCBuildData/build.db": disk I/O error
# Modo default (leve):
#   - mata XCBBuildService/SWBBuildService
#   - apaga XCBuildData/PIFCache/BuildDescriptionCache
#   - apaga frameworks zombie (module.modulemap sem -Swift.h) — corrige "header X-Swift.h not found"
#   - limpa manifest cache orphan do Tuist (.tmp-* do rename conflict)
# Modo --deep:
#   - + apaga Build/Products (todos os frameworks compilados)
#   - + apaga Build/Intermediates.noindex/*.build (objectos/swiftmodules)
#   - Mantém sempre: ModuleCache.noindex, SourcePackages, SwiftExplicitPrecompiledModules,
#     CompilationCache.noindex, Index.noindex → rebuild incremental rápido.
_mx_cache_fix_build_db() {
    local deep=0
    [[ "${1:-}" == "--deep" || "${1:-}" == "-d" ]] && deep=1

    if (( deep )); then
        echo "🔧 mxc db --deep: corrigir build.db + apagar Products/Intermediates (mantém ModuleCache/SourcePackages)…"
    else
        echo "🔧 mxc db: corrigir build database corrompida (disk I/O error)…"
    fi
    _mx_kill_xcode_build_system_daemons

    local dd count=0 broken_total=0
    while IFS= read -r dd; do
        [[ -z "$dd" ]] && continue
        rm -rf \
            "$dd/Build/Intermediates.noindex/XCBuildData" \
            "$dd/Build/Intermediates.noindex/PIFCache" \
            "$dd/Build/Intermediates.noindex/BuildDescriptionCache" \
            2>/dev/null

        if (( deep )); then
            rm -rf "$dd/Build/Products" 2>/dev/null
            local intdir="$dd/Build/Intermediates.noindex"
            if [[ -d "$intdir" ]]; then
                find "$intdir" -maxdepth 1 -type d -name '*.build' -exec rm -rf {} + 2>/dev/null
            fi
        else
            # Modo leve: apagar só frameworks zombie (módulo sem -Swift.h).
            local fw broken=0
            while IFS= read -r fw; do
                [[ -z "$fw" ]] && continue
                rm -rf "$fw"
                broken=$((broken+1))
            done < <(_mx_find_broken_frameworks "$dd")
            if (( broken > 0 )); then
                echo "   ✓ $broken framework(s) zombie apagados em $(basename "$dd")"
                broken_total=$((broken_total+broken))
            fi
        fi

        count=$((count+1))
        echo "   ✓ $(basename "$dd") — graph apagado"
    done < <(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -type d -name 'Pinterest-*' 2>/dev/null)

    _mx_cache_clean_tuist_manifest_orphans

    if (( count == 0 )); then
        echo "ℹ️  nenhum Pinterest-* DerivedData encontrado."
        return 0
    fi
    if (( deep )); then
        echo "✅ mxc db --deep: $count workspace(s). Products + Intermediates apagados; ModuleCache/SourcePackages preservados."
    elif (( broken_total > 0 )); then
        echo "✅ mxc db: $count workspace(s), $broken_total framework(s) zombie fixos. Se continuar a falhar → \`mxc db --deep\`."
    else
        echo "✅ mxc db: $count workspace(s). ModuleCache/SourcePackages/Products preservados. Se continuar a falhar → \`mxc db --deep\`."
    fi
}

_mx_cache_nuke() {
    local include_modulecache=0
    [[ "${1:-}" == "--all" ]] && include_modulecache=1
    echo "⚠️  mxc nuke vai apagar:"
    echo "   - $HOME/Library/Developer/Xcode/DerivedData/Pinterest-*"
    echo "   - tuist clean binaries (no repo atual)"
    (( include_modulecache == 1 )) && echo "   - $HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex (rebuild caro)"
    echo -n "Confirma (y/N)? "
    local ans
    read -r ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Cancelado."; return 0; }
    rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/Pinterest-*
    (( include_modulecache == 1 )) && rm -rf "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex"
    local repo
    repo=$(_mx_repo)
    [[ -n "$repo" ]] && (cd "$repo" && tuist clean binaries) || echo "⚠️  fora de repo Pinterest — pula tuist clean."
    echo "✅ mxc nuke concluído. Próximo build será pesado (warm com \`mxw\`)."
}
# Detecta se Package.resolved mudou desde o último mx → corremos `tuist install` antes de gerar.
# Stamp em /tmp/mx-pkgresolved-<repo-hash>.
_mx_package_resolved_changed() {
    local repo="${1:?}"
    local pkg="$repo/Tuist/Package.resolved"
    [[ -e "$pkg" ]] || pkg="$repo/Package.resolved"
    [[ -e "$pkg" ]] || return 1
    local key stamp prev cur
    key="$(echo -n "$repo" | shasum | awk '{print $1}')"
    stamp="${TMPDIR:-/tmp}/mx-pkgresolved-$key"
    cur=$(shasum "$pkg" 2>/dev/null | awk '{print $1}')
    [[ -z "$cur" ]] && return 1
    prev=$(cat "$stamp" 2>/dev/null || true)
    if [[ "$prev" != "$cur" ]]; then
        echo "$cur" > "$stamp"
        [[ -n "$prev" ]] && return 0
    fi
    return 1
}

# Avisa se binary cache local está stale (sem mtime há > MX_WARM_STALE_DAYS).
_mx_warn_warm_stale() {
    local bin="$HOME/.cache/tuist/Binaries"
    [[ -d "$bin" ]] || return 0
    local now ts age
    now=$(date +%s)
    ts=$(stat -f %m "$bin" 2>/dev/null || echo "$now")
    age=$(( (now - ts) / 86400 ))
    if (( age > MX_WARM_STALE_DAYS )); then
        echo "💡 mx: binary cache local sem mtime há ${age}d — considera \`mxw\` (warm) pra evitar download lento on-demand."
    fi
}

# ─── mxs — system setup pra build máxima (idempotente) ─────────────────────────
# Aplica defaults Xcode + exclusões de Spotlight + Time Machine para acelerar builds.
#   mxs                 -> mxs status
#   mxs status          -> mostra estado actual (TM, Spotlight, Xcode defaults)
#   mxs apply           -> aplica tudo (idempotente; safe)
_mxs_status() {
    local dd="$HOME/Library/Developer/Xcode/DerivedData"
    local tb="$HOME/.cache/tuist"
    local xc="$HOME/Library/Caches/com.apple.dt.Xcode"
    local p k r s v sleep_v
    local keys=(
        IDEBuildOperationMaxNumberOfConcurrentCompileTasks
        IDEBuildOperationMaxNumberOfConcurrentLinkTasks
        IDEPackageOnlyUseVersionsFromResolvedFile
    )
    echo "🛠  mxs status:"
    echo "  CPU:                 $(sysctl -n hw.physicalcpu) physical / $(sysctl -n hw.logicalcpu) logical"
    echo "  RAM:                 $(awk -v b=$(sysctl -n hw.memsize) 'BEGIN{printf "%.0f GB", b/1024/1024/1024}')"
    echo "  Disk free:           $(df -h /System/Volumes/Data | awk 'NR==2{print $4" of "$2}')"
    echo "  TM excluded:"
    for p in "$dd" "$tb" "$xc"; do
        r=$(tmutil isexcluded "$p" 2>&1)
        printf "    %s\n" "$r"
    done
    echo "  Spotlight indexing (.metadata_never_index sentinel):"
    for p in "$dd" "$tb"; do
        if [[ -f "$p/.metadata_never_index" ]]; then
            printf "    %s → ✓ never_index\n" "$p"
        else
            printf "    %s → ✗ (será indexado)\n" "$p"
        fi
    done
    echo "  Xcode defaults:"
    for k in "${keys[@]}"; do
        v=$(defaults read com.apple.dt.Xcode "$k" 2>/dev/null || echo "(unset)")
        printf "    %-55s = %s\n" "$k" "$v"
    done
    sleep_v=$(defaults read NSGlobalDomain NSAppSleepDisabled 2>/dev/null || echo "(unset)")
    printf "    %-55s = %s\n" "NSGlobalDomain NSAppSleepDisabled" "$sleep_v"
}
_mxs_apply() {
    local ncpu
    ncpu=$(sysctl -n hw.logicalcpu)
    local dd="$HOME/Library/Developer/Xcode/DerivedData"
    local tb="$HOME/.cache/tuist"
    local xc="$HOME/Library/Caches/com.apple.dt.Xcode"
    mkdir -p "$dd" "$tb"

    echo "🛠  mxs apply:"

    echo "  → Time Machine: excluir DD, Tuist cache, Xcode caches"
    for p in "$dd" "$tb" "$xc"; do
        [[ -e "$p" ]] && tmutil addexclusion "$p" >/dev/null 2>&1 && echo "    ✓ excluded $p"
    done

    echo "  → Spotlight: criar .metadata_never_index sentinel (sem sudo, Sequoia-correct)"
    for p in "$dd" "$tb"; do
        touch "$p/.metadata_never_index" && echo "    ✓ never_index: $p"
    done

    echo "  → Xcode defaults:"
    defaults write com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks -int "$ncpu"
    echo "    ✓ IDEBuildOperationMaxNumberOfConcurrentCompileTasks = $ncpu"
    defaults write com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentLinkTasks -int "$ncpu"
    echo "    ✓ IDEBuildOperationMaxNumberOfConcurrentLinkTasks = $ncpu"
    defaults delete com.apple.dt.Xcode IDEDisableStateRestoration 2>/dev/null
    echo "    ✓ IDEDisableStateRestoration removido (scheme/destination persistem entre sessões)"
    defaults write com.apple.dt.Xcode IDEPackageOnlyUseVersionsFromResolvedFile -bool YES
    echo "    ✓ IDEPackageOnlyUseVersionsFromResolvedFile = YES (não auto-resolve SPM)"
    defaults write NSGlobalDomain NSAppSleepDisabled -bool YES
    echo "    ✓ NSAppSleepDisabled = YES (Xcode não throttle em background)"

    echo "✅ mxs apply concluído. Reinicia Xcode pra apanhar defaults."
}
unalias mxs 2>/dev/null
mxs() {
    case "${1:-status}" in
        ""|status|s) _mxs_status ;;
        apply|a)     _mxs_apply ;;
        *)
            cat <<'EOF'
mxs — system setup pra builds máximas
  mxs                  status (default)
  mxs status           CPU/RAM/disk + TM exclusions + Spotlight + Xcode defaults
  mxs apply            aplica TM exclusions + Spotlight off + Xcode defaults (sudo necessário p/ Spotlight)
EOF
            ;;
    esac
}

unalias mxc 2>/dev/null
mxc() {
    case "${1:-status}" in
        ""|status|s) _mx_cache_summary ;;
        trim|t)      _mx_cache_trim ;;
        db|fix)      shift; _mx_cache_fix_build_db "$@" ;;
        dd-dedupe|dedupe) _mx_dd_dedupe ;;
        index-reset|index|ir) _mx_cache_reset_index ;;
        xcprefs)     _mx_apply_xcode_prefs ;;
        xcprefs-reset) _mx_reset_xcode_prefs ;;
        nuke)        shift; _mx_cache_nuke "$@" ;;
        *)
            cat <<'EOF'
mxc — cache hygiene
  mxc                  status (default)
  mxc status           tamanhos vs caps + workspaces stale
  mxc trim             apaga Pinterest-<hash> DerivedData stale + tuist binaries se > cap
  mxc db               corrige build.db disk I/O error (XCBuildData/PIFCache) + frameworks
                       zombie (module.modulemap sem -Swift.h) + Tuist manifest orphans.
                       Mantém ModuleCache/SourcePackages/Products → build continua rápido.
  mxc db --deep        + apaga Build/Products + Build/Intermediates.noindex/*.build
                       (quando --deep é preciso: "Could not build module X" persiste após
                       mxc db leve, ou muitos frameworks zombie). Mantém ModuleCache.
  mxc dd-dedupe        remove Pinterest-<hash> DerivedData duplicados (mantém o mais
                       recente). Cura "re-indexação total ao trocar de workspace".
  mxc index-reset      apaga SÓ Index.noindex (mantém Build/ModuleCache). Cura:
                       "Indexing" eterno, red lines fantasma, autocomplete quebrado.
  mxc xcprefs          aplica defaults que reduzem falsos erros do editor
                       (desliga Live Issues, mantém build issues). Fecha/reabre Xcode.
  mxc xcprefs-reset    reverte mxc xcprefs.
  mxc nuke             apaga TUDO Pinterest-* DD + tuist binaries (confirma)
  mxc nuke --all       + ModuleCache.noindex (rebuild caro)

Caps (env vars):
  MX_DD_CAP_GB          (default 80)   cap total DerivedData
  MX_TUIST_BIN_CAP_GB   (default 8)    cap ~/.cache/tuist/Binaries
  MX_DD_STALE_DAYS      (default 14)   idade pra workspace ser podável
EOF
            ;;
    esac
}

# kx — com o Xcode **aberto**: só o *build system* (Swift Build + XCBuild). NÃO mata SourceKitService/SKAgent:
#   partilham com o SourceKit-LSP do Cursor/VS Code (popup “restored”) e forçam reindex/build frio demorado.
unalias kx 2>/dev/null
kx() {
    killall XCBBuildService SWBBuildService 2>/dev/null
    echo "✓ kx: XCBBuildService + SWBBuildService — Xcode relança-os; Cmd+B outra vez. (SourceKit intocado → Cursor OK)"
}

# kx_hard — reset duro: mata SourceKit também (evita com Cursor aberto; build/index no Xcode fica frio).
unalias kx_hard 2>/dev/null
kx_hard() {
    killall SourceKitService XCBBuildService SWBBuildService com.apple.dt.SKAgent 2>/dev/null
    echo "⚠️  kx_hard: SourceKit + build — Cursor/LSP pode avisar; primeiro build no Xcode costuma demorar."
}

# kxd — combo: kx (mata build daemons) + mxc db (limpa build.db + frameworks zombie + manifests).
# Usa quando o Xcode atira "build.db: disk I/O error", "build.db locked", ou erros de
# "Could not build module X / header X-Swift.h not found" em cascata após disk I/O error.
# Passa --deep pra apagar também Products/Intermediates:  kxd --deep
unalias kxd 2>/dev/null
kxd() {
    _mx_kill_xcode_build_system_daemons
    _mx_cache_fix_build_db "$@"
    echo "✓ kxd: build daemons mortos + cache reparada. Cmd+B no Xcode."
}

# mxd — doctor one-liner: "posso buildar agora?"
# Mostra estado do Xcode, DerivedData, ModuleCache, simulador, warm staleness.
unalias mxd 2>/dev/null
mxd() {
    echo "── mxd: Pinterest iOS build doctor ──"
    if pgrep -xq Xcode; then
        echo "  Xcode:        ✓ a correr"
    else
        echo "  Xcode:        — fechado"
    fi
    if pgrep -xq XCBBuildService || pgrep -xq SWBBuildService; then
        echo "  Build daemons: ✓ activos"
    else
        echo "  Build daemons: — inactivos"
    fi
    local dd dd_ok=0 dd_bad=0
    while IFS= read -r dd; do
        [[ -z "$dd" ]] && continue
        if [[ -f "$dd/Build/Intermediates.noindex/XCBuildData/build.db" ]]; then
            if sqlite3 "$dd/Build/Intermediates.noindex/XCBuildData/build.db" "PRAGMA integrity_check;" 2>/dev/null | grep -q "^ok$"; then
                dd_ok=$((dd_ok+1))
            else
                dd_bad=$((dd_bad+1))
                echo "  build.db:     ✗ CORROMPIDA em $(basename "$dd") → corre \`mxc db\`"
            fi
        fi
    done < <(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -type d -name 'Pinterest-*' 2>/dev/null)
    (( dd_bad == 0 && dd_ok > 0 )) && echo "  build.db:     ✓ ok ($dd_ok workspace(s))"
    (( dd_ok == 0 && dd_bad == 0 )) && echo "  build.db:     — ainda não criada"

    # Frameworks zombie (module.modulemap com -Swift.h declarado mas sem o header gerado).
    local zombies=0 fw
    while IFS= read -r dd; do
        [[ -z "$dd" ]] && continue
        while IFS= read -r fw; do
            [[ -z "$fw" ]] && continue
            zombies=$((zombies+1))
        done < <(_mx_find_broken_frameworks "$dd")
    done < <(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -type d -name 'Pinterest-*' 2>/dev/null)
    if (( zombies > 0 )); then
        echo "  Frameworks:   ✗ $zombies zombie(s) (modulemap sem -Swift.h) → corre \`mxc db\`"
    else
        echo "  Frameworks:   ✓ ok"
    fi

    # Tuist manifest cache orphans.
    local mdir="$HOME/.cache/tuist/Manifests" orphans=0
    if [[ -d "$mdir" ]]; then
        orphans=$(find "$mdir" -maxdepth 1 -name '.tmp-*' 2>/dev/null | wc -l | tr -d ' ')
    fi
    if (( orphans > 0 )); then
        echo "  Tuist cache:  ✗ $orphans manifest .tmp-* orphan(s) → \`mxc db\` limpa"
    else
        echo "  Tuist cache:  ✓ ok"
    fi

    local dd_size mc_size idx_size dd_count
    dd_size=$(du -sh ~/Library/Developer/Xcode/DerivedData 2>/dev/null | cut -f1)
    mc_size=$(du -sh ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex 2>/dev/null | cut -f1)
    idx_size=$(du -csh ~/Library/Developer/Xcode/DerivedData/Pinterest-*/Index.noindex 2>/dev/null | tail -1 | cut -f1)
    dd_count=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -type d -name 'Pinterest-*' 2>/dev/null | wc -l | tr -d ' ')
    echo "  DerivedData:  ${dd_size:-0}"
    echo "  ModuleCache:  ${mc_size:-0}"
    echo "  Index total:  ${idx_size:-0}"
    if (( dd_count > 1 )); then
        echo "  Pinterest-*:  ✗ $dd_count workspaces (DUPLICADOS) → \`mxc dd-dedupe\`"
        echo "                  flip entre workspaces re-indexa tudo → red lines fantasma"
    else
        echo "  Pinterest-*:  ✓ $dd_count workspace"
    fi
    # Live Issues toggle (fonte nº1 de falsos erros).
    local live_issues
    live_issues=$(defaults read com.apple.dt.Xcode IDEIssueNavigatorShowsLiveIssues 2>/dev/null)
    if [[ "$live_issues" == "0" ]]; then
        echo "  Live Issues:  ✓ off (menos falsos vermelhos)"
    else
        echo "  Live Issues:  — on (default). \`mxc xcprefs\` desliga → menos falsos erros."
    fi
    local booted
    booted=$(xcrun simctl list devices booted 2>/dev/null | grep -E "iPhone|iPad" | head -1 | sed 's/^ *//')
    [[ -n "$booted" ]] && echo "  Simulador:    ✓ $booted" || echo "  Simulador:    — nenhum booted (mx liga iPhone 14)"
    _mx_warn_warm_stale 2>/dev/null
    echo "── próximo passo: \`mx\` (ou \`mxc db\` se broken, \`kxd --deep\` se cascade de erros) ──"
}

unalias gp 2>/dev/null
unalias gpf 2>/dev/null
_gp_fn() { make ios_lint && git push --no-verify "$@"; }
_gpf_fn() { make ios_lint && git push -f --no-verify "$@"; }
alias gp='_gp_fn'
alias gpf='_gpf_fn'
alias gpff="git push -f --no-verify"
unalias mybuild 2>/dev/null

alias gmb="git for-each-ref --sort=-committerdate refs/heads/ --format='%(refname:short) - %(committerdate:relative) - %(objectname:short) - %(subject)'"
# alias "make xcode"="make tuist"
alias updateAll="brew upgrade && brew upgrade --cask --greedy && brew cleanup && omz update"
alias sshLinux="ssh pietro@pietro-linux"
cleanAllCache() {
    sudo rm -rf \
        "$HOME/Library/Caches" \
        "$HOME/Library/Logs" \
        /private/var/log/asl \
        "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads" \
        /private/var/db/diagnostics \
        "$HOME/Library/Containers/com.apple.iMovieApp/Data/Library/Caches" \
        "$HOME/Library/Containers/com.apple.Safari/Data/Library/Caches" \
        /Library/Logs \
        "$HOME/Library/Containers/com.apple.iBooksX/Data/Library/Caches" \
        "$HOME/Library/Application Support/Code/Cache" \
        "$HOME/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/Cache" \
        "$HOME/Library/Application Support/discord/Cache" \
        "$HOME/Library/Containers/com.apple.mail/Data/Library/Caches" \
        "$HOME/Library/Containers/com.apple.QuickTimePlayerX/Data/Library/Caches/com.apple.avkit.thumbnailCache" 2>/dev/null
    sudo dscacheutil -flushcache
    sudo killall -HUP mDNSResponder
}
alias ctags="/opt/homebrew/bin/ctags"
alias shopt='/usr/bin/shopt'
alias r=./bin/rails
alias gs='gironde sign -ca github'
alias gpp=' arc lint --apply-patches && gpff'
alias vim=nvim

NCPU=16
PIN_BUILD_PARALLEL="-parallelizeTargets -jobs $NCPU ONLY_ACTIVE_ARCH=YES ARCHS=arm64 COMPILER_INDEX_STORE_ENABLE=NO"

export IDEBuildOperationMaxNumberOfConcurrentCompileTasks=16
export IDEBuildOperationMaxNumberOfConcurrentLinkTasks=16
# SWIFT_DETERMINISTIC_HASHING=1 desliga randomização de hashing de Dictionary/Set — só útil pra debug de flakiness. Não exportar globalmente.

# Limpa caches do build graph (DerivedData Pinterest) antes de compilar na shell
_clean_build_graph() {
    _mx_clean_pinterest_derived_caches
}

# Resolve verbose level from MX_VERBOSE env + args ($@).
# 0 = beautified (enxuto); 1 = beautified + preserve-unbeautified (DEFAULT, ver o que tá rolando);
# 2 = raw xcodebuild + -verbose (clang/swiftc raw, muito loud).
# Opt-out: -q / --quiet força nível 0.
_mx_verbose_level() {
    local lvl="${MX_VERBOSE:-1}"
    for a in "$@"; do
        case "$a" in
            -vv|--very-verbose) lvl=2 ;;
            -v|--verbose)       [[ "$lvl" -lt 1 ]] && lvl=1 ;;
            -q|--quiet)         lvl=0 ;;
        esac
    done
    echo "$lvl"
}

# Returns `-verbose` for level >= 2, else empty. Safe to expand unquoted.
_mx_verbose_xcbuild_flag() {
    [[ "${1:-0}" -ge 2 ]] && echo "-verbose"
}

unalias fastbuild 2>/dev/null
fastbuild() {
    local launch=0
    for a in "$@"; do
        case "$a" in
            --run|-r) launch=1 ;;
        esac
    done

    local repo=$(_mx_repo)
    local ws
    ws=$(basename "$(_mx_workspace)")

    local _vlvl
    _vlvl=$(_mx_verbose_level "$@")
    local _vflag
    _vflag=$(_mx_verbose_xcbuild_flag "$_vlvl")

    _clean_build_graph
    local start=$SECONDS
    local sim_dest="platform=iOS Simulator,arch=arm64,name=iPhone 14"
    # Local: desliga background tasks (indexing paralelo) só pra este fastbuild.
    export XCODE_DISABLE_BACKGROUND_TASKS=YES

    echo "🔨 fastbuild: $MX_PIN_SCHEME ($ws) @ $repo${_vlvl:+ (verbose=$_vlvl)}"
    local status
    if [[ "$_vlvl" -ge 2 ]]; then
        (cd "$repo" && tuist xcodebuild -workspace "$ws" build \
            -scheme "$MX_PIN_SCHEME" \
            -configuration Debug \
            -destination "$sim_dest" \
            $_vflag \
            $PIN_BUILD_PARALLEL \
            CODE_SIGNING_ALLOWED=NO \
            RUN_CLANG_STATIC_ANALYZER=NO \
            CLANG_COVERAGE_MAPPING=NO \
            CLANG_COVERAGE_MAPPING_LINKER_ARGS= \
            SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO \
            ENABLE_PREVIEWS=NO \
            ENABLE_TESTING_SEARCH_PATHS=NO \
            build)
        status=$?
    elif [[ "$_vlvl" -ge 1 ]]; then
        (cd "$repo" && tuist xcodebuild -workspace "$ws" build \
            -scheme "$MX_PIN_SCHEME" \
            -configuration Debug \
            -destination "$sim_dest" \
            $PIN_BUILD_PARALLEL \
            CODE_SIGNING_ALLOWED=NO \
            RUN_CLANG_STATIC_ANALYZER=NO \
            CLANG_COVERAGE_MAPPING=NO \
            CLANG_COVERAGE_MAPPING_LINKER_ARGS= \
            SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO \
            ENABLE_PREVIEWS=NO \
            ENABLE_TESTING_SEARCH_PATHS=NO \
            build) 2>&1 | xcbeautify --preserve-unbeautified
        status=$pipestatus[1]
    else
        (cd "$repo" && tuist xcodebuild -workspace "$ws" build \
            -scheme "$MX_PIN_SCHEME" \
            -configuration Debug \
            -destination "$sim_dest" \
            $PIN_BUILD_PARALLEL \
            CODE_SIGNING_ALLOWED=NO \
            RUN_CLANG_STATIC_ANALYZER=NO \
            CLANG_COVERAGE_MAPPING=NO \
            CLANG_COVERAGE_MAPPING_LINKER_ARGS= \
            SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO \
            ENABLE_PREVIEWS=NO \
            ENABLE_TESTING_SEARCH_PATHS=NO \
            build) 2>&1 | xcbeautify
        status=$pipestatus[1]
    fi
    local elapsed=$(( SECONDS - start ))
    if [ $status -eq 0 ]; then
        echo "✅ Build succeeded in ${elapsed}s"
        if [ $launch -eq 1 ]; then
            echo "🚀 Launching on iPhone 14..."
            local sim_id
            sim_id=$(xcrun simctl list devices available | grep "iPhone 14 " | head -1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/')
            if [ -n "$sim_id" ]; then
                xcrun simctl boot "$sim_id" 2>/dev/null
                open -a Simulator
                local app_path
                app_path=$(find ~/Library/Developer/Xcode/DerivedData/Pinterest-*/Build/Products/Debug-iphonesimulator -name "PinterestDevelopment.app" -maxdepth 1 2>/dev/null | head -1)
                if [ -n "$app_path" ]; then
                    xcrun simctl install "$sim_id" "$app_path"
                    xcrun simctl launch "$sim_id" com.pinterest.PinterestDevelopment
                else
                    echo "⚠️  App bundle not found in DerivedData — open Xcode and run manually"
                fi
            else
                echo "⚠️  iPhone 14 simulator not found — create one in Xcode > Settings > Platforms"
            fi
        fi
    else
        echo "❌ Build failed in ${elapsed}s (exit code: $status)"
    fi
    return $status
}

# mb — build CLI espelhando `mx` (PinterestDevelopment, sim iPhone 14) sem abrir o Xcode.
#   mb                 -> build $MX_PIN_SCHEME (PinterestDevelopment)
#   mb <target>        -> gera projeto target-only + build scheme = basename(target)
#   mb -r | --run      -> lança no simulador após build (só quando scheme = PinterestDevelopment)
#   mb <target> -r     -> build targeted + tenta lançar (ignora -r se scheme não for app)
unalias mb 2>/dev/null
_mb_fn() {
    local _launch=0 _targets=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--run)                                     _launch=1; shift ;;
            -v|--verbose|-vv|--very-verbose|-q|--quiet)   shift ;;
            *)                                            _targets="$1"; shift ;;
        esac
    done

    local repo
    repo=$(_mx_repo)
    if [[ -z "$repo" ]]; then
        echo "❌ mb: corre dentro da pasta do clone (git). PWD=$PWD" >&2
        return 1
    fi
    local ws_path
    ws_path=$(_mx_workspace "$repo")
    local ws
    ws=$(basename "$ws_path")

    local scheme
    scheme=$(_mx_scheme_from_targets "$_targets")

    local _vlvl
    _vlvl=$(_mx_verbose_level "$@")
    local _vflag
    _vflag=$(_mx_verbose_xcbuild_flag "$_vlvl")

    # Regenera o projeto quando: targets passados (queremos target-only gen)
    # ou o projeto mudou (Project.swift, Tuist/, etc.). Senão reutiliza o existente.
    if [[ -n "$_targets" ]] || _mx_project_changed "$repo" "$ws_path"; then
        echo "📦 mb: mise generate --fast --no-open${_targets:+ --targets $_targets}…"
        if _mx_mise_generate_fast "$repo" "$_targets"; then
            _mx_stamp_update "$repo"
        else
            echo "❌ mb: mise generate falhou"
            return 1
        fi
    else
        echo "⚡ mb: sem mudanças de projeto — reutiliza projeto atual"
    fi

    _clean_build_graph
    local start=$SECONDS
    local sim_dest="platform=iOS Simulator,arch=arm64,name=iPhone 14"

    echo "🔨 mb: $scheme ($ws) @ $repo → sim $MX_PIN_SIM_SUBSTR${_vlvl:+ (verbose=$_vlvl)}"
    local status
    if [[ "$_vlvl" -ge 2 ]]; then
        (cd "$repo" && tuist xcodebuild -workspace "$ws" build \
            -scheme "$scheme" \
            -configuration Debug \
            -destination "$sim_dest" \
            $_vflag \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            -hideShellScriptEnvironment \
            -onlyUsePackageVersionsFromResolvedFile \
            $PIN_BUILD_PARALLEL \
            CODE_SIGNING_ALLOWED=NO \
            RUN_CLANG_STATIC_ANALYZER=NO \
            CLANG_COVERAGE_MAPPING=NO \
            CLANG_COVERAGE_MAPPING_LINKER_ARGS= \
            SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO \
            COMPILER_INDEX_STORE_ENABLE=NO \
            ENABLE_PREVIEWS=NO \
            ENABLE_TESTING_SEARCH_PATHS=NO \
            build)
        status=$?
    elif [[ "$_vlvl" -ge 1 ]]; then
        (cd "$repo" && tuist xcodebuild -workspace "$ws" build \
            -scheme "$scheme" \
            -configuration Debug \
            -destination "$sim_dest" \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            -hideShellScriptEnvironment \
            -onlyUsePackageVersionsFromResolvedFile \
            $PIN_BUILD_PARALLEL \
            CODE_SIGNING_ALLOWED=NO \
            RUN_CLANG_STATIC_ANALYZER=NO \
            CLANG_COVERAGE_MAPPING=NO \
            CLANG_COVERAGE_MAPPING_LINKER_ARGS= \
            SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO \
            COMPILER_INDEX_STORE_ENABLE=NO \
            ENABLE_PREVIEWS=NO \
            ENABLE_TESTING_SEARCH_PATHS=NO \
            build) 2>&1 | xcbeautify --preserve-unbeautified
        status=$pipestatus[1]
    else
        (cd "$repo" && tuist xcodebuild -workspace "$ws" build \
            -scheme "$scheme" \
            -configuration Debug \
            -destination "$sim_dest" \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            -hideShellScriptEnvironment \
            -onlyUsePackageVersionsFromResolvedFile \
            $PIN_BUILD_PARALLEL \
            CODE_SIGNING_ALLOWED=NO \
            RUN_CLANG_STATIC_ANALYZER=NO \
            CLANG_COVERAGE_MAPPING=NO \
            CLANG_COVERAGE_MAPPING_LINKER_ARGS= \
            SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO \
            COMPILER_INDEX_STORE_ENABLE=NO \
            ENABLE_PREVIEWS=NO \
            ENABLE_TESTING_SEARCH_PATHS=NO \
            build) 2>&1 | xcbeautify
        status=$pipestatus[1]
    fi
    local elapsed=$(( SECONDS - start ))

    if [ $status -ne 0 ]; then
        echo "❌ mb: build falhou em ${elapsed}s (exit $status)"
        return $status
    fi

    echo "✅ mb: build OK em ${elapsed}s"

    if [ $_launch -eq 1 ]; then
        if [[ "$scheme" != "PinterestDevelopment" ]]; then
            echo "ℹ️  mb: --run ignorado (scheme $scheme não é um app instalável)"
            return 0
        fi
        echo "🚀 mb: a lançar $scheme no $MX_PIN_SIM_SUBSTR…"
        local sim_id
        sim_id=$(xcrun simctl list devices available | grep "iPhone 14 " | head -1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/')
        if [ -z "$sim_id" ]; then
            echo "⚠️  mb: iPhone 14 simulator não encontrado — cria um em Xcode > Settings > Platforms"
            return 0
        fi
        xcrun simctl boot "$sim_id" 2>/dev/null
        open -a Simulator
        local app_path
        app_path=$(find ~/Library/Developer/Xcode/DerivedData/Pinterest-*/Build/Products/Debug-iphonesimulator -name "PinterestDevelopment.app" -maxdepth 1 2>/dev/null | head -1)
        if [ -n "$app_path" ]; then
            xcrun simctl install "$sim_id" "$app_path"
            xcrun simctl launch "$sim_id" com.pinterest.PinterestDevelopment
        else
            echo "⚠️  mb: app bundle não encontrado em DerivedData — corre o build uma vez no Xcode"
        fi
    fi

    return 0
}
mb() { time (_mb_fn "$@"); }

# mba — mb com auto-detecção do módulo ativo a partir de git status.
#   0 módulos detectados -> fallback mb (PinterestDevelopment)
#   1 módulo detectado   -> mb <Modulo> (bare target name, sem prefixo Library/Feature/…)
#   N módulos detectados -> lista candidatos e pede escolha (fallback mb sem arg se o user não escolher)
# Flags (-v, -vv, -r, etc.) são passadas a mb.
unalias mba 2>/dev/null
_mba_fn() {
    local _forwarded=()
    while [[ $# -gt 0 ]]; do
        _forwarded+=("$1"); shift
    done
    local repo
    repo=$(_mx_repo)
    if [[ -z "$repo" ]]; then
        echo "❌ mba: corre dentro da pasta do clone (git). PWD=$PWD" >&2
        return 1
    fi
    local modules
    modules=$(_mx_detect_active_module "$repo")
    local count
    count=$(echo "$modules" | sed '/^$/d' | wc -l | tr -d ' ')
    case "$count" in
        0)
            echo "ℹ️  mba: sem módulo ativo detectado no git status → fallback mb (PinterestDevelopment)"
            _mb_fn "${_forwarded[@]}"
            ;;
        1)
            local bare="${modules##*/}"
            echo "🎯 mba: módulo ativo = $modules → target bare = $bare"
            _mb_fn "${_forwarded[@]}" "$bare"
            ;;
        *)
            echo "⚠️  mba: múltiplos módulos modificados:"
            echo "$modules" | sed 's/^/  - /'
            echo -n "→ escolhe um path (Enter = fallback PinterestDevelopment): "
            local choice
            read -r choice
            if [[ -n "$choice" ]]; then
                local bare="${choice##*/}"
                _mb_fn "${_forwarded[@]}" "$bare"
            else
                _mb_fn "${_forwarded[@]}"
            fi
            ;;
    esac
}
mba() { time (_mba_fn "$@"); }

unalias gco 2>/dev/null
unalias gsw 2>/dev/null
alias gco='git checkout'
alias gsw='git switch'


# ─── Xcode / shell build env (antes: section após Mise) ───
# MARK: - Xcode / shell build env (mx + fastbuild)

# xcodebuild (CLI): XCODE_DISABLE_BACKGROUND_TASKS=YES desliga tarefas em segundo plano (incl. indexação paralela)
# durante o build. NÃO exportado globalmente (afetaria Tuist/Fastlane/SPM). Aplicado pontualmente em fastbuild/_mx_warmup_*.

# Indexador do Xcode.app (defaults persistentes). Reabre o Xcode para aplicar por completo.
alias xcode-index-off='defaults write com.apple.dt.Xcode IDEIndexDisable -bool YES && echo "IDEIndexDisable=YES — index do IDE desligado (reabre o Xcode)"'
alias xcode-index-on='defaults write com.apple.dt.Xcode IDEIndexDisable -bool NO && echo "IDEIndexDisable=NO — index do IDE ligado"'
alias idx-off=xcode-index-off
alias idx-on=xcode-index-on
xcode-index-status() {
    if defaults read com.apple.dt.Xcode IDEIndexDisable &>/dev/null; then
        echo "IDEIndexDisable=$(defaults read com.apple.dt.Xcode IDEIndexDisable)"
    else
        echo "IDEIndexDisable não definido — index do IDE ligado por omissão"
    fi
}

export CLANG_INDEX_STORE_ENABLE=YES
export IDEPrecompiledModuleCacheSizeInMB=20480

# Indexação incremental: menos reindex completo ao reabrir (idempotente).
# Não escrever IDEIndexDisable aqui — cada shell resetaria idx-off / idx-on.
defaults write com.apple.dt.Xcode IDEIndexEnableIncrementalIndexing -bool YES 2>/dev/null

# ulimit e OBJC_DISABLE_INITIALIZE_FORK_SAFETY movidos para ~/.zshenv (aplicam-se a toda shell, não só interactive).

alias pin-agent='/usr/local/bin/pin-agent'

# MARK: - Pinterest ai-sandbox
# Mesh em localhost:9092. SonarQube (Homebrew) H2 está em sonar.embeddedDatabase.port=19092 para não conflitar.
# `ai-sandbox-stop --force` limpa proxy/ghostunnel presos de sessões anteriores.
ai-sandbox-claude() {
  command ai-sandbox-stop --force
  command ai-sandbox claude "$@"
}
alias asbc='ai-sandbox-claude'

export NVM_DIR="$HOME/.nvm"
_lazy_load_nvm() {
    unfunction nvm node npm npx 2>/dev/null
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
}

nvm() {
    _lazy_load_nvm
    nvm "$@"
}

node() {
    _lazy_load_nvm
    node "$@"
}

npm() {
    _lazy_load_nvm
    npm "$@"
}

npx() {
    _lazy_load_nvm
    npx "$@"
}

# MARK: - Pinterest iOS: test aliases (xcodebuild test, build-for-testing, test-without-building)
#   mt   <scheme> [only_testing]  — build + test (one shot)
#   mtb  <scheme>                — build-for-testing only (compile, no run)
#   mtt  <scheme> [only_testing] — test-without-building (fastest iteration, reuses last build)
#   Default sim: iPhone 14 (0DA00AEF-ACF2-4619-BB53-F491BC4C28AB)
PIN_TEST_SIM="0DA00AEF-ACF2-4619-BB53-F491BC4C28AB"

mt() {
    local scheme="${1:?Usage: mt <scheme> [only_testing]}"
    local only="${2:-}"
    local ot_flag=()
    [[ -n "$only" ]] && ot_flag=("-only-testing:$only")
    local repo=$(_mx_repo)
    local ws=$(_mx_workspace "$repo")
    local start=$SECONDS
    (cd "$repo" && xcodebuild test \
        -workspace "$ws" \
        -scheme "$scheme" \
        -sdk iphonesimulator \
        -destination "id=$PIN_TEST_SIM" \
        "${ot_flag[@]}" \
        $PIN_BUILD_PARALLEL \
        CODE_SIGNING_ALLOWED=NO \
        2>&1) | xcbeautify --preserve-unbeautified
    local rc=$pipestatus[1]
    local elapsed=$(( SECONDS - start ))
    if [[ $rc -eq 0 ]]; then
        echo "✅ mt: $scheme passed in ${elapsed}s"
    else
        echo "❌ mt: $scheme failed in ${elapsed}s (exit $rc)"
    fi
    return $rc
}

mtb() {
    local scheme="${1:?Usage: mtb <scheme>}"
    local repo=$(_mx_repo)
    local ws=$(_mx_workspace "$repo")
    local start=$SECONDS
    (cd "$repo" && xcodebuild build-for-testing \
        -workspace "$ws" \
        -scheme "$scheme" \
        -sdk iphonesimulator \
        -destination "id=$PIN_TEST_SIM" \
        $PIN_BUILD_PARALLEL \
        CODE_SIGNING_ALLOWED=NO \
        2>&1) | xcbeautify --preserve-unbeautified
    local rc=$pipestatus[1]
    local elapsed=$(( SECONDS - start ))
    if [[ $rc -eq 0 ]]; then
        echo "✅ mtb: $scheme built for testing in ${elapsed}s"
    else
        echo "❌ mtb: $scheme build-for-testing failed in ${elapsed}s (exit $rc)"
    fi
    return $rc
}

mtt() {
    local scheme="${1:?Usage: mtt <scheme> [only_testing]}"
    local only="${2:-}"
    local ot_flag=()
    [[ -n "$only" ]] && ot_flag=("-only-testing:$only")
    local repo=$(_mx_repo)
    local ws=$(_mx_workspace "$repo")
    local start=$SECONDS
    (cd "$repo" && xcodebuild test-without-building \
        -workspace "$ws" \
        -scheme "$scheme" \
        -sdk iphonesimulator \
        -destination "id=$PIN_TEST_SIM" \
        "${ot_flag[@]}" \
        2>&1) | xcbeautify --preserve-unbeautified
    local rc=$pipestatus[1]
    local elapsed=$(( SECONDS - start ))
    if [[ $rc -eq 0 ]]; then
        echo "✅ mtt: $scheme passed in ${elapsed}s (no rebuild)"
    else
        echo "❌ mtt: $scheme failed in ${elapsed}s (exit $rc)"
    fi
    return $rc
}

# ============================================================================
