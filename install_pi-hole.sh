#!/usr/bin/env bash
#
# Deploy Pi-hole on Raspberry Pi OS / Debian with Docker.
#
#   sudo ./install_pi-hole.sh              # install or upgrade in place
#   sudo ./install_pi-hole.sh --check      # report readiness, change nothing
#        ./install_pi-hole.sh --dry-run    # print every command, change nothing
#   sudo ./install_pi-hole.sh --version 2026.11.0
#
# Design rules:
#   * Idempotent. Running it twice is a no-op, not a second stack.
#   * No `curl | sh`. Docker comes from its signed apt repository unless you
#     explicitly ask for the convenience script with --docker-script.
#   * No silent system changes. It does not enable SSH, does not run a distro
#     upgrade, and does not rewrite /etc/resolv.conf.
#   * The admin password is generated, stored in .env (mode 600), and never
#     passed on a command line where `ps` would show it.
#   * Every failure path leaves the previous deployment running.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
readonly DHCP_FILE="${SCRIPT_DIR}/docker-compose.dhcp.yml"
readonly CONTAINER_NAME="pihole"
readonly DEFAULT_VERSION="2026.11.0"
readonly HEALTH_TIMEOUT_SECONDS=180

DRY_RUN=false
CHECK_ONLY=false
INSTALL_DOCKER_SCRIPT=false
REQUESTED_VERSION=""

# ------------------------------------------------------------------ plumbing

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local status=$? line=$1
  printf '\n\033[1;31m[✗]\033[0m failed at install_pi-hole.sh:%s (exit %s)\n' "$line" "$status" >&2
  printf '    The previous deployment, if any, was left untouched.\n' >&2
  if [ "$CHECK_ONLY" = false ] && [ "$DRY_RUN" = false ] && have docker; then
    printf '    Inspect with: docker compose -f %s logs --tail 50\n' "$COMPOSE_FILE" >&2
  fi
  exit "$status"
}
trap 'on_error $LINENO' ERR

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --check              report what is missing and exit; changes nothing
  --dry-run            print the commands that would run; changes nothing
  --version <tag>      deploy this pihole/pihole release (writes PIHOLE_VERSION)
  --docker-script      install Docker with get.docker.com if Docker is missing
  --yes                do not prompt for confirmation
  --help               this text
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }

# Runs a mutating command, or prints it in --dry-run mode.
run() {
  if [ "$DRY_RUN" = true ]; then
    printf '    [dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

confirm() {
  [ "$DRY_RUN" = true ] && return 0
  [ "$ASSUME_YES" = true ] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  case "$reply" in y|Y|yes|YES) return 0 ;; *) die "aborted by user" ;; esac
}

# Value of KEY from .env, without executing the file. Always succeeds: a
# missing key is an empty value, not an error (command substitution under
# `set -e` would otherwise trip the ERR trap).
env_value() {
  if [ -f "$ENV_FILE" ]; then
    sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -n 1 | sed -e 's/^"//' -e 's/"$//'
  fi
  return 0
}

set_env_value() {
  local key=$1 value=$2
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

# --------------------------------------------------------------- preflight

load_platform() {
  [ -r /etc/os-release ] || die "cannot read /etc/os-release; this installer targets Debian-derived systems"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|raspbian|ubuntu) : ;;
    *) warn "untested distribution '${ID:-unknown}'; continuing on a Debian-like assumption" ;;
  esac
  case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    amd64|arm64|armhf) : ;;
    *) warn "architecture '$(uname -m)' is not one Pi-hole publishes images for" ;;
  esac
}

port_in_use() { # proto port
  local proto=$1 port=$2
  if have ss; then
    if [ "$proto" = tcp ]; then
      ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
    else
      ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
    fi
  else
    # Best effort without ss: only TCP can be probed this way.
    [ "$proto" = tcp ] && timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null
  fi
}

our_container_running() {
  have docker || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)" = "true" ] || return 1
  [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$CONTAINER_NAME" 2>/dev/null || true)" = "pihole" ]
}

port_owner_hint() { # port
  local port=$1
  if have ss; then
    ss -H -lunp "sport = :${port}" 2>/dev/null | head -n 1
  fi
}

