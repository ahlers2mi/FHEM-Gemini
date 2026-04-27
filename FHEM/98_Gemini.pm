##############################################################################
# 98_Gemini.pm
#
# FHEM Modul für Google Gemini AI
#
# Funktionen:
#   - Text-Anfragen an Gemini senden
#   - Bilder (Base64 oder Dateipfad) senden
#   - Chat-Verlauf (Multi-Turn) beibehalten
#   - Chat zurücksetzen
#   - FHEM-Geräte per Function Calling steuern
#   - AT-Devices (zeitgesteuert) anlegen
#   - NOTIFY-Devices (eventbasiert) anlegen mit Auto-Cleanup
#
# Attribute:
#   apiKey        - Google Gemini API Key (Pflicht)
#   model         - Gemini Modell (Standard: gemini-3.1-flash-lite-preview)
#   maxHistory    - Maximale Anzahl Chat-Nachrichten (Standard: 20)
#   systemPrompt  - Optionaler System-Prompt
#   timeout       - HTTP Timeout in Sekunden (Standard: 30)
#   deviceList    - Komma-getrennte Liste der Geräte für askAboutDevices
#   deviceRoom    - Komma-getrennte Raumliste; Geräte mit passendem room-Attribut
#                   werden automatisch für askAboutDevices verwendet
#   controlList   - Komma-getrennte Liste der Geräte, die Gemini steuern darf
#   controlRoom   - Komma-getrennte Raumliste; Geraete mit passendem room-Attribut
#                   werden automatisch als steuerbar eingestuft (ergaenzt controlList)
#   automationRoom - Raum für automatisch angelegte AT/NOTIFY-Geräte (Standard: erster Raum von Gemini selbst)
#   disableHistory - Chat-Verlauf deaktivieren (0/1); jede Anfrage wird als eigenstaendiges Gespraech behandelt
#   readingBlacklist - Leerzeichen-getrennte Liste von Reading-/Befehlsnamen, die nicht an Gemini
#                      uebermittelt werden; Wildcards (*) werden unterstuetzt.
#                      Standard: attrTemplate associate R-* RegL_* associatedWith peerListRDate
#                                protLastRcv lastTimeSync lastcmd Heap LoadAvg Uptime Wifi_*
#   safetySettings  - BLOCK_NONE,BLOCK_ONLY_HIGH,BLOCK_MEDIUM_AND_ABOVE 
#
# Set-Befehle:
#   ask <Frage>                    - Textfrage stellen
#   askWithImage <Pfad> <Frage>    - Bild + Frage senden
#   askAboutDevices [<Frage>]      - Geräte-Statusabfrage
#   chat <Nachricht>               - Universeller Befehl: allgemeine Fragen, Geraete-Status
#                                    und Steuerung in einem (ideal fuer Telegram-Integration)
#   control <Anweisung>            - Gemini steuert Geräte via Function Calling
#   resetChat                      - Chat-Verlauf löschen
#
# Lesewerte (Readings):
#   response           - Letzte Antwort von Gemini (Roh-Markdown)
#   responsePlain      - Letzte Antwort, Markdown bereinigt (reiner Text)
#   responseHTML       - Letzte Antwort, Markdown in HTML konvertiert
#   state              - Aktueller Status
#   lastError          - Letzter Fehler
#   chatHistory        - Anzahl der Nachrichten im Verlauf
#   lastCommand        - Letzter ausgeführter set-Befehl
#   lastCommandResult  - Ergebnis des letzten set-Befehls
#   lastAutomation     - Letztes angelegtes AT/NOTIFY-Gerät
#
##############################################################################

# Versionshistorie:
# 4.1.0 - 2026-04-27  Neu: Optimierung Prompt Caching - Trennung von statischer
#                          Gerätestruktur (system_instruction, wird gecacht) und
#                          dynamischen Werten (user message, günstiger Input).
#                          Neue Funktionen: Gemini_BuildStaticDeviceContext,
#                          Gemini_BuildDynamicDeviceStatus, Gemini_BuildStaticControlContext
# 4.0.1 - 2026-04-21  Neu: Attribut safetySettings zur Steuerung der Inhaltsfilterung (Vermeidung von False-Positives bei der Bildanalyse)
#                          - safetySettings
# 4.0.1 - 2026-04-20  Neu: AT/NOTIFY Support via Function Calling
#                          - create_at_device für zeitgesteuerte Aktionen
#                          - create_notify_device für eventbasierte Aktionen
#                          - Attribut automationRoom für Raum-Zuordnung, safetySettings
#                          - Auto-Cleanup für einmalige NOTIFY-Devices
#                          - Reading lastAutomation
# 3.4.0 - 2026-04-16  Neu: Eigenes Globalses Attribut geminiComment für Steuerinfos an Gemini
# 3.3.0 - 2026-04-15  Neu: Metadatareadings
#                          Reading candidatesTokenCount, promptTokenCount,
#                          totalTokenCount
# 3.2.0 - 2026-04-13  Neu: Befehl chat fuer universelle Nachrichten (allgemeine Fragen,
#                          Geraete-Status und Steuerung in einem Befehl, ideal fuer
#                          Telegram-Integration); neues Attribut controlRoom analog zu
#                          deviceRoom fuer steuerbare Geraete; Hilfsfunktion
#                          Gemini_GetControlDevices kombiniert controlList + controlRoom
# 3.1.0 - 2026-04-13  Neu: comment-Attribut der Geraete wird nun an Gemini uebermittelt
#                          (in Gemini_BuildDeviceContext und Gemini_BuildControlContext)
# 3.0.0 - 2026-04-13  Neu: Attribut readingBlacklist (leerzeichen-getrennt, Wildcards moeglich)
#                          ersetzt die hardcodierte Blacklist; Standard-Eintraege erweitert um
#                          R-*, RegL_*, associatedWith, peerListRDate, protLastRcv, lastTimeSync,
#                          lastcmd, Heap, LoadAvg, Uptime, Wifi_*; Blacklist wird nun in
#                          Gemini_BuildDeviceContext, get_device_state und
#                          Gemini_BuildControlContext angewendet
#                          responseHTML (Markdown zu HTML) werden in
#                          Gemini_HandleResponse und Gemini_HandleControlResponse
#                          befuellt; neue Hilfsfunktionen Gemini_MarkdownToPlain
#                          und Gemini_MarkdownToHTML
# 2.8.0 - 2026-04-10  Fix: History-Trimming entfernt nun auch verwaiste
#                          functionResponse-User-Turns am Anfang des Verlaufs,
#                          die ohne vorausgehenden functionCall-Turn ungueltig
#                          sind und API-Fehler 400 verursachen (Issue #8)
# 2.7.0 - 2026-04-10  Fix: set-Befehle werden nun mit Typ-Informationen
#                          (z.B. :slider,0,1,100) an Gemini uebermittelt;
#                          interne FHEM-Eintraege (attrTemplate, associate)
#                          werden per Blacklist herausgefiltert
# 2.6.0 - 2026-04-10  Fix: getAllSets() statt direktem Hash-Zugriff fuer set-Befehle,
#                          damit auch dynamisch berechnete set-Listen korrekt
#                          an Gemini uebermittelt werden (statt "unbekannt")
# 2.5.0 - 2026-04-10  Fix: Chat-Verlauf-Trimming stellt sicher, dass der Verlauf
#                          immer mit einem user-Turn beginnt, um API-Fehler 400
#                          ("function call turn must come after user turn") zu vermeiden
#                          (verwaiste functionResponse-Turns werden in 2.8.0 behoben)
# 2.4.0 - 2026-04-09  Neues Attribut disableHistory: Chat-Verlauf deaktivieren,
#                          jede Anfrage wird als eigenstaendiges Gespraech behandelt
# 2.3.0 - 2026-04-09  Gemini_BuildControlContext gibt jetzt auch die
#                          verfuegbaren set-Befehle jedes Geraets aus, damit
#                          Gemini passende Befehle waehlen kann
# 2.2.1 - 2026-04-09  Fix: Regex fuer verbotene Zeichen auf eine Zeile
#                          zusammengefasst (\n statt literal newline im Source)
# 2.2.0 - 2026-04-09  Fix: control-Befehl übergibt Alias→Name-Mapping als
#                          system_instruction, damit Gemini Sprachbefehle
#                          (Alias-Namen) auf interne FHEM-Namen auflösen kann
# 2.1.0 - 2026-04-09  Neues Attribut deviceRoom: Geräte automatisch per Raum
#                          filtern (komma-getrennte Räume möglich); deviceList
#                          und deviceRoom werden kombiniert, Duplikate vermieden
# 2.0.2 - 2026-04-09  Fix: gesamtes content-Objekt der Modell-Antwort im Chat
#                          speichern (push $content statt konstruiertes Hash)
#                          für korrekte Multi-Turn Function Calling Konversation
# 2.0.1 - 2026-04-09  Standard-Modell auf gemini-3.1-flash-lite-preview aktualisiert
#                          (gemini-2.0-flash wird zum 01.06.2026 abgeschaltet)
# 2.0.0 - 2026-04-09  Function Calling: neuer Befehl "control", Attribut
#                          "controlList", Readings lastCommand/lastCommandResult
# 1.3.0 - 2026-03-31  Fix: UTF-8 Encoding für Readings (Bytes ohne Flag) vs.
#                          Chat-Verlauf (Unicode mit Flag) getrennt behandelt
# 1.2.0 - 2026-03-31  deviceContext nur bei askAboutDevices mitschicken
# 1.1.0 - 2026-03-31  Fix: doppeltes UTF-8 Encoding in FHEM-Readings
# 1.0.0 - 2026-03-31  Initiale Version

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use MIME::Base64;


