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
#   disableHistory - Chat-Verlauf deaktivieren (0/1); jede Anfrage wird als eigenstaendiges Gespraech behandelt
#
# Set-Befehle:
#   ask <Frage>                    - Textfrage stellen
#   askWithImage <Pfad> <Frage>    - Bild + Frage senden
#   askAboutDevices [<Frage>]      - Geräte-Statusabfrage
#   control <Anweisung>            - Gemini steuert Geräte via Function Calling
#   resetChat                      - Chat-Verlauf löschen
#
# Lesewerte (Readings):
#   response           - Letzte Antwort von Gemini
#   state              - Aktueller Status
#   lastError          - Letzter Fehler
#   chatHistory        - Anzahl der Nachrichten im Verlauf
#   lastCommand        - Letzter ausgeführter set-Befehl
#   lastCommandResult  - Ergebnis des letzten set-Befehls
#
##############################################################################

# Versionshistorie:
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
        'deviceRoom:textField-long ' .
        'systemPrompt:textField-long ' .
        $readingFnAttributes;

    return undef;
}

sub Gemini_Define {
    my ($hash, $def) = @_;
    my @args = split('[ \t]+', $def);

    return "Usage: define <name> Gemini" if (@args < 2);

    my $name = $args[0];
    $hash->{NAME}        = $name;
    $hash->{CHAT}        = [];   # Chat-Verlauf als Array-Referenz
    $hash->{VERSION}     = '2.7.0';

    readingsSingleUpdate($hash, 'state',             'initialized', 1);
    readingsSingleUpdate($hash, 'response',          '-',           0);
    readingsSingleUpdate($hash, 'chatHistory',       0,             0);
    readingsSingleUpdate($hash, 'lastError',         '-',           0);
    readingsSingleUpdate($hash, 'lastCommand',       '-',           0);
    readingsSingleUpdate($hash, 'lastCommandResult', '-',           0);

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
        Gemini_SendRequest($hash, $question, undef, undef);
        return undef;

    } elsif ($cmd eq 'askWithImage') {
        return "Usage: set $name askWithImage <Bildpfad> <Frage>" unless @args >= 2;
        my $imagePath = $args[0];
        my $question  = join(' ', @args[1..$#args]);
        return "Bilddatei nicht gefunden: $imagePath" unless -f $imagePath;
        Gemini_SendRequest($hash, $question, $imagePath, undef);
        return undef;

    } elsif ($cmd eq 'askAboutDevices') {
        my $question      = @args ? join(' ', @args) : 'Gib mir eine Zusammenfassung aller Geräte und ihres aktuellen Status.';
        my $deviceContext = Gemini_BuildDeviceContext($hash);
        Gemini_SendRequest($hash, $question, undef, $deviceContext);
        return undef;

    } elsif ($cmd eq 'control') {
        return "Usage: set $name control <Anweisung>" unless @args;
        my $controlList = AttrVal($name, 'controlList', '');
        return "Fehler: Attribut controlList ist nicht gesetzt" unless $controlList;
        my $instruction = join(' ', @args);
        Gemini_SendControl($hash, $instruction);
        return undef;

    } elsif ($cmd eq 'resetChat') {
        $hash->{CHAT} = [];
        readingsSingleUpdate($hash, 'chatHistory', 0, 1);
        readingsSingleUpdate($hash, 'state', 'chat reset', 1);
        Log3 $name, 3, "Gemini ($name): Chat-Verlauf zurückgesetzt";
        return undef;

    } else {
        return "Unknown argument $cmd, choose one of ask:textField askWithImage:textField askAboutDevices:textField control:textField resetChat:noArg";
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
    my ($hash, $question, $imagePath, $deviceContext) = @_; 
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

    my @parts;

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
            shift @{$hash->{CHAT}} while @{$hash->{CHAT}} && $hash->{CHAT}[0]{role} ne 'user';
        } else {
            last;
        }
    }

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $contentsToSend = $disableHistory ? [ $hash->{CHAT}[-1] ] : $hash->{CHAT};

    my %requestBody = (
        contents => $contentsToSend
    );

    my $systemPrompt = AttrVal($name, 'systemPrompt', '');

    my $fullSystem = '';
    $fullSystem .= $systemPrompt   if $systemPrompt;
    $fullSystem .= "\n\n"          if $systemPrompt && $deviceContext;
    $fullSystem .= $deviceContext  if $deviceContext;

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

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'response',    $responseForReading);
    readingsBulkUpdate($hash, 'chatHistory', scalar(@{$hash->{CHAT}}));
    readingsBulkUpdate($hash, 'state',       'ok');
    readingsBulkUpdate($hash, 'lastError',   '-');
    readingsEndUpdate($hash, 1);

    Log3 $name, 4, "Gemini ($name): Antwort erhalten (" . length($responseUnicode) . " Zeichen)";
    return undef;
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
# FHEM Device-Kontext für Gemini aufbauen
##############################################################################
sub Gemini_BuildDeviceContext {
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

    return '' unless @devices;

    my $context = "Aktueller Status der Smart-Home Geräte:\n";

    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $dev   = $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);

        Log3 $name, 3, "Gemini ($name): Alias " . $alias;

        $context .= "\nGerät: $alias (intern: $devName)\n";
        $context .= "  Typ: " . ($dev->{TYPE} // 'unbekannt') . "\n";

        my $state = ReadingsVal($devName, 'state', 'unbekannt');
        $context .= "  Status: $state\n";

        if (exists $dev->{READINGS}) {
            $context .= "  Readings:\n";
            for my $reading (sort keys %{$dev->{READINGS}}) {
                next if $reading eq 'state';
                my $val  = $dev->{READINGS}{$reading}{VAL}  // '';
                my $time = $dev->{READINGS}{$reading}{TIME} // '';
                $context .= "    $reading: $val (Stand: $time)\n";
            }
        }

        for my $attrName (qw(room group alias)) {
            my $attrVal = AttrVal($devName, $attrName, '');
            $context .= "  $attrName: $attrVal\n" if $attrVal;
        }

        Log3 $name, 3, "Gemini ($name): " . $alias . ": " . $context;
    }

    return $context;
}

