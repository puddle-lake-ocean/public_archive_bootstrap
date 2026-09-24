#!/usr/bin/env bash
set -euo pipefail
umask 077

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
  apt-get -o Acquire::Retries=5 update -qq
  apt-get -o Acquire::Retries=5 install -y -qq git curl jq unzip bzip2 nftables python3
}

github_api_get() { curl -fsSL "${CURL_RETRY[@]}" "https://api.github.com/repos/$1"; }

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

download_first_asset_matching() {
  local assets="$1" name_re="$2" dir="$3" out_var="$4" name="" url="" digest=""
  IFS=$'\t' read -r name url digest < <(
    jq -r '.[] | [.name, .browser_download_url, (.digest // "")] | @tsv' <<<"$assets" \
      | awk -F'\t' -v re="$name_re" '$1 ~ re {print; exit}'
  ) || true
  [ -n "$url" ] || return 1
  download_verifying_published_digest "$url" "$digest" "$dir/$name"
  printf -v "$out_var" '%s' "$dir/$name"
}

install_restic() {
  local release tmp archive
  release="$(github_api_get restic/restic/releases/latest)"
  log "installing restic $(jq -r '.tag_name | ltrimstr("v")' <<<"$release") (digest-verified)..."
  tmp="$(mktemp -d)"
  download_first_asset_matching "$(jq '.assets' <<<"$release")" \
    '^restic_[0-9.]+_linux_amd64[.]bz2$' "$tmp" archive \
    || die "no linux amd64 restic in the latest release assets"
  bunzip2 "$archive"
  install -m 0700 "${archive%.bz2}" "$BOOTSTRAP_BIN/restic"
  rm -rf "$tmp"
}

