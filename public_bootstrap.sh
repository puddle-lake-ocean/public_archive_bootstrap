#!/usr/bin/env bash
set -euo pipefail

BW_POINTER_ITEM="${BW_POINTER_ITEM:-archive_bootstrap_pointer}"
BW_SERVER_URL="${BW_SERVER_URL:-https://vault.bitwarden.com}"
BW_SERVE_READY_TIMEOUT="${BW_SERVE_READY_TIMEOUT:-20}"

RESTORE_TAG=""
RESTORE_PATH=""
RESTORE_HANDOFF=""
HANDOFF_ARGS=()

BOOTSTRAP_BIN=""
BW_SERVE_URL=""
BW_SERVE_PID=""
BW_NFT_TABLE=""
BW_APPDATA=""

CURL_RETRY=(--retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors)
APT_RETRY=(-o Acquire::Retries=5)

log() { printf '\033[34m[bootstrap]\033[0m %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
public_bootstrap.sh — restore an encrypted restic archive onto a fresh
machine. Run as root, from a root-owned terminal. Takes no arguments.
EOF
}

install_os_packages() {
  log "installing OS packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get "${APT_RETRY[@]}" update -qq
  apt-get "${APT_RETRY[@]}" install -y -qq git curl jq unzip bzip2 nftables python3
}

github_release_json() {
  curl -fsSL "${CURL_RETRY[@]}" "https://api.github.com/repos/$1"
}

download_verifying_published_digest() {
  local url="$1" expected="$2" dest="$3" name got
  name="$(basename "$dest")"
  [[ "$expected" == sha256:* ]] || die "GitHub API returned no sha256 digest for $name"
  curl -fsSL "${CURL_RETRY[@]}" "$url" -o "$dest"
  got="sha256:$(sha256sum "$dest" | awk '{print $1}')"
  [[ "$got" == "$expected" ]] || die "digest verification FAILED for $name
  expected: $expected
  got:      $got"
  log "digest OK: $name ($expected)"
}

install_restic() {
  local rel_json want_ver tmp assets bz2_name bz2_url expected
  rel_json="$(github_release_json restic/restic/releases/latest)"
  want_ver="$(jq -r '.tag_name | sub("^v"; "")' <<<"$rel_json")"
  [ -n "$want_ver" ] || die "could not determine latest restic release"
  log "installing restic $want_ver (digest-verified)..."

  tmp="$(mktemp -d)"
  assets="$(jq -r --arg v "$want_ver" \
    '.assets[] | [.name, .browser_download_url, (.digest // "")] | @tsv' <<<"$rel_json")"
  IFS=$'\t' read -r bz2_name bz2_url expected < <(
    awk -F'\t' -v v="$want_ver" '$1 == "restic_" v "_linux_amd64.bz2" {print; exit}' <<<"$assets"
  )
  [ -n "$bz2_url" ] || die "no restic_${want_ver}_linux_amd64.bz2 in release assets"

  download_verifying_published_digest "$bz2_url" "$expected" "$tmp/$bz2_name"
  bunzip2 -k "$tmp/$bz2_name"
  install -m 0755 "$tmp/${bz2_name%.bz2}" "$BOOTSTRAP_BIN/restic"
  rm -rf "$tmp"
}

newest_cli_tag_in_monorepo_release_list() {
  local ver
  ver="$(jq -r '.[].tag_name | select(startswith("cli-v"))' <<<"$1" \
          | sed 's/^cli-v//' | sort -V | tail -n1)"
  [ -n "$ver" ] || return 1
  printf 'cli-v%s' "$ver"
}

install_bw_cli() {
  log "installing Bitwarden CLI (digest-verified)..."
  local tmp rel_json cli_tag assets zip_url zip_name expected
  tmp="$(mktemp -d)"
  rel_json="$(github_release_json 'bitwarden/clients/releases?per_page=100')"
  cli_tag="$(newest_cli_tag_in_monorepo_release_list "$rel_json")" \
    || die "could not determine latest Bitwarden CLI release"

  assets="$(jq -r --arg t "$cli_tag" \
    '.[] | select(.tag_name==$t) | .assets[] | [.name, .browser_download_url, (.digest // "")] | @tsv' \
    <<<"$rel_json")"
  IFS=$'\t' read -r zip_name zip_url expected < <(
    awk -F'\t' '$1 ~ /^bw-linux-[0-9].*\.zip$/ {print; exit}' <<<"$assets"
  )
  [ -n "$zip_url" ] || die "no bw-linux amd64 zip in $cli_tag assets"

  download_verifying_published_digest "$zip_url" "$expected" "$tmp/$zip_name"
  unzip -q "$tmp/$zip_name" -d "$tmp"
  install -m 0755 "$tmp/bw" "$BOOTSTRAP_BIN/bw"
  rm -rf "$tmp"
}