##############################################################################
# Hilfsfunktion: Gerätekontext für control-Befehl aufbauen (Alias-Mapping)
##############################################################################
sub Gemini_BuildControlContext {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $controlList = AttrVal($name, 'controlList', '');
    return '' unless $controlList;

    my @devices = split(/\s*,\s*/, $controlList);
    return '' unless @devices;

    # Interne FHEM-Eintraege, die nicht an Gemini uebermittelt werden sollen
    my @blacklist = qw(attrTemplate associate);
    my %blackset  = map { $_ => 1 } @blacklist;

    my $context = "Verfuegbare Geraete zum Steuern:\n";
    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);

        # Set-Befehle ermitteln (getAllSets liefert auch dynamisch berechnete Befehle)
        my $setListRaw = main::getAllSets($devName) // '';

        # Typ-Informationen (z.B. :slider,0,1,100) behalten, nur Blacklist-Eintraege filtern
        my @cmds;
        for my $entry (split(/\s+/, $setListRaw)) {
            my ($cmdName) = split(/:/, $entry, 2);  # Befehlsname zum Filtern extrahieren
            next unless $cmdName;
            next if $blackset{$cmdName};
            push @cmds, $entry;                     # kompletten Eintrag inkl. :slider,... behalten
        }

        my $cmdsStr = @cmds ? join(', ', @cmds) : 'unbekannt';
        $context .= "  $alias (intern: $devName) -- set-Befehle: $cmdsStr\n";
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
                description => 'Führt einen FHEM set-Befehl auf einem Gerät aus, z.B. on, off oder einen numerischen Wert',
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
}

