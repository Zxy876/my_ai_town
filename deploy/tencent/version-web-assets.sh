#!/bin/sh
set -eu

build_dir=${1:-web-build}
html="$build_dir/index.html"
pck="$build_dir/index.pck"
wasm="$build_dir/index.wasm"
js="$build_dir/index.js"

test -s "$html"
test -s "$pck"
test -s "$wasm"
test -s "$js"

hash_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -c1-16
	else
		shasum -a 256 "$1" | cut -c1-16
	fi
}

audio_worklet_src=""
if [ -s "$build_dir/index.audio.worklet.js" ]; then
	audio_worklet_src="$build_dir/index.audio.worklet.js"
elif [ -s "$build_dir/godot.audio.worklet.js" ]; then
	audio_worklet_src="$build_dir/godot.audio.worklet.js"
fi
position_worklet_src=""
if [ -s "$build_dir/index.audio.position.worklet.js" ]; then
	position_worklet_src="$build_dir/index.audio.position.worklet.js"
elif [ -s "$build_dir/godot.audio.position.worklet.js" ]; then
	position_worklet_src="$build_dir/godot.audio.position.worklet.js"
fi

pck_hash=$(hash_file "$pck")
wasm_hash=$(hash_file "$wasm")
pck_name="index.$pck_hash.pck"
wasm_name="index.$wasm_hash.wasm"
wasm_base=${wasm_name%.wasm}

mv "$pck" "$build_dir/$pck_name"
mv "$wasm" "$build_dir/$wasm_name"
ln -s "$pck_name" "$pck"
ln -s "$wasm_name" "$wasm"

audio_worklet_name=""
position_worklet_name=""

if [ -n "$audio_worklet_src" ]; then
	h=$(hash_file "$audio_worklet_src")
	audio_worklet_name="index.${h}.audio.worklet.js"
	if [ "$audio_worklet_src" != "$build_dir/$audio_worklet_name" ]; then
		mv "$audio_worklet_src" "$build_dir/$audio_worklet_name"
	fi
	ln -sf "$audio_worklet_name" "$build_dir/godot.audio.worklet.js"
	ln -sf "$audio_worklet_name" "$build_dir/index.audio.worklet.js"
fi

if [ -n "$position_worklet_src" ]; then
	h=$(hash_file "$position_worklet_src")
	position_worklet_name="index.${h}.audio.position.worklet.js"
	if [ "$position_worklet_src" != "$build_dir/$position_worklet_name" ]; then
		mv "$position_worklet_src" "$build_dir/$position_worklet_name"
	fi
	ln -sf "$position_worklet_name" "$build_dir/godot.audio.position.worklet.js"
	ln -sf "$position_worklet_name" "$build_dir/index.audio.position.worklet.js"
fi

PCK_NAME="$pck_name" WASM_NAME="$wasm_name" WASM_BASE="$wasm_base" \
	perl -0pi -e '
		s/"index\.pck"/"$ENV{PCK_NAME}"/g;
		s/"index\.wasm"/"$ENV{WASM_NAME}"/g;
		s/"executable":"index"/"executable":"$ENV{WASM_BASE}","mainPack":"$ENV{PCK_NAME}"/;
	' "$html"

if [ -n "$audio_worklet_name$position_worklet_name" ]; then
	AUDIO_WORKLET_NAME="$audio_worklet_name" POSITION_WORKLET_NAME="$position_worklet_name" \
		perl -0pi -e '
			if (length $ENV{AUDIO_WORKLET_NAME}) {
				s/"(?:godot|index)\.audio\.worklet\.js"/"$ENV{AUDIO_WORKLET_NAME}"/g;
			}
			if (length $ENV{POSITION_WORKLET_NAME}) {
				s/"(?:godot|index)\.audio\.position\.worklet\.js"/"$ENV{POSITION_WORKLET_NAME}"/g;
			}
		' "$js"
fi

grep -Fq "\"executable\":\"$wasm_base\"" "$html"
grep -Fq "\"mainPack\":\"$pck_name\"" "$html"
grep -Fq "\"$pck_name\"" "$html"
grep -Fq "\"$wasm_name\"" "$html"
if [ -n "$audio_worklet_name" ]; then
	grep -Fq "\"$audio_worklet_name\"" "$js"
fi
if [ -n "$position_worklet_name" ]; then
	grep -Fq "\"$position_worklet_name\"" "$js"
fi

{
	printf 'VERSIONED_PCK=%s\n' "$pck_name"
	printf 'VERSIONED_WASM=%s\n' "$wasm_name"
	printf 'VERSIONED_AUDIO_WORKLET=%s\n' "$audio_worklet_name"
	printf 'VERSIONED_POSITION_WORKLET=%s\n' "$position_worklet_name"
}
