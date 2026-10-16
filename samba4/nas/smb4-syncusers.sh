#!/bin/sh
# Copia gli account dal passdb stock (Samba 3) al passdb Samba 4.
# Passa dal formato testo smbpasswd: l'import tdbsam->tdbsam fallisce in silenzio.
# Fail-closed: il passdb attivo viene sostituito solo se utenti, UID e hash coincidono.
. /mnt/array1/.buffalo-samba-test/prod/smb4-env.sh
umask 077
W=$P/private/sync.$$
mkdir $W || exit 1
trap 'rm -rf $W' EXIT
cat > $W/t.conf <<EOC
[global]
    private dir = $W
    lock directory = $W
    state directory = $W
    cache directory = $W
    pid directory = $W
    ncalrpc dir = $W/ncalrpc
    passdb backend = tdbsam:$W/new.tdb
EOC
/usr/local/bin/pdbedit -L -w -s /etc/samba/smb.conf > $W/smbpasswd.txt 2>/dev/null || exit 1
N=$(grep -c ':' $W/smbpasswd.txt)
[ "$N" -ge 1 ] || { log4 "sync: nessun account stock"; exit 1; }
s4 $B/usr/bin/pdbedit -s $W/t.conf -i smbpasswd:$W/smbpasswd.txt -e tdbsam:$W/new.tdb >/dev/null 2>&1
FA=$(cut -d: -f1,2,4 $W/smbpasswd.txt | sort | md5sum)
FB=$(s4 $B/usr/bin/pdbedit -s $W/t.conf -L -w 2>/dev/null | cut -d: -f1,2,4 | sort | md5sum)
[ "$FA" = "$FB" ] || { log4 "sync: verifica fallita, passdb invariato"; exit 1; }
mv $W/new.tdb ${SMB4_PASSDB:-$P/private/passdb.tdb} || exit 1
log4 "sync: $N account copiati"
