# Setup: Offsite-Backup nach Azure Blob Storage

Anleitung zum Nachbauen. Ausgangslage ist ein Linux-Server mit einem laufenden
Dienst, dessen Daten bereits lokal als Archiv gesichert werden.

Voraussetzungen: ein Azure-Abonnement und ein Konto, das App-Registrierungen
anlegen und Rollen zuweisen darf.

---

## 1. Speicherkonto anlegen

Azure-Portal, Speicherkonten, Erstellen.

| Feld | Wert |
|---|---|
| Region | eine erlaubte Region, hier Norway East |
| Leistung | Standard |
| Primärer Dienst | Azure Blob Storage |
| Redundanz | LRS (lokal redundant, günstigste Stufe) |
| Öffentlicher Blobzugriff | deaktiviert |

Zur Region: In eingeschränkten Abonnements, etwa `Azure for Students`, greift
eine Deny-Richtlinie. Wird die Erstellung mit `RequestDisallowedByAzure`
abgelehnt, ist die Region das Problem, nicht die Konfiguration. Eine der
erlaubten Regionen wählen und erneut versuchen.

## 2. Container anlegen

Im Speicherkonto: Datenspeicher, Container, plus Container hinzufügen.

- Name: `minecraft-backups`
- Anonymer Zugriff: privat, kein anonymer Zugriff

Der Container `$logs` wird von Azure selbst angelegt und bleibt unangetastet.

## 3. Dienstprinzipal anlegen

Microsoft Entra ID, App-Registrierungen, Neue Registrierung.

- Name: `sp-minecraft-backup`
- Kontotypen: Standardauswahl

Auf der Übersichtsseite notieren:

- **Anwendungs-ID (Client)**
- **Verzeichnis-ID (Mandant)**

Beides sind Kennnummern, keine Geheimnisse.

Dann Zertifikate & Geheimnisse, Neuer geheimer Clientschlüssel, Laufzeit 24 Monate.

> **Der Wert wird genau einmal angezeigt.** Nach dem Verlassen oder Neuladen der
> Seite ist er unwiederbringlich weg. Sofort kopieren und sicher ablegen, erst
> danach weiterklicken. Geht er verloren, wird ein neuer Schlüssel angelegt und
> der alte gelöscht.

## 4. Berechtigung vergeben

Zurück ins Speicherkonto, **in den Container hineingehen**, dort
Zugriffssteuerung (IAM), Hinzufügen, Rollenzuweisung hinzufügen.

- Rolle: **Storage Blob Data Contributor** (deutsch: Mitwirkender an Storage-Blobdaten)
- Zugriff zuweisen zu: Benutzer, Gruppe oder Dienstprinzipal
- Mitglied: `sp-minecraft-backup`

Wichtig ist der Bereich. Die Zuweisung gehört auf den Container, nicht auf das
Speicherkonto. Damit darf der Dienstprinzipal in genau diesen einen Container
schreiben und sonst nirgendwo hin.

Die Zuweisung braucht ein bis zwei Minuten, bis sie greift.

## 5. Azure CLI installieren

Auf dem Server:

```bash
curl -fsSL 'https://azurecliprod.blob.core.windows.net/$root/deb_install.sh' | sudo bash
az version
```

Das Microsoft-Repo liefert seit CLI-Version 2.46 auch arm64-Pakete, die
Installation funktioniert auf ARM-Instanzen ohne Sonderbehandlung.

## 6. Anmeldung testen

```bash
read -rsp "Client Secret: " AZ_SECRET && echo
az login --service-principal \
  -u "<ANWENDUNGS-ID>" \
  -p "$AZ_SECRET" \
  --tenant "<VERZEICHNIS-ID>"
```

Das Secret wird über `read` eingelesen, damit es nicht in `~/.bash_history`
landet. In der History steht anschließend nur `"$AZ_SECRET"`.

Erfolgreich ist die Anmeldung, wenn die Ausgabe `"type": "servicePrincipal"`
enthält.

Testupload:

```bash
echo "test $(date)" > /tmp/test.txt

az storage blob upload \
  --account-name <STORAGE-ACCOUNT> \
  --container-name minecraft-backups \
  --name test.txt \
  --file /tmp/test.txt \
  --auth-mode login
```

`--auth-mode login` weist die CLI an, die Anmeldung des Dienstprinzipals zu
verwenden statt eines Kontoschlüssels. Ohne diesen Schalter sucht sie nach
einem Schlüssel und schlägt fehl.

Kommt `AuthorizationPermissionMismatch`, ist die Rollenzuweisung noch nicht
aktiv. Ein bis zwei Minuten warten und erneut versuchen.

## 7. Zugangsdaten hinterlegen

Cron kann nichts interaktiv eingeben, die Anmeldung muss also aus einer Datei
kommen.

```bash
nano /home/ubuntu/.azure-backup.env    # Inhalt siehe .env.example
chmod 600 /home/ubuntu/.azure-backup.env
```

## 8. Backup-Skript erweitern

Den Upload-Block aus [`../scripts/backup.sh`](../scripts/backup.sh) ans Ende des
bestehenden Backup-Skripts anhängen. Danach einmal von Hand ausführen:

```bash
bash /home/ubuntu/minecraft-server/backup.sh
cat /home/ubuntu/minecraft-backups/azure-upload.log
```

Erwartet wird eine Zeile mit `OK` und dem Archivnamen.

## 9. Lifecycle-Regel

Speicherkonto, Datenverwaltung, Lebenszyklusverwaltung, Regel hinzufügen.

- Name: `delete-old-backups`
- Regelbereich: Blobs mit Filtern begrenzen
- Blobtyp: Blockblobs, Basis-Blobs
- Bedingung: keine Änderung seit 15 Tagen, dann Blob löschen
- Blobpräfix: `minecraft-backups/`

Die Regel läuft einmal täglich und greift beim ersten Mal mit bis zu 48 Stunden
Verzögerung. Ist am Speicherkonto zusätzlich "Vorläufiges Löschen von Blobs"
aktiv, bleiben gelöschte Archive für die eingestellte Frist wiederherstellbar.

## 10. Restore testen

Der Schritt, den man nicht überspringt.

```bash
az storage blob list \
  --account-name <STORAGE-ACCOUNT> \
  --container-name minecraft-backups \
  --auth-mode login --output table

az storage blob download \
  --account-name <STORAGE-ACCOUNT> \
  --container-name minecraft-backups \
  --name world_JJJJ-MM-TT_HH-MM.tar.gz \
  --file /tmp/restore-test.tar.gz \
  --auth-mode login

tar -tzf /tmp/restore-test.tar.gz | head -20
```

`tar -tzf` listet den Inhalt auf, ohne zu entpacken. Erscheinen die erwarteten
Dateien, ist das Archiv vollständig und lesbar. Danach aufräumen:

```bash
rm /tmp/restore-test.tar.gz /tmp/test.txt
```

---

## Wartung

| Was | Wann |
|---|---|
| `azure-upload.log` auf `FEHLER` prüfen | monatlich |
| Restore erneut testen | halbjährlich |
| Clientschlüssel erneuern | vor Ablauf, bei 24 Monaten Laufzeit |
| Größe des Containers und Kosten prüfen | vierteljährlich |

Der Ablauf des Clientschlüssels ist der wahrscheinlichste Grund für einen
späteren Ausfall. Ein Kalendereintrag zwei Monate vor Ablauf spart die
Fehlersuche.
