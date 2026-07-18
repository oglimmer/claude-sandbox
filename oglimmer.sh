#!/usr/bin/env bash

set -euo pipefail

# Manage per-workspace sandbox profiles: skills, plugins and MCP servers.
# See profiles/README.md for what a profile is and how it reaches Claude Code.
#
# This repo builds no images and deploys nothing, so the usual build/release
# commands don't apply — the shape, logging and option conventions follow
# coding-guidelines/oglimmer-sh.md.

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROFILES_DIR="$SCRIPT_DIR/profiles"
STATE_DIR="$SCRIPT_DIR/profile-state"
ENV_FILE="$SCRIPT_DIR/.env"

VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
HELP=false

COMMAND=""
PROFILE_OVERRIDE=""
ARGS=()
MCP_ENV=()
MCP_URL=""
MCP_TRANSPORT=""

# Color output (only if terminal supports it)
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    BOLD="$(tput bold)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    RED="$(tput setaf 1)"
    BLUE="$(tput setaf 4)"
    DIM="$(tput dim)"
    RESET="$(tput sgr0)"
else
    BOLD="" GREEN="" YELLOW="" RED="" BLUE="" DIM="" RESET=""
fi

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${RESET} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${RESET} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${RESET} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${RESET} $1" >&2
}

log_verbose() {
    [[ "$VERBOSE" == "true" ]] && echo -e "${DIM}[VERBOSE]${RESET} $1"
    return 0
}

execute_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${DIM}[DRY-RUN]${RESET} $*"
        return 0
    fi
    log_verbose "$*"
    "$@"
}