##############################################################################
# Control-Funktion: Gerät steuern via Function Calling
##############################################################################
sub Gemini_SendControl {
    my ($hash, $instruction) = @_;
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

    $hash->{CONTROL_START_IDX} = scalar(@{$hash->{CHAT}});

    push @{$hash->{CHAT}}, {
        role  => 'user',
        parts => [{ text => $instruction }]
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

    my $systemPrompt   = AttrVal($name, 'systemPrompt', '');
    my $controlContext = Gemini_BuildControlContext($hash);

    my $fullSystem = '';
    $fullSystem .= $systemPrompt    if $systemPrompt;
    $fullSystem .= "\n\n"           if $systemPrompt && $controlContext;
    $fullSystem .= $controlContext  if $controlContext;

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

    my $candidate = $result->{candidates}[0];
    my $content   = $candidate->{content};
    my $parts     = $content->{parts} // [];

    # Function Call prüfen
    for my $part (@$parts) {
        if (exists $part->{functionCall}) {
            my $fc     = $part->{functionCall};
            my $fcName = $fc->{name}  // '';
            my $args   = $fc->{args}  // {};

            # Gesamtes content-Objekt der Modell-Antwort speichern (Fix 2.0.2)
            push @{$hash->{CHAT}}, $content;

            if ($fcName eq 'set_device') {
                my $device  = $args->{device}  // '';
                my $command = $args->{command} // '';

                if ($command =~ /[;|`\$\(\)<>
]/) {
                    my $errMsg = "Fehler: Ungültiger Befehl '$command' (unerlaubte Zeichen)";
                    Log3 $name, 2, "Gemini ($name): $errMsg";
                    Gemini_SendFunctionResult($hash, $fcName, $errMsg);
                    return;
                }

                my $controlList = AttrVal($name, 'controlList', '');
                my %allowed     = map { $_ => 1 } split(/\s*,\s*/, $controlList);

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
                    Gemini_SendFunctionResult($hash, $fcName, "OK: $device $command ausgefuehrt");
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
                    Gemini_SendFunctionResult($hash, $fcName, $errMsg);
                }
                return;

            } elsif ($fcName eq 'get_device_state') {
                my $device = $args->{device} // '';
                my $stateResult;

                if (exists $main::defs{$device}) {
                    my $dev = $main::defs{$device};
                    $stateResult  = "Geraet: $device\n";
                    $stateResult .= "Typ: " . ($dev->{TYPE} // 'unbekannt') . "\n";
                    $stateResult .= "Status: " . ReadingsVal($device, 'state', 'unbekannt') . "\n";
                    if (exists $dev->{READINGS}) {
                        $stateResult .= "Readings:\n";
                        for my $reading (sort keys %{$dev->{READINGS}}) {
                            next if $reading eq 'state';
                            my $val = $dev->{READINGS}{$reading}{VAL} // '';
                            $stateResult .= "  $reading: $val\n";
                        }
                    }
                } else {
                    $stateResult = "Fehler: Geraet '$device' nicht gefunden";
                }

                Gemini_SendFunctionResult($hash, $fcName, $stateResult);
                return;

            } else {
                Gemini_SendFunctionResult($hash, $fcName, "Fehler: Unbekannte Funktion '$fcName'");
                return;
            }
        }
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

    my $responseForReading = $responseUnicode;
    utf8::encode($responseForReading) if utf8::is_utf8($responseForReading);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'response',    $responseForReading);
    readingsBulkUpdate($hash, 'chatHistory', scalar(@{$hash->{CHAT}}));
    readingsBulkUpdate($hash, 'state',       'ok');
    readingsBulkUpdate($hash, 'lastError',   '-');
    readingsEndUpdate($hash, 1);

    Log3 $name, 4, "Gemini ($name): Control-Antwort erhalten (" . length($responseUnicode) . " Zeichen)";
    return undef;
}

##############################################################################
# Hilfsfunktion: functionResponse an Gemini zurückschicken
##############################################################################
sub Gemini_SendFunctionResult {
    my ($hash, $fcName, $resultText) = @_;
    my $name = $hash->{NAME};

    push @{$hash->{CHAT}}, {
        role  => 'user',
        parts => [{
            functionResponse => {
                name     => $fcName,
                response => { result => $resultText }
            }
        }]
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

    my $systemPrompt   = AttrVal($name, 'systemPrompt', '');
    my $controlContext = Gemini_BuildControlContext($hash);

    my $fullSystem = '';
    $fullSystem .= $systemPrompt    if $systemPrompt;
    $fullSystem .= "\n\n"           if $systemPrompt && $controlContext;
    $fullSystem .= $controlContext  if $controlContext;

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

    Log3 $name, 4, "Gemini ($name): FunctionResult fuer '$fcName' gesendet";

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

1;

=pod
=item device
=item summary Google Gemini AI integration for FHEM
=item summary_DE Google Gemini KI Anbindung fuer FHEM

=begin html

<a name="Gemini"></a>
<h3>Gemini</h3>
<ul>
  FHEM Modul zur Anbindung der Google Gemini AI API.<br><br>

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
      Function Calling steuern darf (Pflicht fuer den control-Befehl).
      Alias-Namen und verfuegbare set-Befehle der Geraete werden automatisch
      an Gemini uebermittelt, sodass Sprachbefehle mit Alias-Namen und
      passende Befehle automatisch erkannt werden.
      Beispiel: <code>attr GeminiAI controlList Lampe1,Heizung,Rolladen1</code></li>
  </ul><br>

  <b>Set</b><br>
  <ul>
    <li><b>ask</b> &lt;Frage&gt; - Textfrage stellen</li>
    <li><b>askWithImage</b> &lt;Bildpfad&gt; &lt;Frage&gt; - Bild + Frage senden</li>
    <li><b>askAboutDevices</b> [&lt;Frage&gt;] - Geraete-Status an Gemini uebergeben und Frage stellen</li>
    <li><b>control</b> &lt;Anweisung&gt; - Gemini steuert FHEM-Geraete eigenstaendig per
      Function Calling. Beispiel: <code>set GeminiAI control Mach die Wohnzimmerlampe an</code>.
      Nur Geraete aus <b>controlList</b> duerfen gesteuert werden.</li>
    <li><b>resetChat</b> - Chat-Verlauf loeschen</li>
  </ul><br>

  <b>Get</b><br>
  <ul>
    <li><b>chatHistory</b> - Chat-Verlauf anzeigen</li>
  </ul><br>

  <b>Readings</b><br>
  <ul>
    <li><b>response</b> - Letzte Textantwort von Gemini</li>
    <li><b>state</b> - Aktueller Status</li>
    <li><b>lastError</b> - Letzter Fehler</li>
    <li><b>chatHistory</b> - Anzahl der Nachrichten im Chat-Verlauf</li>
    <li><b>lastCommand</b> - Letzter ausgefuehrter set-Befehl (z.B. <code>Lampe1 on</code>)</li>
    <li><b>lastCommandResult</b> - Ergebnis des letzten set-Befehls (<code>ok</code> oder Fehlermeldung)</li>
  </ul>
</ul>

=end html
=cut