install_bw_cli() {
  log "installing Bitwarden CLI (digest-verified)..."
  local releases newest_cli tmp archive
  releases="$(github_api_get 'bitwarden/clients/releases?per_page=100')"
  newest_cli="$(jq -r '.[].tag_name | select(startswith("cli-v"))' <<<"$releases" | sort -V | tail -n1)"
  [ -n "$newest_cli" ] || die "could not determine latest Bitwarden CLI release"
  tmp="$(mktemp -d)"
  download_first_asset_matching \
    "$(jq --arg t "$newest_cli" '.[] | select(.tag_name == $t) | .assets' <<<"$releases")" \
    '^bw-linux-[0-9].*[.]zip$' "$tmp" archive \
    || die "no bw-linux amd64 zip in $newest_cli assets"
  unzip -q "$archive" -d "$tmp"
  install -m 0700 "$tmp/bw" "$BOOTSTRAP_BIN/bw"
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
  fi
  [ -z "$BW_NFT_TABLE" ] || nft delete table ip "$BW_NFT_TABLE" 2>/dev/null || true
  [ -z "$BW_APPDATA" ] || rm -rf "$BW_APPDATA"
  [ -z "$BOOTSTRAP_BIN" ] || rm -rf "$BOOTSTRAP_BIN"
  BW_SERVE_PID="" BW_NFT_TABLE="" BW_APPDATA="" BOOTSTRAP_BIN=""
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
  local method="$1" path="$2" body=() resp
  [ -z "${3:-}" ] || body=(-H 'Content-Type: application/json' --data-binary "$3")
  resp="$(curl -sS -m 30 -X "$method" "${body[@]}" "$BW_SERVE_URL$path")" || return 1
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

vault_item_field_value() {
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
  [ -n "${BW_EMAIL:-}" ] || read -r -p "Bitwarden account email: " BW_EMAIL
  [ -n "$BW_EMAIL" ] || die "email required"
  [ -n "${BW_MASTER:-}" ] || read_secret_starred BW_MASTER "Master password: "
  [ -n "$BW_MASTER" ] || die "master password required"
  export BW_EMAIL BW_MASTER BW_SERVER_URL
}

start_bw_with_fresh_appdata() {
  rm -rf "${BW_APPDATA:?}"
  mkdir -m 0700 "$BW_APPDATA"
  printf '{}' > "$BW_APPDATA/data.json"
  bw config server "$BW_SERVER_URL" >/dev/null
}

login_asking_again_while_someone_can_answer() {
  local tries=0 retyped_email
  until bw login "$BW_EMAIL" --passwordenv BW_MASTER --raw >/dev/null; do
    tries=$((tries + 1))
    if [ ! -t 0 ] || [ "$tries" -ge 3 ]; then
      die "could not log in to $BW_SERVER_URL as $BW_EMAIL.
  Check BOTH the address and the password — bw reports one message
  for a wrong password and a wrong account, and it cannot tell you
  which. Nothing has been written outside this live session."
    fi
    printf '\n  that login was refused (attempt %s of 3).\n  account: %s\n  %s\n' \
      "$tries" "$BW_EMAIL" "Enter a different address, or press Enter to keep that one." >&2
    read -r retyped_email
    BW_EMAIL="${retyped_email:-$BW_EMAIL}"
    read_secret_starred BW_MASTER "Master password: "
    [ -n "$BW_MASTER" ] || die "master password required"
    export BW_EMAIL BW_MASTER
    start_bw_with_fresh_appdata
  done
}

reject_nonroot_traffic_to_port_before_daemon_binds() {
  BW_NFT_TABLE="bw_bootstrap_$$"
  nft delete table ip "$BW_NFT_TABLE" 2>/dev/null || true
  nft -f - <<EOF || die "could not install the nftables uid guard — refusing to expose an unlocked vault."
table ip $BW_NFT_TABLE {
  chain output {
    type filter hook output priority 0; policy accept;
    ip daddr 127.0.0.1 tcp dport $1 meta skuid != 0 reject with tcp reset
  }
}
EOF
}

wait_until_the_vault_daemon_answers() {
  local half_seconds=0
  until curl -sS -m 2 "$BW_SERVE_URL/status" >/dev/null 2>&1; do
    kill -0 "$BW_SERVE_PID" 2>/dev/null || die "the vault daemon exited before becoming ready"
    [ "$((half_seconds += 1))" -le $((BW_SERVE_READY_TIMEOUT * 2)) ] \
      || die "the vault daemon was not ready within ${BW_SERVE_READY_TIMEOUT}s"
    sleep 0.5
  done
}

bw_session_start() {
  [ -z "$BW_SERVE_URL" ] || return 0
  trap remove_transient_state EXIT INT TERM
  prompt_for_account_and_master_password

  BW_APPDATA="$(mktemp -d /dev/shm/bw-data.XXXXXX)"
  export BITWARDENCLI_APPDATA_DIR="$BW_APPDATA"
  start_bw_with_fresh_appdata
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
  export BW_SERVE_URL="http://127.0.0.1:$port"
  wait_until_the_vault_daemon_answers

  vault_api POST /unlock "$(jq -n --arg p "$BW_MASTER" '{password:$p}')" >/dev/null \
    || die "vault unlock failed"
  vault_api POST /sync >/dev/null || die "vault sync failed"
  log "vault unlocked; the daemon is root-only and dies with this script."
}

pointer_note_or_die() {
  local item note
  item="$(vault_item_matching_name_exactly "$BW_POINTER_ITEM")" \
    || die "no vault item named '$BW_POINTER_ITEM'.
       Set BW_POINTER_ITEM if it is named something else."
  note="$(jq -r '.notes // empty' <<<"$item")"
  [ -n "$note" ] || die "'$BW_POINTER_ITEM' has an empty note"
  jq -e . >/dev/null 2>&1 <<<"$note" || die "the note on '$BW_POINTER_ITEM' is not JSON."
  printf '%s' "$note"
}

export_credentials_from_the_first_complete_item() {
  local f_id="$1" f_key="$2" f_repo="$3" f_pass="$4"; shift 4
  local name item b2_id b2_key repo pass
  for name in "$@"; do
    if ! item="$(vault_item_matching_name_exactly "$name" 2>/dev/null)"; then
      log "  '$name' — absent, trying the next"
      continue
    fi
    b2_id="$( vault_item_field_value "$f_id"   "$item")"
    b2_key="$(vault_item_field_value "$f_key"  "$item")"
    repo="$(  vault_item_field_value "$f_repo" "$item")"
    pass="$(  vault_item_field_value "$f_pass" "$item")"
    if [ -n "$b2_id" ] && [ -n "$b2_key" ] && [ -n "$repo" ] && [ -n "$pass" ]; then
      export AWS_ACCESS_KEY_ID="$b2_id" AWS_SECRET_ACCESS_KEY="$b2_key"
      export RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass"
      log "credentials resolved from '$name'."
      return 0
    fi
    log "  '$name' — present but missing one of the four fields, trying the next"
  done
  die "none of the items named by '$BW_POINTER_ITEM' resolved a
       complete credential set. Either its note's field names are
       stale, or every item it names is gone."
}

read_restore_plan_and_credentials_from_pointer_note() {
  log "reading the vault item '$BW_POINTER_ITEM'..."
  local note f_id f_key f_repo f_pass entry miss=() names=()
  note="$(pointer_note_or_die)"
  IFS=$'\x1f' read -r f_id f_key f_repo f_pass RESTORE_TAG RESTORE_PATH RESTORE_HANDOFF < <(
    jq -r '[.fields.key_id, .fields.key_secret, .fields.repo_url, .fields.repo_password,
            .restore.tag, .restore.path, .restore.handoff] | map(. // "") | join("\u001f")' \
      <<<"$note")
  mapfile -t names < <(jq -r '.credentials[]? | select(length > 0)' <<<"$note")

  for entry in "credentials=${names[*]}" "fields.key_id=$f_id" "fields.key_secret=$f_key" \
               "fields.repo_url=$f_repo" "fields.repo_password=$f_pass" \
               "restore.tag=$RESTORE_TAG" "restore.path=$RESTORE_PATH" \
               "restore.handoff=$RESTORE_HANDOFF"; do
    [ -n "${entry#*=}" ] || miss+=("${entry%%=*}")
  done
  [ "${#miss[@]}" -eq 0 ] || die "the note on '$BW_POINTER_ITEM' is missing: ${miss[*]}"
  [[ "$RESTORE_PATH" == /* ]] || die "restore.path must be absolute, got '$RESTORE_PATH'"

  export_credentials_from_the_first_complete_item "$f_id" "$f_key" "$f_repo" "$f_pass" "${names[@]}"
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

newest_snapshot_for_tag() {
  restic snapshots --tag "$1" --latest 1 --json 2>/dev/null \
    | jq -r '[.[]?] | if length > 0 then (max_by(.time).short_id // empty) else empty end'
}

restore_bootstrap() {
  install -d -m 0755 -o root -g root "$(dirname "$RESTORE_PATH")"
  local snap tmp
  snap="$(newest_snapshot_for_tag "$RESTORE_TAG")"
  [ -n "$snap" ] || report_that_this_repository_holds_no_snapshot_and_stop

  if [ -n "$(ls -A "$RESTORE_PATH" 2>/dev/null)" ]; then
    log "$RESTORE_PATH already populated — skipping restore."
    return 0
  fi

  log "restoring (snapshot $snap)..."
  tmp="$(mktemp -d)"
  restic restore "$snap" --target "$tmp"
  [ -d "$tmp$RESTORE_PATH" ] || { rm -rf "$tmp"; die "snapshot $snap does not carry $RESTORE_PATH.
       The note's restore.path and the snapshot disagree."; }
  mv "$tmp$RESTORE_PATH" "$RESTORE_PATH"
  rm -rf "$tmp"
  chown -R root:root "$RESTORE_PATH"
}

hand_off_to_restored_tree() {
  local handoff="$RESTORE_PATH/$RESTORE_HANDOFF"
  [ -f "$handoff" ] || die "what was restored has no $RESTORE_HANDOFF in it.
       Either the snapshot predates it, or the note's
       restore.handoff is wrong."
  log "handing off..."
  bash "$handoff" ${HANDOFF_ARGS[@]+"${HANDOFF_ARGS[@]}"}
}

require_root_owned_tty() {
  [ "$(id -u)" -eq 0 ] || die "run as root"
  local tty_path tty_owner=""
  tty_path="$(tty 2>/dev/null || true)"
  [ -z "$tty_path" ] || tty_owner="$(stat -c %U "$tty_path" 2>/dev/null || true)"
  [ "$tty_owner" = "root" ] || die "stdin TTY must be root-owned (got owner='$tty_owner', tty='$tty_path').
       sudo/su from a non-root login leaves the TTY owned by that user.
       Open a true root terminal (console, root ssh, or a separate root login)."
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help) usage; exit 0 ;;
      *)         HANDOFF_ARGS+=("$arg") ;;
    esac
  done
  require_root_owned_tty
  install_os_packages
  stage_tools_that_are_not_part_of_the_archive
  bw_session_start
  read_restore_plan_and_credentials_from_pointer_note
  restore_bootstrap
  hand_off_to_restored_tree
}

if [ "${BASH_SOURCE[0]}" = "${0:-}" ]; then
  main "$@"
fi