show_help() {
    cat <<EOF
${BOLD}Usage:${RESET} ${SCRIPT_NAME} [OPTIONS] [COMMAND]

Manage per-workspace sandbox profiles — the skills, plugins and MCP servers
that a given WORKSPACE_DIR gets. See profiles/README.md.

${BOLD}COMMANDS:${RESET}
    list [PROFILE]              Show skills, plugins and MCP servers (default),
                                plus anything installed from inside the sandbox
    profiles                    List every profile and mark the active one
    new PROFILE                 Create a profile skeleton and its state directory
    mcp-add PROFILE NAME -- CMD [ARGS...]
                                Add a stdio MCP server to the profile
    mcp-add PROFILE NAME --url URL
                                Add an http/sse MCP server to the profile
    mcp-rm PROFILE NAME         Remove an MCP server from the profile
    skill-add PROFILE SRC       Copy a skill directory into the profile
    skill-rm PROFILE NAME       Remove a skill from the profile
    doctor                      Check every profile for the usual breakages
    run [CLAUDE ARGS...]        Start the sandbox with the active profile;
                                anything after 'run' is passed to Claude Code
                                (e.g. 'run -c' to continue the last session)

${BOLD}OPTIONS:${RESET}
    -p, --profile NAME          Act on this profile instead of the active one
    -v, --verbose               Show the commands being run
        --dry-run               Print what would change without writing
    -h, --help                  Show this help

${BOLD}MCP-ADD OPTIONS:${RESET}
        --env KEY=VALUE         Environment variable for the server (repeatable)
        --transport TYPE        Transport for --url servers (default: http)

${BOLD}WHICH PROFILE:${RESET}
    Highest wins, matching what docker compose itself does:
        -p NAME  >  CLAUDE_PROFILE in the environment  >  .env  >  'default'

    Options go before the command, since everything after 'run' is handed to
    Claude Code:  ${SCRIPT_NAME} -p my-api run -c

    Use 'common' as the profile to reach the skills every profile inherits.

${BOLD}EXAMPLES:${RESET}
    ${SCRIPT_NAME} list                     # the active profile
    ${SCRIPT_NAME} -p my-api list           # a specific one
    ${SCRIPT_NAME} -p my-api run -c         # run it, continue its last session
    ${SCRIPT_NAME} new my-api
    ${SCRIPT_NAME} mcp-add my-api playwright -- npx -y @playwright/mcp@latest
    ${SCRIPT_NAME} mcp-add my-api grafana --env GRAFANA_URL=\${GRAFANA_URL} -- uvx mcp-grafana
    ${SCRIPT_NAME} skill-add common ~/.claude/skills/renovate-config
    ${SCRIPT_NAME} doctor

Secrets belong in .env and are referenced from mcp.json as \${VAR}; this script
warns when a literal value is passed instead, and redacts literals when listing.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        # Everything after `run` belongs to Claude Code, not to this script, so
        # `run -c` continues the last session instead of tripping the unknown
        # option check. Script options go before the command.
        if [[ "$COMMAND" == "run" ]]; then
            ARGS+=("$@")
            break
        fi
        case "$1" in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -p|--profile)
                [[ $# -ge 2 ]] || { log_error "--profile needs a profile name"; exit 1; }
                PROFILE_OVERRIDE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                HELP=true
                shift
                ;;
            --env)
                [[ $# -ge 2 ]] || { log_error "--env needs a KEY=VALUE argument"; exit 1; }
                MCP_ENV+=("$2")
                shift 2
                ;;
            --url)
                [[ $# -ge 2 ]] || { log_error "--url needs an argument"; exit 1; }
                MCP_URL="$2"
                shift 2
                ;;
            --transport)
                [[ $# -ge 2 ]] || { log_error "--transport needs an argument"; exit 1; }
                MCP_TRANSPORT="$2"
                shift 2
                ;;
            --)
                # Everything after -- is the server's command line, kept verbatim.
                shift
                ARGS+=("$@")
                break
                ;;
            -*)
                log_error "Unknown option: $1"
                echo "Run '${SCRIPT_NAME} --help' for usage." >&2
                exit 1
                ;;
            *)
                if [[ -z "$COMMAND" ]]; then
                    COMMAND="$1"
                else
                    ARGS+=("$1")
                fi
                shift
                ;;
        esac
    done
}

check_prerequisites() {
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required to read and write mcp.json. Install it with: brew install jq"
        exit 1
    fi
}

# The profile selected in .env — the one a bare `docker compose run` would use.
active_profile() {
    # Same precedence docker compose uses, so the script never reports a
    # different profile than the one that actually gets mounted:
    #   --profile flag  >  CLAUDE_PROFILE in the environment  >  .env  >  default
    if [[ -n "$PROFILE_OVERRIDE" ]]; then
        echo "$PROFILE_OVERRIDE"
        return 0
    fi
    if [[ -n "${CLAUDE_PROFILE:-}" ]]; then
        echo "$CLAUDE_PROFILE"
        return 0
    fi
    local profile=""
    if [[ -f "$ENV_FILE" ]]; then
        profile=$(grep -E '^[[:space:]]*CLAUDE_PROFILE=' "$ENV_FILE" 2>/dev/null \
            | tail -1 | cut -d= -f2- | tr -d '"'"'"' \t\r')
    fi
    echo "${profile:-default}"
}

# Resolve the profile a command should act on: explicit argument wins, else the
# active one.
resolve_profile() {
    local given="${1:-}"
    if [[ -n "$given" ]]; then
        echo "$given"
    else
        active_profile
    fi
}

require_profile_dir() {
    local profile="$1"
    if [[ ! -d "$PROFILES_DIR/$profile" ]]; then
        log_error "No such profile: $profile"
        log_info "Create it with: ${SCRIPT_NAME} new $profile"
        exit 1
    fi
}

# A value is safe to print when it's an env-var reference rather than a literal.
is_env_reference() {
    [[ "$1" =~ ^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$ ]]
}

redact() {
    if is_env_reference "$1"; then
        echo "$1"
    else
        echo "<redacted>"
    fi
}

# Is VAR referenced as ${VAR} actually available to the container?
env_var_status() {
    local ref="$1" name
    name="${ref#\$}"
    name="${name#\{}"
    name="${name%\}}"
    if [[ -f "$ENV_FILE" ]] && grep -qE "^[[:space:]]*${name}=.+" "$ENV_FILE"; then
        if grep -qE "^[[:space:]]*-[[:space:]]*${name}=" "$SCRIPT_DIR/docker-compose.yml"; then
            echo "ok"
        else
            echo "no-passthrough"
        fi
    else
        echo "unset"
    fi
}

list_skills() {
    local profile="$1" label found=false
    for src in "common" "$profile"; do
        [[ -d "$PROFILES_DIR/$src/skills" ]] || continue
        while IFS= read -r skill; do
            [[ -n "$skill" ]] || continue
            found=true
            label="$skill"
            # A profile skill with the same name wins at copy time.
            if [[ "$src" != "common" && -d "$PROFILES_DIR/common/skills/$skill" ]]; then
                label="$skill ${YELLOW}(shadows common)${RESET}"
            fi
            if [[ ! -f "$PROFILES_DIR/$src/skills/$skill/SKILL.md" ]]; then
                label="$label ${RED}(no SKILL.md — will not load)${RESET}"
            fi
            echo -e "    ${DIM}${src}/${RESET} $label"
        done < <(find -L "$PROFILES_DIR/$src/skills" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
    done
    [[ "$found" == "true" ]] || echo -e "    ${DIM}none${RESET}"
}

list_plugins() {
    local profile="$1" found=false
    if [[ -d "$PROFILES_DIR/$profile/plugins" ]]; then
        while IFS= read -r plugin; do
            [[ -n "$plugin" ]] || continue
            found=true
            echo "    $plugin"
        done < <(find -L "$PROFILES_DIR/$profile/plugins" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
    fi
    [[ "$found" == "true" ]] || echo -e "    ${DIM}none${RESET}"
}

# Anything a `/plugin` or `/mcp` *inside* the sandbox wrote to profile-state/.
# It is real — Claude Code loads it, so it shows up in /skills — but it is not
# declared in profiles/, so it is invisible to the sections above and a fresh
# checkout of this repo will not have it. Listed separately rather than merged
# in, precisely so the difference stays visible.
list_runtime() {
    local profile="$1"
    local state="$STATE_DIR/$profile"
    local lines=() name
    [[ -d "$state" ]] || return 0

    # The entrypoint rebuilds ~/.claude/skills from the profile on every start,
    # so an undeclared skill here is a leftover that the next run will delete.
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        [[ -d "$PROFILES_DIR/$profile/skills/$name" ]] && continue
        [[ -d "$PROFILES_DIR/common/skills/$name" ]] && continue
        lines+=("    ${DIM}skill${RESET}   $name ${YELLOW}(wiped on next start)${RESET}")
    done < <(find -L "$state/skills" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)

    # Plugins have no declarative equivalent yet, so every one of these was
    # installed by hand. A plugin's bundled skills appear in /skills too, which
    # is the usual reason /skills and this command disagree.
    if [[ -f "$state/plugins/installed_plugins.json" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            lines+=("    ${DIM}plugin${RESET}  $name")
        done < <(jq -r '.plugins // {} | keys[]' "$state/plugins/installed_plugins.json" 2>/dev/null | sort)
    fi

    # Both scopes `claude mcp add` can write to: user-level and per-project.
    if [[ -f "$state/.claude.json" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            jq -e --arg n "$name" '.mcpServers // {} | has($n)' \
                "$PROFILES_DIR/$profile/mcp.json" >/dev/null 2>&1 && continue
            lines+=("    ${DIM}mcp${RESET}     $name")
        done < <(jq -r '[(.mcpServers // {} | keys[]),
                         ((.projects // {}) | to_entries[] | (.value.mcpServers // {}) | keys[])]
                        | unique[]' "$state/.claude.json" 2>/dev/null)
    fi

    [[ ${#lines[@]} -gt 0 ]] || return 0

    echo -e "  ${BOLD}Runtime${RESET} ${DIM}(in profile-state/$profile, not declared in profiles/$profile)${RESET}"
    printf '%b\n' "${lines[@]}"
    echo -e "    ${DIM}Installed from inside the sandbox. To make it reproducible, declare it${RESET}"
    echo -e "    ${DIM}in the profile — e.g. ${SCRIPT_NAME} skill-add $profile SRC.${RESET}"
    echo
}

list_mcp() {
    local profile="$1"
    local mcp_file="$PROFILES_DIR/$profile/mcp.json"

    if [[ ! -f "$mcp_file" ]]; then
        echo -e "    ${DIM}none${RESET}"
        return 0
    fi
    if ! jq empty "$mcp_file" 2>/dev/null; then
        echo -e "    ${RED}invalid JSON — Claude Code will refuse to start${RESET}"
        return 0
    fi

    local names
    names=$(jq -r '.mcpServers // {} | keys[]' "$mcp_file" 2>/dev/null)
    if [[ -z "$names" ]]; then
        echo -e "    ${DIM}none${RESET}"
        return 0
    fi

    local name kind detail
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        kind=$(jq -r --arg n "$name" '.mcpServers[$n].type // (if .mcpServers[$n].url then "http" else "stdio" end)' "$mcp_file")
        if [[ "$kind" == "stdio" ]]; then
            detail=$(jq -r --arg n "$name" '[.mcpServers[$n].command] + (.mcpServers[$n].args // []) | join(" ")' "$mcp_file")
        else
            detail=$(jq -r --arg n "$name" '.mcpServers[$n].url // ""' "$mcp_file")
        fi
        echo -e "    ${BOLD}${name}${RESET}  ${DIM}${kind}${RESET}  $detail"

        # Env vars: show references, redact literals, flag what won't resolve.
        local key value status
        while IFS=$'\t' read -r key value; do
            [[ -n "$key" ]] || continue
            if is_env_reference "$value"; then
                status=$(env_var_status "$value")
                case "$status" in
                    ok)
                        echo -e "        ${DIM}env${RESET} $key=$value ${GREEN}✓${RESET}"
                        ;;
                    no-passthrough)
                        echo -e "        ${DIM}env${RESET} $key=$value ${YELLOW}✗ set in .env but no passthrough in docker-compose.yml${RESET}"
                        ;;
                    *)
                        echo -e "        ${DIM}env${RESET} $key=$value ${YELLOW}✗ not set in .env${RESET}"
                        ;;
                esac
            else
                echo -e "        ${DIM}env${RESET} $key=$(redact "$value") ${YELLOW}literal — move it to .env and reference \${$key}${RESET}"
            fi
        done < <(jq -r --arg n "$name" '.mcpServers[$n].env // {} | to_entries[] | "\(.key)\t\(.value)"' "$mcp_file")
    done <<< "$names"
}

cmd_list() {
    local profile
    profile=$(resolve_profile "${ARGS[0]:-}")
    require_profile_dir "$profile"

    local marker=""
    [[ "$profile" == "$(active_profile)" ]] && marker=" ${GREEN}(active)${RESET}"

    echo
    echo -e "${BOLD}Profile:${RESET} ${profile}${marker}"
    echo -e "  ${DIM}config${RESET}  profiles/$profile"
    if [[ -d "$STATE_DIR/$profile" ]]; then
        if [[ -f "$STATE_DIR/$profile/.credentials.json" ]]; then
            echo -e "  ${DIM}state${RESET}   profile-state/$profile ${GREEN}(logged in)${RESET}"
        else
            echo -e "  ${DIM}state${RESET}   profile-state/$profile ${YELLOW}(logged out — run /login in the sandbox)${RESET}"
        fi
    else
        echo -e "  ${DIM}state${RESET}   ${YELLOW}missing — create it with: ${SCRIPT_NAME} new $profile${RESET}"
    fi

    echo
    echo -e "  ${BOLD}Skills${RESET}"
    list_skills "$profile"
    echo
    echo -e "  ${BOLD}Plugins${RESET}"
    list_plugins "$profile"
    echo
    echo -e "  ${BOLD}MCP servers${RESET}"
    list_mcp "$profile"
    echo
    list_runtime "$profile"
    if [[ -f "$PROFILES_DIR/$profile/settings.json" ]]; then
        echo -e "  ${BOLD}Settings overlay${RESET}"
        echo -e "    $(jq -r 'keys | join(", ")' "$PROFILES_DIR/$profile/settings.json" 2>/dev/null || echo "${RED}invalid JSON${RESET}")"
        echo
    fi
}

cmd_profiles() {
    local active
    active=$(active_profile)
    echo
    echo -e "${BOLD}Profiles${RESET} ${DIM}(active: $active)${RESET}"
    while IFS= read -r profile; do
        [[ -n "$profile" ]] || continue
        [[ "$profile" == "common" ]] && continue
        local marker="" counts skills mcps
        [[ "$profile" == "$active" ]] && marker=" ${GREEN}←${RESET}"
        skills=$(find -L "$PROFILES_DIR/$profile/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        mcps=$(jq -r '.mcpServers // {} | length' "$PROFILES_DIR/$profile/mcp.json" 2>/dev/null || echo 0)
        counts="${skills} skills, ${mcps} mcp"
        echo -e "  ${profile}${marker}  ${DIM}${counts}${RESET}"
    done < <(find -L "$PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
    echo
    echo -e "${DIM}common/ is inherited by every profile:${RESET} $(find -L "$PROFILES_DIR/common/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ') skills"
    echo
}

cmd_new() {
    local profile="${ARGS[0]:-}"
    if [[ -z "$profile" ]]; then
        log_error "Usage: ${SCRIPT_NAME} new PROFILE"
        exit 1
    fi
    if [[ -d "$PROFILES_DIR/$profile" ]]; then
        log_error "Profile already exists: $profile"
        exit 1
    fi

    execute_cmd mkdir -p "$PROFILES_DIR/$profile/skills"
    # Pre-create the state directory: compose would otherwise create it as root,
    # which is the usual cause of a profile that silently does nothing.
    execute_cmd mkdir -p "$STATE_DIR/$profile"
    log_success "Created profile '$profile'"
    echo
    log_info "Point .env at it:"
    echo "    WORKSPACE_DIR=/path/to/your/repo"
    echo "    CLAUDE_PROFILE=$profile"
}

cmd_mcp_add() {
    local profile="${ARGS[0]:-}"
    local name="${ARGS[1]:-}"
    local command_args=("${ARGS[@]:2}")

    if [[ -z "$profile" || -z "$name" ]]; then
        log_error "Usage: ${SCRIPT_NAME} mcp-add PROFILE NAME -- CMD [ARGS...]"
        log_info "   or: ${SCRIPT_NAME} mcp-add PROFILE NAME --url URL"
        exit 1
    fi
    require_profile_dir "$profile"

    if [[ -z "$MCP_URL" && ${#command_args[@]} -eq 0 ]]; then
        log_error "Give the server a command after -- , or a --url"
        exit 1
    fi

    local mcp_file="$PROFILES_DIR/$profile/mcp.json"
    if [[ ! -f "$mcp_file" ]]; then
        log_verbose "Creating $mcp_file"
        execute_cmd sh -c "printf '{\n  \"mcpServers\": {}\n}\n' > '$mcp_file'"
        [[ "$DRY_RUN" == "true" ]] && log_info "(dry run: further edits shown against an empty config)"
    elif ! jq empty "$mcp_file" 2>/dev/null; then
        log_error "$mcp_file is not valid JSON — fix it before adding servers"
        exit 1
    fi

    if [[ -f "$mcp_file" ]] && jq -e --arg n "$name" '.mcpServers[$n]' "$mcp_file" >/dev/null 2>&1; then
        log_warning "Server '$name' already exists in profile '$profile' — replacing it"
    fi

    # Build the server object, then merge it in. Env values are passed through
    # verbatim so ${VAR} references survive to the container.
    local env_json="{}"
    local pair key value
    for pair in ${MCP_ENV+"${MCP_ENV[@]}"}; do
        key="${pair%%=*}"
        value="${pair#*=}"
        if [[ "$key" == "$pair" ]]; then
            log_error "--env expects KEY=VALUE, got: $pair"
            exit 1
        fi
        if ! is_env_reference "$value"; then
            log_warning "$key holds a literal value. Put the secret in .env and pass --env $key=\${$key} instead."
        fi
        env_json=$(jq --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$env_json")
    done

    local server_json
    if [[ -n "$MCP_URL" ]]; then
        server_json=$(jq -n \
            --arg type "${MCP_TRANSPORT:-http}" \
            --arg url "$MCP_URL" \
            --argjson env "$env_json" \
            '{type: $type, url: $url} + (if ($env | length) > 0 then {env: $env} else {} end)')
    else
        local cmd="${command_args[0]}"
        local rest=("${command_args[@]:1}")
        local args_json="[]"
        if [[ ${#rest[@]} -gt 0 ]]; then
            args_json=$(printf '%s\n' "${rest[@]}" | jq -R . | jq -s .)
        fi
        server_json=$(jq -n \
            --arg command "$cmd" \
            --argjson args "$args_json" \
            --argjson env "$env_json" \
            '{type: "stdio", command: $command, args: $args} + (if ($env | length) > 0 then {env: $env} else {} end)')
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${DIM}[DRY-RUN]${RESET} would write to $mcp_file:"
        jq --arg n "$name" --argjson s "$server_json" '{($n): $s}' <<<"{}"
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    jq --arg n "$name" --argjson s "$server_json" \
        '.mcpServers = ((.mcpServers // {}) | .[$n] = $s)' "$mcp_file" >"$tmp"
    mv "$tmp" "$mcp_file"

    log_success "Added MCP server '$name' to profile '$profile'"
    log_info "Restart the sandbox for it to take effect."
}

cmd_mcp_rm() {
    local profile="${ARGS[0]:-}"
    local name="${ARGS[1]:-}"

    if [[ -z "$profile" || -z "$name" ]]; then
        log_error "Usage: ${SCRIPT_NAME} mcp-rm PROFILE NAME"
        exit 1
    fi
    require_profile_dir "$profile"

    local mcp_file="$PROFILES_DIR/$profile/mcp.json"
    if [[ ! -f "$mcp_file" ]]; then
        log_error "Profile '$profile' has no mcp.json"
        exit 1
    fi
    if ! jq -e --arg n "$name" '.mcpServers[$n]' "$mcp_file" >/dev/null 2>&1; then
        log_error "No MCP server '$name' in profile '$profile'"
        exit 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${DIM}[DRY-RUN]${RESET} would remove '$name' from $mcp_file"
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    jq --arg n "$name" 'del(.mcpServers[$n])' "$mcp_file" >"$tmp"
    mv "$tmp" "$mcp_file"
    log_success "Removed MCP server '$name' from profile '$profile'"
}

cmd_skill_add() {
    local profile="${ARGS[0]:-}"
    local src="${ARGS[1]:-}"

    if [[ -z "$profile" || -z "$src" ]]; then
        log_error "Usage: ${SCRIPT_NAME} skill-add PROFILE SRC"
        log_info "SRC is a skill directory, e.g. ~/.claude/skills/renovate-config"
        exit 1
    fi
    require_profile_dir "$profile"

    src="${src%/}"
    if [[ ! -d "$src" ]]; then
        log_error "Not a directory: $src"
        exit 1
    fi
    if [[ ! -f "$src/SKILL.md" ]]; then
        log_error "$src has no SKILL.md — Claude Code would not load it"
        exit 1
    fi

    local name
    name=$(basename "$src")
    local dest="$PROFILES_DIR/$profile/skills/$name"
    if [[ -d "$dest" ]]; then
        log_warning "Skill '$name' already in profile '$profile' — replacing it"
        execute_cmd rm -rf "$dest"
    fi

    execute_cmd mkdir -p "$PROFILES_DIR/$profile/skills"
    # -L dereferences: skills under ~/.claude/skills are often symlinks to a
    # checkout elsewhere, and copying the link itself would leave a dangling
    # pointer that resolves on the host and breaks in the container.
    execute_cmd cp -aL "$src" "$dest"
    log_success "Added skill '$name' to profile '$profile'"

    # Skills that shell out to host paths are the usual disappointment: they
    # resolve on the host and vanish in the container.
    if grep -rqE '(/Users/|/opt/homebrew/|~/dev/)' "$dest" 2>/dev/null; then
        log_warning "'$name' references host paths. Mount them in docker-compose.override.yml or it will fail in the sandbox:"
        grep -rhoE '(/Users/[A-Za-z0-9._/-]+|/opt/homebrew/[A-Za-z0-9._/-]+|~/dev/[A-Za-z0-9._-]+)' "$dest" 2>/dev/null | sort -u | head -5 | sed 's/^/        /'
    fi
}

cmd_skill_rm() {
    local profile="${ARGS[0]:-}"
    local name="${ARGS[1]:-}"

    if [[ -z "$profile" || -z "$name" ]]; then
        log_error "Usage: ${SCRIPT_NAME} skill-rm PROFILE NAME"
        exit 1
    fi
    require_profile_dir "$profile"

    local dest="$PROFILES_DIR/$profile/skills/$name"
    if [[ ! -d "$dest" ]]; then
        log_error "No skill '$name' in profile '$profile'"
        exit 1
    fi
    execute_cmd rm -rf "$dest"
    log_success "Removed skill '$name' from profile '$profile'"
}

cmd_doctor() {
    local issues=0
    local active
    active=$(active_profile)

    echo
    echo -e "${BOLD}Checking profiles${RESET}"

    if [[ ! -d "$PROFILES_DIR/$active" ]]; then
        log_error "Active profile '$active' has no directory at profiles/$active"
        issues=$((issues + 1))
    fi

    while IFS= read -r profile; do
        [[ -n "$profile" ]] || continue
        [[ "$profile" == "common" ]] && continue

        # Compose creates a missing bind-mount source as root; a root-owned
        # profile or state directory silently contributes nothing.
        local d
        for d in "$PROFILES_DIR/$profile" "$STATE_DIR/$profile"; do
            if [[ -d "$d" && ! -w "$d" ]]; then
                log_error "$profile: $(basename "$(dirname "$d")")/$profile is not writable (root-owned?)"
                issues=$((issues + 1))
            fi
        done

        if [[ ! -d "$STATE_DIR/$profile" ]]; then
            log_warning "$profile: no state directory — compose will create it as root. Run: ${SCRIPT_NAME} new $profile"
            issues=$((issues + 1))
        fi

        local mcp_file="$PROFILES_DIR/$profile/mcp.json"
        if [[ -f "$mcp_file" ]]; then
            if ! jq empty "$mcp_file" 2>/dev/null; then
                log_error "$profile: mcp.json is not valid JSON"
                issues=$((issues + 1))
            else
                local key value status
                while IFS=$'\t' read -r key value; do
                    [[ -n "$key" ]] || continue
                    if is_env_reference "$value"; then
                        status=$(env_var_status "$value")
                        case "$status" in
                            unset)
                                log_warning "$profile: $key references $value, which is not set in .env"
                                issues=$((issues + 1))
                                ;;
                            no-passthrough)
                                log_warning "$profile: $key references $value, set in .env but missing from docker-compose.yml environment:"
                                issues=$((issues + 1))
                                ;;
                        esac
                    else
                        log_warning "$profile: $key holds a literal value — move it to .env and reference \${$key}"
                        issues=$((issues + 1))
                    fi
                done < <(jq -r '.mcpServers // {} | to_entries[] | .value.env // {} | to_entries[] | "\(.key)\t\(.value)"' "$mcp_file")
            fi
        fi

        # A skill directory without SKILL.md is invisible to Claude Code.
        local skill
        while IFS= read -r skill; do
            [[ -n "$skill" ]] || continue
            if [[ ! -f "$skill/SKILL.md" ]]; then
                log_warning "$profile: skills/$(basename "$skill") has no SKILL.md — it will not load"
                issues=$((issues + 1))
            fi
        done < <(find -L "$PROFILES_DIR/$profile/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    done < <(find -L "$PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)

    # State directories whose profile is gone: harmless, but they hold a login.
    if [[ -d "$STATE_DIR" ]]; then
        local orphan
        while IFS= read -r orphan; do
            [[ -n "$orphan" ]] || continue
            if [[ ! -d "$PROFILES_DIR/$orphan" ]]; then
                log_warning "profile-state/$orphan has no matching profile — leftover from a removed one"
                issues=$((issues + 1))
            fi
        done < <(find -L "$STATE_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
    fi

    echo
    if [[ $issues -eq 0 ]]; then
        log_success "No problems found"
    else
        log_warning "$issues issue(s) found"
    fi
    echo
}

cmd_run() {
    local profile
    profile=$(active_profile)

    # Flags after `run` win over an inherited CLAUDE_ARGS; compose passes the
    # variable through and the container's CMD word-splits it onto `claude`.
    local claude_args="${CLAUDE_ARGS:-}"
    if [[ ${#ARGS[@]} -gt 0 ]]; then
        claude_args="${ARGS[*]}"
    fi

    # Catch a typo before compose does: it would create the missing directory
    # as root and start a sandbox with an empty profile.
    require_profile_dir "$profile"

    # The profile itself is valid, so a missing state directory is just a first
    # run (a fresh clone has none — profile-state/ is gitignored). Create it as
    # the invoking user; letting compose do it would make it root-owned and the
    # sandbox would fail to write its login.
    if [[ ! -d "$STATE_DIR/$profile" ]]; then
        log_info "Creating profile-state/$profile (first run for this profile)"
        execute_cmd mkdir -p "$STATE_DIR/$profile"
    fi

    log_info "Starting sandbox with profile '$profile'"
    [[ -n "$claude_args" ]] && log_verbose "claude args: $claude_args"

    # CLAUDE_PROFILE is passed explicitly so --profile reaches compose too.
    execute_cmd env CLAUDE_PROFILE="$profile" CLAUDE_ARGS="$claude_args" \
        docker compose run --rm claude
}

main() {
    parse_args "$@"

    if [[ "$HELP" == "true" || "${COMMAND}" == "help" ]]; then
        show_help
        exit 0
    fi

    check_prerequisites

    case "${COMMAND:-list}" in
        list)      cmd_list ;;
        profiles)  cmd_profiles ;;
        new)       cmd_new ;;
        mcp-add)   cmd_mcp_add ;;
        mcp-rm)    cmd_mcp_rm ;;
        skill-add) cmd_skill_add ;;
        skill-rm)  cmd_skill_rm ;;
        doctor)    cmd_doctor ;;
        run)       cmd_run ;;
        *)
            log_error "Unknown command: $COMMAND"
            echo "Run '${SCRIPT_NAME} --help' for usage." >&2
            exit 1
            ;;
    esac
}

main "$@"
