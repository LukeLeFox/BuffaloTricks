#!/usr/bin/env python3
"""Sostituto minimo di NAS Navigator per l'Auto Power Buffalo (CS-WX).

Riproduce solo il traffico Auto Power osservato nella cattura reale
buffalo-power-proxmox.pcap (cattura reale di NAS Navigator su Proxmox):

  ACTIVE   = FF x6 + MAC_NAS x16  (102 byte) -> UDP/9, raffiche da 3, ogni ~150 s
  SHUTDOWN = 00 x6 + MAC_NAS x16  (102 byte) -> UDP/9 unicast, raffica da 3, all'arresto

Il lease lato pwrmgr e' 300 s: se questo processo muore senza inviare SHUTDOWN
il NAS va comunque in standby alla scadenza. Non usa ACP/UDP 22936.
Solo libreria standard.
"""
import argparse
import signal
import socket
import sys
import time


def packet(mac: str, active: bool) -> bytes:
    raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
    if len(raw) != 6:
        raise ValueError(f"MAC non valido: {mac}")
    return (b"\xff" if active else b"\x00") * 6 + raw * 16


def burst(sock, payload, targets, port, count, label):
    """Invia la raffica e restituisce quanti datagrammi sono partiti."""
    sent = 0
    errors = set()
    for _ in range(count):
        for t in targets:
            try:
                sock.sendto(payload, (t, port))
                sent += 1
            except OSError as e:
                errors.add(f"{t}: {e.strerror}")
    msg = f"{label} {sent}/{count * len(targets)} -> {', '.join(targets)}:{port}"
    if errors:
        msg += " | errori: " + "; ".join(sorted(errors))
    print(msg, flush=True)
    return sent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac", required=True, help="MAC del NAS")
    ap.add_argument("--ip", required=True, help="IP unicast del NAS")
    ap.add_argument("--broadcast", help="indirizzo broadcast (opzionale)")
    ap.add_argument("--port", type=int, default=9)
    ap.add_argument("--interval", type=float, default=150.0)
    ap.add_argument("--burst", type=int, default=3)
    ap.add_argument("--retry", type=float, default=5.0,
                    help="secondi prima di riprovare se una raffica fallisce del tutto")
    ap.add_argument("--once", choices=["active", "shutdown"],
                    help="invia una sola raffica ed esce")
    a = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    active = packet(a.mac, True)
    shutdown = packet(a.mac, False)
    active_targets = [a.ip] + ([a.broadcast] if a.broadcast else [])

    if a.once:
        if a.once == "active":
            burst(sock, active, active_targets, a.port, a.burst, "ACTIVE")
        else:
            burst(sock, shutdown, [a.ip], a.port, a.burst, "SHUTDOWN")
        return

    stopping = False

    def on_term(signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    next_at = time.monotonic()
    while not stopping:
        now = time.monotonic()
        if now >= next_at:
            sent = burst(sock, active, active_targets, a.port, a.burst, "ACTIVE")
            # all'avvio la rete del container puo' non essere ancora pronta:
            # se non e' partito nulla si riprova presto invece di aspettare l'intervallo
            next_at = now + (a.interval if sent else a.retry)
        time.sleep(min(1.0, max(0.0, next_at - time.monotonic())))

    burst(sock, shutdown, [a.ip], a.port, a.burst, "SHUTDOWN")
    sys.exit(0)


if __name__ == "__main__":
    main()