stage_tools_that_are_not_part_of_the_archive() {
  if command -v restic >/dev/null 2>&1 && command -v bw >/dev/null 2>&1; then
    log "restic + bw already resolve on PATH — skipping transient fetch."
    return 0
  fi
  BOOTSTRAP_BIN="$(mktemp -d)"
  trap remove_transient_state EXIT INT TERM
  export PATH="$BOOTSTRAP_BIN:$PATH"
  install_restic
  install_bw_cli
}

remove_transient_state() {
  if [ -n "$BW_SERVE_PID" ]; then
    kill "$BW_SERVE_PID" 2>/dev/null || true
    wait "$BW_SERVE_PID" 2>/dev/null || true
    BW_SERVE_PID=""
  fi
  if [ -n "$BW_NFT_TABLE" ]; then
    if nft list table ip "$BW_NFT_TABLE" >/dev/null 2>&1; then
      nft delete table ip "$BW_NFT_TABLE" || true
    fi
    BW_NFT_TABLE=""
  fi
  if [ -n "$BW_APPDATA" ]; then rm -rf "$BW_APPDATA"; BW_APPDATA=""; fi
  if [ -n "$BOOTSTRAP_BIN" ]; then rm -rf "$BOOTSTRAP_BIN"; BOOTSTRAP_BIN=""; fi
  return 0
}

bind_a_port_and_release_it() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

url_encode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

vault_api() {
  local method="$1" path="$2" body="${3:-}" resp
  if [ -n "$body" ]; then
    resp="$(curl -sS -m 30 -X "$method" "$BW_SERVE_URL$path" \
      -H 'Content-Type: application/json' --data-binary "$body")" || return 1
  else
    resp="$(curl -sS -m 30 -X "$method" "$BW_SERVE_URL$path")" || return 1
  fi
  if [ "$(jq -r '.success // false' <<<"$resp" 2>/dev/null)" != "true" ]; then
    echo "vault API: $method $path failed:" \
      "$(jq -r '.message // "unknown error"' <<<"$resp" 2>/dev/null)" >&2
    return 1
  fi
  printf '%s' "$resp"
}

vault_item_matching_name_exactly() {
  local name="$1" resp item
  resp="$(vault_api GET "/list/object/items?search=$(url_encode "$name")")" || return 1
  item="$(jq -c --arg n "$name" \
    'first(.data.data[]? | select(.name == $n and (.deletedDate == null)))' \
    <<<"$resp" 2>/dev/null)"
  [ -n "$item" ] && [ "$item" != "null" ] || return 1
  printf '%s' "$item"
}

item_field_value() {
  jq -r --arg f "$1" '.fields[]? | select(.name==$f) | .value // empty' <<<"$2"
}

this_console_cannot_draw_stars() { [ ! -e /dev/tty ] || ! [ -t 0 ]; }

read_secret_without_showing_its_length() {
  read -r -s -p "$2" "$1"
  echo
}

silence_the_terminal_echo_before_the_prompt_invites_typing() {
  stty -echo -icanon min 1 time 0 </dev/tty
  printf '%s' "$1" >/dev/tty
}

draw_one_star()    { printf '*'     >/dev/tty; }
rub_out_one_star() { printf '\b \b' >/dev/tty; }

restore_the_terminal_and_end_the_line() {
  stty "$1" </dev/tty
  printf '\n' >/dev/tty
}

