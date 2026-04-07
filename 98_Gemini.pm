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
#
# Attribute:
#   apiKey        - Google Gemini API Key (Pflicht)
#   model         - Gemini Modell (Standard: gemini-2.0-flash)
#   maxHistory    - Maximale Anzahl Chat-Nachrichten (Standard: 20)
#   systemPrompt  - Optionaler System-Prompt
#   timeout       - HTTP Timeout in Sekunden (Standard: 30)
#
# Set-Befehle:
#   ask <Frage>                    - Textfrage stellen
#   askWithImage <Pfad> <Frage>    - Bild + Frage senden
#   resetChat                      - Chat-Verlauf löschen
#
# Lesewerte (Readings):
#   response      - Letzte Antwort von Gemini
#   state         - Aktueller Status
#   lastError     - Letzter Fehler
#   chatHistory   - Anzahl der Nachrichten im Verlauf
#
##############################################################################

# Versionshistorie:
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
    $hash->{VERSION}     = '1.3.0';

    readingsSingleUpdate($hash, 'state',       'initialized', 1);
    readingsSingleUpdate($hash, 'response',    '-',           0);
    readingsSingleUpdate($hash, 'chatHistory', 0,             0);
    readingsSingleUpdate($hash, 'lastError',   '-',           0);

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

    } elsif ($cmd eq 'resetChat') {
        $hash->{CHAT} = [];
        readingsSingleUpdate($hash, 'chatHistory', 0, 1);
        readingsSingleUpdate($hash, 'state', 'chat reset', 1);
        Log3 $name, 3, "Gemini ($name): Chat-Verlauf zurückgesetzt";
        return undef;

    } else {
        return "Unknown argument $cmd, choose one of ask:textField askWithImage:textField askAboutDevices:textField resetChat:noArg";
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
  </ul><br>

  <b>Set</b><br>
  <ul>
    <li><b>ask</b> &lt;Frage&gt; - Textfrage stellen</li>
    <li><b>askWithImage</b> &lt;Bildpfad&gt; &lt;Frage&gt; - Bild + Frage senden</li>
    <li><b>resetChat</b> - Chat-Verlauf löschen</li>
  </ul><br>

  <b>Get</b><br>
  <ul>
    <li><b>chatHistory</b> - Chat-Verlauf anzeigen</li>
  </ul>
</ul>

=end html
=cut