sub Gemini_Initialize {
    my ($hash) = @_; 

    $hash->{DefFn}      = 'Gemini_Define';
    $hash->{UndefFn}    = 'Gemini_Undefine';
    $hash->{SetFn}      = 'Gemini_Set';
    $hash->{GetFn}      = 'Gemini_Get';
    $hash->{AttrFn}     = 'Gemini_Attr';
    $hash->{AttrList}   =
        'apiKey ' .
        'model ' .
        'maxHistory:5,10,20,50,100 ' .
        'timeout ' .
        'disable:0,1 ' .
        'disableHistory:0,1 ' .
        'deviceList:textField-long ' .
        'controlList:textField-long ' .
        'controlRoom:textField-long ' .
        'deviceRoom:textField-long ' .
        'automationRoom ' .
        'safetySettings:BLOCK_NONE,BLOCK_ONLY_HIGH,BLOCK_MEDIUM_AND_ABOVE ' .
        'systemPrompt:textField-long ' .
        'readingBlacklist:textField-long ' .
        $readingFnAttributes;

    return undef;
}

sub Gemini_Define {    
    my $hash = shift;
    my $def  = shift;
    my $h    = shift;
    
    my @args = split('[ \t]+', $def);

    return "Usage: define <name> Gemini" if (@args < 2);

    my $name = $args[0];
    $hash->{NAME}        = $name;
    $hash->{CHAT}        = [];   # Chat-Verlauf als Array-Referenz
    $hash->{VERSION}     = '4.1.0';

    readingsSingleUpdate($hash, 'state',             'initialized', 1);
    readingsSingleUpdate($hash, 'response',          '-',           0);
    readingsSingleUpdate($hash, 'chatHistory',       0,             0);
    readingsSingleUpdate($hash, 'lastError',         '-',           0);
    readingsSingleUpdate($hash, 'lastCommand',       '-',           0);
    readingsSingleUpdate($hash, 'lastCommandResult', '-',           0);
    readingsSingleUpdate($hash, 'lastAutomation',    '-',           0);

    addToAttrList($hash->{NAME} . "Comment:textField-long","Gemini");  
    
    Log3 $name, 3, "Gemini ($name): Defined";
    return undef;
}

sub Gemini_Undefine {
    my ($hash, $name) = @_;
    return undef;
}

sub Gemini_Attr {
    my ($cmd, $name, $attr, $value) = @_; 
    if ($attr eq 'timeout') {
        return "timeout must be a positive number" unless ($value =~ /^\d+$/ && $value > 0);
    }
    return undef;
}