read_secret_starred() {
  local __var="$1" __prompt="$2" __acc="" __ch __saved
  if this_console_cannot_draw_stars; then
    read_secret_without_showing_its_length "$__var" "$__prompt"
    return 0
  fi
  __saved="$(stty -g </dev/tty)" || return 1
  silence_the_terminal_echo_before_the_prompt_invites_typing "$__prompt"
  while IFS= read -r -n1 __ch </dev/tty; do
    case "$__ch" in
      '')            break ;;
      $'\003')       restore_the_terminal_and_end_the_line "$__saved"; exit 130 ;;
      $'\177'|$'\b') if [ -n "$__acc" ]; then __acc="${__acc%?}"; rub_out_one_star; fi ;;
      $'\025')       while [ -n "$__acc" ]; do __acc="${__acc%?}"; rub_out_one_star; done ;;
      *)             __acc="$__acc$__ch"; draw_one_star ;;
    esac
  done
  restore_the_terminal_and_end_the_line "$__saved"
  printf -v "$__var" '%s' "$__acc"
  unset __acc
}

prompt_for_account_and_master_password() {
  if [ -z "${BW_EMAIL:-}" ]; then
    read -r -p "Bitwarden account email: " BW_EMAIL
  fi
  [ -n "$BW_EMAIL" ] || die "email required"
  if [ -z "${BW_MASTER:-}" ]; then
    read_secret_starred BW_MASTER "Master password: "
  fi
  [ -n "$BW_MASTER" ] || die "master password required"
  export BW_EMAIL BW_MASTER BW_SERVER_URL
}

discard_appdata_from_the_refused_attempt() {
  rm -rf "${BW_APPDATA:?}"
  mkdir -p "$BW_APPDATA"
  chmod 0700 "$BW_APPDATA"
  bw config server "$BW_SERVER_URL" >/dev/null
}

login_asking_again_while_someone_can_answer() {
  local tries=0 retyped_email
  until bw login "$BW_EMAIL" --passwordenv BW_MASTER --raw >/dev/null; do
    tries=$((tries + 1))
    if [ ! -t 0 ] || [ "$tries" -ge 3 ]; then
      echo "ERROR: could not log in to $BW_SERVER_URL as $BW_EMAIL." >&2
      echo "  Check BOTH the address and the password — bw reports one message" >&2
      echo "  for a wrong password and a wrong account, and it cannot tell you" >&2
      echo "  which. Nothing has been written outside this live session." >&2
      exit 1
    fi
    echo >&2
    echo "  that login was refused (attempt $tries of 3)." >&2
    echo "  account: $BW_EMAIL" >&2
    echo "  Enter a different address, or press Enter to keep that one." >&2
    read -r retyped_email
    [ -z "$retyped_email" ] || BW_EMAIL="$retyped_email"
    read_secret_starred BW_MASTER "Master password: "
    [ -n "$BW_MASTER" ] || die "master password required"
    export BW_EMAIL BW_MASTER
    discard_appdata_from_the_refused_attempt
  done
}

reject_nonroot_traffic_to_port_before_daemon_binds() {
  local port="$1"
  BW_NFT_TABLE="bw_bootstrap_$$"
  nft delete table ip "$BW_NFT_TABLE" 2>/dev/null || true
  nft -f - <<EOF || die "could not install the nftables uid guard — refusing to expose an unlocked vault."
table ip $BW_NFT_TABLE {
  chain output {
    type filter hook output priority 0; policy accept;
    ip daddr 127.0.0.1 tcp dport $port meta skuid != 0 reject with tcp reset
  }
}
EOF
}

wait_until_the_vault_daemon_answers() {
  local waited=0
  until curl -sS -m 2 "$BW_SERVE_URL/status" >/dev/null 2>&1; do
    kill -0 "$BW_SERVE_PID" 2>/dev/null \
      || die "the vault daemon exited before becoming ready"
    sleep 0.5
    waited=$((waited + 1))
    [ "$waited" -le $((BW_SERVE_READY_TIMEOUT * 2)) ] \
      || die "the vault daemon was not ready within ${BW_SERVE_READY_TIMEOUT}s"
  done
}

