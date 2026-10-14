#!/bin/sh
#
# Tiene giusto l'orologio del NAS.
#
# Causa del problema: hbplug (client del servizio cloud Pogoplug, chiuso) ha un
# client NTP interno che a ogni avvio imposta l'ora al valore di overflow NTP
# (7 feb 2036 06:28:16 UTC). daemonwatch -> hbmgr.sh -> hbwd lo riavvia di continuo.
# Rimedio: il lanciatore hbplug_buffalo viene sostituito da un'attesa infinita
# (hbwd resta contento, hbplug non parte) e l'ora viene sincronizzata via NTP.
# L'RTC non conserva valori validi, quindi non viene scritto.
#
#   boot: /etc/rc.d/extensions.d/S98B_fix_time -> questo script con "start"
#         (prefisso B = eseguito in background da rcS, non rallenta il boot)
#   cron: * * * * * check  (se l'anno e' fuori 2025-2030 sincronizza subito;
#                           verifica sempre che hbplug sia spento)
#         9 * * * *        (sincronizzazione oraria, anche subito dopo
#                           calib_time.sh delle 04:08 che riporta l'ora dell'RTC)
#
# Rollback:
#   cp -p /usr/local/cloudengines/bin/hbplug_buffalo.disabled /usr/local/cloudengines/bin/hbplug_buffalo
#   rm /etc/rc.d/extensions.d/S98B_fix_time ; togliere la riga dal crontab ; rm /etc/melco/fix-time.sh

NTPDATE=/usr/local/sbin/ntpdate
SERVERS="it.pool.ntp.org pool.ntp.org time.cloudflare.com"
LOG=/etc/melco/fix-time.log
LAUNCHER=/usr/local/cloudengines/bin/hbplug_buffalo
MARK="NEUTRALIZZATO-fix-time"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG"
    # tiene il log piccolo
    if [ "$(wc -l < "$LOG")" -gt 200 ]; then
        tail -n 100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

neutralize_hbplug() {
    [ -f "$LAUNCHER" ] || return 0
    # il firmware ripristina il lanciatore originale a ogni boot
    if ! grep -q "$MARK" "$LAUNCHER"; then
        [ -f "$LAUNCHER.disabled" ] || cp -p "$LAUNCHER" "$LAUNCHER.disabled"
        cat > "$LAUNCHER" <<EOF
#!/bin/sh
# $MARK: hbplug (Pogoplug) resettava l'orologio al 2036 col suo client NTP.
# Originale in hbplug_buffalo.disabled. Vedi /etc/melco/fix-time.sh
while :; do sleep 86400; done
EOF
        chmod 755 "$LAUNCHER"
        log "lanciatore hbplug neutralizzato"
    fi
    # al boot hbplug puo' essere gia' partito (o partire a momenti dal vecchio
    # lanciatore ancora in esecuzione): lo si ferma finche' non resta assente
    # per due controlli di fila. hbwd rilancia il lanciatore, che ora resta in attesa.
    absent=0
    i=0
    while [ $absent -lt 2 ] && [ $i -lt 30 ]; do
        if pidof hbplug > /dev/null 2>&1; then
            killall hbplug > /dev/null 2>&1
            [ $i -eq 0 ] && log "hbplug in esecuzione: fermato"
            absent=0
        else
            absent=$((absent + 1))
        fi
        i=$((i + 1))
        sleep 2
    done
}

sync_once() {
    for s in $SERVERS; do
        if $NTPDATE -s -b -t 3 "$s" > /dev/null 2>&1; then
            SYNCED_FROM=$s
            return 0
        fi
    done
    return 1
}

[ -x "$NTPDATE" ] || exit 0

# da rcS gira in background: non deve morire a fine boot
trap '' HUP

neutralize_hbplug

if [ "$1" = "check" ]; then
    # cron ogni minuto: sincronizza solo se l'anno e' palesemente sbagliato
    y=$(date +%Y)
    [ "$y" -ge 2025 ] && [ "$y" -le 2030 ] && exit 0
    if sync_once; then
        log "check: anno $y, sincronizzato con $SYNCED_FROM"
        exit 0
    fi
    log "check: anno $y, sincronizzazione fallita"
    exit 1
fi

if [ "$1" = "start" ]; then
    # al boot la rete o il DNS possono non essere ancora pronti: riprova fino a ~2 min
    i=0
    while [ $i -lt 12 ]; do
        if sync_once; then
            log "boot: sincronizzato con $SYNCED_FROM"
            exit 0
        fi
        i=$((i + 1))
        sleep 10
    done
    log "boot: sincronizzazione fallita dopo 12 tentativi"
    exit 1
fi

sync_once || { log "cron: sincronizzazione fallita"; exit 1; }
exit 0