check_ports() {
  local dns_port web_port https_port problem=0
  dns_port=$(env_value PIHOLE_DNS_PORT || true); dns_port=${dns_port:-53}
  web_port=$(env_value PIHOLE_WEB_PORT || true); web_port=${web_port:-80}
  https_port=$(env_value PIHOLE_HTTPS_PORT || true); https_port=${https_port:-443}

  if our_container_running; then
    ok "Pi-hole is already running on this host; the port check is skipped"
    return 0
  fi

  if port_in_use tcp "$dns_port" || port_in_use udp "$dns_port"; then
    warn "port ${dns_port} is already in use: $(port_owner_hint "$dns_port" || true)"
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      warn "  systemd-resolved's stub listener is the usual cause. Set"
      warn "  DNSStubListener=no in /etc/systemd/resolved.conf, then: systemctl restart systemd-resolved"
      warn "  (this keeps resolved for local name resolution and frees port 53)"
    fi
    warn "  or set PIHOLE_DNS_PORT to a free port in .env"
    problem=1
  fi
  for port in "$web_port" "$https_port"; do
    if port_in_use tcp "$port"; then
      warn "port ${port} is already in use: $(port_owner_hint "$port" || true)"
      warn "  change PIHOLE_WEB_PORT / PIHOLE_HTTPS_PORT in .env, or stop the other service"
      problem=1
    fi
  done
  [ "$problem" -eq 0 ] && ok "ports ${dns_port}/tcp+udp, ${web_port}/tcp, ${https_port}/tcp are free"
  return "$problem"
}

check_container_collision() {
  have docker || return 0
  docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || return 0
  our_container_running || \
  [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$CONTAINER_NAME" 2>/dev/null || true)" = "pihole" ] || \
    die "a container named '${CONTAINER_NAME}' exists but was not created by this compose project; rename or remove it first"
}

check_dns_reachability() {
  if have getent && getent hosts registry-1.docker.io >/dev/null 2>&1; then
    ok "DNS resolution works (registry-1.docker.io resolves)"
    return 0
  fi
  warn "cannot resolve registry-1.docker.io; the image pull will fail"
  warn "  fix the host's resolver first. This installer deliberately does not"
  warn "  rewrite /etc/resolv.conf: doing so on a systemd-resolved host breaks DNS"
  warn "  in a way that survives a reboot."
  return 1
}

check_disk() {
  local avail_kb
  avail_kb=$(df -Pk "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
  if [ "$avail_kb" -lt 2097152 ]; then
    warn "less than 2 GB free in ${SCRIPT_DIR} (${avail_kb} KB); the image needs about 1 GB"
    return 1
  fi
  ok "disk space: $((avail_kb / 1024)) MB free"
}

validate_pihole_version() {
  local version=$1
  [[ "$version" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]] || \
    die "PIHOLE_VERSION '${version}' is not a release tag like 2026.11.0 (refusing to chase 'latest')"
}

validate_password() {
  local password=$1
  [ "${#password}" -ge 12 ] || die "WEBPASSWORD must be at least 12 characters"
  # These characters would be reinterpreted by compose's .env interpolation.
  case "$password" in
    *[[:space:]]*|*'"'*|*"'"*|*'#'*|*'$'*|*\\*)
      die "WEBPASSWORD must not contain quotes, #, backslash, \$ or spaces: docker compose would misread it" ;;
  esac
}

# --------------------------------------------------------------- env file

generate_password() {
  if have openssl; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24
  else
    dd if=/dev/urandom bs=96 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-24
  fi
}

