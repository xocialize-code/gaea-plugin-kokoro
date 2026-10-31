#!/bin/zsh
# The plugin against in-process MLXServeEngine: seeded speak jobs called on the signed bundle the way Gaea calls them
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through kokoro-inproc with the
# lane configuration, text plan and seeding the worker uses. Each pair must be byte for byte the same WAV.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh)
#
# Cases: af_heart seed 42 (one piece), bm_lewis seed 7 with a pause (three pieces), bf_emma seed 3 on a 2,000-character
# text (nine pieces), and am_adam seed 0.
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/kokoro.gaeaplugin
MODELS=${CHECK_MODELS_ROOT:-$HOME/Library/Application Support/MLXEngine/Models}
SWIFTPM=(-c release --build-system swiftbuild)
xcrun swift build $SWIFTPM --product kokoro-inproc > /dev/null && xcrun swift build -c release --product gaea-plugin-check > /dev/null
INPROC=$(xcrun swift build $SWIFTPM --show-bin-path)/kokoro-inproc; CHECK=$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# Kokoro golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"

# compare <name> <voice> <seed> <text file>
compare() {
  local name=$1 voice=$2 seed=$3 text=$4
  $CHECK $B --operation audio.speak --model kokoro-82m --lane bf16 --params '{"voice":"'$voice'"}' --seed $seed \
    --text "text=$(cat $text)" --models-root "$MODELS" --budget 64000000000 --timeout 600 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(grep -o '"path":"[^"]*"' $OUT/$name-gpp.log | tail -1 | sed 's/"path":"//; s/"$//; s/\\\//\//g')
  [[ -n $file && -f $file ]] && cp $file $OUT/$name-gpp.wav
  $INPROC --once --voice $voice --seed $seed --text-file $text --models-root "$MODELS" --out $OUT/$name-inproc.wav 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  if [[ ! -f $OUT/$name-gpp.wav ]]; then fail=$((fail+1)); say "FAIL  $name: no output over GPP ($(grep -E 'FAIL|error' $OUT/$name-gpp.log | tail -1))"; return; fi
  if [[ ! -f $OUT/$name-inproc.wav ]]; then fail=$((fail+1)); say "FAIL  $name: no in-process output"; return; fi
  local a=$(shasum -a 256 $OUT/$name-gpp.wav | cut -c1-16) b=$(shasum -a 256 $OUT/$name-inproc.wav | cut -c1-16)
  local ran=$(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1)
  if [[ $a == $b ]]; then pass=$((pass+1)); say "PASS  $name ($voice, seed $seed): byte-identical, sha256 $a…; over GPP $ran; in-process $(cat $OUT/$name-inproc.json)"
  else fail=$((fail+1)); say "FAIL  $name: differs ($a… / $b…)"; fi
}

print -r -- 'Gaea speaks. This sentence came from a signed plugin, over its own protocol.' > $OUT/one.txt
print -r -- 'Gaea speaks. This sentence came from a signed plugin, over its own protocol. [pause 0.5s] And this one streamed, piece by piece, as it was drawn.' > $OUT/pause.txt
python3 -c "print(' '.join(['Sentence %d of the long text runs on for a while, with a comma or two, so the plan has to cut it into pieces.' % i for i in range(1, 19)]))" > $OUT/long.txt
compare one af_heart 42 $OUT/one.txt
compare pause bm_lewis 7 $OUT/pause.txt
compare long bf_emma 3 $OUT/long.txt
compare seed0 am_adam 0 $OUT/one.txt
for s in $OUT/*.gpp; do
  if python3 ${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}/tools/validate.py --transcript $s >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  ${s:t} passes validate.py"
  else fail=$((fail+1)); say "FAIL  ${s:t} fails validate.py"; fi
done
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
