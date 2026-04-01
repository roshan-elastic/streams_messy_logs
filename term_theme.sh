# ANSI colors for ingest scripts — no dependencies. Set NO_COLOR=1 to disable.
if [[ -n "$NO_COLOR" ]] || { [[ ! -t 1 ]] && [[ ! -t 2 ]]; }; then
  T_RESET="" T_BOLD="" T_DIM="" T_RED="" T_GREEN="" T_YELLOW="" T_BLUE="" T_CYAN="" T_MAGENTA=""
else
  T_RESET=$'\e[0m'
  T_BOLD=$'\e[1m'
  T_DIM=$'\e[2m'
  T_RED=$'\e[31m'
  T_GREEN=$'\e[32m'
  T_YELLOW=$'\e[33m'
  T_BLUE=$'\e[34m'
  T_MAGENTA=$'\e[35m'
  T_CYAN=$'\e[36m'
fi

term_hr() {
  echo "${T_DIM}────────────────────────────────────────────────────────────────────────────────${T_RESET}"
}

# Printed once when --preferred-schema is omitted (POST /logs/_bulk).
term_logs_deprecation_info() {
  echo "${T_BOLD}${T_YELLOW}INFO:${T_RESET} ${T_DIM}The${T_RESET} ${T_CYAN}logs${T_RESET} ${T_DIM}stream is deprecated from Elastic 9.4.0 onwards. If you are using 9.4.0 or above, set${T_RESET} ${T_CYAN}--preferred-schema otel${T_RESET} ${T_DIM}or${T_RESET} ${T_CYAN}--preferred-schema ecs${T_RESET} ${T_DIM}to send via${T_RESET} ${T_CYAN}POST /logs.otel/_bulk${T_RESET} ${T_DIM}or${T_RESET} ${T_CYAN}POST /logs.ecs/_bulk${T_RESET} ${T_DIM}instead of${T_RESET} ${T_CYAN}POST /logs/_bulk${T_RESET}${T_DIM}.${T_RESET}" >&2
}

# Printed once when --preferred-schema is otel or ecs (before the ingest loop).
# Args: schema (otel|ecs), full bulk URL (e.g. https://host/logs.otel/_bulk)
term_wired_stream_info() {
  local schema=$1 bulk_url=$2
  local desc
  if [[ "$schema" == "otel" ]]; then
    desc="OpenTelemetry-style wired stream (logs.otel)"
  else
    desc="ECS wired stream (logs.ecs)"
  fi
  echo "${T_BOLD}${T_GREEN}INFO:${T_RESET} ${T_DIM}Preferred schema${T_RESET} ${T_CYAN}$schema${T_RESET} ${T_DIM}—${T_RESET} $desc${T_DIM}.${T_RESET}" >&2
  echo "${T_BOLD}${T_GREEN}INFO:${T_RESET} ${T_DIM}Sending bulk requests to${T_RESET} ${T_CYAN}$bulk_url${T_RESET}" >&2
}
