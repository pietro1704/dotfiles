#!/usr/bin/env bash

set -euo pipefail

# Ensure wttr.in answers using utf-8 so special glyphs render correctly
export LC_ALL=pt_BR.UTF-8

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux"
CACHE_FILE="${CACHE_DIR}/weather.txt"
LOCATION_FILE_DEFAULT="$HOME/.tmux/weather_location"
FORMAT_DEFAULT='%m+|+%S+-+%s+|+%p+|+%C+%t+%l'
LANG="${TMUX_WEATHER_LANG:-pt-br}"
TTL="${TMUX_WEATHER_CACHE_SECONDS:-600}"

mkdir -p "${CACHE_DIR}"

sanitize_ttl() {
  case "$1" in
    ''|*[!0-9]*) echo 600 ;;
    *) echo "$1" ;;
  esac
}

TTL="$(sanitize_ttl "${TTL}")"

get_mtime() {
  if stat -f %m "$1" >/dev/null 2>&1; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

needs_refresh() {
  if [ ! -s "${CACHE_FILE}" ]; then
    return 0
  fi

  local now last
  now=$(date +%s)
  last=$(get_mtime "${CACHE_FILE}")

  if [ $((now - last)) -ge "${TTL}" ]; then
    return 0
  fi

  return 1
}

trim() {
  # shellcheck disable=SC2001
  echo "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

LOCATION="${TMUX_WEATHER_LOCATION:-}"
LOCATION_FILE="${TMUX_WEATHER_LOCATION_FILE:-${LOCATION_FILE_DEFAULT}}"

if [ -z "${LOCATION}" ] && [ -f "${LOCATION_FILE}" ]; then
  LOCATION="$(trim "$(cat "${LOCATION_FILE}")")"
fi

LOCATION="${LOCATION//  / }"
LOCATION_ENCODED="${LOCATION// /+}"

FORMAT_ENCODED="${TMUX_WEATHER_FORMAT:-${FORMAT_DEFAULT}}"

build_url() {
  local path="https://wttr.in/"
  if [ -n "${LOCATION_ENCODED}" ]; then
    path+="${LOCATION_ENCODED}"
  fi
  printf '%s?format=%s&lang=%s&m' "${path}" "${FORMAT_ENCODED}" "${LANG}"
}

fetch_weather() {
  curl -fsSL "$(build_url)"
}

update_cache() {
  local tmp
  tmp=$(mktemp -t tmux-weather.XXXXXX)
  if fetch_weather > "${tmp}"; then
    mv "${tmp}" "${CACHE_FILE}"
  else
    rm -f "${tmp}"
  fi
}

if needs_refresh; then
  update_cache
fi

if [ -s "${CACHE_FILE}" ]; then
  cat "${CACHE_FILE}"
else
  echo " weather indisponível"
fi