bw_session_start() {
  [ -z "$BW_SERVE_URL" ] || return 0
  trap remove_transient_state EXIT INT TERM

  prompt_for_account_and_master_password

  BW_APPDATA="$(mktemp -d /dev/shm/bw-data.XXXXXX)"
  export BITWARDENCLI_APPDATA_DIR="$BW_APPDATA"
  bw config server "$BW_SERVER_URL" >/dev/null
  if ! bw login --check >/dev/null 2>&1; then
    log "logging in to $BW_SERVER_URL ..."
    log "  If this account has two-step login, or this machine is new to it,"
    log "  bw asks for a code below. A bare machine is always a new device."
    login_asking_again_while_someone_can_answer
    log "  logged in"
  fi

  local port
  port="$(bind_a_port_and_release_it)" || die "could not allocate a local port"
  reject_nonroot_traffic_to_port_before_daemon_binds "$port"

  bw serve --hostname 127.0.0.1 --port "$port" >/dev/null 2>&1 &
  BW_SERVE_PID=$!
  BW_SERVE_URL="http://127.0.0.1:$port"
  export BW_SERVE_URL
  wait_until_the_vault_daemon_answers

  vault_api POST /unlock "$(jq -n --arg p "$BW_MASTER" '{password:$p}')" >/dev/null \
    || die "vault unlock failed"
  vault_api POST /sync >/dev/null || die "vault sync failed"
  log "vault unlocked; the daemon is root-only and dies with this script."
}

pointer_note_or_die() {
  local ptr note
  ptr="$(vault_item_matching_name_exactly "$BW_POINTER_ITEM")" || {
    echo "ERROR: no vault item named '$BW_POINTER_ITEM'." >&2
    echo "       Set BW_POINTER_ITEM if it is named something else." >&2
    exit 1
  }
  note="$(jq -r '.notes // empty' <<<"$ptr")"
  [ -n "$note" ] || {
    die "'$BW_POINTER_ITEM' has an empty note"
  }
  jq -e . >/dev/null 2>&1 <<<"$note" || die "the note on '$BW_POINTER_ITEM' is not JSON."
  printf '%s' "$note"
}

