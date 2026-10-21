#!/usr/bin/env bash
# A throwaway OpenSSH server for Tide's SSH tests. It runs as the current
# user on 127.0.0.1, accepts only the client keys it generates, and keeps
# everything in one scratch directory.
#
#   scripts/ssh-test-server.sh start <dir> [port]   # prints KEY=value lines, also saved in <dir>/env
#   scripts/ssh-test-server.sh stop <dir>
#
# The client keys are Ed25519, ECDSA P-256 and RSA, so tests can check which
# kinds of key Tide's SSH client can sign in a way OpenSSH accepts. Without a
# port it takes the first free one from 2222 up.
set -euo pipefail

die() {
  echo "ssh-test-server: $*" >&2
  exit 1
}

find_sshd() {
  local candidate
  for candidate in /usr/sbin/sshd /opt/homebrew/sbin/sshd /usr/local/sbin/sshd; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return
    fi
  done
  die "no sshd found"
}

listening() {
  nc -z 127.0.0.1 "$1" >/dev/null 2>&1
}

start() {
  local dir=${1:-} port=${2:-}
  [ -n "$dir" ] || die "usage: start <dir> [port]"
  mkdir -p "$dir"
  dir=$(cd "$dir" && pwd -P)
  [ ! -e "$dir/sshd.pid" ] || die "$dir already has a server; stop it first"
  rm -f "$dir"/host_ed25519* "$dir"/client_*
  ssh-keygen -q -t ed25519 -N '' -C tide-test-host -f "$dir/host_ed25519"
  ssh-keygen -q -t ed25519 -N '' -C tide-test-ed25519 -f "$dir/client_ed25519"
  ssh-keygen -q -t ecdsa -b 256 -N '' -C tide-test-ecdsa -f "$dir/client_ecdsa"
  ssh-keygen -q -t rsa -b 3072 -N '' -C tide-test-rsa -f "$dir/client_rsa"
  cat "$dir/client_ed25519.pub" "$dir/client_ecdsa.pub" "$dir/client_rsa.pub" >"$dir/authorized_keys"
  chmod 600 "$dir/authorized_keys"
  if [ -z "$port" ]; then
    port=2222
    while listening "$port"; do port=$((port + 1)); done
  fi
  local user
  user=$(id -un)
  cat >"$dir/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $dir/host_ed25519
PidFile $dir/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
AllowUsers $user
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PrintMotd no
UseDNS no
Subsystem sftp internal-sftp
LogLevel VERBOSE
# The same plain shell whatever the account's login shell is, so tests see a
# predictable prompt (zsh on a fresh account can stop at its new-user menu).
ForceCommand /bin/bash --noprofile --norc -i
SetEnv BASH_SILENCE_DEPRECATION_WARNING=1
EOF
  local sshd
  sshd=$(find_sshd)
  "$sshd" -t -f "$dir/sshd_config" || die "sshd rejected its configuration"
  "$sshd" -f "$dir/sshd_config" -E "$dir/sshd.log"
  local tries=0
  until listening "$port"; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then
      cat "$dir/sshd.log" >&2 || true
      die "sshd did not listen on port $port"
    fi
    sleep 0.2
  done
  {
    echo "TIDE_SSH_HOST=127.0.0.1"
    echo "TIDE_SSH_PORT=$port"
    echo "TIDE_SSH_USER=$user"
    echo "TIDE_SSH_DIR=$dir"
  } >"$dir/env"
  cat "$dir/env"
}

stop() {
  local dir=${1:-}
  [ -n "$dir" ] || die "usage: stop <dir>"
  [ -f "$dir/sshd.pid" ] || return 0
  kill "$(cat "$dir/sshd.pid")" 2>/dev/null || true
  rm -f "$dir/sshd.pid"
}

case "${1:-}" in
start)
  shift
  start "$@"
  ;;
stop)
  shift
  stop "$@"
  ;;
*)
  echo "usage: $0 start <dir> [port] | stop <dir>" >&2
  exit 64
  ;;
esac
