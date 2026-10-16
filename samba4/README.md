# SMB2/SMB3 con autenticazione: Samba 4.23 al posto dello smbd stock

Lo smbd del firmware è **Samba 3.0.30** (2008): parla solo **SMB1** e le share
create dalla web UI sono di solito accessibili in **guest**. I client moderni
rifiutano SMB1 o l'accesso guest su SMB2/3 (Windows 10 1709+, Windows 11 24H2,
macOS recenti, kernel Linux con `vers=3.x`).

Qui lo smbd stock viene sostituito da **Samba 4.23.13** compilato per ARMv5,
installato sull'array dati, con:

- SMB2.02 → SMB3.1.1, SMB1 e guest disattivati, NTLMv2;
- **utenti e password della web UI Buffalo** copiati a ogni avvio (niente da reimpostare);
- share lette dalla `smb.conf` stock: le modifiche dalla web UI continuano a valere;
- elenco delle share (`\\NAS`) tramite `samba-dcerpcd`;
- `nmbd` stock, NAS Navigator, Auto Power e standby invariati;
- ritorno allo stock con un solo comando.

## Misure (CS-WX, file da 64 MB, client Linux in gigabit)

| Modalità | Scrittura | Lettura |
|---|---|---|
| SMB1 stock, guest | 10,7 MB/s | 14,3 MB/s |
| SMB3.1.1 autenticato, senza firma | 9–10 MB/s | 12–17,6 MB/s |
| SMB2.1 firmato (HMAC-SHA256) | 3,4 MB/s | 4,1 MB/s |
| SMB3.1.1 firmato AES-128-**CMAC** | 2,0–2,3 MB/s | 2,3–2,4 MB/s |
| SMB3.1.1 firmato AES-128-**GMAC** | 0,9 MB/s | 1,0 MB/s |

Il Kirkwood 88F6281 non ha istruzioni AES: la **firma** costa moltissimo.
Il server preferisce CMAC e firma solo se il client lo pretende
(`server signing = default`). Vedi [Client](#client) per Windows 11 e macOS.

---

## Come è fatto

```
/etc/init.d/smb.sh            (patch: smb.sh.patch)
  start_smbd ──► prod/smb4-start.sh ──ok──► Samba 4 su 445/139
       │                         └─errore─► smbd stock come prima
  stop_smbd  ──► killall smbd samba-dcerpcd rpcd_* + attesa (l'array va smontato in standby)
  reload     ──► prod/smb4-reload.sh (web UI: share e utenti aggiornati)

/mnt/array1/.buffalo-samba-test/
  v2/          Samba 4.23.13 + uClibc (loader e RPATH puntano qui)
  prod/        global.conf, smb4-*.sh, smb.conf generata, passdb, lock, log
/usr/libexec/samba → v2/usr/libexec/samba   (percorsi compilati nella build)
/usr/lib/samba     → v2/usr/lib/samba
```

| Script | Cosa fa |
|---|---|
| [`smb4-env.sh`](nas/smb4-env.sh) | percorsi; `B=` sceglie quale build usare |
| [`smb4-genconf.sh`](nas/smb4-genconf.sh) | `global.conf` + share della `smb.conf` stock (guest → no, via `vfs audit`), nome NetBIOS e workgroup dalla web UI |
| [`smb4-syncusers.sh`](nas/smb4-syncusers.sh) | copia utenti e hash dal passdb stock al passdb Samba 4, **fail-closed** |
| [`smb4-start.sh`](nas/smb4-start.sh) | lock, attende che la 445 sia libera, sync, `samba-dcerpcd`, `smbd`, verifica, preriscalda i worker RPC |
| [`smb4-reload.sh`](nas/smb4-reload.sh) | `reload` dalla web UI: nuova config con HUP, riavvio solo se cambiano gli utenti |
| [`fix-samba4.sh`](nas/fix-samba4.sh) | hook di boot: il firmware ripristina `/etc/init.d` a ogni avvio |

### Utenti: perché il formato testo `smbpasswd`

L'export `tdbsam` → `tdbsam` con il `pdbedit` di Samba 3 (e anche quello di
Samba 4) **esce con codice 0 e produce un TDB da 421888 byte senza account**.
Passando dal formato testo funziona:

```sh
/usr/local/bin/pdbedit -L -w -s /etc/samba/smb.conf > smbpasswd.txt      # Samba 3
pdbedit -i smbpasswd:smbpasswd.txt -e tdbsam:new.tdb                     # Samba 4
```

`smb4-syncusers.sh` sostituisce il passdb attivo solo se `utente:UID:hash NT`
coincide tra stock e Samba 4 (confronto su md5, gli hash non vengono stampati).
Il DB stock non viene mai scritto.

### Elenco share: `samba-dcerpcd` su una CPU da 1,2 GHz

Da Samba 4.16 l'elenco share (srvsvc) è servito da `samba-dcerpcd` e dai
processi `rpcd_*`. Sul CS-WX:

- all'avvio `samba-dcerpcd` interroga ogni `rpcd_*` (~5-10 s l'uno);
- con i default ogni worker esce dopo **60 s** di inattività e ripartire costa
  ~20 s: il client va in `NT_STATUS_IO_TIMEOUT`.