sub Gemini_Set {
    my ($hash, $name, $cmd, @args) = @_; 

    return "\"set $name\" needs at least one argument" unless defined($cmd);

    if ($cmd eq 'ask') {
        return "Usage: set $name ask <Frage>" unless @args;
        my $question = join(' ', @args);
        Gemini_SendRequest($hash, $question, undef, 0);
        return undef;

    } elsif ($cmd eq 'askWithImage') {
        return "Usage: set $name askWithImage <Bildpfad> <Frage>" unless @args >= 2;
        my $imagePath = $args[0];
        my $question  = join(' ', @args[1..$#args]);
        return "Bilddatei nicht gefunden: $imagePath" unless -f $imagePath;
        Gemini_SendRequest($hash, $question, $imagePath, 0);
        return undef;

    } elsif ($cmd eq 'askAboutDevices') {
        my $question = @args ? join(' ', @args) : 'Gib mir eine Zusammenfassung aller Geräte und ihres aktuellen Status.';
        Gemini_SendRequest($hash, $question, undef, 1);
        return undef;

    } elsif ($cmd eq 'chat') {
        return "Usage: set $name chat <Nachricht>" unless @args;
        my $message = join(' ', @args);
        my @controlDevices = Gemini_GetControlDevices($hash);
        if (@controlDevices) {
            Gemini_SendControl($hash, $message, 1);
        } else {
            Gemini_SendRequest($hash, $message, undef, 1);
        }
        return undef;

    } elsif ($cmd eq 'control') {
        return "Usage: set $name control <Anweisung>" unless @args;
        my @controlDevices = Gemini_GetControlDevices($hash);
        return "Fehler: Weder controlList noch controlRoom ist gesetzt" unless @controlDevices;
        my $instruction = join(' ', @args);
        Gemini_SendControl($hash, $instruction, 0);
        return undef;

    } elsif ($cmd eq 'resetChat') {
        $hash->{CHAT} = [];
        readingsSingleUpdate($hash, 'chatHistory', 0, 1);
        readingsSingleUpdate($hash, 'state', 'chat reset', 1);
        Log3 $name, 3, "Gemini ($name): Chat-Verlauf zurückgesetzt";
        return undef;

    } else {
        return "Unknown argument $cmd, choose one of ask:textField askWithImage:textField askAboutDevices:textField chat:textField control:textField resetChat:noArg";
    }
}

sub Gemini_Get {
    my ($hash, $name, $cmd, @args) = @_; 

    if ($cmd eq 'chatHistory') {
        my $history = $hash->{CHAT};
        my $output  = "Chat-Verlauf (" . scalar(@$history) . " Einträge):\n";
        $output    .= "-" x 60 . "\n";
        for my $i (0..$#$history) {
            my $msg  = $history->[$i];
            my $role = $msg->{role} eq 'user' ? 'Du' : 'Gemini';
            my $text = '';
            for my $part (@{$msg->{parts}}) {
                $text .= $part->{text} if exists $part->{text};
                $text .= '[Bild]'      if exists $part->{inline_data};
            }
            $output .= sprintf("[%02d] %s: %s\n", $i+1, $role, $text);
        }
        return $output;
    }

    return "Unknown argument $cmd, choose one of chatHistory:noArg";
}

##############################################################################
# Hauptfunktion: Anfrage an Gemini API senden
##############################################################################
sub Gemini_SendRequest {
    my ($hash, $question, $imagePath, $includeDeviceStatus) = @_; 
    my $name = $hash->{NAME};

    if (AttrVal($name, 'disable', 0)) {
        readingsSingleUpdate($hash, 'state', 'disabled', 1);
        return;
    }

    my $apiKey = AttrVal($name, 'apiKey', '');
    if (!$apiKey) {
        readingsSingleUpdate($hash, 'lastError', 'Kein API Key gesetzt (attr apiKey)', 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Gemini ($name): Kein API Key konfiguriert!";
        return;
    }

    my $model       = AttrVal($name, 'model',      'gemini-3.1-flash-lite-preview');
    my $safetyLevel = AttrVal($name, 'safetySettings', 'BLOCK_ONLY_HIGH');
    my $timeout     = AttrVal($name, 'timeout',    30);
    my $maxHistory  = AttrVal($name, 'maxHistory', 20);

    # DYNAMISCHER Teil: aktueller Gerätestatus (in user message, nicht gecacht)
    my $dynamicStatus = '';
    if ($includeDeviceStatus) {
        $dynamicStatus = Gemini_BuildDynamicDeviceStatus($hash);
    }

    # User-Turn zusammenbauen
    my @parts;

    # Erst dynamischer Status (falls gewünscht)
    if ($dynamicStatus) {
        push @parts, { text => $dynamicStatus };
    }

    # Dann Bild (falls vorhanden)
    if ($imagePath) {
        my $mimeType = Gemini_GetMimeType($imagePath);
        open(my $fh, '<', $imagePath) or do {
            readingsSingleUpdate($hash, 'lastError', "Kann Bild nicht lesen: $imagePath", 1);
            readingsSingleUpdate($hash, 'state', 'error', 1);
            return;
        };
        binmode($fh);
        local $/;
        my $imageData   = <$fh>;
        close($fh);
        my $base64Image = encode_base64($imageData, '');

        push @parts, {
            inline_data => {
                mime_type => $mimeType,
                data      => $base64Image
            }
        };
        Log3 $name, 4, "Gemini ($name): Bild geladen: $imagePath ($mimeType)";
    }

    # Dann die eigentliche Frage
    push @parts, { text => $question };

    push @{$hash->{CHAT}}, {
        role  => 'user',
        parts => \@parts
    };

    while (scalar(@{$hash->{CHAT}}) > $maxHistory) {
        shift @{$hash->{CHAT}};
    }
    
    # Ensure history starts with a valid user text turn (API requirement):
    # remove leading model turns and orphaned user functionResponse turns
    # (a functionResponse without a preceding functionCall is invalid)
    while (@{$hash->{CHAT}}) {
        my $first = $hash->{CHAT}[0];
        if ($first->{role} ne 'user') {
            shift @{$hash->{CHAT}};
        } elsif (exists $first->{parts}[0]{functionResponse}) {
            shift @{$hash->{CHAT}};
            # Also remove any following model turns that are now stranded without the functionResponse
            shift @{$hash->{CHAT}} while @{$hash->{CHAT}} && $hash->{CHAT}[0]{role} ne 'user';
        } else {
            last;
        }
    }

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $contentsToSend = $disableHistory ? [ $hash->{CHAT}[-1] ] : $hash->{CHAT};

    my %requestBody = (
        contents => $contentsToSend,
        safetySettings => [
            { category => "HARM_CATEGORY_HARASSMENT", threshold => $safetyLevel },
            { category => "HARM_CATEGORY_HATE_SPEECH", threshold => $safetyLevel },
            { category => "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold => $safetyLevel },
            { category => "HARM_CATEGORY_DANGEROUS_CONTENT", threshold => $safetyLevel },
        ]
    );

    # STATISCHER Teil für system_instruction (wird gecacht!)
    my $systemPrompt        = AttrVal($name, 'systemPrompt', '');
    my $staticDeviceContext = '';
    
    if ($includeDeviceStatus) {
        $staticDeviceContext = Gemini_BuildStaticDeviceContext($hash);
    }

    my $fullSystem = '';
    $fullSystem .= $systemPrompt if $systemPrompt;
    $fullSystem .= "\n\n" if $systemPrompt && $staticDeviceContext;
    $fullSystem .= $staticDeviceContext if $staticDeviceContext;

    if ($fullSystem) {
        $requestBody{system_instruction} = {
            parts => [{ text => $fullSystem }]
        };
    }

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Encode Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        return;
    }

    Log3 $name, 4, "Gemini ($name): Anfrage " . $jsonBody;

    my $url = "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}";

    readingsSingleUpdate($hash, 'state', 'requesting...', 1);

    HttpUtils_NonblockingGet({
        url      => $url,
        timeout  => $timeout,
        method   => 'POST',
        header   => "Content-Type: application/json\r\nAccept: application/json",
        data     => $jsonBody,
        hash     => $hash,
        callback => \&Gemini_HandleResponse,
    });

    return undef;
}

##############################################################################
# Callback: Antwort von Gemini verarbeiten
##############################################################################
sub Gemini_HandleResponse {
    my ($param, $err, $data) = @_; 
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err) {
        readingsSingleUpdate($hash, 'lastError', "HTTP Fehler: $err", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Gemini ($name): HTTP Fehler: $err";
        pop @{$hash->{CHAT}};
        return;
    }

    utf8::downgrade($data, 1);

    Log3 $name, 5, "Gemini ($name): Antwort raw: $data";

    my $result = eval { decode_json($data) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Parse Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Gemini ($name): JSON Parse Fehler: $@";
        pop @{$hash->{CHAT}};
        return;
    }

    if (exists $result->{error}) {
        my $errMsg  = $result->{error}{message} // 'Unbekannter API Fehler';
        my $errCode = $result->{error}{code}    // 'N/A';
        readingsSingleUpdate($hash, 'lastError', "API Fehler $errCode: $errMsg", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Gemini ($name): API Fehler $errCode: $errMsg";
        pop @{$hash->{CHAT}};
        return;
    }
    if (exists $result->{usageMetadata}) {
        my $promptTokenCount = $result->{usageMetadata}{promptTokenCount};
        my $candidatesTokenCount = $result->{usageMetadata}{candidatesTokenCount};
        my $totalTokenCount= $result->{usageMetadata}{totalTokenCount};
        readingsSingleUpdate($hash, 'promptTokenCount', $promptTokenCount, 1);
        readingsSingleUpdate($hash, 'candidatesTokenCount', $candidatesTokenCount, 1);
        readingsSingleUpdate($hash, 'totalTokenCount', $totalTokenCount, 1);
    }

    my $responseUnicode = '';
    eval {
        $responseUnicode = $result->{candidates}[0]{content}{parts}[0]{text};
    };

    if (!$responseUnicode) {
        my $finishReason = eval { $result->{candidates}[0]{finishReason} } // 'UNKNOWN';
        readingsSingleUpdate($hash, 'lastError', "Leere Antwort, finishReason: $finishReason", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 2, "Gemini ($name): Leere Antwort erhalten, finishReason: $finishReason";
        pop @{$hash->{CHAT}};
        return;
    }

    push @{$hash->{CHAT}}, {
        role  => 'model',
        parts => [{ text => $responseUnicode }]
    };

    my $responseForReading = $responseUnicode;
    utf8::encode($responseForReading) if utf8::is_utf8($responseForReading);

    my $responsePlain = Gemini_MarkdownToPlain($responseUnicode);
    utf8::encode($responsePlain) if utf8::is_utf8($responsePlain);

    my $responseHTML = Gemini_MarkdownToHTML($responseUnicode);
    utf8::encode($responseHTML) if utf8::is_utf8($responseHTML);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'response',      $responseForReading);
    readingsBulkUpdate($hash, 'responsePlain', $responsePlain);
    readingsBulkUpdate($hash, 'responseHTML',  $responseHTML);
    readingsBulkUpdate($hash, 'chatHistory', scalar(@{$hash->{CHAT}}));
    readingsBulkUpdate($hash, 'state',       'ok');
    readingsBulkUpdate($hash, 'lastError',   '-');
    readingsEndUpdate($hash, 1);

    Log3 $name, 4, "Gemini ($name): Antwort erhalten (" . length($responseUnicode) . " Zeichen)";
    return undef;
}

##############################################################################
# Hilfsfunktion: Markdown in reinen Text konvertieren
##############################################################################
sub Gemini_MarkdownToPlain {
    my ($text) = @_;
    return '' unless defined $text;

    # Code-Blöcke (```...```) → nur Inhalt behalten
    $text =~ s/```[^\n]*\n(.*?)```/$1/gms;

    # Fett (**text** oder __text__) → text
    $text =~ s/\*\*(.+?)\*\*/$1/gs;
    $text =~ s/__(.+?)__/$1/gs;

    # Kursiv (*text* oder _text_) → text
    $text =~ s/\*(.+?)\*/$1/gs;
    $text =~ s/_(.+?)_/$1/gs;

    # Inline-Code (`code`) → code
    $text =~ s/`(.+?)`/$1/gs;

    # Überschriften (# Titel) → Titel
    $text =~ s/^#{1,6}\s+(.+)$/$1/gm;

    # Listenpunkte (- oder * am Zeilenanfang) → Text
    $text =~ s/^[\-\*]\s+(.+)$/$1/gm;

    # HTML-Links (<a ...>text</a>) → text
    $text =~ s/<a[^>]*>(.+?)<\/a>/$1/gsi;

    # Trennlinien (--- oder ***) → leere Zeile
    $text =~ s/^(?:---|\*\*\*)\s*$//gm;

    return $text;
}

##############################################################################
# Hilfsfunktion: Markdown in HTML konvertieren
##############################################################################
sub Gemini_MarkdownToHTML {
    my ($text) = @_;
    return '' unless defined $text;

    # Code-Blöcke (```...```) → <pre><code>...</code></pre>
    $text =~ s/```[^\n]*\n(.*?)```/<pre><code>$1<\/code><\/pre>/gms;

    # Fett (**text** oder __text__) → <b>text</b>
    $text =~ s/\*\*(.+?)\*\*/<b>$1<\/b>/gs;
    $text =~ s/__(.+?)__/<b>$1<\/b>/gs;

    # Kursiv (*text* oder _text_) → <i>text</i>
    $text =~ s/\*(.+?)\*/<i>$1<\/i>/gs;
    $text =~ s/_(.+?)_/<i>$1<\/i>/gs;

    # Inline-Code (`code`) → <code>code</code>
    $text =~ s/`(.+?)`/<code>$1<\/code>/gs;

    # Überschriften (# bis ######, gekappt bei <h6>)
    $text =~ s/^#{6}\s+(.+)$/<h6>$1<\/h6>/gm;
    $text =~ s/^#{5}\s+(.+)$/<h6>$1<\/h6>/gm;
    $text =~ s/^#{4}\s+(.+)$/<h6>$1<\/h6>/gm;
    $text =~ s/^#{3}\s+(.+)$/<h5>$1<\/h5>/gm;
    $text =~ s/^#{2}\s+(.+)$/<h4>$1<\/h4>/gm;
    $text =~ s/^#\s+(.+)$/<h3>$1<\/h3>/gm;

    # Zusammenhängende Listenblöcke (- oder * am Zeilenanfang) → <ul><li>...</li></ul>
    $text =~ s/((?:^[\-\*]\s+.+\n?)+)/my $block = $1; $block =~ s{^[\-\*]\s+(.+)$}{<li>$1<\/li>}gm; "<ul>$block<\/ul>"/gme;

    # Trennlinien (--- oder ***) → <hr>
    $text =~ s/^(?:---|\*\*\*)\s*$/<hr>/gm;

    # Zeilenumbrüche → <br> (außerhalb von Block-Elementen)
    $text =~ s/\n(?!<(?:ul|\/ul|li|\/li|h[3-6]|\/h[3-6]|pre|\/pre|hr))/<br>\n/g;

    return $text;
}

##############################################################################
# Hilfsfunktion: MIME-Typ anhand Dateiendung bestimmen
##############################################################################
sub Gemini_GetMimeType {
    my ($filePath) = @_; 

    my $ext = '';
    if ($filePath =~ /\.([^.]+)$/) {
        $ext = lc($1);
    }

    my %mimeTypes = (
        'jpg'  => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'png'  => 'image/png',
        'gif'  => 'image/gif',
        'webp' => 'image/webp',
        'bmp'  => 'image/bmp',
        'heic' => 'image/heic',
        'heif' => 'image/heif',
    );

    return $mimeTypes{$ext} // 'image/jpeg';
}

##############################################################################
# Hilfsfunktion: Blacklist-Muster fuer Readings/Befehle liefern
##############################################################################
sub Gemini_GetBlacklist {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $attr = AttrVal($name, 'readingBlacklist', '');
    if ($attr ne '') {
        return split(/\s+/, $attr);
    }
    return qw(
        attrTemplate associate R-* RegL_* associatedWith
        peerListRDate protLastRcv lastTimeSync lastcmd
        Heap LoadAvg Uptime Wifi_*
    );
}

##############################################################################
# Hilfsfunktion: Pruefen ob ein Name auf ein Blacklist-Muster passt
##############################################################################
sub Gemini_IsBlacklisted {
    my ($entry, @patterns) = @_;
    for my $pat (@patterns) {
        return 1 if Gemini_GlobMatch($pat, $entry);
    }
    return 0;
}

# Einfacher Glob-Vergleich ohne Regex (kein Backtracking-Risiko)
# Unterstuetzt nur * als Platzhalter fuer beliebig viele Zeichen
sub Gemini_GlobMatch {
    my ($pat, $str) = @_;
    return ($str eq $pat) unless index($pat, '*') >= 0;
    return 1 if $pat eq '*';

    my @parts  = split(/\*/, $pat, -1);
    my $prefix = shift @parts;
    my $suffix = pop   @parts;

    return 0 if length($prefix) && substr($str, 0, length($prefix)) ne $prefix;
    return 0 if length($suffix) && substr($str, -length($suffix))   ne $suffix;

    my $pos = length($prefix);
    for my $mid (@parts) {
        next unless length($mid);
        my $found = index($str, $mid, $pos);
        return 0 if $found < 0;
        $pos = $found + length($mid);
    }
    return 1;
}

##############################################################################
# Hilfsfunktion: Raum für Automation-Geräte ermitteln
##############################################################################
sub Gemini_GetAutomationRoom {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    # 1. Prüfe explizites Attribut automationRoom
    my $automationRoom = AttrVal($name, 'automationRoom', '');
    return $automationRoom if $automationRoom;
    
    # 2. Fallback: ersten Raum von Gemini selbst nutzen
    my $myRooms = AttrVal($name, 'room', '');
    if ($myRooms) {
        my @rooms = split(/\s*,\s*/, $myRooms);
        return $rooms[0] if @rooms;
    }
    
    # 3. Kein Raum gefunden
    return '';
}

##############################################################################
# Hilfsfunktion: Liste der Geräte aus deviceList/deviceRoom ermitteln
##############################################################################
sub Gemini_GetDeviceList {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my %seen;
    my @devices;

    # Geräte aus deviceRoom sammeln
    my $deviceRoom = AttrVal($name, 'deviceRoom', '');
    if ($deviceRoom) {
        my @rooms = split(/\s*,\s*/, $deviceRoom);
        for my $devName (sort keys %main::defs) {
            my $devRoomAttr = AttrVal($devName, 'room', '');
            for my $room (@rooms) {
                if (grep { $_ eq $room } split(/\s*,\s*/, $devRoomAttr)) {
                    unless ($seen{$devName}) {
                        push @devices, $devName;
                        $seen{$devName} = 1;
                    }
                    last;
                }
            }
        }
    }

    # Geräte aus deviceList hinzufügen (Duplikate vermeiden)
    my $devList = AttrVal($name, 'deviceList', '');
    $devList = join(',', sort keys %main::defs) if $devList eq '*';
    if ($devList) {
        for my $devName (split(/\s*,\s*/, $devList)) {
            unless ($seen{$devName}) {
                push @devices, $devName;
                $seen{$devName} = 1;
            }
        }
    }

    return @devices;
}

##############################################################################
# OPTIMIERT: Statischen Gerätekontext für Prompt Caching aufbauen
# (Gerätestruktur ohne aktuelle Werte - wird gecacht in system_instruction)
##############################################################################
sub Gemini_BuildStaticDeviceContext {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my @devices = Gemini_GetDeviceList($hash);
    return '' unless @devices;

    my $context   = "Verfügbare Smart-Home Geräte (Struktur):\n\n";
    my @blacklist = Gemini_GetBlacklist($hash);

    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $dev   = $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);

        $context .= "Gerät: $alias (intern: $devName)\n";
        $context .= "  Typ: " . ($dev->{TYPE} // 'unbekannt') . "\n";

        # Nur verfügbare Readings OHNE aktuelle Werte auflisten
        if (exists $dev->{READINGS}) {
            my @readings = grep { 
                $_ ne 'state' && !Gemini_IsBlacklisted($_, @blacklist) 
            } sort keys %{$dev->{READINGS}};
            
            if (@readings) {
                $context .= "  Verfügbare Readings: " . join(', ', @readings) . "\n";
            }
        }

        # Statische Attribute
        for my $attrName ('room', 'group', 'alias', 'comment', $hash->{NAME} . "Comment") {
            my $attrVal = AttrVal($devName, $attrName, '');
            $context .= "  $attrName: $attrVal\n" if $attrVal;
        }

        $context .= "\n";
    }

    return $context;
}

##############################################################################
# OPTIMIERT: Dynamischen Gerätestatus für User-Message aufbauen
# (Aktuelle Werte - günstiger Input, nicht gecacht)
##############################################################################
sub Gemini_BuildDynamicDeviceStatus {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my @devices = Gemini_GetDeviceList($hash);
    return '' unless @devices;

    my $status    = "Aktueller Gerätestatus:\n\n";
    my @blacklist = Gemini_GetBlacklist($hash);

    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $dev   = $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);
        my $state = ReadingsVal($devName, 'state', 'unbekannt');
        
        $status .= "$alias: $state";

        # Nur wichtigste Readings mit aktuellen Werten (kompakt)
        if (exists $dev->{READINGS}) {
            my @values;
            for my $reading (sort keys %{$dev->{READINGS}}) {
                next if $reading eq 'state';
                next if Gemini_IsBlacklisted($reading, @blacklist);
                my $val = $dev->{READINGS}{$reading}{VAL} // '';
                push @values, "$reading=$val";
            }
            $status .= " (" . join(', ', @values) . ")" if @values;
        }
        $status .= "\n";
    }

    return $status;
}

##############################################################################
# Hilfsfunktion: Liste aller steuerbaren Geräte ermitteln (controlList + controlRoom)
##############################################################################
sub Gemini_GetControlDevices {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my %seen;
    my @devices;

    # Geräte aus controlRoom sammeln
    my $controlRoom = AttrVal($name, 'controlRoom', '');
    if ($controlRoom) {
        my @rooms = split(/\s*,\s*/, $controlRoom);
        for my $devName (sort keys %main::defs) {
            my $devRoomAttr = AttrVal($devName, 'room', '');
            for my $room (@rooms) {
                if (grep { $_ eq $room } split(/\s*,\s*/, $devRoomAttr)) {
                    unless ($seen{$devName}) {
                        push @devices, $devName;
                        $seen{$devName} = 1;
                    }
                    last;
                }
            }
        }
    }

    # Geräte aus controlList hinzufügen (Duplikate vermeiden)
    my $controlList = AttrVal($name, 'controlList', '');
    if ($controlList) {
        for my $devName (split(/\s*,\s*/, $controlList)) {
            unless ($seen{$devName}) {
                push @devices, $devName;
                $seen{$devName} = 1;
            }
        }
    }

    return @devices;
}

##############################################################################
# OPTIMIERT: Statischen Control-Kontext für Prompt Caching aufbauen
# (Gerätestruktur mit set-Befehlen, ohne aktuelle Werte - wird gecacht)
##############################################################################
sub Gemini_BuildStaticControlContext {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my @devices = Gemini_GetControlDevices($hash);
    return '' unless @devices;

    my @blacklist = Gemini_GetBlacklist($hash);

    my $context = "Verfügbare Geräte zum Steuern:\n\n";
    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);

        # Set-Befehle ermitteln (getAllSets liefert auch dynamisch berechnete Befehle)
        my $setListRaw = main::getAllSets($devName) // '';

        # Typ-Informationen (z.B. :slider,0,1,100) behalten, nur Blacklist-Eintraege filtern
        my @cmds;
        for my $entry (split(/\s+/, $setListRaw)) {
            my ($cmdName) = split(/:/, $entry, 2);
            next unless $cmdName;
            next if Gemini_IsBlacklisted($cmdName, @blacklist);
            push @cmds, $entry;
        }

        my $cmdsStr       = @cmds ? join(', ', @cmds) : 'unbekannt';
        my $comment       = AttrVal($devName, 'comment', '');
        my $geminiComment = AttrVal($devName, $name . 'Comment', '');
        
        $context .= "Gerät: $alias (intern: $devName)\n";
        $context .= "  Allgemeine Beschreibung: $comment\n" if $comment;
        $context .= "  Beschreibung für Gemini: $geminiComment\n" if $geminiComment;
        $context .= "  Set-Befehle: $cmdsStr\n\n";
    }

    return $context;
}

