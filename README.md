# FHEM-Gemini

FHEM-Modul zur Anbindung der Google Gemini AI API. Ermöglicht Textanfragen, Bildanalyse, Smart-Home-Gerätesteuerung per Sprachbefehl (Function Calling) und mehr – direkt aus FHEM heraus.

## Inhaltsverzeichnis

- [Features](#features)
- [Voraussetzungen](#voraussetzungen)
- [Installation](#installation)
- [Einrichtung](#einrichtung)
- [Verwendung](#verwendung)
- [Attribute](#attribute)
- [Readings](#readings)
- [Praxisbeispiele](#praxisbeispiele)
- [Fehlerbehebung](#fehlerbehebung)
- [Versionshistorie](#versionshistorie)
- [Lizenz](#lizenz)

---

## Features

- 💬 **Textfragen** – beliebige Fragen an Gemini stellen und die Antwort in FHEM-Readings speichern
- 🖼️ **Bildanalyse** – Kamerabilder oder Snapshots direkt analysieren lassen (z. B. Türkamera, Überwachungskamera)
- 🏠 **Gerätesteuerung** – Smart-Home-Geräte per natürlicher Sprache steuern (Function Calling, Whitelist-basiert)
- 📋 **Geräte-Status** – Zusammenfassung aller oder ausgewählter Geräte inkl. Raumfilter
- 🔄 **Multi-Turn Chat** – Kontext über mehrere Anfragen hinweg erhalten (optional deaktivierbar)
- 📝 **Mehrere Ausgabeformate** – Antwort als Roh-Markdown, reiner Text und HTML verfügbar
- 🛡️ **Sicherheit** – nur explizit freigegebene Geräte dürfen gesteuert werden; konfigurierbarer Readings-Filter

---

## Voraussetzungen

- **FHEM** ab Version 5.x (Perl-basiert)
- **Google Gemini API Key** – kostenlos erhältlich unter [aistudio.google.com](https://aistudio.google.com/app/apikey)
- Perl-Modul `JSON` (i. d. R. bereits vorhanden; ggf. `cpan JSON`)

---

## Installation

### Erstmalig installieren

In der FHEM-Kommandozeile oder `fhem.cfg`:

```
update all https://raw.githubusercontent.com/ahlers2mi/FHEM-Gemini/main/controls_Gemini.txt
shutdown restart
```

### Für automatische Updates (zusammen mit `update all`)

```
update add https://raw.githubusercontent.com/ahlers2mi/FHEM-Gemini/main/controls_Gemini.txt
```

Danach wird das Modul bei jedem `update all` automatisch auf den neuesten Stand gebracht.

---

## Einrichtung

### 1. Gerät definieren

```
define GeminiAI Gemini
```

### 2. API Key setzen

```
attr GeminiAI apiKey DEIN-GOOGLE-GEMINI-API-KEY
```

### 3. Modell wählen (optional)

```
attr GeminiAI model gemini-3.1-flash-lite-preview
```

`gemini-3.1-flash-lite-preview` ist bereits der Standardwert. Weitere verfügbare Modelle:
`gemini-3.1-flash-image-preview`, `gemini-3.1-pro-preview`, `gemini-3-flash-preview`, `gemini-3-pro-image-preview` u. a.

### 4. System-Prompt setzen (optional)

Mit dem `systemPrompt`-Attribut kann Gemini eine Rolle oder ein Verhalten vorgegeben werden:

```
attr GeminiAI systemPrompt Du bist ein KI-Assistent und Teil meiner FHEM Haussteuerung. Deine Aufgaben sind:

### 1. Geräte steuern und Rückmeldung geben > 
- **WICHTIG:** Verwende für alle Befehle **ausschließlich** den exakten `Internals NAME` aus FHEM. Ignoriere Aliase, Räume oder Beschreibungen bei der Befehlserstellung. > 
- Wenn du den exakten FHEM-Namen eines Geräts nicht eindeutig aus dem Kontext identifizieren kannst, frage **zwingend** nach, bevor du einen Befehl generierst. > 
- Erstelle keine komplexen `notify` oder `at` Befehle, wenn der exakte Trigger oder der Ziel-Gerätename unsicher sind. > 
- Syntax für Aktionen: `set <EXAKTER_NAME> <PARAMETER> <WERT>` (Beispiel: `set Lamp_Esszimmer on`). > - Syntax für Automatisierungen: Wenn du ein `notify` erstellst, nutze exakt `set <TRIGGER_GERÄT> <EVENT> <ZIEL_GERÄT> <BEFEHL>`.

### Gerätespezifische Regeln:
- in der Beschreibung für Gemini könnte ein Hinweis zum schalten stehen
- **Rollladen:** Wenn das Gerät als Rolllade erkannt wird und den set-Parameter "pct" hat:
  - 0 = ganz schließen, 100 = ganz öffnen.
- **Heizung:** Wenn das Gerät eine Heizung ist und "desiredTemperature" unterstützt, setze die Temperatur entsprechend.
- **Andere Befehle:** Bei Befehlen wie `motion_detection`:
  - Syntax: `set <GERÄT> motion_detection true`.

## 2. Beantworte allgemeine und Internet-Fragen
- Beantworte Fragen zu Geräten oder allgemeine Fragen, sofern sie mit aktuellen Internetdaten beantwortet werden können.
- Hole Datum und Uhrzeit immer aus dem Internet.
- Verwende keine Trainingsdaten für aktuelle Informationen.

## 3. Antwortformat
- Antworte immer kurz und prägnant (maximal 2 Sätze).
- Keine ausführlichen Erklärungen, nur das Wesentliche.

## 4. Interaktionslimit
- Nach 20 Interaktionen im aktuellen Chat werden die ersten Interaktionen nicht mehr übertragen

## 5. Sicherheit und Privatsphäre
- Die Adresse des Hauses ist: Im Nott 35, 48301 Nottuln.
- Gib die Adresse nur aus, wenn explizit danach gefragt wird.
- Gehe sorgsam mit sensiblen Daten um.

## 6. Sonstiges
- Wir können Chats fortsetzen, aber beachte das Interaktionslimit.
```

---

## Verwendung

### Textfrage stellen

```
set GeminiAI ask Was ist das Wetter morgen in Berlin?
set GeminiAI ask Erkläre mir den Unterschied zwischen Wärmepumpe und Brennwertkessel.
```

### Bild analysieren

```
set GeminiAI askWithImage /opt/fhem/www/snapshot.jpg Was ist auf diesem Bild zu sehen?
set GeminiAI askWithImage /opt/fhem/www/door.jpg Ist jemand an der Tür?
```

Unterstützte Bildformate: `jpg`/`jpeg`, `png`, `gif`, `webp`, `bmp`, `heic`, `heif`.

### Geräte-Status abfragen

Einzelne Geräte über `deviceList` angeben:

```
attr GeminiAI deviceList Lampe1,Heizung,Rolladen1
set GeminiAI askAboutDevices Welche Geräte sind gerade eingeschaltet?
```

Alle Geräte eines oder mehrerer Räume automatisch einbeziehen:

```
attr GeminiAI deviceRoom Wohnzimmer,Küche
set GeminiAI askAboutDevices Gib mir eine Zusammenfassung aller Geräte.
```

`deviceList` und `deviceRoom` können gleichzeitig gesetzt sein – Duplikate werden automatisch entfernt.

Mit dem Wildcard `*` werden **alle** in FHEM definierten Geräte einbezogen:

```
attr GeminiAI deviceList *
set GeminiAI askAboutDevices Welche Geräte sind gerade aktiv?
```

Wird kein Fragetext angegeben, fragt das Modul automatisch nach einer Zusammenfassung:

```
set GeminiAI askAboutDevices
```

### Geräte per Sprachbefehl steuern (Function Calling)

```
attr GeminiAI controlList Lampe1,Heizung,Rolladen1
set GeminiAI control Mach die Wohnzimmerlampe an
set GeminiAI control Stelle die Heizung auf 21 Grad
set GeminiAI control Fahre alle Rolläden runter
set GeminiAI control Dimme das Licht im Schlafzimmer auf 30 Prozent
```

Gemini löst Alias-Namen automatisch auf interne FHEM-Namen auf und wählt passende `set`-Befehle selbstständig aus. Nur Geräte aus `controlList` (oder `controlRoom`) dürfen gesteuert werden.

Gemini kann im Rahmen eines `control`-Befehls den aktuellen Status eines Geräts selbstständig abfragen (z. B. um zu prüfen, ob eine Lampe bereits an ist), bevor es einen Steuerbefehl absetzt.

Steuerbare Geräte können auch über einen Raum angegeben werden:

```
attr GeminiAI controlRoom Wohnzimmer,Küche
set GeminiAI control Mach alle Lichter im Wohnzimmer aus
```

`controlList` und `controlRoom` können gleichzeitig gesetzt sein – Duplikate werden automatisch entfernt.

### Universeller Chat-Befehl (für Telegram-Integration)

Der `chat`-Befehl ermöglicht allgemeine Fragen, Geräte-Statusabfragen und Steuerungsbefehle in einem einzigen Befehl. Das ist ideal für die Integration mit Telegram oder anderen Messaging-Diensten, bei denen Nachrichten als einfacher Text ankommen:

```
set GeminiAI chat Ist die Wohnzimmerlampe an?
set GeminiAI chat Mach bitte das Licht im Flur aus
set GeminiAI chat Stelle die Heizung auf 20 Grad
set GeminiAI chat Was ist der Unterschied zwischen Wärmepumpe und Brennwertkessel?
set GeminiAI chat Gib mir eine Zusammenfassung aller Geräte
```

Gemini entscheidet selbstständig, ob eine allgemeine Frage beantwortet, ein Gerätestatus abgefragt oder ein Steuerungsbefehl ausgeführt werden soll.

- Wenn `controlList` oder `controlRoom` konfiguriert ist, kann Gemini Geräte steuern und Statusfragen über Function Calling beantworten.
- Der Geräte-Status aus `deviceList`/`deviceRoom` wird automatisch als Kontext mitgegeben, damit Gemini auch Fragen zu Geräten außerhalb der Steuerliste beantworten kann.
- Wenn keine Steuerliste konfiguriert ist, funktioniert `chat` wie `ask` (ggf. mit Geräte-Kontext).

**Telegram-Beispiel:**

```perl
define TelegramBot TELEGRAM <bot-token>

define GeminiTelegramNotify notify TelegramBot:msgText.* {
    my $msg = ReadingsVal("TelegramBot", "msgText", "");
    fhem("set GeminiAI chat $msg") if $msg;
}

define GeminiResponseNotify notify GeminiAI:responsePlain {
    my $text = ReadingsVal("GeminiAI", "responsePlain", "");
    fhem("set TelegramBot message $text") if $text;
}
```

### Chat-Verlauf verwalten

Chat zurücksetzen:

```
set GeminiAI resetChat
```

Chat-Verlauf anzeigen (FHEM-Kommandozeile oder `get`):

```
get GeminiAI chatHistory
```

---

## Attribute

| Attribut | Beschreibung | Standard |
|---|---|---|
| `apiKey` | Google Gemini API Key **(Pflicht)** | – |
| `model` | Gemini-Modell | `gemini-3.1-flash-lite-preview` |
| `maxHistory` | Maximale Anzahl gespeicherter Chat-Nachrichten | `20` |
| `safetySettings` | Konfiguriert die Schwellenwerte für die Inhaltsfilterung der Google-API. Hilfreich, wenn harmlose Anfragen (z.B. Personen auf Kamerabildern) blockiert werden. (BLOCK_NONE, BLOCK_ONLY_HIGH, BLOCK_MEDIUM_AND_ABOVE) | `BLOCK_ONLY_HIGH` |
| `systemPrompt` | Optionaler System-Prompt (Rolle/Verhalten von Gemini) | – |
| `timeout` | HTTP-Timeout in Sekunden | `30` |
| `disable` | Modul deaktivieren (`0`/`1`) | `0` |
| `disableHistory` | Chat-Verlauf deaktivieren (`0`/`1`); jede Anfrage wird ohne vorherigen Verlauf an die API gesendet. Der interne Verlauf bleibt erhalten (für `resetChat`), wird aber nicht übertragen. | `0` |
| `deviceList` | Komma-getrennte Geräteliste für `askAboutDevices`; `*` bezieht alle FHEM-Geräte ein | – |
| `deviceRoom` | Komma-getrennte Raumliste; alle Geräte mit passendem `room`-Attribut werden für `askAboutDevices` verwendet | – |
| `controlList` | Komma-getrennte Liste der Geräte, die Gemini steuern darf **(Pflicht für `control`/`chat` mit Steuerung)** | – |
| `controlRoom` | Komma-getrennte Raumliste; alle Geräte mit passendem `room`-Attribut werden automatisch als steuerbar eingestuft und ergänzen `controlList`. Duplikate werden entfernt. | – |
| `readingBlacklist` | Leerzeichen-getrennte Liste von Reading- bzw. Befehlsnamen, die **nicht** an Gemini übermittelt werden. Wildcards mit `*` werden unterstützt (z. B. `R-*`, `Wifi_*`). Wenn nicht gesetzt, gilt die eingebaute Standardliste. | `attrTemplate associate R-* RegL_* associatedWith peerListRDate protLastRcv lastTimeSync lastcmd Heap LoadAvg Uptime Wifi_*` |

---

## Readings

| Reading | Beschreibung |
|---|---|
| `response` | Letzte Textantwort von Gemini (Roh-Markdown) |
| `responsePlain` | Letzte Textantwort, Markdown bereinigt (reiner Text – ideal für Sprachausgabe, Telegram, Notify) |
| `responseHTML` | Letzte Textantwort, Markdown in HTML konvertiert (ideal für Tablet-UI, Web-Frontends) |
| `state` | Aktueller Status (`initialized`, `requesting...`, `ok`, `error`, `disabled`) |
| `lastError` | Letzter Fehler |
| `chatHistory` | Anzahl der Nachrichten im Chat-Verlauf |
| `lastCommand` | Letzter von Gemini ausgeführter `set`-Befehl (z. B. `Lampe1 on`) |
| `lastCommandResult` | Ergebnis des letzten `set`-Befehls (`ok` oder Fehlermeldung) |

---

## Praxisbeispiele

### Sprachausgabe mit Text2Speech

Das Reading `responsePlain` enthält die Antwort ohne Markdown-Formatierung und eignet sich direkt für die Sprachausgabe:

```perl
define GeminiNotify notify GeminiAI:responsePlain {
    my $text = ReadingsVal("GeminiAI", "responsePlain", "");
    fhem("set Lautsprecher speak $text") if $text;
}
```

### Antwort per Telegram verschicken

Mit dem `chat`-Befehl können eingehende Telegram-Nachrichten direkt an Gemini weitergeleitet werden – Gemini entscheidet selbst, ob eine allgemeine Frage beantwortet, ein Gerätestatus abgefragt oder ein Gerät gesteuert werden soll:

```perl
define GeminiTelegramIn notify TelegramBot:msgText.* {
    my $msg = ReadingsVal("TelegramBot", "msgText", "");
    fhem("set GeminiAI chat $msg") if $msg;
}

define GeminiTelegramOut notify GeminiAI:responsePlain {
    my $text = ReadingsVal("GeminiAI", "responsePlain", "");
    fhem("set TelegramBot message $text") if $text;
}
```

Einfaches Weiterleiten der Gemini-Antwort (ohne eingehende Nachrichten):

```perl
define GeminiTelegram notify GeminiAI:responsePlain {
    my $text = ReadingsVal("GeminiAI", "responsePlain", "");
    fhem("set TelegramBot message $text") if $text;
}
```

### Türkamera-Analyse bei Bewegung

```perl
define KameraAnalyse notify BewegungsMelder:on {
    fhem("set GeminiAI askWithImage /opt/fhem/www/cam.jpg Ist jemand an der Tür?")
}
```

### Tägliche Hausübersicht

```perl
define HausReport at *08:00:00 {
    fhem("set GeminiAI askAboutDevices Gib mir eine kurze Zusammenfassung des Hauses für heute Morgen.")
}
```

### Antwort in HTML-Widget anzeigen (FHEM Tablet UI / ftui)

Das Reading `responseHTML` enthält die Antwort als HTML, direkt verwendbar in Web-Frontends:

```
{ReadingsVal("GeminiAI","responseHTML","")}
```

---

## Fehlerbehebung

| Symptom | Mögliche Ursache | Lösung |
|---|---|---|
| `state: error`, `lastError` enthält HTTP-Fehler 400 | Ungültiger Chat-Verlauf (veraltete Turns) | `set GeminiAI resetChat` ausführen |
| `state: error`, `lastError` enthält HTTP-Fehler 401/403 | API Key ungültig oder fehlt | `apiKey`-Attribut prüfen |
| `state: error`, `lastError` enthält HTTP-Fehler 429 | API-Kontingent überschritten | Anfragen reduzieren oder API-Quota erhöhen |
| `state: disabled` | Modul deaktiviert | `attr GeminiAI disable 0` setzen |
| Keine Gerätesteuerung, Fehler „controlList/controlRoom nicht gesetzt" | `controlList` und `controlRoom` fehlen | `attr GeminiAI controlList Gerät1,Gerät2` oder `attr GeminiAI controlRoom Raum1` setzen |
| Timeout-Fehler bei langen Antworten | Standard-Timeout zu kurz | `attr GeminiAI timeout 60` erhöhen |
| Antwort enthält interne Readings (z. B. `Wifi_RSSI`) | Blacklist zu kurz | `readingBlacklist` um unerwünschte Readings ergänzen |

Detaillierte Fehlermeldungen werden im FHEM-Log auf Level 3 ausgegeben. Zum Aktivieren:

```
attr global verbose 3
```

---

## Versionshistorie

| Version | Datum | Änderung |
|---|---|---|
| 4.0.1 | 2026-04-21 | Neu: Attribut safetySettings zur Steuerung der Inhaltsfilterung (Vermeidung von False-Positives bei der Bildanalyse)
| 4.0.0 | 2026-04-20 | Neu: AT/NOTIFY Support via Function Calling für zeitgesteuerte und eventbasierte Aktionen; Attribut automationRoom
| 3.3.0 | 2026-04-15 | Metadatareadings candidatesTokenCount, promptTokenCount, totalTokenCount
| 3.2.0 | 2026-04-13 | Neuer Befehl `chat`: universeller Befehl für allgemeine Fragen, Geräte-Status und Steuerung in einem (ideal für Telegram); neues Attribut `controlRoom`: steuerbare Geräte per Raum angeben (analog zu `deviceRoom`) |
| 3.1.0 | 2026-04-13 | `comment`-Attribut der Geräte wird jetzt an Gemini übermittelt (in `askAboutDevices` und `control`) |
| 3.0.0 | 2026-04-13 | Neues Attribut `readingBlacklist`: konfigurierbare Filterliste für Readings und set-Befehle mit Wildcard-Unterstützung (`*`); ersetzt die hardcodierte Blacklist; erweiterte Standardliste |
| 2.9.0 | 2026-04-10 | Neu: Readings `responsePlain` (Markdown bereinigt) und `responseHTML` (Markdown zu HTML) |
| 2.8.0 | 2026-04-10 | Fix: History-Trimming entfernt verwaiste `functionResponse`-User-Turns am Anfang des Verlaufs (API-Fehler 400, Issue #8) |
| 2.7.0 | 2026-04-10 | Fix: `set`-Befehle werden mit Typ-Informationen (z. B. `:slider,0,1,100`) an Gemini übermittelt; interne FHEM-Einträge per Blacklist gefiltert |
| 2.6.0 | 2026-04-10 | Fix: `getAllSets()` statt direktem Hash-Zugriff für `set`-Befehle, damit dynamisch berechnete `set`-Listen korrekt übermittelt werden |
| 2.5.0 | 2026-04-10 | Fix: Chat-Verlauf-Trimming stellt sicher, dass der Verlauf immer mit einem `user`-Turn beginnt (API-Fehler 400 vermeiden) |
| 2.4.0 | 2026-04-09 | Neues Attribut `disableHistory`: Chat-Verlauf optional deaktivieren |
| 2.3.0 | 2026-04-09 | `Gemini_BuildControlContext` gibt jetzt auch verfügbare `set`-Befehle aus |
| 2.2.1 | 2026-04-09 | Fix: Regex für verbotene Zeichen korrigiert |
| 2.2.0 | 2026-04-09 | Fix: Alias→Name-Mapping wird als `system_instruction` übergeben |
| 2.1.0 | 2026-04-09 | Neues Attribut `deviceRoom` |
| 2.0.2 | 2026-04-09 | Fix: gesamtes `content`-Objekt der Modellantwort im Chat speichern |
| 2.0.1 | 2026-04-09 | Standard-Modell auf `gemini-3.1-flash-lite-preview` aktualisiert |
| 2.0.0 | 2026-04-09 | Function Calling: neuer Befehl `control`, Attribut `controlList` |
| 1.3.0 | 2026-03-31 | Fix: UTF-8 Encoding für Readings vs. Chat-Verlauf getrennt behandelt |
| 1.2.0 | 2026-03-31 | `deviceContext` nur bei `askAboutDevices` mitschicken |
| 1.1.0 | 2026-03-31 | Fix: doppeltes UTF-8 Encoding in FHEM-Readings |
| 1.0.0 | 2026-03-31 | Initiale Version |

---

## Lizenz

Dieses Modul ist ein Community-Beitrag und steht unter der [GNU General Public License v2](https://www.gnu.org/licenses/gpl-2.0.html), entsprechend der FHEM-Lizenz.
