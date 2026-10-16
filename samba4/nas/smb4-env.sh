# Incluso dagli script smb4-*: percorsi e ambiente isolato di Samba 4.
R=/mnt/array1/.buffalo-samba-test
P=$R/prod
# binari Samba 4: v2 = build con samba-dcerpcd (loader e RPATH già puntano a v2).
# Per tornare alla build precedente: B=$R
B=$R/v2
RPCDS="rpcd_epmapper rpcd_classic rpcd_winreg rpcd_lsad"
s4() {
    (
        ulimit -c 0
        unset LD_PRELOAD
        export LD_LIBRARY_PATH="$B/lib:$B/usr/lib:$B/usr/lib/samba"
        "$@"
    )
}
log4() { echo "$(date '+%F %T') $*" >> $P/var/log/smb4-wrapper.log; }
