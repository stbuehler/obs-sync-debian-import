#!/bin/bash

set -e

self=$(readlink -f "$0")
base=$(dirname "${self}")
cd "${base}"

TARGET=root@192.168.0.181
PROJECT="Debian:7.0"
REPOSITORY="standard"
ARCHS=("x86_64" "i586")
PACKAGEDIR=../packages

echo "Syncing packages"
ssh "${TARGET}" mkdir -p /srv/imports/${PROJECT}/${REPOSITORY}
rsync -e ssh -rlt --delete-after "${PACKAGEDIR}/" "${TARGET}:/srv/imports/${PROJECT}/${REPOSITORY}/"


for ARCH in "${ARCHS[@]}"; do
	case "${ARCH}" in
	x86_64) DEBARCH=amd64 ;;
	i586) DEBARCH=i386 ;;
	*)
		echo "Unknown architecture ${ARCH}" >&2
		exit 1
		;;
	esac

	echo "Linking new files for ${ARCH} (from ${DEBARCH})"
	ssh "${TARGET}" rm -rf /srv/obs/build/${PROJECT}/${REPOSITORY}/${ARCH}/:full.new
	ssh "${TARGET}" mkdir -p /srv/obs/build/${PROJECT}/${REPOSITORY}/${ARCH}/:full.new
	ssh "${TARGET}" chown obsrun:obsrun \
		/srv/obs/build/${PROJECT} \
		/srv/obs/build/${PROJECT}/${REPOSITORY} \
		/srv/obs/build/${PROJECT}/${REPOSITORY}/${ARCH} \
		/srv/obs/build/${PROJECT}/${REPOSITORY}/${ARCH}/:full.new

	ssh "${TARGET}" "find '/srv/imports/${PROJECT}/${REPOSITORY}' -type f \\( -name '*_${DEBARCH}.deb' -o -name '*_all.deb' \\)" \
		"| (t=/srv/obs/build/${PROJECT}/${REPOSITORY}/${ARCH}/:full.new; " \
		'while read f; do n=$(basename "$f"); [ "${n}" != "${n%%_*}" ] && n=${n%%_*}.deb; ln "$f" "$t/$n"; done)'
done

echo "Stopping scheduler"
ssh "${TARGET}" rcobsscheduler shutdown

echo "Deleting old :full, moving :full.new => .full"
for ARCH in "${ARCHS[@]}"; do
	ssh "${TARGET}" rm -rf /srv/obs/build/${PROJECT}/${REPOSITORY}/${ARCH}/:full
	ssh "${TARGET}" mv /srv/obs/build/${PROJECT}/${REPOSITORY}/${ARCH}/:full.new /srv/obs/build/${PROJECT}/${REPOSITORY}/${ARCH}/:full
done

echo "Starting scheduler"
ssh "${TARGET}" rcobsscheduler start

echo "Rescan repositories"
for ARCH in "${ARCHS[@]}"; do
	ssh "${TARGET}" /usr/lib/obs/server/bs_admin --rescan-repository ${PROJECT} ${REPOSITORY} ${ARCH}
done

echo "Done."
