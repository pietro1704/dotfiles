#!/usr/bin/env bash

set -euo pipefail

# Ensure wttr.in answers using utf-8 so special glyphs render correctly
export LC_ALL=pt_BR.UTF-8

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux"
CACHE_FILE="${CACHE_DIR}/weather.txt"
LOCATION_FILE_DEFAULT="$HOME/.tmux/weather_location"
FORMAT_DEFAULT='%m+|+%S+-+%s+|+%p+|+%C+%t'
LANG="${TMUX_WEATHER_LANG:-pt-br}"
TTL="${TMUX_WEATHER_CACHE_SECONDS:-600}"
DEFAULT_LOCATION="${TMUX_WEATHER_DEFAULT_LOCATION:-}"
CONNECT_TIMEOUT="${TMUX_WEATHER_CONNECT_TIMEOUT:-5}"
MAX_TIME="${TMUX_WEATHER_MAX_TIME:-10}"

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

if [ -z "${LOCATION}" ] && [ -n "${DEFAULT_LOCATION}" ]; then
  LOCATION="${DEFAULT_LOCATION}"
fi

LOCATION="${LOCATION//  / }"
LOCATION_ENCODED="${LOCATION// /+}"
LOCATION_LABEL="${LOCATION}"

FORMAT_ENCODED="${TMUX_WEATHER_FORMAT:-${FORMAT_DEFAULT}}"

build_url() {
  local scheme="${1:-https}"
  local path="${scheme}://wttr.in/"
  if [ -n "${LOCATION_ENCODED}" ]; then
    path+="${LOCATION_ENCODED}"
  fi
  printf '%s?format=%s&lang=%s&m' "${path}" "${FORMAT_ENCODED}" "${LANG}"
}

curl_weather() {
  curl -fsSL --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${MAX_TIME}" --retry 1 --retry-delay 1 --http1.1 "$1"
}

fetch_weather() {
  if curl_weather "$(build_url https)"; then
    return 0
  fi

  curl_weather "$(build_url http)"
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
  WEATHER_TEXT="$(<"${CACHE_FILE}")"
  if [ -n "${LOCATION_LABEL}" ]; then
    printf '%s %s\n' "${WEATHER_TEXT}" "${LOCATION_LABEL}"
  else
    printf '%s\n' "${WEATHER_TEXT}"
  fi
else
  echo " weather indisponível"
fi
