#!/bin/sh
# Genera $P/smb.conf: global fisso + share prese dalla smb.conf stock.
# Gli accessi guest vengono disattivati: con SMB2/3 servono utenti veri.
. /mnt/array1/.buffalo-samba-test/prod/smb4-env.sh
TMP=$P/smb.conf.tmp.$$
cat $P/global.conf > $TMP || exit 1
# nome NetBIOS e workgroup come nella web UI Buffalo
stockval() { sed -n "s/^[ \t]*$1[ \t]*=[ \t]*//p" /etc/samba/smb.conf | head -1; }
NB=$(stockval "netbios name")
WG=$(stockval workgroup)
[ -n "$NB" ] && sed -i "s/^    netbios name = .*/    netbios name = $NB/" $TMP
[ -n "$WG" ] && sed -i "s/^    workgroup = .*/    workgroup = $WG/" $TMP
awk '
/^[ \t]*\[/ { skip = (tolower($0) ~ /\[global\]/); if (!skip) print "" }
skip { next }
/^[ \t]*(vfs objects|audit:|csc policy)/ { next }
/^[ \t]*guest ok[ \t]*=/ { print "    guest ok = no"; next }
{ print }
' /etc/samba/smb.conf >> $TMP || { rm -f $TMP; exit 1; }
if [ -n "$SMB4_PORTS" ]; then
    sed -i "s/^    smb ports = .*/    smb ports = $SMB4_PORTS/; s|^    pid directory = .*|    pid directory = $P/var/run|" $TMP
fi
mv $TMP ${SMB4_CONF:-$P/smb.conf}
