#!/bin/sh
# Avvia Samba 4 al posto dello smbd stock (chiamato da /etc/init.d/smb.sh).
# Exit != 0: smb.sh avvia lo smbd stock come prima.
# Per tornare allo stock in modo permanente: touch /etc/samba/USE_STOCK
. /mnt/array1/.buffalo-samba-test/prod/smb4-env.sh
[ -f /etc/samba/USE_STOCK ] && exit 1
[ -x $B/usr/sbin/smbd ] || exit 1
mkdir -p $P/private $P/var/lock $P/var/state $P/var/cache $P/var/log $P/var/run/ncalrpc || exit 1

# un solo avvio alla volta (smb.sh restart può arrivare anche da daemonwatch)
L=$P/var/run/start.lock
s4_running() {
    PID=$(cat /var/run/smbd.pid 2>/dev/null)
    [ -n "$PID" ] && grep -q "$B/usr/sbin/smbd" /proc/$PID/cmdline 2>/dev/null
}
i=0
while ! mkdir $L 2>/dev/null; do
    # c'è un altro avvio in corso: lo si aspetta (max 60 s, poi il lock è scaduto)
    if [ $i -ge 60 ]; then
        rmdir $L 2>/dev/null
    fi
    sleep 1
    i=$((i + 1))
done
trap 'rmdir $L 2>/dev/null' EXIT
if [ $i -gt 0 ] && s4_running; then
    log4 "start: Samba 4 già avviato da un altro avvio"
    exit 0
fi

port445() { grep -q ':01BD 00000000:0000 0A' /proc/net/tcp; }

# nessuno smbd (stock o Samba 4) deve essere ancora vivo o tenere la porta
i=0
while { pidof smbd > /dev/null || port445; } && [ $i -lt 15 ]; do
    sleep 1
    i=$((i + 1))
done
if pidof smbd > /dev/null || port445; then
    log4 "start: smbd ancora attivo o porta 445 occupata"
    exit 1
fi
# samba-dcerpcd e worker rimasti da un avvio precedente
if pidof samba-dcerpcd $RPCDS > /dev/null; then
    killall samba-dcerpcd $RPCDS 2>/dev/null
    sleep 2
    killall -9 samba-dcerpcd $RPCDS 2>/dev/null
fi

# daemonwatch riavvia smb.sh se /var/run/smbd.pid non punta a un processo vivo:
# durante la preparazione ci si mette il pid di questo script
echo $$ > /var/run/smbd.pid

$P/smb4-genconf.sh || { log4 "start: genconf fallito"; exit 1; }
s4 $B/usr/bin/testparm -s $P/smb.conf >/dev/null 2>&1 || { log4 "start: testparm fallito"; exit 1; }
$P/smb4-syncusers.sh || [ -s $P/private/passdb.tdb ] || { log4 "start: nessun passdb"; exit 1; }
# samba-dcerpcd (elenco share, LSA) se presente nella build; senza, smbd funziona comunque
D=/usr/libexec/samba/samba-dcerpcd
if [ -x $D ]; then
    chmod 755 $P/var/run $P/var/run/ncalrpc
    rm -f $P/var/run/ncalrpc/EPMAPPER
    RL=""
    for r in $RPCDS; do RL="$RL /usr/libexec/samba/$r"; done
    s4 $D -D -s $P/smb.conf $RL || log4 "start: samba-dcerpcd non avviato"
fi

rm -f /var/run/smbd.pid
s4 $B/usr/sbin/smbd -D -s $P/smb.conf || { log4 "start: smbd -D fallito"; exit 1; }

i=0
while [ $i -lt 30 ]; do
    if s4_running && port445; then
        # deve restare vivo: un panic arriva dopo qualche secondo
        sleep 3
        if [ -d /proc/$PID ]; then
            log4 "start: Samba 4 attivo, pid $PID"
            # i worker rpcd partono in ~20 s: li si avvia subito, così il primo
            # elenco share dei client non va in timeout
            if [ -x $D ]; then
                (
                    i=0
                    while [ ! -S $P/var/run/ncalrpc/EPMAPPER ] && [ $i -lt 180 ]; do sleep 1; i=$((i + 1)); done
                    s4 $B/usr/bin/rpcclient -s $P/smb.conf -N ncalrpc: -c srvinfo > /dev/null 2>&1
                    log4 "start: worker rpcd avviati: $(pidof $RPCDS)"
                ) < /dev/null > /dev/null 2>&1 &
            fi
            exit 0
        fi
    fi
    sleep 1
    i=$((i + 1))
done
log4 "start: Samba 4 non in ascolto su 445, ritorno allo stock"
killall smbd 2>/dev/null
sleep 2
killall -9 smbd 2>/dev/null
exit 1
