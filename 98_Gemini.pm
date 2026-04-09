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
#   model         - Gemini Modell (Standard: gemini-2.0-flash)
#   maxHistory    - Maximale Anzahl Chat-Nachrichten (Standard: 20)
#   systemPrompt  - Optionaler System-Prompt
#   timeout       - HTTP Timeout in Sekunden (Standard: 30)
#   deviceList    - Komma-getrennte Liste der Geräte für askAboutDevices
#   controlList   - Komma-getrennte Liste der Geräte, die Gemini steuern darf
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
        'systemPrompt ' .
        'timeout ' .
        'disable:0,1 ' .
        'deviceList ' .
        'controlList ' .
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
    $hash->{VERSION}     = '2.0.0';

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
    # Validierung
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
        my $question     = @args ? join(' ', @args) : 'Gib mir eine Zusammenfassung aller Geräte und ihres aktuellen Status.';
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
    my ($hash, $question, $imagePath, $deviceContext) = @_;  # $deviceContext neu
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

    my $model      = AttrVal($name, 'model',      'gemini-2.0-flash');
    my $timeout    = AttrVal($name, 'timeout',    30);
    my $maxHistory = AttrVal($name, 'maxHistory', 20);

    # Neue User-Nachricht aufbauen
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

    # Request-Body aufbauen
    my %requestBody = (
        contents => $hash->{CHAT}
    );

    # System-Prompt + optionaler Device-Kontext zusammenbauen
    my $systemPrompt = AttrVal($name, 'systemPrompt', '');
    # $deviceContext kommt jetzt als Parameter, KEIN BuildDeviceContext()-Aufruf hier

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

    # Sicherstellen dass $data reine Bytes sind
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

    # Antwort extrahieren - decode_json liefert Unicode-String (UTF-8 Flag gesetzt)
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

    # Für den Chat-Verlauf: Unicode-String behalten (encode_json braucht Unicode)
    push @{$hash->{CHAT}}, {
        role  => 'model',
        parts => [{ text => $responseUnicode }]
    };

    # Für FHEM-Readings: UTF-8 Flag entfernen (FHEM erwartet Bytes ohne Flag)
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
    my $name     = $hash->{NAME};
    my $devList  = AttrVal($name, 'deviceList', '');

    $devList = join(' ', $main::defs) if $devList eq "*";
    return '' unless $devList;

    my @devices  = split(/\s*,\s*/, $devList);
    my $context  = "Aktueller Status der Smart-Home Geräte:\n";

    for my $devName (@devices) {
        # Device existiert?
        next unless exists $main::defs{$devName};
        my $dev = $main::defs{$devName};

        # Alias holen falls vorhanden
        my $alias = AttrVal($devName, 'alias', $devName);

        Log3 $name, 3, "Gemini ($name): Alias " . $alias;

        $context .= "\nGerät: $alias (intern: $devName)\n";
        $context .= "  Typ: " . ($dev->{TYPE} // 'unbekannt') . "\n";

        # State
        my $state = ReadingsVal($devName, 'state', 'unbekannt');
        $context .= "  Status: $state\n";

        # Alle Readings ausgeben
        if (exists $dev->{READINGS}) {
            $context .= "  Readings:\n";
            for my $reading (sort keys %{$dev->{READINGS}}) {
                next if $reading eq 'state';
                my $val  = $dev->{READINGS}{$reading}{VAL} // '';
                my $time = $dev->{READINGS}{$reading}{TIME} // '';
                $context .= "    $reading: $val (Stand: $time)\n";
            }
        }

        # Wichtige Attribute mit ausgeben
        for my $attrName (qw(room group alias)) {
            my $attrVal = AttrVal($devName, $attrName, '');
            $context .= "  $attrName: $attrVal\n" if $attrVal;
        }

        Log3 $name, 3, "Gemini ($name): " . $alias . ": " . $context ;

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

    my $model      = AttrVal($name, 'model',      'gemini-2.0-flash');
    my $timeout    = AttrVal($name, 'timeout',    30);
    my $maxHistory = AttrVal($name, 'maxHistory', 20);

    # Startindex merken für Fehlerbehandlung
    $hash->{CONTROL_START_IDX} = scalar(@{$hash->{CHAT}});

    # Neue User-Nachricht in den Chat aufnehmen
    push @{$hash->{CHAT}}, {
        role  => 'user',
        parts => [{ text => $instruction }]
    };

    while (scalar(@{$hash->{CHAT}}) > $maxHistory) {
        shift @{$hash->{CHAT}};
        $hash->{CONTROL_START_IDX}-- if $hash->{CONTROL_START_IDX} > 0;
    }

    my %requestBody = (
        contents => $hash->{CHAT},
        tools    => Gemini_GetControlTools()
    );

    my $systemPrompt = AttrVal($name, 'systemPrompt', '');
    if ($systemPrompt) {
        $requestBody{system_instruction} = {
            parts => [{ text => $systemPrompt }]
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

    # Sicherstellen dass $data reine Bytes sind
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

            # Modell-Antwort (functionCall) in Chat-Verlauf speichern
            push @{$hash->{CHAT}}, {
                role  => 'model',
                parts => [{ functionCall => $fc }]
            };

            if ($fcName eq 'set_device') {
                my $device  = $args->{device}  // '';
                my $command = $args->{command} // '';

                # Basis-Validierung: keine Shell-Sonderzeichen im Befehl
                if ($command =~ /[;|`\$\(\)<>\n\r]/) {
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

                    Log3 $name, 3, "Gemini ($name): set $device $command → $setResult";
                    Gemini_SendFunctionResult($hash, $fcName, "OK: $device $command ausgeführt");
                } else {
                    my $errMsg = "Fehler: Gerät '$device' nicht in controlList oder nicht vorhanden";

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
                    $stateResult  = "Gerät: $device\n";
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
                    $stateResult = "Fehler: Gerät '$device' nicht gefunden";
                }

                Gemini_SendFunctionResult($hash, $fcName, $stateResult);
                return;

            } else {
                Gemini_SendFunctionResult($hash, $fcName, "Fehler: Unbekannte Funktion '$fcName'");
                return;
            }
        }
    }

    # Kein Function Call – finale Textantwort extrahieren
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
    push @{$hash->{CHAT}}, {
        role  => 'model',
        parts => [{ text => $responseUnicode }]
    };

    delete $hash->{CONTROL_START_IDX};

    # Für FHEM-Readings: UTF-8 Flag entfernen
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

    # functionResponse in Chat-Verlauf aufnehmen
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
    my $model   = AttrVal($name, 'model',    'gemini-2.0-flash');
    my $timeout = AttrVal($name, 'timeout',  30);

    my %requestBody = (
        contents => $hash->{CHAT},
        tools    => Gemini_GetControlTools()
    );

    my $systemPrompt = AttrVal($name, 'systemPrompt', '');
    if ($systemPrompt) {
        $requestBody{system_instruction} = {
            parts => [{ text => $systemPrompt }]
        };
    }

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Encode Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Gemini_RollbackControlSession($hash);
        return;
    }

    Log3 $name, 4, "Gemini ($name): FunctionResult für '$fcName' gesendet";

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
=item summary_DE Google Gemini KI Anbindung für FHEM

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
    <li><b>model</b> - Gemini Modell (Standard: gemini-2.0-flash)</li>
    <li><b>maxHistory</b> - Max. Chat-Nachrichten (Standard: 20)</li>
    <li><b>systemPrompt</b> - Optionaler System-Prompt</li>
    <li><b>timeout</b> - HTTP Timeout in Sekunden (Standard: 30)</li>
    <li><b>disable</b> - Modul deaktivieren</li>
    <li><b>deviceList</b> - Komma-getrennte Geräteliste für askAboutDevices</li>
    <li><b>controlList</b> - Komma-getrennte Liste der Geräte, die Gemini per
      Function Calling steuern darf (Pflicht für den control-Befehl).
      Beispiel: <code>attr GeminiAI controlList Lampe1,Heizung,Rolladen1</code></li>
  </ul><br>

  <b>Set</b><br>
  <ul>
    <li><b>ask</b> &lt;Frage&gt; - Textfrage stellen</li>
    <li><b>askWithImage</b> &lt;Bildpfad&gt; &lt;Frage&gt; - Bild + Frage senden</li>
    <li><b>askAboutDevices</b> [&lt;Frage&gt;] - Geräte-Status an Gemini übergeben und Frage stellen</li>
    <li><b>control</b> &lt;Anweisung&gt; - Gemini steuert FHEM-Geräte eigenständig per
      Function Calling. Beispiel: <code>set GeminiAI control Mach die Wohnzimmerlampe an</code>.
      Nur Geräte aus <b>controlList</b> dürfen gesteuert werden.</li>
    <li><b>resetChat</b> - Chat-Verlauf löschen</li>
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
    <li><b>lastCommand</b> - Letzter ausgeführter set-Befehl (z.B. <code>Lampe1 on</code>)</li>
    <li><b>lastCommandResult</b> - Ergebnis des letzten set-Befehls (<code>ok</code> oder Fehlermeldung)</li>
  </ul>
</ul>

=end html
=cut
