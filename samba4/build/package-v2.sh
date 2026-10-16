#!/bin/bash
# Impacchetta la build Buildroot di Samba 4.23.13 per Buffalo CS-WX / LS-WXL (ARMv5, kernel 2.6.31).
# Tutto finisce sotto $V sul NAS: loader uClibc e RPATH vengono riscritti con patchelf,
# così i binari non toccano mai /lib e /usr/lib del firmware stock.
set -euo pipefail

O=${O:-$PWD/out-stock}
V=/mnt/array1/.buffalo-samba-test/v2
STAGE=${STAGE:-$PWD/stage-v2}
PATCHELF=$O/host/bin/patchelf
T=$O/target

[ -x "$PATCHELF" ] || { echo "manca $PATCHELF (make host-patchelf)"; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE$V"
D=$STAGE$V

# librerie di base (uClibc, libgcc, libatomic, ...) e tutte le librerie in /usr/lib
mkdir -p "$D/lib" "$D/usr/lib" "$D/usr/sbin" "$D/usr/bin" "$D/usr/libexec"
cp -a "$T"/lib/*.so* "$D/lib/"
cp -a "$T"/usr/lib/*.so* "$D/usr/lib/"
cp -a "$T/usr/lib/samba" "$D/usr/lib/"
cp -a "$T/usr/libexec/samba" "$D/usr/libexec/"
cp -a "$T/usr/sbin/smbd" "$D/usr/sbin/"
for b in testparm pdbedit smbpasswd smbstatus smbclient smbcontrol rpcclient; do
    [ -e "$T/usr/bin/$b" ] && cp -a "$T/usr/bin/$b" "$D/usr/bin/"
done

RPATH="$V/lib:$V/usr/lib:$V/usr/lib/samba"
INTERP="$V/lib/ld-uClibc.so.0"

# riscrive interprete (solo eseguibili) e RPATH (tutti gli ELF dinamici)
find "$D" -type f | while read -r f; do
    file -b "$f" | grep -q '^ELF' || continue
    file -b "$f" | grep -q 'dynamically linked' || continue
    case "$(basename "$f")" in ld-uClibc*|libc.so*|libuClibc*) continue ;; esac
    if "$PATCHELF" --print-interpreter "$f" >/dev/null 2>&1; then
        "$PATCHELF" --set-interpreter "$INTERP" "$f"
    fi
    "$PATCHELF" --force-rpath --set-rpath "$RPATH" "$f"
done

# niente simboli di debug: il NAS ha poco spazio e poca RAM
STRIP=$O/host/bin/arm-buildroot-linux-uclibcgnueabi-strip
find "$D" -type f \( -name '*.so*' -o -path '*/bin/*' -o -path '*/sbin/*' -o -path '*/libexec/*' \) \
    -exec sh -c 'file -b "$1" | grep -q ^ELF && "$2" --strip-unneeded "$1"' _ {} "$STRIP" \;

tar -C "$STAGE" -czf $PWD/samba-4.23.13-v2.tar.gz .
du -sh "$D"
ls -l $PWD/samba-4.23.13-v2.tar.gz
md5sum $PWD/samba-4.23.13-v2.tar.gz
