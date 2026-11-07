#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Container-side driver: rpmbuild the staged liuqin device specs with
# --target aarch64, then hand the RPMs to postprocess.py (hashes, createrepo,
# root-install validation, build-info.json).  Executed by
# scripts/build-device-rpms.sh inside the Fedora 45 builder image.
set -euo pipefail

WORK=${WORK:-/work}
OUT=${OUT:-$WORK/out/rpms}
TOP=${TOP:-$WORK/rpmbuild}
ONLY=${ONLY:-firmware,audio,device-support}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
export SOURCE_DATE_EPOCH

log() { printf 'build-inner: %s\n' "$*" >&2; }

[ -d "$WORK/SOURCES" ] || { echo "missing $WORK/SOURCES" >&2; exit 1; }
[ -d "$WORK/SPECS" ] || { echo "missing $WORK/SPECS" >&2; exit 1; }

rm -rf "$TOP"
mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SRPMS,SOURCES,SPECS} "$OUT"
rm -f "$OUT"/*.rpm "$OUT"/SHA256SUMS "$OUT"/build-info.json "$OUT"/validation-report.json
cp "$WORK"/SPECS/*.spec "$TOP/SPECS/"

for item in ${ONLY//,/ }; do
	spec=$TOP/SPECS/liuqin-$item.spec
	[ -f "$spec" ] || { echo "unknown package spec: $spec" >&2; exit 1; }
	log "rpmbuild --target aarch64 $(basename "$spec")"
	rpmbuild -bb --target aarch64 \
		--define "_topdir $TOP" \
		--define "_sourcedir $WORK/SOURCES" \
		--define "_buildhost liuqin-build" \
		--define "dist .fc45" \
		"$spec"
done

built=$(find "$TOP/RPMS" -name '*.rpm' -type f | LC_ALL=C sort)
[ -n "$built" ] || { echo 'rpmbuild produced no packages' >&2; exit 1; }
# shellcheck disable=SC2086
cp $built "$OUT"/
log "copied $(printf '%s\n' $built | wc -l) RPMs to $OUT"

python3 "$WORK/scripts/postprocess.py" --work "$WORK" --out "$OUT"

log 'done'
