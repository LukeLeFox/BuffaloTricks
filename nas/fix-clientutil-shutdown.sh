#!/bin/sh
#
# Fix per lo spegnimento/standby bloccato: in clientUtil_servd.sh stop il comando
# "rm /var/run/clientUtil_server-<if>.pid" resta in attesa di input sulla console
# (wchan n_tty_read) e blocca standby.rcDown / shutdown per ore.
# Diventa "rm -f". Il firmware ripristina /etc/init.d a ogni boot, quindi lo script
# va rieseguito: hook /etc/rc.d/extensions.d/S99_clientutil_shutdown_fix (+ cron di riserva).

TARGET="/etc/init.d/clientUtil_servd.sh"
LOG="/etc/melco/fix-clientutil-shutdown.log"

[ -f "$TARGET" ] || exit 0

if [ "$1" = "start" ]; then
    echo "$(date) - boot hook invoked" >> "$LOG"
fi

if grep -q 'rm /var/run/clientUtil_server-${DEVICE_NETWORK_SECONDARY}.pid' "$TARGET"; then
    sed -i \
        's|rm /var/run/clientUtil_server-${DEVICE_NETWORK_SECONDARY}.pid|rm -f /var/run/clientUtil_server-${DEVICE_NETWORK_SECONDARY}.pid|' \
        "$TARGET"
    echo "$(date) - patched SECONDARY" >> "$LOG"
fi

if grep -q 'rm /var/run/clientUtil_server-${DEVICE_NETWORK_PRIMARY}.pid' "$TARGET"; then
    sed -i \
        's|rm /var/run/clientUtil_server-${DEVICE_NETWORK_PRIMARY}.pid|rm -f /var/run/clientUtil_server-${DEVICE_NETWORK_PRIMARY}.pid|' \
        "$TARGET"
    echo "$(date) - patched PRIMARY" >> "$LOG"
fi

exit 0
