#!/usr/bin/env bash
set -euo pipefail

repo="https://github.com/dennisyang101/dennisyang101.github.io.git"
tmp="${TMPDIR:-/tmp}/hexo-pages"

npm run build
rm -rf "$tmp"
mkdir -p "$tmp"
cp -R public/. "$tmp/"

git -C "$tmp" init -b main
git -C "$tmp" config user.name "DennisYang777"
git -C "$tmp" config user.email "dlex351279@gmail.com"
git -C "$tmp" remote add origin "$repo"
git -C "$tmp" add .
git -C "$tmp" commit -m "Deploy blog"
git -C "$tmp" push -f origin main