##############################################################################
# Hilfsfunktion: Tool-Definitionen für Function Calling zurückgeben
##############################################################################
sub Gemini_GetControlTools {
    return [{
        function_declarations => [
            {
                name        => 'set_device',
                description => 'Führt einen FHEM set-Befehl auf einem Gerät aus, z.B. on, off oder einen numerischen Wert. Kann parallel mehrfach aufgerufen werden, um mehrere Geräte gleichzeitig zu schalten.',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device  => { type => 'string', description => 'FHEM Gerätename (intern)' },
                        command => { type => 'string', description => 'Der set-Befehl, z.B. on, off, 21' }
                    },
                    required => ['device', 'command']
                }
            },
            {
                name        => 'get_device_state',
                description => 'Liest den aktuellen Status und alle Readings eines FHEM-Geräts',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device => { type => 'string', description => 'FHEM Gerätename (intern)' }
                    },
                    required => ['device']
                }
            },
            {
                name        => 'create_at_device',
                description => 'Legt ein zeitgesteuertes AT-Device in FHEM an. Für einmalige Aktionen (wird automatisch gelöscht) oder wiederkehrende Zeitpläne (bleibt bestehen). Zeitformat: HH:MM:SS oder +HH:MM:SS (relativ). Für wiederkehrende Aktionen: *HH:MM:SS',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device_name => { 
                            type => 'string', 
                            description => 'Name des neuen AT-Geräts, z.B. LichtAus_2145, LichtAn_5Min' 
                        },
                        time_spec   => { 
                            type => 'string', 
                            description => 'Zeitspezifikation: HH:MM:SS (absolut), +HH:MM:SS (relativ), *HH:MM:SS (täglich wiederkehrend), *{Wochentag}HH:MM:SS (wöchentlich)' 
                        },
                        command     => { 
                            type => 'string', 
                            description => 'Der set-Befehl, keine Verkettung von Befehlen, du kannst mehrere create_at_device aufrufen, Wichtig: Verwende ausschließlich den exakten FHEM-Gerätenamen (den Namen, der in der FHEM-Geräteliste steht), niemals den Alias oder einen geschätzten Namen. Syntax: set <GERÄTENAME> <PARAMETER> <WERT> bzw. set <GERÄTENAME> <WERT>'
                        },
                        recurring   => { 
                            type => 'boolean', 
                            description => 'true für wiederkehrende Aktionen (bleibt bestehen), false für einmalige Aktionen (wird nach Ausführung gelöscht). Standard: false' 
                        }
                    },
                    required => ['device_name', 'time_spec', 'command']
                }
            },
            {
                name        => 'create_notify_device',
                description => 'Legt ein eventbasiertes NOTIFY-Device in FHEM an, das auf Ereignisse anderer Geräte reagiert. Für einmalige Reaktionen (löscht sich automatisch) oder permanente Event-Handler (bleibt bestehen).',
                parameters  => {
                    type       => 'object',
                    properties => {
                        device_name => { 
                            type => 'string', 
                            description => 'Name des neuen NOTIFY-Geräts, z.B. TuerOffen, BewegungEsszimmerLicht' 
                        },
                        event_spec  => { 
                            type => 'string', 
                            description => 'Event-Spezifikation: "Gerätename:Event-Pattern", z.B. "Tuer:open" oder "Bewegung:.*" oder "Temp:temperature.*20"' 
                        },
                        command     => { 
                            type => 'string', 
                            description => 'Der set-Befehl, keine Verkettung von Befehlen, du kannst mehrere create_notify_device aufrufen, Wichtig: Verwende ausschließlich den exakten FHEM-Gerätenamen (den Namen, der in der FHEM-Geräteliste steht), niemals den Alias oder einen geschätzten Namen. Syntax: set <GERÄTENAME> <PARAMETER> <WERT> bzw. set <GERÄTENAME> <WERT>'  
                        },
                        one_shot    => { 
                            type => 'boolean', 
                            description => 'true für einmalige Reaktion (löscht sich nach Ausführung selbst), false für permanente Event-Überwachung. Standard: true' 
                        }
                    },
                    required => ['device_name', 'event_spec', 'command']
                }
            }
        ]
    }];
}

