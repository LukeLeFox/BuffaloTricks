#!/bin/sh
# Chiamato da smb.sh reload (es. modifiche dalla web UI): aggiorna share e utenti di Samba 4.
# Exit != 0 se Samba 4 non è attivo: smb.sh fa il normale HUP allo stock.
. /mnt/array1/.buffalo-samba-test/prod/smb4-env.sh
PID=$(cat /var/run/smbd.pid 2>/dev/null)
[ -n "$PID" ] && grep -q "$B/usr/sbin/smbd" /proc/$PID/cmdline 2>/dev/null || exit 1
$P/smb4-genconf.sh || exit 1
FA=$(/usr/local/bin/pdbedit -L -w -s /etc/samba/smb.conf 2>/dev/null | cut -d: -f1,2,4 | sort | md5sum)
FB=$(s4 $B/usr/bin/pdbedit -s $P/smb.conf -L -w 2>/dev/null | cut -d: -f1,2,4 | sort | md5sum)
if [ "$FA" = "$FB" ]; then
    kill -HUP $PID
    log4 "reload: config ricaricata"
    exit 0
fi
# smbd tiene aperto il passdb: per vedere utenti/password nuovi va riavviato
log4 "reload: utenti cambiati, riavvio Samba 4"
kill $PID
i=0
while [ -d /proc/$PID ] && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
killall smbd 2>/dev/null
sleep 1
killall -9 smbd 2>/dev/null
$P/smb4-start.sh