ensure_env() {
  if [ ! -f "$ENV_FILE" ]; then
    [ -f "$ENV_EXAMPLE" ] || die ".env.example is missing; cannot create .env"
    log "creating .env from .env.example (mode 600)"
    run cp "$ENV_EXAMPLE" "$ENV_FILE"
    run chmod 600 "$ENV_FILE"
  else
    run chmod 600 "$ENV_FILE"
  fi

  local timezone
  timezone=$(env_value TZ || true)
  if [ -z "$timezone" ]; then
    timezone=$(cat /etc/timezone 2>/dev/null || true)
    if [ -z "$timezone" ] && have timedatectl; then
      timezone=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    fi
    run set_env_value TZ "${timezone:-UTC}"
    ok "timezone set to ${timezone:-UTC} from the host"
  fi

  local password=""
  password=$(env_value WEBPASSWORD || true)
  if [ -z "$password" ]; then
    password=$(generate_password)
    log "generating a 24-character admin password"
    run set_env_value WEBPASSWORD "$password"
    GENERATED_PASSWORD=$password
  fi
  validate_password "$password"

  if [ -n "$REQUESTED_VERSION" ]; then
    run set_env_value PIHOLE_VERSION "$REQUESTED_VERSION"
  fi
  local version
  version=$(env_value PIHOLE_VERSION || true)
  if [ -z "$version" ]; then
    # An .env from an older checkout predates the pinned image tag.
    version=$DEFAULT_VERSION
    run set_env_value PIHOLE_VERSION "$version"
  fi
  validate_pihole_version "$version"
  local dns_port web_port
  dns_port=$(env_value PIHOLE_DNS_PORT); dns_port=${dns_port:-53}
  web_port=$(env_value PIHOLE_WEB_PORT); web_port=${web_port:-80}
  ok "configuration: Pi-hole ${version}, DNS port ${dns_port}, web port ${web_port}"
}

dhcp_enabled() {
  [ "$(env_value PIHOLE_ENABLE_DHCP || true)" = "true" ]
}

compose() {
  local args=(-f "$COMPOSE_FILE")
  if dhcp_enabled; then
    args+=(-f "$DHCP_FILE")
  fi
  docker compose --project-directory "$SCRIPT_DIR" "${args[@]}" "$@"
}

# ------------------------------------------------------------------ docker

ensure_docker() {
  if have docker && docker compose version >/dev/null 2>&1; then
    ok "docker $(docker --version | sed 's/Docker version //; s/,.*//') with the compose plugin is present"
    return 0
  fi

  if [ "$INSTALL_DOCKER_SCRIPT" = true ]; then
    warn "installing Docker from get.docker.com at your request; this is a moving remote script"
    local tmp
    tmp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    run curl -fsSL --proto '=https' --tlsv1.2 https://get.docker.com -o "$tmp"
    run sh "$tmp"
  else
    log "installing Docker from Docker's signed apt repository"
    # shellcheck disable=SC1091
    . /etc/os-release
    run apt-get update -y
    run apt-get install -y ca-certificates curl gnupg
    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL --proto '=https' --tlsv1.2 "https://download.docker.com/linux/${ID}/gpg" \
      -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc
    local repo_line
    repo_line="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable"
    if [ "$DRY_RUN" = true ]; then
      printf '    [dry-run] write %s\n' "$repo_line"
    else
      printf '%s\n' "$repo_line" > /etc/apt/sources.list.d/docker.list
    fi
    run apt-get update -y
    run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  run systemctl enable --now docker
  docker compose version >/dev/null 2>&1 || die "Docker installed but the compose plugin is not available"
}

# ------------------------------------------------------------------ deploy

deploy() {
  log "validating the compose file and .env interpolation"
  if [ "$DRY_RUN" = false ]; then
    compose config --quiet || die "docker compose config rejected the deployment files"
  else
    printf '    [dry-run] docker compose config --quiet\n'
  fi

  log "pulling pihole/pihole:$(configured_version)"
  run compose pull

  log "starting the stack (an existing deployment is recreated only if the image changed)"
  run compose up -d --remove-orphans
}

wait_for_health() {
  [ "$DRY_RUN" = true ] && return 0
  local waited=0 status
  log "waiting for Pi-hole to become healthy (timeout ${HEALTH_TIMEOUT_SECONDS}s)"
  while [ "$waited" -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)
    case "$status" in
      healthy) ok "container is healthy after ${waited}s"; return 0 ;;
      exited|dead|missing) break ;;
    esac
    sleep 5
    waited=$((waited + 5))
  done
  compose logs --no-color --tail 50 >&2 || true
  die "Pi-hole did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s (last status: ${status:-unknown})"
}

configured_version() { local v; v=$(env_value PIHOLE_VERSION); echo "${v:-$DEFAULT_VERSION}"; }
dns_port() { local p; p=$(env_value PIHOLE_DNS_PORT); echo "${p:-53}"; }
web_port() { local p; p=$(env_value PIHOLE_WEB_PORT); echo "${p:-80}"; }