##############################################################################
# Hilfsfunktion: Control-Session-Chat zurücksetzen (Fehlerbehandlung)
##############################################################################
sub Gemini_RollbackControlSession {
    my ($hash) = @_;
    my $startIdx = $hash->{CONTROL_START_IDX} // 0;
    splice(@{$hash->{CHAT}}, $startIdx);
    delete $hash->{CONTROL_START_IDX};
    delete $hash->{CHAT_INCLUDE_DEVICE_STATUS};
}

##############################################################################
# OPTIMIERT: Control-Funktion mit Prompt Caching
##############################################################################
sub Gemini_SendControl {
    my ($hash, $instruction, $includeDeviceStatus) = @_;
    my $name = $hash->{NAME};

    if (AttrVal($name, 'disable', 0)) {
        readingsSingleUpdate($hash, 'state', 'disabled', 1);
        return;
    }

    my $apiKey = AttrVal($name, 'apiKey', '');
    if (!$apiKey) {
        readingsSingleUpdate($hash, 'lastError', 'Kein API Key gesetzt (attr apiKey)', 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Gemini ($name): Kein API Key konfiguriert!";
        return;
    }

    my $model      = AttrVal($name, 'model',      'gemini-3.1-flash-lite-preview');
    my $timeout    = AttrVal($name, 'timeout',    30);
    my $maxHistory = AttrVal($name, 'maxHistory', 20);

    $hash->{CONTROL_START_IDX}           = scalar(@{$hash->{CHAT}});
    $hash->{CHAT_INCLUDE_DEVICE_STATUS}  = $includeDeviceStatus;

    # DYNAMISCHER Teil: aktueller Gerätestatus (falls gewünscht)
    my @parts;
    
    if ($includeDeviceStatus) {
        my $dynamicStatus = Gemini_BuildDynamicDeviceStatus($hash);
        push @parts, { text => $dynamicStatus } if $dynamicStatus;
    }

    # Die eigentliche Anweisung
    push @parts, { text => $instruction };

    push @{$hash->{CHAT}}, {
        role  => 'user',
        parts => \@parts
    };

    while (scalar(@{$hash->{CHAT}}) > $maxHistory) {
        shift @{$hash->{CHAT}};
        $hash->{CONTROL_START_IDX}-- if $hash->{CONTROL_START_IDX} > 0;
    }
    
    # Ensure history starts with a valid user text turn (API requirement):
    # remove leading model turns and orphaned user functionResponse turns
    # (a functionResponse without a preceding functionCall is invalid)
    while (@{$hash->{CHAT}}) {
        my $first = $hash->{CHAT}[0];
        if ($first->{role} ne 'user') {
            shift @{$hash->{CHAT}};
            $hash->{CONTROL_START_IDX}-- if $hash->{CONTROL_START_IDX} > 0;
        } elsif (exists $first->{parts}[0]{functionResponse}) {
            shift @{$hash->{CHAT}};
            $hash->{CONTROL_START_IDX}-- if $hash->{CONTROL_START_IDX} > 0;
            # Also remove any following model turns that are now stranded without the functionResponse
            while (@{$hash->{CHAT}} && $hash->{CHAT}[0]{role} ne 'user') {
                shift @{$hash->{CHAT}};
                $hash->{CONTROL_START_IDX}-- if $hash->{CONTROL_START_IDX} > 0;
            }
        } else {
            last;
        }
    }

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $contentsToSend = $disableHistory ? [ $hash->{CHAT}[-1] ] : $hash->{CHAT};

    my %requestBody = (
        contents => $contentsToSend,
        tools    => Gemini_GetControlTools()
    );

    # STATISCHER Teil für system_instruction (wird gecacht!)
    my $systemPrompt         = AttrVal($name, 'systemPrompt', '');
    my $staticControlContext = Gemini_BuildStaticControlContext($hash);
    my $staticDeviceContext  = '';
    
    if ($includeDeviceStatus) {
        $staticDeviceContext = Gemini_BuildStaticDeviceContext($hash);
    }

    my $fullSystem = '';
    $fullSystem .= $systemPrompt if $systemPrompt;
    $fullSystem .= "\n\n" if $systemPrompt && $staticDeviceContext;
    $fullSystem .= $staticDeviceContext if $staticDeviceContext;
    $fullSystem .= "\n\n" if $fullSystem && $staticControlContext;
    $fullSystem .= $staticControlContext if $staticControlContext;

    if ($fullSystem) {
        $requestBody{system_instruction} = {
            parts => [{ text => $fullSystem }]
        };
    }

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Encode Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        pop @{$hash->{CHAT}};
        return;
    }

    Log3 $name, 4, "Gemini ($name): Control-Anfrage " . $jsonBody;

    my $url = "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}";

    readingsSingleUpdate($hash, 'state', 'requesting...', 1);

    HttpUtils_NonblockingGet({
        url      => $url,
        timeout  => $timeout,
        method   => 'POST',
        header   => "Content-Type: application/json\r\nAccept: application/json",
        data     => $jsonBody,
        hash     => $hash,
        callback => \&Gemini_HandleControlResponse,
    });

    return undef;
}

