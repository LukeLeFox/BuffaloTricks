# "Finto" NAS Navigator in un container LXC (Auto Power)

Con l'interruttore su **AUTO** il Buffalo resta acceso finché almeno un PC con
NAS Navigator è acceso, e va in standby quando l'ultimo si spegne. Di solito
serve una VM Windows sempre pronta solo per questo.

Qui la VM è sostituita da ~80 righe di Python (solo libreria standard) in un
container LXC Debian da 128 MB: accendere il container sveglia il NAS,
spegnerlo lo manda in standby. Home Assistant può comandarlo come comandava la VM.

## Il protocollo Auto Power

Ricavato da catture reali di NAS Navigator e dall'analisi di `pwrmgr`/`naswol`,
poi verificato sul CS-WX.

| Messaggio | Contenuto (102 byte) | Destinazione |
|---|---|---|
| ACTIVE | `FF` ×6 + MAC del NAS ×16 (= un normale magic packet WOL) | UDP/9, unicast al NAS e broadcast |
| SHUTDOWN | `00` ×6 + MAC del NAS ×16 | UDP/9, unicast al NAS |

- NAS Navigator invia raffiche da 3 pacchetti, ACTIVE ogni ~150 s.
- `pwrmgr` tiene un **lease di 300 s per ogni client** (misurato sul CS-WX: senza
  rinnovi lo standby parte ~300-307 s dopo l'ultimo ACTIVE).
- SHUTDOWN ritira subito il lease di quel client.
- **Nei primi ~5 minuti dopo il boot lo SHUTDOWN non basta**: al primo giro
  `pmcd_exec.sh` esegue `pwrmgr -c localhost act`, cioè il NAS registra se stesso
  con il suo lease da 300 s. È voluto: il NAS si addormenta comunque alla scadenza.
- Il discovery di NAS Navigator (ACP, UDP/22936) non serve per tenere sveglio il NAS.

### Tempi misurati (CS-WX, firmware 1.13 build 2.35)

| Evento | Tempo |
|---|---|
| primo ACTIVE → Samba disponibile (il NAS si riavvia: `SUPPORT_WAKEUP_BY_REBOOT=1`) | ~2 min |
| SHUTDOWN (uptime > 5 min) → standby in RAM | ~1,5 min |
| nessun ACTIVE (client morto) → standby | ~6 min |

### Come capire lo stato del NAS dall'esterno

| Stato | TCP 445 | HTTP :80 | ping |
|---|---|---|---|
| normale | aperta | 200 (GUI) | sì |
| standby in RAM | chiusa | 404 (server minimale) | **sì** |
| riavvio in corso | — | — | no |

Il ping risponde anche in standby: non usarlo per capire se il NAS è sveglio.

## Installazione

### 1. Container su Proxmox

Debian 13 standard, **non privilegiato**, 1 core, 128 MB RAM, swap 0, 2 GB disco,
rete su `vmbr0`, **firewall disattivato** (può bloccare i broadcast),
*Start at boot* disattivato (l'accensione la decide Home Assistant).
Conviene una prenotazione DHCP o un IP statico. Se sostituisci la VM di NAS
Navigator puoi riusarne l'IP, ma allora **VM e container non vanno mai accesi insieme**.

### 2. Script e servizio

```bash
cp nas-keepalive.py /usr/local/bin/nas-keepalive.py
chmod 755 /usr/local/bin/nas-keepalive.py
cp nas-keepalive.service /etc/systemd/system/
# sostituisci <MAC_NAS>, <IP_NAS>, <BROADCAST_LAN> in ExecStart
systemctl daemon-reload
systemctl enable nas-keepalive
```

Il servizio parte con il container. Se all'avvio la rete non è ancora pronta
riprova ogni 5 s; allo stop (spegnimento ordinato del container) invia SHUTDOWN.
Il log dice quanti pacchetti sono partiti:

```
journalctl -u nas-keepalive
ACTIVE 6/6 -> <IP_NAS>, <BROADCAST_LAN>:9
SHUTDOWN 3/3 -> <IP_NAS>:9
```

Prova a secco senza toccare il NAS (porta diversa da 9, ascolta con tcpdump):

```bash
python3 nas-keepalive.py --mac <MAC_NAS> --ip <IP_DI_PROVA> --port 19009 --interval 4
```

### 3. Home Assistant (API REST di Proxmox)

Utente/token Proxmox con un ruolo minimo
(`Datastore.Audit, Sys.Audit, VM.Audit, VM.Console, VM.PowerMgmt`) solo sul container:

```bash
pveum acl modify /vms/<CTID> --users homeassistant@pve --roles VMControl
```

`configuration.yaml` (il token in `secrets.yaml` come
`pve_auth_header: "PVEAPIToken=homeassistant@pve!<nome>=<segreto>"`):

```yaml
binary_sensor:
  - platform: rest
    name: pve_nasnavi_running
    resource: "https://<IP_PROXMOX>:8006/api2/json/nodes/<NODO>/lxc/<CTID>/status/current"
    headers:
      Authorization: !secret pve_auth_header
    verify_ssl: false
    scan_interval: 10
    value_template: >
      {{ ((value_json or {}).get('data', {}).get('status')) == 'running' }}
    device_class: power

rest_command:
  pve_nasnavi_start:
    url: "https://<IP_PROXMOX>:8006/api2/json/nodes/<NODO>/lxc/<CTID>/status/start"
    method: POST
    headers:
      Authorization: !secret pve_auth_header
    verify_ssl: false
  pve_nasnavi_shutdown:
    url: "https://<IP_PROXMOX>:8006/api2/json/nodes/<NODO>/lxc/<CTID>/status/shutdown"
    method: POST
    headers:
      Authorization: !secret pve_auth_header
    verify_ssl: false

template:
  - switch:
      - name: "NAS Navigator"
        unique_id: "nas_navigator_ct"
        state: "{{ is_state('binary_sensor.pve_nasnavi_running', 'on') }}"
        turn_on:
          - action: rest_command.pve_nasnavi_start
        turn_off:
          - action: rest_command.pve_nasnavi_shutdown
```

Usa **shutdown**, non stop: con `stop` il container muore senza inviare SHUTDOWN
e il NAS si addormenta solo alla scadenza del lease (~6 min).
Nei percorsi API il tipo è `lxc`, non `qemu`.
