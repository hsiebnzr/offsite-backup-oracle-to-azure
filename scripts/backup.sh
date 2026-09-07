#!/bin/bash
#
# Nächtliches Backup der Minecraft-Welt mit Offsite-Upload nach Azure Blob Storage.
#
# Aufruf per Cron:
#   0 4 * * * bash /home/ubuntu/minecraft-server/backup.sh
#
# Voraussetzungen:
#   - Azure CLI installiert (/usr/bin/az)
#   - /home/ubuntu/.azure-backup.env vorhanden, Rechte 600
#   - Minecraft läuft in einer screen-Session namens "minecraft"

BACKUP_DIR="/home/ubuntu/minecraft-backups"
WORLD_DIR="/home/ubuntu/minecraft-server"
ENV_FILE="/home/ubuntu/.azure-backup.env"
AZ="/usr/bin/az"

DATE=$(date +%Y-%m-%d_%H-%M)
ARCHIV="$BACKUP_DIR/world_$DATE.tar.gz"
LOG="$BACKUP_DIR/azure-upload.log"

mkdir -p "$BACKUP_DIR"

# Befehl an die Server-Konsole schicken
mc() { screen -S minecraft -X stuff "$1$(printf '\r')"; }

# Sicherheitsnetz: Speichern wieder einschalten, auch wenn das Skript abbricht.
# Ohne das würde ein Abbruch zwischen save-off und save-on das Speichern dauerhaft
# deaktivieren. Der Server liefe weiter, ohne etwas auf Platte zu schreiben, und
# das fällt erst beim nächsten Absturz auf.
trap 'mc "save-on"' EXIT INT TERM

# ---------------------------------------------------------------
# 1. Welt konsistent sichern
# ---------------------------------------------------------------
mc "save-off"
mc "save-all"
sleep 10

tar -czf "$ARCHIV" -C "$WORLD_DIR" world

mc "save-on"

# ---------------------------------------------------------------
# 2. Lokale Aufbewahrung: 7 Tage
# ---------------------------------------------------------------
# Muster bewusst auf "world_2*" verengt, damit manuell erstellte Archive
# wie world_stopped_* nicht mitgelöscht werden.
find "$BACKUP_DIR" -name "world_2*.tar.gz" -mtime +7 -delete

# ---------------------------------------------------------------
# 3. Offsite-Upload nach Azure Blob Storage
# ---------------------------------------------------------------
# Voller Pfad zu az, weil Cron eine minimale PATH-Variable hat.
# Jeder Schritt wird protokolliert: ein stillschweigend gescheiterter
# Backup-Upload ist gefährlicher als gar keiner.

if [ ! -r "$ENV_FILE" ]; then
    echo "$(date) FEHLER Zugangsdatei $ENV_FILE nicht lesbar" >> "$LOG"
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

if "$AZ" login --service-principal \
        -u "$AZ_APP_ID" \
        -p "$AZ_SECRET" \
        --tenant "$AZ_TENANT" \
        --output none 2>>"$LOG"; then

    if "$AZ" storage blob upload \
            --account-name "$AZ_ACCOUNT" \
            --container-name "$AZ_CONTAINER" \
            --name "world_$DATE.tar.gz" \
            --file "$ARCHIV" \
            --auth-mode login \
            --no-progress \
            --output none 2>>"$LOG"; then
        echo "$(date) OK world_$DATE.tar.gz" >> "$LOG"
    else
        echo "$(date) FEHLER Upload world_$DATE.tar.gz" >> "$LOG"
    fi

else
    echo "$(date) FEHLER Anmeldung am Dienstprinzipal" >> "$LOG"
fi