##############################################################################
# Callback: Antwort auf Control-Anfrage / Function-Result verarbeiten
##############################################################################
sub Gemini_HandleControlResponse {
    my ($param, $err, $data) = @_; 
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err) {
        readingsSingleUpdate($hash, 'lastError', "HTTP Fehler: $err", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Gemini ($name): HTTP Fehler: $err";
        Gemini_RollbackControlSession($hash);
        return;
    }

    utf8::downgrade($data, 1);

    Log3 $name, 5, "Gemini ($name): Control-Antwort raw: $data";

    my $result = eval { decode_json($data) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Parse Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Gemini ($name): JSON Parse Fehler: $@";
        Gemini_RollbackControlSession($hash);
        return;
    }

    if (exists $result->{error}) {
        my $errMsg  = $result->{error}{message} // 'Unbekannter API Fehler';
        my $errCode = $result->{error}{code}    // 'N/A';
        readingsSingleUpdate($hash, 'lastError', "API Fehler $errCode: $errMsg", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Gemini ($name): API Fehler $errCode: $errMsg";
        Gemini_RollbackControlSession($hash);
        return;
    }

    if (exists $result->{usageMetadata}) {
        my $promptTokenCount = $result->{usageMetadata}{promptTokenCount};
        my $candidatesTokenCount = $result->{usageMetadata}{candidatesTokenCount};
        my $totalTokenCount= $result->{usageMetadata}{totalTokenCount};
        readingsSingleUpdate($hash, 'promptTokenCount', $promptTokenCount, 1);
        readingsSingleUpdate($hash, 'candidatesTokenCount', $candidatesTokenCount, 1);
        readingsSingleUpdate($hash, 'totalTokenCount', $totalTokenCount, 1);
    }

    my $candidate = $result->{candidates}[0];
    my $content   = $candidate->{content};
    my $parts     = $content->{parts} // [];

    # Function Calls prüfen – alle parallel zurückgegebenen Calls sammeln und gemeinsam abarbeiten
    my @fcResults = ();
    for my $part (@$parts) {
        if (exists $part->{functionCall}) {
            my $fc     = $part->{functionCall};
            my $fcName = $fc->{name} // '';
            my $args   = $fc->{args} // {};
            my $result = Gemini_ExecuteFunctionCall($hash, $fcName, $args);
            push @fcResults, { name => $fcName, result => $result };
        }
    }

    if (@fcResults) {
        # Gesamtes content-Objekt der Modell-Antwort einmalig speichern (Fix 2.0.2)
        push @{$hash->{CHAT}}, $content;
        Gemini_SendFunctionResults($hash, \@fcResults);
        return;
    }

    # Kein Function Call - finale Textantwort extrahieren
    my $responseUnicode = '';
    for my $part (@$parts) {
        $responseUnicode .= $part->{text} if exists $part->{text};
    }

    if (!$responseUnicode) {
        my $finishReason = $candidate->{finishReason} // 'UNKNOWN';
        readingsSingleUpdate($hash, 'lastError', "Leere Antwort, finishReason: $finishReason", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 2, "Gemini ($name): Leere Control-Antwort, finishReason: $finishReason";
        Gemini_RollbackControlSession($hash);
        return;
    }

    # Finale Modellantwort in Chat-Verlauf speichern
    push @{$hash->{CHAT}}, $content;

    delete $hash->{CONTROL_START_IDX};
    delete $hash->{CHAT_INCLUDE_DEVICE_STATUS};

    my $responseForReading = $responseUnicode;
    utf8::encode($responseForReading) if utf8::is_utf8($responseForReading);

    my $responsePlain = Gemini_MarkdownToPlain($responseUnicode);
    utf8::encode($responsePlain) if utf8::is_utf8($responsePlain);

    my $responseHTML = Gemini_MarkdownToHTML($responseUnicode);
    utf8::encode($responseHTML) if utf8::is_utf8($responseHTML);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'response',      $responseForReading);
    readingsBulkUpdate($hash, 'responsePlain', $responsePlain);
    readingsBulkUpdate($hash, 'responseHTML',  $responseHTML);
    readingsBulkUpdate($hash, 'chatHistory', scalar(@{$hash->{CHAT}}));
    readingsBulkUpdate($hash, 'state',       'ok');
    readingsBulkUpdate($hash, 'lastError',   '-');
    readingsEndUpdate($hash, 1);

    Log3 $name, 4, "Gemini ($name): Control-Antwort erhalten (" . length($responseUnicode) . " Zeichen)";
    return undef;
}

##############################################################################
# Hilfsfunktion: Einzelnen Function Call ausführen, Ergebnis als String zurückgeben
##############################################################################
sub Gemini_ExecuteFunctionCall {
    my ($hash, $fcName, $args) = @_;
    my $name = $hash->{NAME};

    if ($fcName eq 'set_device') {
        my $device  = $args->{device}  // '';
        my $command = $args->{command} // '';

        if ($command =~ /[;|`\$\(\)<>\n]/) {
            my $errMsg = "Fehler: Ungültiger Befehl '$command' (unerlaubte Zeichen)";
            Log3 $name, 2, "Gemini ($name): $errMsg";
            return $errMsg;
        }

        my %allowed = map { $_ => 1 } Gemini_GetControlDevices($hash);

        if ($allowed{$device} && exists $main::defs{$device}) {
            my $setResult = CommandSet(undef, "$device $command");
            $setResult //= 'ok';
            $setResult = 'ok' if $setResult eq '';

            my $cmdForReading = "$device $command";
            utf8::encode($cmdForReading) if utf8::is_utf8($cmdForReading);
            my $resForReading = $setResult;
            utf8::encode($resForReading) if utf8::is_utf8($resForReading);

            readingsBeginUpdate($hash);
            readingsBulkUpdate($hash, 'lastCommand',       $cmdForReading);
            readingsBulkUpdate($hash, 'lastCommandResult', $resForReading);
            readingsEndUpdate($hash, 1);

            Log3 $name, 3, "Gemini ($name): set $device $command -> $setResult";
            return "OK: $device $command ausgefuehrt";
        } else {
            my $errMsg = "Fehler: Geraet '$device' nicht in controlList oder nicht vorhanden";

            my $cmdForReading = "$device $command";
            utf8::encode($cmdForReading) if utf8::is_utf8($cmdForReading);
            my $resForReading = $errMsg;
            utf8::encode($resForReading) if utf8::is_utf8($resForReading);

            readingsBeginUpdate($hash);
            readingsBulkUpdate($hash, 'lastCommand',       $cmdForReading);
            readingsBulkUpdate($hash, 'lastCommandResult', $resForReading);
            readingsEndUpdate($hash, 1);

            Log3 $name, 2, "Gemini ($name): $errMsg";
            return $errMsg;
        }

    } elsif ($fcName eq 'get_device_state') {
        my $device = $args->{device} // '';

        if (exists $main::defs{$device}) {
            my $dev = $main::defs{$device};
            my @blacklist = Gemini_GetBlacklist($hash);
            my $stateResult  = "Geraet: $device\n";
            $stateResult .= "Typ: " . ($dev->{TYPE} // 'unbekannt') . "\n";
            $stateResult .= "Status: " . ReadingsVal($device, 'state', 'unbekannt') . "\n";
            if (exists $dev->{READINGS}) {
                $stateResult .= "Readings:\n";
                for my $reading (sort keys %{$dev->{READINGS}}) {
                    next if $reading eq 'state';
                    next if Gemini_IsBlacklisted($reading, @blacklist);
                    my $val = $dev->{READINGS}{$reading}{VAL} // '';
                    $stateResult .= "  $reading: $val\n";
                }
            }
            return $stateResult;
        } else {
            return "Fehler: Geraet '$device' nicht gefunden";
        }

    } elsif ($fcName eq 'create_at_device') {
        my $deviceName = $args->{device_name} // '';
        my $timeSpec   = $args->{time_spec}   // '';
        my $command    = $args->{command}     // '';
        my $recurring  = $args->{recurring}   // 0;

        # Sicherheit: Device-Name validieren
        if ($deviceName !~ /^[a-zA-Z0-9_\-]+$/) {
            my $errMsg = "Fehler: Ungültiger Gerätename '$deviceName'";
            Log3 $name, 2, "Gemini ($name): $errMsg";
            return $errMsg;
        }
        
        my $uniqueID = sprintf("%x%x%x", time(), rand(0xffff), rand(0xffff));
        $deviceName = "at_" . $name . "_" . $uniqueID . "_" . $deviceName;
        
        # Prüfen ob Device bereits existiert
        if (exists $main::defs{$deviceName}) {
            my $errMsg = "Fehler: Gerät '$deviceName' existiert bereits";
            Log3 $name, 2, "Gemini ($name): $errMsg";
            return $errMsg;
        }

        # Sicherheit: Command validieren
        if ($command =~ /[;|`\(\)<>]/) {
            my $errMsg = "Fehler: Ungültiger Befehl '$command' (unerlaubte Zeichen)";
            Log3 $name, 2, "Gemini ($name): $errMsg";
            return $errMsg;
        }

        # Raum ermitteln
        my $room = Gemini_GetAutomationRoom($hash);

        # AT-Device anlegen                
        my $defineCmd = "$deviceName at $timeSpec $command";
        my $defineResult = CommandDefine(undef, $defineCmd);
        
        if ($defineResult) {
            my $errMsg = "Fehler beim Anlegen von AT-Device: $defineResult";
            Log3 $name, 2, "Gemini ($name): AT $defineCmd";
            Log3 $name, 2, "Gemini ($name): $errMsg";
            return $errMsg;
        }

        # Raum setzen wenn vorhanden
        if ($room) {
            CommandAttr(undef, "$deviceName room $room");
        }

        # Für einmalige AT-Devices: Selbstlöschung einbauen
        unless ($recurring) {
            # Erweitere den Befehl um Selbstlöschung
            my $extendedCmd = "$command;; delete $deviceName";
            CommandModify(undef, "$deviceName $timeSpec $extendedCmd");
            Log3 $name, 3, "Gemini ($name): AT-Device $deviceName angelegt (einmalig, löscht sich selbst) im Raum '$room'";
        } else {
            Log3 $name, 3, "Gemini ($name): AT-Device $deviceName angelegt (wiederkehrend) im Raum '$room'";
        }

        # Reading aktualisieren
        my $autoForReading = "AT: $deviceName";
        utf8::encode($autoForReading) if utf8::is_utf8($autoForReading);
        readingsSingleUpdate($hash, 'lastAutomation', $autoForReading, 1);

        return "OK: AT-Device '$deviceName' erfolgreich angelegt" . ($room ? " im Raum '$room'" : "");

    } elsif ($fcName eq 'create_notify_device') {
        my $deviceName = $args->{device_name} // '';
        my $eventSpec  = $args->{event_spec}  // '';
        my $command    = $args->{command}     // '';
        my $oneShot    = $args->{one_shot}    // 1;

        # Sicherheit: Device-Name validieren
        if ($deviceName !~ /^[a-zA-Z0-9_\-]+$/) {
            my $errMsg = "Fehler: Ungültiger Gerätename '$deviceName'";
            Log3 $name, 2, "Gemini ($name): $errMsg";
            return $errMsg;
        }

        my $uniqueID = sprintf("%x%x%x", time(), rand(0xffff), rand(0xffff));
        $deviceName = "n_" . $name . "_" . $uniqueID . "_" . $deviceName;

        # Prüfen ob Device bereits existiert
        if (exists $main::defs{$deviceName}) {
            my $errMsg = "Fehler: Gerät '$deviceName' existiert bereits";
            Log3 $name, 2, "Gemini ($name): $errMsg";
            return $errMsg;
        }

        # Sicherheit: Command validieren
        if ($command =~ /[;|`\(\)<>]/) {
            my $errMsg = "Fehler: Ungültiger Befehl '$command' (unerlaubte Zeichen)";
            Log3 $name, 2, "Gemini ($name): $errMsg";
            return $errMsg;
        }

        # Raum ermitteln
        my $room = Gemini_GetAutomationRoom($hash);

        # Für one-shot NOTIFYs: Selbstlöschung in Perl-Block einbauen
        my $finalCommand = $command;
        if ($oneShot) {
            $finalCommand = "{ fhem('$command');; fhem('delete $deviceName') }";
        }

        # NOTIFY-Device anlegen                
        my $defineCmd = "$deviceName notify $eventSpec $finalCommand";
        my $defineResult = CommandDefine(undef, $defineCmd);
        
        if ($defineResult) {
            my $errMsg = "Fehler beim Anlegen von NOTIFY-Device: $defineResult";
            Log3 $name, 2, "Gemini ($name): NOTIFY $defineCmd";
            Log3 $name, 2, "Gemini ($name): $errMsg";
            return $errMsg;
        }

        # Raum setzen wenn vorhanden
        if ($room) {
            CommandAttr(undef, "$deviceName room $room");
        }

        if ($oneShot) {
            Log3 $name, 3, "Gemini ($name): NOTIFY-Device $deviceName angelegt (einmalig, löscht sich selbst) im Raum '$room'";
        } else {
            Log3 $name, 3, "Gemini ($name): NOTIFY-Device $deviceName angelegt (permanent) im Raum '$room'";
        }

        # Reading aktualisieren
        my $autoForReading = "NOTIFY: $deviceName";
        utf8::encode($autoForReading) if utf8::is_utf8($autoForReading);
        readingsSingleUpdate($hash, 'lastAutomation', $autoForReading, 1);

        return "OK: NOTIFY-Device '$deviceName' erfolgreich angelegt" . ($room ? " im Raum '$room'" : "");

    } else {
        return "Fehler: Unbekannte Funktion '$fcName'";
    }
}

##############################################################################
# Hilfsfunktion: Mehrere functionResponse-Ergebnisse in einem Turn an Gemini schicken
# $results = [{ name => '...', result => '...' }, ...]
##############################################################################
sub Gemini_SendFunctionResults {
    my ($hash, $results) = @_;
    my $name = $hash->{NAME};

    my @parts = map {
        {
            functionResponse => {
                name     => $_->{name},
                response => { result => $_->{result} }
            }
        }
    } @$results;

    push @{$hash->{CHAT}}, {
        role  => 'user',
        parts => \@parts
    };

    my $apiKey  = AttrVal($name, 'apiKey',   '');
    my $model   = AttrVal($name, 'model',    'gemini-3.1-flash-lite-preview');
    my $timeout = AttrVal($name, 'timeout',  30);

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $contentsToSend;
    if ($disableHistory) {
        my $startIdx = $hash->{CONTROL_START_IDX} // 0;
        $contentsToSend = [ @{$hash->{CHAT}}[$startIdx..$#{$hash->{CHAT}}] ];
    } else {
        $contentsToSend = $hash->{CHAT};
    }

    my %requestBody = (
        contents => $contentsToSend,
        tools    => Gemini_GetControlTools()
    );

    # STATISCHER Teil für system_instruction (wird gecacht!)
    my $systemPrompt         = AttrVal($name, 'systemPrompt', '');
    my $staticControlContext = Gemini_BuildStaticControlContext($hash);
    my $staticDeviceContext  = '';
    
    my $includeDeviceStatus = $hash->{CHAT_INCLUDE_DEVICE_STATUS} // 0;
    if ($includeDeviceStatus) {
        $staticDeviceContext = Gemini_BuildStaticDeviceContext($hash);
    }

    my $fullSystem = '';
    $fullSystem .= $systemPrompt if $systemPrompt;
    $fullSystem .= "\n\n" if $systemPrompt && $staticDeviceContext;
    $fullSystem .= $staticDeviceContext if $staticDeviceContext;
    $fullSystem .= "\n\n" if $fullSystem && $staticControlContext;
    $fullSystem .= $staticControlContext if $staticControlContext;

    if ($fullSystem) {
        $requestBody{system_instruction} = {
            parts => [{ text => $fullSystem }]
        };
    }

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Encode Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Gemini_RollbackControlSession($hash);
        return;
    }

    my $names = join(', ', map { $_->{name} } @$results);
    Log3 $name, 4, "Gemini ($name): FunctionResults fuer '$names' gesendet";

    my $url = "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}";

    HttpUtils_NonblockingGet({
        url      => $url,
        timeout  => $timeout,
        method   => 'POST',
        header   => "Content-Type: application/json\r\nAccept: application/json",
        data     => $jsonBody,
        hash     => $hash,
        callback => \&Gemini_HandleControlResponse,
    });

    return undef;
}

##############################################################################
# Hilfsfunktion: Einzelnes functionResponse-Ergebnis an Gemini schicken (Wrapper)
##############################################################################
sub Gemini_SendFunctionResult {
    my ($hash, $fcName, $resultText) = @_;
    Gemini_SendFunctionResults($hash, [{ name => $fcName, result => $resultText }]);
}

1;

=pod
=item device
=item summary Google Gemini AI integration for FHEM with Automation
=item summary_DE Google Gemini KI Anbindung fuer FHEM mit Automatisierung
=begin html

<a name="Gemini"></a>
<h3>Gemini</h3>
<ul>
  FHEM Modul zur Anbindung der Google Gemini AI API mit Automatisierungsfunktionen.<br><br>

  <b>Define</b><br>
  <ul><code>define &lt;name&gt; Gemini</code></ul><br>

  <b>Attribute</b><br>
  <ul>
    <li><b>apiKey</b> - Google Gemini API Key (Pflicht)</li>
    <li><b>model</b> - Gemini Modell (Standard: gemini-3.1-flash-lite-preview)</li>
    <li><b>maxHistory</b> - Max. Chat-Nachrichten (Standard: 20)</li>
    <li><b>systemPrompt</b> - Optionaler System-Prompt</li>
    <li><b>timeout</b> - HTTP Timeout in Sekunden (Standard: 30)</li>
    <li><b>disable</b> - Modul deaktivieren</li>
    <li><b>disableHistory</b> - Chat-Verlauf deaktivieren (0/1). Bei 1 wird jede Anfrage
      ohne vorherigen Chat-Verlauf gesendet und als eigenstaendiges Gespraech behandelt.
      Der interne Verlauf bleibt erhalten (fuer resetChat), wird aber nicht an die API uebermittelt.</li>
    <li><b>deviceList</b> - Komma-getrennte Geraete liste fuer askAboutDevices</li>
    <li><b>deviceRoom</b> - Komma-getrennte Raumliste; alle Geraete mit passendem
      FHEM-room-Attribut werden automatisch fuer askAboutDevices verwendet.
      Beispiel: <code>attr GeminiAI deviceRoom Wohnzimmer,Kueche</code>.
      Kann zusammen mit <b>deviceList</b> verwendet werden.</li>
    <li><b>controlList</b> - Komma-getrennte Liste der Geraete, die Gemini per
      Function Calling steuern darf (Pflicht fuer den control- bzw. chat-Befehl).
      Alias-Namen und verfuegbare set-Befehle der Geraete werden automatisch
      an Gemini uebermittelt, sodass Sprachbefehle mit Alias-Namen und
      passende Befehle automatisch erkannt werden.
      Beispiel: <code>attr GeminiAI controlList Lampe1,Heizung,Rolladen1</code></li>
    <li><b>controlRoom</b> - Komma-getrennte Raumliste; alle Geraete mit passendem
      FHEM-room-Attribut werden automatisch als steuerbar eingestuft und ergaenzen
      die <b>controlList</b>. Duplikate werden automatisch entfernt.
      Beispiel: <code>attr GeminiAI controlRoom Wohnzimmer,Kueche</code>.
      Kann zusammen mit <b>controlList</b> verwendet werden.</li>
    <li><b>automationRoom</b> - Raum fuer automatisch angelegte AT/NOTIFY-Geraete.
      Wenn nicht gesetzt, wird der erste Raum des Gemini-Devices selbst verwendet.
      Beispiel: <code>attr GeminiAI automationRoom Automation</code></li>
    <li><b>readingBlacklist</b> - Leerzeichen-getrennte Liste von Reading- bzw.
      Befehlsnamen, die <b>nicht</b> an Gemini uebermittelt werden sollen.
      Wildcards mit <code>*</code> werden unterstuetzt, z.B. <code>R-*</code> oder <code>Wifi_*</code>.<br>
      Wenn das Attribut nicht gesetzt ist, gilt folgende eingebaute Standardliste:<br>
      <code>attrTemplate associate R-* RegL_* associatedWith peerListRDate protLastRcv
      lastTimeSync lastcmd Heap LoadAvg Uptime Wifi_*</code><br>
      Sobald das Attribut gesetzt wird, ersetzt die angegebene Liste die Standardliste vollstaendig.
      Beispiel: <code>attr GeminiAI readingBlacklist attrTemplate associate R-* Wifi_*</code></li>
  </ul><br>

  <b>Set</b><br>
  <ul>
    <li><b>ask</b> &lt;Frage&gt; - Textfrage stellen</li>
    <li><b>askWithImage</b> &lt;Bildpfad&gt; &lt;Frage&gt; - Bild + Frage senden</li>
    <li><b>askAboutDevices</b> [&lt;Frage&gt;] - Geraete-Status an Gemini uebergeben und Frage stellen</li>
    <li><b>chat</b> &lt;Nachricht&gt; - Universeller Befehl fuer allgemeine Fragen, Geraete-Status
      und Steuerung in einem einzigen Befehl. Ideal fuer die Telegram-Integration.
      Wenn <b>controlList</b> oder <b>controlRoom</b> konfiguriert ist, kann Gemini sowohl
      Geraete steuern als auch Statusfragen beantworten und Automatisierungen anlegen. 
      Der Geraete-Status aus <b>deviceList</b>/<b>deviceRoom</b> wird automatisch als Kontext mitgegeben.
      Beispiel: <code>set GeminiAI chat Ist die Wohnzimmerlampe an?</code><br>
      Beispiel: <code>set GeminiAI chat Mach bitte das Licht im Flur aus</code><br>
      Beispiel: <code>set GeminiAI chat Schalte das Licht morgen um 7 Uhr ein</code><br>
      Beispiel: <code>set GeminiAI chat Benachrichtige mich wenn die Haustuer geoeffnet wird</code></li>
    <li><b>control</b> &lt;Anweisung&gt; - Gemini steuert FHEM-Geraete eigenstaendig per
      Function Calling und kann auch AT/NOTIFY-Devices anlegen. 
      Beispiel: <code>set GeminiAI control Mach die Wohnzimmerlampe an</code><br>
      Beispiel: <code>set GeminiAI control Schalte in 5 Minuten alle Lampen aus</code><br>
      Beispiel: <code>set GeminiAI control Wenn die Tuer aufgeht, schalte das Licht ein</code>.
      Nur Geraete aus <b>controlList</b>/<b>controlRoom</b> duerfen gesteuert werden.</li>
    <li><b>resetChat</b> - Chat-Verlauf loeschen</li>
  </ul><br>

  <b>Get</b><br>
  <ul>
    <li><b>chatHistory</b> - Chat-Verlauf anzeigen</li>
  </ul><br>

  <b>Readings</b><br>
  <ul>
    <li><b>response</b> - Letzte Textantwort von Gemini (Roh-Markdown)</li>
    <li><b>responsePlain</b> - Letzte Textantwort, Markdown-Syntax entfernt (reiner Text, ideal fuer Sprachausgabe, Telegram, Notify)</li>
    <li><b>responseHTML</b> - Letzte Textantwort, Markdown in HTML konvertiert (ideal fuer Tablet-UI, Web-Frontends)</li>
    <li><b>state</b> - Aktueller Status</li>
    <li><b>lastError</b> - Letzter Fehler</li>
    <li><b>chatHistory</b> - Anzahl der Nachrichten im Chat-Verlauf</li>
    <li><b>lastCommand</b> - Letzter ausgefuehrter set-Befehl (z.B. <code>Lampe1 on</code>)</li>
    <li><b>lastCommandResult</b> - Ergebnis des letzten set-Befehls (<code>ok</code> oder Fehlermeldung)</li>
    <li><b>lastAutomation</b> - Letztes angelegtes AT/NOTIFY-Geraet</li>
    <li><b>candidatesTokenCount</b> - Anzahl der vom Modell generierten Tokens (Antwort)</li>
    <li><b>promptTokenCount</b> - Anzahl der gesendeten Tokens (deine Frage/Input)</li>
    <li><b>totalTokenCount</b> - Gesamtsumme der verbrauchten Tokens (Input + Output)</li>                      
  </ul><br>

  <b>Beispiele für Automatisierung</b><br>
  <ul>
    <li><code>set GeminiAI chat Schalte das Licht um 18:00 ein</code> - Legt AT-Device an</li>
    <li><code>set GeminiAI chat In 30 Minuten soll die Heizung ausgehen</code> - Relatives AT-Device</li>
    <li><code>set GeminiAI chat Jeden Tag um 22:00 alle Lampen ausschalten</code> - Wiederkehrendes AT</li>
    <li><code>set GeminiAI chat Wenn die Haustuer aufgeht, schalte das Licht ein</code> - NOTIFY (einmalig)</li>
    <li><code>set GeminiAI chat Überwache die Temperatur, wenn sie über 25 Grad geht, sende Alarm</code> - NOTIFY (permanent)</li>
  </ul>
</ul>

=end html
=cut