Per questo `smb4-start.sh` avvia `samba-dcerpcd` da sé con solo
`rpcd_epmapper rpcd_classic rpcd_winreg rpcd_lsad`, `global.conf` imposta
`rpc start on demand helpers = no` e `rpcd_*:idle_seconds = 31536000`
(un anno: valori più alti superano il `time_t` a 32 bit), e dopo l'avvio un
`rpcclient ncalrpc:` locale fa partire i worker (riprova fino a 3 volte: al boot
il NAS è carico). Risultato: primo elenco share in 0,4-0,5 s; senza preriscaldamento ~5-20 s.

---

## Installazione

> Prima: backup di `/etc` (contiene `smb.conf`, `smbpasswd.tdb`, `secrets.tdb`)
> e RAID sano (`cat /proc/mdstat`). Serve un accesso root SSH (vedi README principale).

### 1. Binari

Compila (vedi [Build](#build)) e copia il pacchetto sul NAS:

```sh
cat samba-4.23.13-v2.tar.gz | ssh <legacy-opts> root@<IP_NAS> 'cd / && tar xzf -'
```

Prova rapida sul NAS (nessun servizio toccato):

```sh
/mnt/array1/.buffalo-samba-test/v2/usr/sbin/smbd -V      # Version 4.23.13
```

### 2. Script

```sh
P=/mnt/array1/.buffalo-samba-test/prod
mkdir -p $P && cp global.conf smb4-*.sh $P/ && chmod 755 $P/smb4-*.sh
mkdir -p $P/private $P/var/lock $P/var/state $P/var/cache $P/var/log $P/var/run/ncalrpc
chmod 700 $P/private ; chmod 755 $P/var/run $P/var/run/ncalrpc   # Samba controlla i permessi
$P/smb4-syncusers.sh && $P/smb4-genconf.sh
```

Prova su una porta di test senza fermare lo stock (`smb ports = 4445`, lock/state
in un'altra cartella) prima del passaggio: è stato fatto così.

### 3. `smb.sh` e hook di boot

```sh
cp -p /etc/init.d/smb.sh /etc/melco/smb.sh.stock
patch /etc/init.d/smb.sh < smb.sh.patch          # oppure applicala su un PC e copia il file
cp -p /etc/init.d/smb.sh /etc/melco/smb.sh.samba4
cp fix-samba4.sh /etc/melco/ && chmod 755 /etc/melco/fix-samba4.sh
ln -sf /etc/melco/fix-samba4.sh /etc/rc.d/extensions.d/S97B_fix_samba4
md5sum /etc/melco/smb.sh.stock                   # deve coincidere con STOCK_MD5 in fix-samba4.sh
/etc/init.d/smb.sh restart                        # ~60 s; log in $P/var/log/smb4-wrapper.log
```

`fix-samba4.sh` reinstalla `smb.sh.samba4` a ogni boot **solo** se trova lo
`smb.sh` stock con l'md5 atteso; dopo un aggiornamento firmware lascia lo stock.

Nei test (reboot e risveglio dallo standby) `smb.sh` modificato è rimasto al suo
posto e Samba 4 è partito direttamente da `rcS`; il firmware ha ripristinato solo
`clientUtil_servd.sh`. L'hook resta come rete di sicurezza: se `smb.sh` torna
stock, per ~1-2 minuti al boot parte lo smbd stock, poi l'hook passa a Samba 4.

### Verifica

```sh
cat /var/run/smbd.pid ; tr '\0' ' ' < /proc/$(cat /var/run/smbd.pid)/cmdline   # .../v2/usr/sbin/smbd
grep -c ':01BD 00000000:0000 0A' /proc/net/tcp                                 # porta 445
pidof samba-dcerpcd rpcd_classic rpcd_winreg
smbclient -L //<IP_NAS> -U <utente>                                            # dal PC
```

---

## Client

Gli utenti sono quelli della web UI. **Il guest non funziona più.**

- **Linux (`mount.cifs`, Proxmox, Jellyfin)**: `vers=3.1.1` e file credenziali
  (`chmod 600`), utente dedicato con sola lettura se basta:

  ```
  //<IP_NAS>/media  /mnt/smb  cifs  credentials=/root/.smb-nas,_netdev,vers=3.1.1,uid=1000,gid=1000,nofail,x-systemd.automount  0  0
  ```
  ```
  username=<utente>
  password=<password>
  ```
- **Dolphin / GNOME / smbclient con richiesta password infinita**: in
  `/etc/samba/smb.conf` del PC c'era `client min protocol = NT1` (serviva per lo
  stock). Con NT1 come minimo la negoziazione con un server senza SMB1 fallisce
  (`NT_STATUS_INVALID_PARAMETER`) prima ancora dell'autenticazione:
  `client min protocol = SMB2_02`.
- **Windows 11 24H2 e macOS** impongono la firma (~2 MB/s su questo NAS). In LAN
  di casa si può togliere l'obbligo lato client:
  - Windows (PowerShell admin): `Set-SmbClientConfiguration -RequireSecuritySignature $false`
  - macOS: `signing_required=no` in `/etc/nsmb.conf` (non verificato qui)
- Aprire `\\<NAS>\media` direttamente funziona sempre; `\\<NAS>` mostra l'elenco
  grazie a `samba-dcerpcd`.

---

## Build

Ricetta in [`build/`](build/): Buildroot **2025.02.18**, arm926t, EABI soft-float,
**uClibc-ng 1.0.59**, GCC 13.4, **header kernel 2.6.31.14** (come il kernel del
NAS: uClibc non usa syscall che il kernel non ha).

```sh
tar xJf buildroot-2025.02.18.tar.xz
cp build/buildroot-package-samba4/* buildroot-2025.02.18/package/samba4/
rm buildroot-2025.02.18/package/samba4/0002-ldap_message_test.c-include-stdint.h-before-cmoka.h.patch
sed -i 's/^SAMBA4_VERSION = .*/SAMBA4_VERSION = 4.23.13/' buildroot-2025.02.18/package/samba4/samba4.mk
cp -r build/patches build/cswx_samba_defconfig build/package-v2.sh .
cd buildroot-2025.02.18
make O=$PWD/../out-stock BR2_DEFCONFIG=$PWD/../cswx_samba_defconfig defconfig
make O=$PWD/../out-stock            # ~1 h su 32 core, compresa la toolchain
cd .. && O=$PWD/out-stock ./package-v2.sh   # → samba-4.23.13-v2.tar.gz
```

| File | Perché |
|---|---|
| `cswx_samba_defconfig` | toolchain e pacchetti (`BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_REALLY_OLD`) |
| `buildroot-package-samba4/` | hash 4.23.13 (firma GPG verificata) e patch heimdal riscritta per 4.23 |
| `patches/linux-headers/0001-*` | uClibc-ng 1.0.59 non definisce più `__GLIBC__`: `linux/socket.h` 2.6.31 ridefiniva `sockaddr`, `iovec`, `msghdr` |
| `patches/samba4/0100-*` | `FICLONERANGE` / `struct file_clone_range` non esistono negli header < 4.5 |
| `package-v2.sh` | copia binari e librerie, `patchelf` di loader e RPATH verso `v2/`, strip |

La uClibc risultante esporta `accept4` e `pipe2` ma non `prlimit`, `syncfs`,
`setns`, `sendmmsg`, `getrandom`, `statx` (introdotte dopo il 2.6.31).

---

## Rollback

| Cosa | Comando sul NAS |
|---|---|
| Subito allo stock (resta fino a nuovo ordine) | `touch /etc/samba/USE_STOCK && /etc/init.d/smb.sh restart` |
| Di nuovo Samba 4 | `rm /etc/samba/USE_STOCK && /etc/init.d/smb.sh restart` |
| Build precedente | `B=$R` in `prod/smb4-env.sh`, poi `restart` |
| Togliere tutto | `rm /etc/rc.d/extensions.d/S97B_fix_samba4`, `cp -p /etc/melco/smb.sh.stock /etc/init.d/smb.sh`, `rm /usr/libexec/samba /usr/lib/samba`, `restart` |

I client Linux montati con `vers=3.1.1` vanno riportati a `guest,vers=1.0`.

---

## Cosa è andato storto (e come è stato risolto)

- **Loop di riavvii al primo passaggio**: `daemonwatch` riavvia `smb.sh` se
  `/var/run/smbd.pid` non punta a un processo vivo; durante il restart due avvii
  si sono accavallati e il secondo smbd andava in panic (445 occupata).
  → lock in `smb4-start.sh`, attesa porta libera, pid dello script nel pid file
  durante la preparazione, verifica che il pid in ascolto sia quello giusto.
- **`samba-dcerpcd` uscito in silenzio**: i servizi sulla riga di comando vanno
  passati con il percorso completo; senza IPv6 nel kernel serve `interfaces = eth1 lo`
  + `bind interfaces only = yes`; la cartella `ncalrpc` deve essere 0755.
- **`/etc/init.d` ripristinato al boot** → hook `fix-samba4.sh`.

## Stato delle verifiche

| | |
|---|---|
| SMB3.1.1, auth, guest rifiutato, SMB1 rifiutato | ✅ |
| utenti e password della web UI | ✅ (4 account, hash identici) |
| Proxmox `mount.cifs` vers=3.1.1, Jellyfin | ✅ |
| Dolphin, iPhone (File) | ✅ |
| elenco share (`smbclient -L`) | ✅ |
| `smb.sh restart` senza loop | ✅ |
| reboot completo: Samba 4 v2 parte da solo, Proxmox si ricollega | ✅ |
| standby Auto Power (CT NAS Navigator spento): smbd, samba-dcerpcd e rpcd fermati in ~4 s, array smontato | ✅ |
| risveglio (CT riacceso): NAS di nuovo su SMB3 in ~2,5 min, elenco share e mount ok | ✅ |
| Windows Explorer `\\NAS`, Finder | ⏳ da verificare |
