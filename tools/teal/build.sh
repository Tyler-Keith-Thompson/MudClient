#!/bin/zsh
# Regenerate every Teal source in Scripts/ to the .lua the client loads (or `check` to type-check only).
# The live client also compiles-on-require via bootstrap.lua's __teal_compile, so this is for CI / a clean
# deterministic rebuild.  usage: tools/teal/build.sh [check]
cd "${0:A:h}/../.." || exit 2
TL=./tools/teal/tl
fail=0
for tl in Scripts/*.tl(N) Scripts/*/*.tl(N); do
  [ "${tl%.d.tl}" != "$tl" ] && continue              # any *.d.tl declaration file: type-checked via config, never generated
  if [ "$1" = check ]; then
    $TL check "$tl" || fail=1
  else
    if $TL gen "$tl" -o "${tl%.tl}.lua" >/dev/null; then echo "gen  ${tl%.tl}.lua"; else echo "FAIL $tl"; fail=1; fi
  fi
done
exit $fail
