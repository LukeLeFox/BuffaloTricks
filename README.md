# BuffaloTricks

Fix persistenti per NAS Buffalo **LinkStation LS-WX20 / CloudStation CS-WX**
(firmware 1.13 build 2.35, BusyBox 1.7, root via ACP Commander).

| Problema | Fix |
|---|---|
| Errori e traffico verso il cloud Pogoplug (chiuso) | [Disattivare Pogoplug](#1-disattivare-pogoplug) |
| Orologio sempre al **7 febbraio 2036** | [Orologio](#2-orologio-sempre-al-2036) — `nas/fix-time.sh` |
| Standby / spegnimento bloccato per ore (LED che lampeggia) | [Standby bloccato](#3-standby-o-spegnimento-bloccato) — `nas/fix-clientutil-shutdown.sh` |
| Serve una VM Windows con NAS Navigator per l'Auto Power | [Finto NAS Navigator in LXC](nas-navigator-ct/README.md) |

---

## 🧠 Cosa sopravvive al boot

Il firmware rigenera parte del sistema a ogni avvio (anche ogni risveglio
dallo standby Auto Power, che è un riavvio).

| Percorso | Al boot | Uso |
|---|---|---|
| `/etc/hosts` | **ripristinato** | ricopiato ogni minuto da cron |
| `/etc/init.d/*` | **ripristinato** | correggere con un hook, non a mano |
| `/usr/local/cloudengines/bin/*` (Pogoplug) | **ripristinato** | neutralizzato da un hook a ogni boot |
| `/etc/melco/` | persistente | script e file custom |
| crontab di root (`/var/spool/cron/crontabs/root` → `/etc/cron/crontabs/root`) | persistente | cron |
| `/etc/rc.d/extensions.d/S*` | persistente (verificato su più riavvii da standby) | **hook di boot** |

### Hook di boot: `/etc/rc.d/extensions.d`

`/etc/init.d/rcS`, dopo aver avviato rete, Samba, cron e i demoni (step3/step4),
esegue ogni file `S*` in `/etc/rc.d/extensions.d/` con argomento `start`.
I nomi `SNNB_*` vengono eseguiti **in background** (non rallentano il boot).
Basta un symlink a uno script in `/etc/melco`:

```sh
ln -sf /etc/melco/mio-script.sh /etc/rc.d/extensions.d/S98B_mio_script
```

Uno script in background deve ignorare `SIGHUP` (`trap '' HUP`), altrimenti
viene ucciso a fine `rcS`.

> BusyBox crond vuole un **TAB** tra schedule e comando. Dopo aver modificato il
> crontab: `echo root > /etc/cron/crontabs/cron.update` (o riavvia crond).

---

## 1. Disattivare Pogoplug

### 1.1 Blocca i domini con `/etc/melco/hosts.custom`

```sh
cat <<'EOF' > /etc/melco/hosts.custom
127.0.0.1 localhost.localdomain localhost
10.10.99.253 LIL-NAS

# Block Pogoplug / CloudEngines queries
127.0.0.1 service.pogoplug.com
127.0.0.1 secure.pogoplug.com
127.0.0.1 my.pogoplug.com
127.0.0.1 api.pogoplug.com
127.0.0.1 www.pogoplug.com
127.0.0.1 cloud.pogoplug.com
127.0.0.1 pogo.pogoplug.com
127.0.0.1 update.pogoplug.com
127.0.0.1 stats.pogoplug.com
127.0.0.1 heartbeat.pogoplug.com
EOF

printf "*/1 * * * *\tcp /etc/melco/hosts.custom /etc/hosts\n" >> /var/spool/cron/crontabs/root
```

### 1.2 Ferma `hbplug` neutralizzando il lanciatore

> ⚠️ **Non usare** `killall hbplug hbplug_buffalo hbwd` da cron (versione
> precedente di questo README). `daemonwatch` sorveglia `hbwd` e lo fa ripartire
> con `/etc/init.d/hbmgr.sh restart`: ogni minuto `hbplug` riparte e a ogni
> avvio **reimposta l'orologio al 2036** (vedi sotto).

Catena di avvio: `daemonwatch` → `hbmgr.sh` → `hbwd` → `bin/hbplug_buffalo` → `hbplug`.
Il fix sostituisce il lanciatore `hbplug_buffalo` con un'attesa infinita:
`hbwd` vede il figlio vivo, `daemonwatch` è contento, `hbplug` non parte.
Lo fa `nas/fix-time.sh` (sezione 2), che lo rifà a ogni boot perché il firmware
ripristina il lanciatore originale. L'originale resta in `hbplug_buffalo.disabled`.

---

## 2. Orologio sempre al 2036

**Sintomo:** data `Thu Feb 7 07:28 CET 2036` dopo ogni boot (e di nuovo ogni
minuto con il vecchio `killall`), date sbagliate nei log, cron e SMART.

**Causa:** `hbplug` contiene un client NTP proprio ("Chose random NTP peer",
`settimeofday`). Non ricevendo una risposta valida imposta il timestamp NTP 0,
cioè l'overflow dell'era NTP: **2036-02-07 06:28:16 UTC**.
In più l'RTC non conserva un'ora valida (va fuori dal 2008) e il cron stock
`calib_time.sh` delle 04:08 esegue `hwclock -s`.
L'NTP della web GUI può restare disattivato.

**Fix:** [`nas/fix-time.sh`](nas/fix-time.sh) neutralizza `hbplug` (1.2) e
sincronizza con `ntpdate` (`it.pool.ntp.org`, con riserve). Non scrive l'RTC.

```sh
cp fix-time.sh /etc/melco/fix-time.sh && chmod 755 /etc/melco/fix-time.sh
ln -sf /etc/melco/fix-time.sh /etc/rc.d/extensions.d/S98B_fix_time
printf "* * * * *\t/etc/melco/fix-time.sh check >/dev/null 2>&1\n" >> /etc/cron/crontabs/root
printf "9 * * * *\t/etc/melco/fix-time.sh >/dev/null 2>&1\n" >> /etc/cron/crontabs/root
echo root > /etc/cron/crontabs/cron.update
/etc/melco/fix-time.sh
```

- al boot: neutralizza `hbplug` e sincronizza (riprova fino a ~2 min);
- ogni minuto (`check`): se l'anno è fuori 2025-2030 sincronizza subito, e
  verifica che `hbplug` sia spento;
- ogni ora al minuto 9: sincronizzazione normale (corregge anche le 04:08).

Log: `/etc/melco/fix-time.log`. Dopo un risveglio l'ora è giusta in ~20 s - 2 min.

---

## 3. Standby o spegnimento bloccato

**Sintomo:** interruttore su OFF (o standby Auto Power), LED power che lampeggia
per ore, SSH ancora attivo, RAID sano, `sync` immediato.

**Causa:** in `/etc/init.d/clientUtil_servd.sh stop`

```sh
rm /var/run/clientUtil_server-${DEVICE_NETWORK_PRIMARY}.pid
```

resta in attesa di input dalla console (`wchan` = `n_tty_read`, stdin =
`/dev/console`). La catena è `standby.rcDown` → `shutdown_proc.sh` →
`clientUtil_servd.sh stop` → `rm`. Siccome `shutdown_proc.sh` ferma clientUtil
**prima** di Samba (e cron prima ancora), il NAS resta acceso con SMB attivo.
Uccidere quel `rm` sblocca subito lo spegnimento.

**Fix:** `rm` → `rm -f`. `/etc/init.d` viene ripristinato a ogni boot, quindi
[`nas/fix-clientutil-shutdown.sh`](nas/fix-clientutil-shutdown.sh) lo ricorregge:

```sh
cp /etc/init.d/clientUtil_servd.sh /etc/melco/clientUtil_servd.sh.stock
cp fix-clientutil-shutdown.sh /etc/melco/ && chmod 755 /etc/melco/fix-clientutil-shutdown.sh
ln -sf /etc/melco/fix-clientutil-shutdown.sh /etc/rc.d/extensions.d/S99_clientutil_shutdown_fix
# riserva finché non sono provati anche gli avvii a freddo:
printf "* * * * *\t/etc/melco/fix-clientutil-shutdown.sh >/dev/null 2>&1\n" >> /etc/cron/crontabs/root
```

Verificato: hook eseguito a ogni boot (log `/etc/melco/fix-clientutil-shutdown.log`),
standby con SHUTDOWN completato in ~1,5 min senza `rm` bloccati.

---

## ♻️ Rollback

```sh
# Pogoplug + orologio
cp -p /usr/local/cloudengines/bin/hbplug_buffalo.disabled /usr/local/cloudengines/bin/hbplug_buffalo
rm -f /etc/rc.d/extensions.d/S98B_fix_time /etc/melco/fix-time.sh
sed -i '/fix-time.sh/d' /etc/cron/crontabs/root
sed -i '/hosts.custom/d' /etc/cron/crontabs/root

# standby bloccato
rm -f /etc/rc.d/extensions.d/S99_clientutil_shutdown_fix
sed -i '/fix-clientutil-shutdown.sh/d' /etc/cron/crontabs/root
cp -p /etc/melco/clientUtil_servd.sh.stock /etc/init.d/clientUtil_servd.sh

echo root > /etc/cron/crontabs/cron.update
```

---

## 🏆 Testato su

- Buffalo LinkStation LS-WX20 / CloudStation CS-WX (CS-WX20/R1-EU), Marvell 88F6281
- Firmware 1.13 build 2.35, kernel 2.6.31.8, BusyBox 1.7, OpenSSH 3.7.1
- Auto Power comandato da Proxmox + Home Assistant

Per SSH da client moderni l'OpenSSH 3.7.1 del NAS richiede algoritmi legacy:

```
ssh -o KexAlgorithms=+diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1 \
    -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@<IP_NAS>
```

## 📎 Autori

**Luke** e **ChatGPT** (2025); orologio, standby e NAS Navigator in LXC con **Claude** (2026).