verify_deployment() {
  [ "$DRY_RUN" = true ] && return 0
  local port answer code
  port=$(dns_port)

  # pi.hole is answered by FTL itself, so this tests Pi-hole and not upstream.
  if have dig; then
    answer=$(dig +short +time=2 +tries=2 @127.0.0.1 -p "$port" pi.hole 2>/dev/null | head -n 1)
  else
    answer=$(docker exec "$CONTAINER_NAME" dig +short +time=2 +tries=2 @127.0.0.1 pi.hole 2>/dev/null | head -n 1)
  fi
  [ -n "$answer" ] || die "Pi-hole is running but did not answer a DNS query for pi.hole on port ${port}"
  ok "DNS answers on port ${port} (pi.hole -> ${answer})"

  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$(web_port)/admin/" 2>/dev/null || true)
  case "$code" in
    200|302|401) ok "admin interface answers on port $(web_port) (HTTP ${code})" ;;
    *) warn "admin interface did not answer as expected (HTTP ${code:-none}); check 'docker compose logs pihole'" ;;
  esac
}

summary() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '\n'
  if [ "$DRY_RUN" = true ]; then
    ok "dry run complete; nothing was changed"
  else
    ok "Pi-hole $(configured_version) is deployed"
  fi
  printf '    admin     : http://%s/admin\n' "${ip:-<pi-ip>}"
  printf '    password  : stored in %s (mode 600)\n' "$ENV_FILE"
  if [ -n "${GENERATED_PASSWORD:-}" ]; then
    printf '    generated : %s\n' "$GENERATED_PASSWORD"
    printf '                (shown once; change it in the admin UI if it was logged)\n'
  fi
  printf '    DNS       : point your router or clients at %s\n' "${ip:-<pi-ip>}"
  printf '    upgrade   : sudo ./install_pi-hole.sh --version <new-tag>\n'
  printf '    logs      : docker compose -f %s logs -f pihole\n' "$COMPOSE_FILE"
  printf '    remove    : docker compose -f %s down   (add -v to drop the network)\n' "$COMPOSE_FILE"
}

# -------------------------------------------------------------------- main

parse_args() {
  ASSUME_YES=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) CHECK_ONLY=true ;;
      --dry-run) DRY_RUN=true ;;
      --version) shift; [ $# -gt 0 ] || die "--version needs a tag"; REQUESTED_VERSION=$1 ;;
      --docker-script) INSTALL_DOCKER_SCRIPT=true ;;
      --yes|-y) ASSUME_YES=true ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown argument '$1' (try --help)" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  GENERATED_PASSWORD=""

  if [ "$CHECK_ONLY" = false ] && [ "$DRY_RUN" = false ]; then
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo ./install_pi-hole.sh"
  fi

  cd "$SCRIPT_DIR"
  load_platform

  log "preflight"
  local ready=0
  check_disk || ready=1
  check_container_collision
  check_dns_reachability || ready=1
  if have docker && docker compose version >/dev/null 2>&1; then
    ok "docker with the compose plugin is present"
  else
    warn "docker is not installed; it will be installed from Docker's signed apt repository"
    [ "$CHECK_ONLY" = true ] && ready=1
  fi

  if [ "$CHECK_ONLY" = true ]; then
    check_ports || ready=1
    if [ -f "$ENV_FILE" ]; then
      ok ".env exists; WEBPASSWORD is $([ -n "$(env_value WEBPASSWORD || true)" ] && echo set || echo MISSING)"
    else
      # Missing .env is the normal first-install state, not a problem.
      log ".env does not exist yet; it will be created with a generated password"
    fi
    printf '\n'
    if [ "$ready" -ne 0 ]; then
      warn "not ready: resolve the items above, then re-run"
      exit 1
    fi
    ok "ready to install"
    exit 0
  fi

  confirm "Deploy Pi-hole with a generated or existing password on this host?"
  ensure_env
  check_ports || die "free the ports above, or change PIHOLE_DNS_PORT / PIHOLE_WEB_PORT / PIHOLE_HTTPS_PORT in .env"
  ensure_docker
  deploy
  wait_for_health
  verify_deployment
  summary
}

# Allow the functions to be sourced by a test without deploying anything.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