require_absolute_restore_path() {
  case "$RESTORE_PATH" in
    /*) ;;
    *) die "restore.path must be absolute, got '$RESTORE_PATH'" ;;
  esac
}

export_credentials_for_this_process_only() {
  export AWS_ACCESS_KEY_ID="$1"
  export AWS_SECRET_ACCESS_KEY="$2"
  export RESTIC_REPOSITORY="$3"
  export RESTIC_PASSWORD="$4"
}

resolve_credentials_from_the_first_complete_item() {
  local f_id="$1" f_key="$2" f_repo="$3" f_pass="$4"; shift 4
  local name item_json b2_id b2_key repo pass
  for name in "$@"; do
    if ! item_json="$(vault_item_matching_name_exactly "$name" 2>/dev/null)"; then
      log "  '$name' — absent, trying the next"
      continue
    fi
    b2_id="$(  item_field_value "$f_id"   "$item_json")"
    b2_key="$( item_field_value "$f_key"  "$item_json")"
    repo="$(   item_field_value "$f_repo" "$item_json")"
    pass="$(   item_field_value "$f_pass" "$item_json")"
    if [ -n "$b2_id" ] && [ -n "$b2_key" ] && [ -n "$repo" ] && [ -n "$pass" ]; then
      export_credentials_for_this_process_only "$b2_id" "$b2_key" "$repo" "$pass"
      log "credentials resolved from '$name'."
      return 0
    fi
    log "  '$name' — present but missing one of the four fields, trying the next"
  done
  echo "ERROR: none of the items named by '$BW_POINTER_ITEM' resolved a" >&2
  echo "       complete credential set. Either its note's field names are" >&2
  echo "       stale, or every item it names is gone." >&2
  exit 1
}

read_pointer() {
  log "reading the vault item '$BW_POINTER_ITEM'..."
  local note f_id f_key f_repo f_pass miss=()
  note="$(pointer_note_or_die)"

  f_id="$(  jq -r '.fields.key_id // empty'        <<<"$note")"
  f_key="$( jq -r '.fields.key_secret // empty'    <<<"$note")"
  f_repo="$(jq -r '.fields.repo_url // empty'      <<<"$note")"
  f_pass="$(jq -r '.fields.repo_password // empty' <<<"$note")"
  RESTORE_TAG="$(    jq -r '.restore.tag // empty'     <<<"$note")"
  RESTORE_PATH="$(   jq -r '.restore.path // empty'    <<<"$note")"
  RESTORE_HANDOFF="$(jq -r '.restore.handoff // empty' <<<"$note")"

  local -a names=()
  mapfile -t names < <(jq -r '.credentials[]? | select(length > 0)' <<<"$note")

  [ "${#names[@]}" -gt 0 ] || miss+=(credentials)
  [ -n "$f_id" ]            || miss+=(fields.key_id)
  [ -n "$f_key" ]           || miss+=(fields.key_secret)
  [ -n "$f_repo" ]          || miss+=(fields.repo_url)
  [ -n "$f_pass" ]          || miss+=(fields.repo_password)
  [ -n "$RESTORE_TAG" ]     || miss+=(restore.tag)
  [ -n "$RESTORE_PATH" ]    || miss+=(restore.path)
  [ -n "$RESTORE_HANDOFF" ] || miss+=(restore.handoff)
  [ "${#miss[@]}" -eq 0 ] || die "the note on '$BW_POINTER_ITEM' is missing: ${miss[*]}"

  require_absolute_restore_path
  resolve_credentials_from_the_first_complete_item \
    "$f_id" "$f_key" "$f_repo" "$f_pass" "${names[@]}"
}

report_that_this_repository_holds_no_snapshot_and_stop() {
  cat <<EOF

============================================================
 No '$RESTORE_TAG' snapshot in this repository.

 This script restores an archive; it does not create one.
 Push an initial snapshot from a machine that has one, then
 re-run here.
============================================================
EOF
  exit 0
}

restore_bootstrap() {
  install -d -m 0755 -o root -g root "$(dirname "$RESTORE_PATH")"

  local snap
  snap="$(restic snapshots --tag "$RESTORE_TAG" --latest 1 --json 2>/dev/null \
            | jq -r '.[0].short_id // empty')"
  [ -n "$snap" ] || report_that_this_repository_holds_no_snapshot_and_stop

  if [ -e "$RESTORE_PATH" ] && [ -n "$(ls -A "$RESTORE_PATH" 2>/dev/null)" ]; then
    log "$RESTORE_PATH already populated — skipping restore."
    return 0
  fi

  log "restoring (snapshot $snap)..."
  local tmp
  tmp="$(mktemp -d)"
  restic restore "$snap" --target "$tmp"
  [ -d "$tmp$RESTORE_PATH" ] || {
    echo "ERROR: snapshot $snap does not carry $RESTORE_PATH." >&2
    echo "       The note's restore.path and the snapshot disagree." >&2
    rm -rf "$tmp"
    exit 1
  }
  mv "$tmp$RESTORE_PATH" "$RESTORE_PATH"
  rm -rf "$tmp"
  chown -R root:root "$RESTORE_PATH"
}

hand_off_to_restored_tree() {
  local handoff="$RESTORE_PATH/$RESTORE_HANDOFF"
  [ -f "$handoff" ] || {
    echo "ERROR: what was restored has no $RESTORE_HANDOFF in it." >&2
    echo "       Either the snapshot predates it, or the note's" >&2
    echo "       restore.handoff is wrong." >&2
    exit 1
  }
  log "handing off..."
  bash "$handoff" ${HANDOFF_ARGS[@]+"${HANDOFF_ARGS[@]}"}
}

require_root_owned_tty() {
  [ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
  local tty_path tty_owner
  tty_path="$(tty 2>/dev/null || true)"
  tty_owner="$( [ -n "$tty_path" ] && stat -c %U "$tty_path" 2>/dev/null || echo "" )"
  [ "$tty_owner" = "root" ] || {
    echo "ERROR: stdin TTY must be root-owned (got owner='$tty_owner', tty='$tty_path')." >&2
    echo "       sudo/su from a non-root login leaves the TTY owned by that user." >&2
    echo "       Open a true root terminal (console, root ssh, or a separate root login)." >&2
    exit 1
  }
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      *)         HANDOFF_ARGS+=("$1"); shift ;;
    esac
  done
  require_root_owned_tty
  install_os_packages
  stage_tools_that_are_not_part_of_the_archive
  bw_session_start
  read_pointer
  restore_bootstrap
  hand_off_to_restored_tree
}

if [ "${BASH_SOURCE[0]}" = "${0:-}" ]; then
  main "$@"
fi
