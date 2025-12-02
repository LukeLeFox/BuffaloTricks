# BuffaloTricks


# Disabilitare per Sempre Pogoplug su NAS Buffalo
*(Metodo Persistente tramite BusyBox Cron Override)*

## 🔥 Obiettivo
Eliminare definitivamente:

- gli errori “Impossibile raggiungere il servizio Pogoplug”
- il traffico DNS continuo verso i server cloud
- i tentativi HTTPS ogni 2 secondi
- l’impatto CPU dei demoni CloudEngines (`hbplug`, `hbwd`)

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

E i cronjob di BusyBox **vengono eseguiti SEMPRE**, anche se il resto del sistema è read-only.

➡️ Quindi sovrascriviamo `/etc/hosts` **ogni minuto** tramite cron.  
➡️ Dopo ogni boot, entro 60 secondi, il file è correttamente patchato.

---

## ✅ Soluzione Permanente (testata su LS-WX20)

### 1️⃣ Crea il file persistente `/etc/melco/hosts.custom`

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

Verifica:

```
cat /etc/melco/hosts.custom
```

---

### 2️⃣ Aggiungi un cronjob persistente per sovrascrivere `/etc/hosts`

BusyBox *richiede un TAB* tra schedule e comando.  
Per evitare l’editor `vi`, usiamo un append diretto:

```
printf "*/1 * * * *\tcp /etc/melco/hosts.custom /etc/hosts
" >> /var/spool/cron/crontabs/root
```

Verifica:

```
crontab -l
```

Deve apparire:

```
*/1 * * * *    cp /etc/melco/hosts.custom /etc/hosts
```

(Il TAB può sembrare invisibile)

---

### 3️⃣ Riavvia cron

```
killall crond
/usr/sbin/crond
```

Oppure:

```
/etc/init.d/cron restart
```

---

### 4️⃣ Riavvia il NAS

```
reboot
```

---

### 5️⃣ Dopo 60 secondi dal boot: verifica

```
cat /etc/hosts
```

Se il fix è attivo, vedrai:

```
127.0.0.1 localhost.localdomain localhost
10.10.99.253 LIL-NAS
127.0.0.1 service.pogoplug.com
…
```

---

## 🎉 Risultato

- 🔇 Nessun traffico DNS verso Pogoplug  
- 💨 Nessun tentativo HTTPS verso i vecchi server cloud  
- 🧩 Nessun timeout ripetuto nella GUI  
- 🧘 NAS più silenzioso, stabile e leggero  
- 🔒 Patch **persistente al 100%**  
- ❇️ Completamente reversibile rimuovendo la riga nel crontab

---

## ♻️ Disattivare la patch (opzionale)

Apri il crontab:

```
crontab -e
```

Cancella la riga:

```
*/1 * * * *    cp /etc/melco/hosts.custom /etc/hosts
```

Oppure con un comando:

```
sed -i '/hosts.custom/d' /var/spool/cron/crontabs/root
```

Riavvia cron:

```
killall crond
/usr/sbin/crond
```

---

## 🧩 Note tecniche sul funzionamento

- Buffalo *ricrea* `/etc/hosts` ad ogni boot  
- ma `crond` parte dopo questo ripristino  
- e legge **solo** `/var/spool/cron/crontabs/root`  
- quindi la patch viene applicata *dopo* il reset del firmware  
- i demoni Pogoplug (`hbplug`, `hbwd`) vedono `127.0.0.1`  
- smettono di fare retry e la GUI non segnala più il cloud come “non raggiungibile”

---

## 🏆 Fix confermato su:

- Buffalo LinkStation LS-WX20 (CS-WX20/R1-EU)
- Firmware 1.13 build 2.35
- root via ACP Commander
- BusyBox v1.7

---

## 📎 Autore

Fix sviluppato e testato da **Luke** e **ChatGPT**, 2025.  
Con assistenza tecnica, reverse-engineering e patching runtime.
