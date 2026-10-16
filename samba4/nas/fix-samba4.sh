#!/bin/sh
#
# Rimette Samba 4 (SMB2/SMB3) al posto dello smbd stock 3.0.30 a ogni boot.
# Il firmware ripristina /etc/init.d a ogni avvio (anche al risveglio dallo
# standby Auto Power), quindi smb.sh torna quello stock e avvia SMB1.
#
#   boot: /etc/rc.d/extensions.d/S97B_fix_samba4 -> questo script con "start"
#         (prefisso B = eseguito in background da rcS, non rallenta il boot)
#
# Installa /etc/melco/smb.sh.samba4 solo se /etc/init.d/smb.sh è lo stock
# conosciuto (STOCK_MD5): dopo un aggiornamento firmware non tocca nulla.
#
# Rollback: rm /etc/rc.d/extensions.d/S97B_fix_samba4 e riavviare
#           (oppure, al volo: touch /etc/samba/USE_STOCK && /etc/init.d/smb.sh restart)

trap '' HUP

R=/mnt/array1/.buffalo-samba-test
B=$R/v2
NEW=/etc/melco/smb.sh.samba4
TARGET=/etc/init.d/smb.sh
LOG=/etc/melco/fix-samba4.log
STOCK_MD5=eb60e58b440562274cec7168661122c4

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG"; }

md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

[ "$1" = "start" ] && log "boot hook"

# l'array dati deve essere montato (Samba 4 e i suoi binari stanno lì)
i=0
while [ ! -x $B/usr/sbin/smbd ] && [ $i -lt 120 ]; do
    sleep 2
    i=$((i + 1))
done
[ -x $B/usr/sbin/smbd ] || { log "Samba 4 non trovato su $B: resta lo stock"; exit 0; }
[ -f "$NEW" ] || { log "manca $NEW"; exit 0; }

# percorsi compilati nella build (samba-dcerpcd, moduli vfs)
[ -L /usr/libexec/samba ] || ln -sfn $B/usr/libexec/samba /usr/libexec/samba
[ -L /usr/lib/samba ] || ln -sfn $B/usr/lib/samba /usr/lib/samba

CUR=$(md5 "$TARGET")
if [ "$CUR" = "$(md5 "$NEW")" ]; then
    log "smb.sh già aggiornato"
    exit 0
fi
if [ "$CUR" != "$STOCK_MD5" ]; then
    log "smb.sh sconosciuto (md5 $CUR): non lo tocco"
    exit 0
fi

cat "$NEW" > "$TARGET"
chmod 755 "$TARGET"
log "smb.sh aggiornato, riavvio Samba"
"$TARGET" restart > /dev/null 2>&1
log "restart finito: pid $(cat /var/run/smbd.pid 2>/dev/null)"
exit 0
