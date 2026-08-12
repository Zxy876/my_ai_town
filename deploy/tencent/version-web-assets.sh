#!/bin/sh
set -eu

build_dir=${1:-web-build}
html="$build_dir/index.html"
pck="$build_dir/index.pck"
wasm="$build_dir/index.wasm"

test -s "$html"
test -s "$pck"
test -s "$wasm"

hash_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -c1-16
	else
		shasum -a 256 "$1" | cut -c1-16
	fi
}

pck_hash=$(hash_file "$pck")
wasm_hash=$(hash_file "$wasm")
pck_name="index.$pck_hash.pck"
wasm_name="index.$wasm_hash.wasm"
wasm_base=${wasm_name%.wasm}

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

grep -Fq "\"executable\":\"$wasm_base\"" "$html"
grep -Fq "\"mainPack\":\"$pck_name\"" "$html"
grep -Fq "\"$pck_name\"" "$html"
grep -Fq "\"$wasm_name\"" "$html"

printf 'VERSIONED_PCK=%s\nVERSIONED_WASM=%s\n' "$pck_name" "$wasm_name"
