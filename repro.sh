#!/usr/bin/env bash
#
# Kill one build, and the build after it produces a binary that does not match
# the source. README.md explains what is going on underneath.
#
#   ./repro.sh                       # the cargo on your PATH
#   CARGO="cargo +1.98.0" ./repro.sh # a specific toolchain
#
set -uo pipefail
set -m                        # give each background job its own process group
cd "$(dirname "$0")"
CARGO=${CARGO:-cargo}
POISON_MIN=${POISON_MIN:-8}   # how many of the old session's files to damage before killing
INCR="$PWD/target/release/incremental"

if command -v sha256sum >/dev/null 2>&1; then hash_of() { sha256sum "$@"; }
else                                          hash_of() { shasum -a 256 "$@"; }; fi

# rustc's finished ("finalized") incremental sessions, oldest first.
sessions()  { find "$INCR" -maxdepth 2 -type d -name 's-*' ! -name '*-working' 2>/dev/null | sort; }
newest()    { sessions | tail -1; }
bitcode()   { ( cd "$1" 2>/dev/null && hash_of ./*.pre-lto.bc 2>/dev/null | sort ); }
damaged()   { printf '%s\n' "$1" | comm -13 "$2" - | wc -l | tr -d ' '; }
set_salt()  { printf '%s\npub const SALT: u64 = %s;\n' \
                "/// The whole program's output is a function of this one number." "$1" > src/salt.rs; }
src_sha()   { hash_of src/salt.rs | cut -c1-16; }
# SIGNAL=INT is what Ctrl-C sends. SIGNAL=KILL for a hard kill (an OOM, a
# CI runner going away). Both leave the same damage behind.
SIGNAL=${SIGNAL:-INT}
kill_tree() { kill -"$SIGNAL" -- "-$1" 2>/dev/null || kill -"$SIGNAL" "$1" 2>/dev/null; }
build()     { $CARGO build --release 2>&1 | grep -E 'Compiling|Finished|error' | sed 's/^/      /'; }

attempt() {
  local A BUILD start now prev="" n=0 killed=no

  echo "[1/6] a normal, complete build, with SALT = 1"
  set_salt 1
  echo "      src/salt.rs is $(src_sha)"
  build
  EXPECTED=$(./target/release/poison-demo)
  A=$(newest)
  echo "      it prints 16 module checksums, starting $(echo "$EXPECTED" | sed -n 2p)"
  echo "      rustc's finished session: $(basename "$A")"
  echo "      holding $(bitcode "$A" | wc -l | tr -d ' ') .pre-lto.bc files, which are now supposed to be read-only"
  bitcode "$A" > /tmp/repro-before.txt

  echo
  echo "[2/6] set SALT = 2, start a build, and kill it once it has written into"
  echo "      that finished session"
  set_salt 2
  $CARGO build --release > /tmp/repro-killed.log 2>&1 &
  BUILD=$!
  start=$(date +%s)
  while kill -0 "$BUILD" 2>/dev/null; do
    now=$(bitcode "$A")
    if [ -n "$now" ]; then
      n=$(damaged "$now" /tmp/repro-before.txt)
      # wait for one poll with no further change, so no file is caught half-written
      if [ "$n" -ge "$POISON_MIN" ] && [ "$now" = "$prev" ]; then
        echo "      SIG$SIGNAL $(( $(date +%s) - start ))s in, after it has rewritten $n of them"
        kill_tree "$BUILD"; killed=yes; break
      fi
      prev="$now"
    fi
    [ $(( $(date +%s) - start )) -gt 300 ] && break
    sleep 0.05
  done
  wait "$BUILD" 2>/dev/null; sleep 1
  [ "$killed" = yes ] || { echo "      the build finished before we could kill it"; return 2; }

  echo
  echo "[3/6] what the killed build did to the session it was only supposed to read"
  echo "      files whose contents changed: $(damaged "$(bitcode "$A")" /tmp/repro-before.txt) of $(wc -l < /tmp/repro-before.txt | tr -d ' ')"
  [ "$(newest)" = "$A" ] || { echo "      but it finished a session of its own first"; return 2; }
  echo "      it is still the newest finished session, so it is what the next build reads"

  echo
  echo "[4/6] put the source back to SALT = 1"
  set_salt 1
  echo "      src/salt.rs is now $(src_sha), the same bytes step 1 built"
  build

  echo
  echo "[5/6] run it"
  ACTUAL=$(./target/release/poison-demo)
  local DIFF; DIFF=$(diff <(echo "$EXPECTED") <(echo "$ACTUAL"))
  if [ -z "$DIFF" ]; then
    echo "      the output is unchanged"
    echo
    echo "RESULT: no divergence this time. Try again: it depends on which codegen"
    echo "        units the killed build got to."
    return 1
  fi
  echo "$DIFF" | sed 's/^/      /'

  echo
  echo "[6/6] and it sticks: touch the source and build again"
  touch src/salt.rs
  build
  if [ "$(./target/release/poison-demo)" = "$ACTUAL" ]; then
    echo "      still the same wrong binary"
  else
    echo "      output changed again"
  fi
  echo "      (only 'cargo clean' clears it, which is how you know the source is fine)"

  echo
  echo "RESULT: cargo build produced a binary that does not match the source."
  echo "        Lines marked < are what this source computes."
  echo "        Lines marked > are what the binary you just built prints."
  return 0
}

echo "cargo: $($CARGO --version)"
echo
for i in 1 2 3; do
  if [ $i -gt 1 ]; then echo; echo "--- attempt $i, from a clean target/ ---"; echo; $CARGO clean; fi
  attempt && exit 0
  [ $? -eq 1 ] && exit 1
done
echo "Gave up after 3 attempts."
exit 2
