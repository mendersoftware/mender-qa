#!/bin/bash
# vm-env.sh VAR...: prints "export VAR=value" for the variables set on the host,
# piped into the VM by "make vm-*" (never on a command line).
for v in "$@"; do
  [ -n "${!v:-}" ] && printf 'export %s=%q\n' "$v" "${!v}"
done
exit 0
