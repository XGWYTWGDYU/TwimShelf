#!/bin/sh
# Runs the server as PUID:PGID (default 1000:1000) when started as root, after giving that user
# the data folder; as whoever the container runs as otherwise (`user:` in compose).
set -e
mkdir -p "${TL_DATA:-/data}"
if [ "$(id -u)" = "0" ]; then
  uid="${PUID:-1000}"; gid="${PGID:-1000}"
  # only what is not theirs yet: a large library is not walked on every start
  find "${TL_DATA:-/data}" \( ! -uid "$uid" -o ! -gid "$gid" \) -exec chown "$uid:$gid" {} + 2>/dev/null || true
  exec setpriv --reuid="$uid" --regid="$gid" --clear-groups /app/twimshelf-server "$@"
fi
exec /app/twimshelf-server "$@"
