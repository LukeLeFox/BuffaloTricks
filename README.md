# BuffaloTricks


# Disabilitare per Sempre Pogoplug su NAS Buffalo LS-WX20
*(Metodo Persistente tramite BusyBox Cron Override + Hardening Processi)*

## 🔥 Obiettivo
Eliminare definitivamente:

- gli errori “Impossibile raggiungere il servizio Pogoplug”
- il traffico DNS continuo verso i server cloud
- i tentativi HTTPS ogni 2 secondi
- l’impatto CPU dei demoni CloudEngines (`hbplug`, `hbwd`)
- i processi cloud residui che tentano connessioni interne

… utilizzando un metodo **persistente**, sicuro e compatibile con il firmware Buffalo che ripristina `/etc` ad ogni boot.

---

## 🧠 Perché questo metodo funziona

Il firmware Buffalo LS-WX20:

- ripristina `/etc/hosts` ad ogni boot  
- ripristina binari CloudEngines (`hbwd`, `hbplug`)  
- ignora `/etc/init.d/`  
- ignora `/etc/rc.local`  
- non esegue script user in rc.d  
- ricrea metà filesystem da squashfs ad ogni riavvio

❗ **MA NON RIPRISTINA:**

- `/etc/melco`  
- `/var/spool/cron/crontabs/root`  

➡️ Quindi usiamo **cron** sia per sovrascrivere `/etc/hosts` che per **terminare i processi Pogoplug**, rendendo il fix permanente.

---

# ✅ Soluzione Permanente (testata su LS-WX20)

## 1️⃣ Crea il file persistente `/etc/melco/hosts.custom`

```
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
```

---

## 2️⃣ Sovrascrivi `/etc/hosts` automaticamente ogni minuto

BusyBox *richiede un TAB* tra schedule e comando.  
Usiamo un append diretto:

```
printf "*/1 * * * *\tcp /etc/melco/hosts.custom /etc/hosts
" >> /var/spool/cron/crontabs/root
```

Verifica:

```
crontab -l
```

---

## 3️⃣ **Kill dei processi Pogoplug** (fix aggiuntivo consigliato)

I servizi cloud Buffalo (`hbplug`, `hbwd`) continueranno a ripartire dopo il boot.  
Dato che il cloud non esiste più, possiamo terminarli ciclicamente.

Aggiungiamo una seconda entry cron:

```
printf "*/1 * * * *\tkillall hbplug hbplug_buffalo hbwd 2>/dev/null
" >> /var/spool/cron/crontabs/root
```

Effetti:

- nessun processo Pogoplug attivo
- niente loop interni
- niente log superflui
- NAS più silenzioso

Verifica:

```
crontab -l
```

---

## 4️⃣ Riavvia cron

```
killall crond
/usr/sbin/crond
```

Oppure:

```
/etc/init.d/cron restart
```

---

## 5️⃣ Riavvia il NAS

```
reboot
```

---

## 6️⃣ Dopo 60 secondi: verifica

### Hosts:

```
cat /etc/hosts
```

Deve mostrare le entry Pogoplug bloccate.

### Processi Pogoplug:

```
ps | grep hb
```

Non deve apparire nessuno dei processi:

- hbplug  
- hbplug_buffalo  
- hbwd  

---

# 🎉 Risultato

- 🔇 Nessun traffico DNS verso Pogoplug  
- 💨 Nessun tentativo HTTPS verso i vecchi server cloud  
- 🧩 Nessun timeout ripetuto nella GUI  
- 🧘 NAS più silenzioso, stabile e leggero  
- 🔒 Patch **persistente al 100%**  
- 🚫 NESSUN processo cloud in esecuzione  
- ❇️ Completamente reversibile rimuovendo le due righe dal crontab

---

# ♻️ Disattivare la patch

### Rimuovi le righe dal crontab:

```
sed -i '/hosts.custom/d' /var/spool/cron/crontabs/root
sed -i '/killall hbplug/d' /var/spool/cron/crontabs/root
```

Riavvia cron:

```
killall crond
/usr/sbin/crond
```

---

# 🧩 Note tecniche

- `/etc/melco` è persistente → ideale per file custom  
- `/var/spool/cron/crontabs/root` è persistente → entry cron sicure  
- Cron parte dopo che Buffalo ripristina `/etc`  
- Override e kill avvengono *dopo* il reset del firmware  
- Il NAS resta completamente funzionante (SMB, DLNA, RAID, GUI)  
- La parte cloud viene soppressa in modo pulito  

---

# 🏆 Fix confermato su:

- Buffalo LinkStation LS-WX20 (CS-WX20/R1-EU)
- Firmware 1.13 build 2.35
- root via ACP Commander
- BusyBox v1.7

---

# 📎 Autore

Fix sviluppato e testato da **Luke** e **ChatGPT**, 2025.  
Con assistenza tecnica, reverse-engineering e patching runtime.

