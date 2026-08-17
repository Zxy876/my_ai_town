#!/bin/sh
set -eu

build_dir=${1:-web-build}
html="$build_dir/index.html"
pck="$build_dir/index.pck"
wasm="$build_dir/index.wasm"
js="$build_dir/index.js"
audio_worklet="$build_dir/godot.audio.worklet.js"
position_worklet="$build_dir/godot.audio.position.worklet.js"

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

maybe_version_worklet() {
	src_path="$1"
	kind="$2"
	if [ -s "$src_path" ]; then
		h=$(hash_file "$src_path")
		dst_name="index.${h}.${kind}.worklet.js"
		mv "$src_path" "$build_dir/$dst_name"
		ln -s "$dst_name" "$src_path"
		ln -s "$dst_name" "$build_dir/index.${kind}.worklet.js"
		printf '%s\n' "$dst_name"
	else
		printf '\n'
	fi
}

pck_hash=$(hash_file "$pck")
wasm_hash=$(hash_file "$wasm")
pck_name="index.$pck_hash.pck"
wasm_name="index.$wasm_hash.wasm"
wasm_base=${wasm_name%.wasm}
audio_worklet_name=$(maybe_version_worklet "$audio_worklet" "audio")
position_worklet_name=$(maybe_version_worklet "$position_worklet" "audio.position")
[ -n "${audio_worklet_name:-}" ] || audio_worklet_name=""
[ -n "${position_worklet_name:-}" ] || position_worklet_name=""

mv "$pck" "$build_dir/$pck_name"
mv "$wasm" "$build_dir/$wasm_name"
ln -s "$pck_name" "$pck"
ln -s "$wasm_name" "$wasm"

PCK_NAME="$pck_name" WASM_NAME="$wasm_name" WASM_BASE="$wasm_base" \
	perl -0pi -e '
		s/"index\.pck"/"$ENV{PCK_NAME}"/g;
		s/"index\.wasm"/"$ENV{WASM_NAME}"/g;
		s/"executable":"index"/"executable":"$ENV{WASM_BASE}","mainPack":"$ENV{PCK_NAME}"/;
	' "$html"

if [ -n "${audio_worklet_name:-}" ] || [ -n "${position_worklet_name:-}" ]; then
	AUDIO_WORKLET_NAME="$audio_worklet_name" POSITION_WORKLET_NAME="$position_worklet_name" \
		perl -0pi -e '
			if (length $ENV{AUDIO_WORKLET_NAME}) {
				s/"godot\.audio\.worklet\.js"/"$ENV{AUDIO_WORKLET_NAME}"/g;
			}
			if (length $ENV{POSITION_WORKLET_NAME}) {
				s/"godot\.audio\.position\.worklet\.js"/"$ENV{POSITION_WORKLET_NAME}"/g;
			}
		' "$js"
fi

grep -Fq "\"executable\":\"$wasm_base\"" "$html"
grep -Fq "\"mainPack\":\"$pck_name\"" "$html"
grep -Fq "\"$pck_name\"" "$html"
grep -Fq "\"$wasm_name\"" "$html"
if [ -n "${audio_worklet_name:-}" ]; then
	grep -Fq "\"$audio_worklet_name\"" "$js"
fi
if [ -n "${position_worklet_name:-}" ]; then
	grep -Fq "\"$position_worklet_name\"" "$js"
fi

{
	printf 'VERSIONED_PCK=%s\n' "$pck_name"
	printf 'VERSIONED_WASM=%s\n' "$wasm_name"
	if [ -n "${audio_worklet_name:-}" ]; then
		printf 'VERSIONED_AUDIO_WORKLET=%s\n' "$audio_worklet_name"
	else
		printf 'VERSIONED_AUDIO_WORKLET=\n'
	fi
	if [ -n "${position_worklet_name:-}" ]; then
		printf 'VERSIONED_POSITION_WORKLET=%s\n' "$position_worklet_name"
	else
		printf 'VERSIONED_POSITION_WORKLET=\n'
	fi
}
