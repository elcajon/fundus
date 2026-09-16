# Ablage

Eine native Mac-App für Paperless-ngx, inspiriert von [Papers](https://papersapp.info). Anders als Papers kommt sie auch an Paperless heran, wenn es hinter **Pangolin** (badger + SSO) veröffentlicht ist.

## Bauen und testen

Xcode ist nicht nötig, die Command Line Tools reichen:

```sh
./test.sh
./build.sh
open build/Ablage.app
```

- `build.sh` baut gegen das neueste macOS-26-SDK, weil im 27er-SDK `@State` ein Macro ist, dessen Plugin nur mit Xcode ausgeliefert wird (die Liquid-Glass-APIs sind in beiden SDKs identisch). Danach trägt es mit `vtool` die echte SDK-Version ins Binary ein: SwiftPM schreibt dort sonst die Mindestversion 14.0 hinein, und macOS zeigt die App dann im alten Design ohne Liquid Glass.
- Signiert wird mit Hardened Runtime und einem selbst erzeugten Zertifikat aus einem eigenen Schlüsselbund unter `.signing/` (nicht im Repo). Der Login-Schlüsselbund bleibt unberührt. Ohne Apple-Entwicklerzertifikat bindet macOS „Immer erlauben“ beim Schlüsselbund-Zugriff trotzdem an den einzelnen Build: Nach jedem Neubau fragt es einmal nach dem Passwort.
- `test.sh` führt die Tests (Swift Testing) aus und gibt den Pfad zum Macro-Plugin mit, den die Command Line Tools sonst nicht finden.
- Beide Skripte prüfen über `scripts/make-strings.py`, dass jeder sichtbare Text eine englische Übersetzung hat (`scripts/translations_en.py`). Deutsch ist die Entwicklungssprache.

Zum Installieren nach `/Applications` ziehen (nötig für „Beim Anmelden starten“).

## Wie die App durch Pangolin kommt

Pangolin beantwortet `/api/*` ohne Session mit `401 Unauthorized` (text/plain), bevor Paperless die Anfrage überhaupt sieht.

1. **SSO-Login im App-Fenster.** Beim Verbinden öffnet sich ein WebView mit dem Pangolin-Login. Nach der Anmeldung liegt das Resource-Cookie `p_session_token` im persistenten WebKit-Speicher. Die App kopiert es in ihre URLSession und nutzt es nach jedem Neustart wieder.
   - **Passkeys aus dem Schlüsselbund funktionieren in diesem Fenster nicht.** macOS erlaubt WebAuthn in eingebetteten WebViews nur signierten Browsern mit Entitlement. In Pocket-ID deshalb *Alternative Anmeldemöglichkeiten → Mit einem anderen Gerät anmelden* (QR-Code mit dem iPhone) oder *Logincode* nehmen. Das Banner im Login-Fenster hat dafür einen Direktknopf.
2. **Paperless-Auth.** Nach dem SSO-Login liest die App `/api/profile/`. Hat das Profil einen API-Token, wird er in den Schlüsselbund übernommen, sonst reicht das Paperless-Session-Cookie zum Lesen. Importe, Bearbeiten und der Push-Workflow brauchen den Token (Paperless prüft ihn vor der Session, also ohne CSRF).
3. **Alternative ohne Browser:** In den Einstellungen lässt sich ein Pangolin Access Token (Resource → Share Link) eintragen. Die App schickt ihn als `P-Access-Token-Id`/`P-Access-Token`-Header mit, das sind die Standardnamen aus Pangolins `resource_access_token_headers`.

Läuft die Pangolin-Session ab, öffnet sich das Login-Fenster von selbst wieder. Solange sie abgelaufen ist, lädt die App keine Vorschaubilder und fragt nicht nach neuen Dokumenten: Jede Anfrage wäre ein 401, und CrowdSec wertet solche Serien als Angriff.

Die App löscht nichts per `DELETE`: Das CrowdSec-Plugin auf dem Pangolin-Stack blockt bodylose DELETEs über HTTP/3.

## Bedienung

Bewusst minimalistisch, nach dem Vorbild von Papers: ein Fenster ohne Seitenleiste, die Dokumente in ihrem echten Seitenverhältnis. Ab macOS 26 mit Liquid Glass (System-Toolbar, Glas-Suchfeld, weicher Scroll-Rand), auf älteren Systemen mit den bisherigen Materialien.

| | |
|---|---|
| Klick, ⌘-Klick, ⇧-Klick, ⌘A | auswählen, zur Auswahl hinzufügen, Bereich, alles |
| Doppelklick, Leertaste, ↩, ⌘↓ | lesen (im selben Fenster) |
| Esc, ⌘↑ | Lesemodus schließen, Auswahl aufheben |
| ← → ↑ ↓ | durchs Raster wandern, im Lesemodus ← → zum vorigen/nächsten Dokument |
| ⌘I | Informationen: Titel, Datum, Korrespondent, Typ und Tags bearbeiten (⌘S sichert) |
| ⇧⌘I | Eingang anzeigen |
| ⌘↩ | im Eingang: Änderungen sichern, Eingangs-Tags entfernen, weiter zum nächsten |
| ⌘F | suchen |
| ⌘+ / ⌘− / ⌘0 | Dokumente größer, kleiner, Ansicht zurücksetzen |
| ⌘O, Dateien aufs Fenster ziehen | importieren |
| Dokument aus dem Fenster ziehen | Originaldatei in Finder, Mail usw. ablegen |
| ⇧⌘S / ⌘E | Auswahl teilen / exportieren (Originaldateien) |
| ⇧⌘O | in Paperless öffnen |
| ⌘R | neu laden |

**Suche.** Freitext geht an den Volltextindex von Paperless. Filter tippt man direkt ins Suchfeld: `#Steuer` (Tag), `@Obi` (Korrespondent), `typ:Rechnung` (Dokumenttyp). Namen mit Leerzeichen in Anführungszeichen: `#"Haus und Garten"`. Unter dem Feld erscheinen passende Vorschläge; abgeschlossene Filter werden zu Tokens. Mehrere Tags müssen alle passen, mehrere Korrespondenten oder Typen gelten als „oder“. Sortiert wird über Darstellung → Sortieren nach (Dokumentdatum oder Hinzugefügt).

**Importe.** Nach dem Hochladen verfolgt die App den Paperless-Task. In der Toolbar zeigt ein Knopf laufende und fehlgeschlagene Importe, samt Meldung von Paperless (z. B. Duplikat). Dateien werden gestreamt, nicht komplett in den Speicher geladen.

## Mitteilungen

- **Auf dem Mac:** Ablage fragt Paperless regelmäßig (Standard: alle 2 Minuten) nach neuen Dokumenten und meldet sie mit Vorschaubild. Ein Klick öffnet das Dokument. Selbst importierte Dokumente meldet der Import, nicht der Watcher.
- **Menüleiste:** Das Symbol zeigt die neuesten Dokumente und schnelle Aktionen. Mit Symbol läuft Ablage nach dem Schließen des Fensters weiter; auf Wunsch ohne Dock-Symbol und mit Start beim Anmelden.
- **Aufs iPhone (ntfy):** Einstellungen → Mitteilungen legt in Paperless den Workflow „Ablage: Push bei neuem Dokument“ an (Trigger „Dokument hinzugefügt“, Webhook an ntfy). Ab Paperless 2.16 wird als JSON an die ntfy-Wurzel gesendet, damit Titel, Korrespondent und ein Link zum Dokument ankommen; ältere Versionen bekommen Klartext an das Thema. Deaktivieren schaltet den Workflow per PATCH ab. Wer das Thema kennt, liest mit.

## Offline und Spotlight

Ablage gleicht alle 15 Minuten (und nach neuen Dokumenten) eine lokale Kopie ab: Titel, Text (bis 50 000 Zeichen je Dokument) und Vorschaubilder aller Dokumente, dazu die 150 zuletzt geöffneten Vorschauen. Einmal täglich ein vollständiger Abgleich, der auch Gelöschtes entfernt. Liegt unter `~/Library/Caches/de.max-venz.ablage/<host>/`.

- Ohne Verbindung zeigt die App die lokale Kopie, sucht darin und öffnet bereits geöffnete Dokumente.
- Die Dokumente werden an Spotlight gemeldet. Ein Treffer öffnet sie in Ablage (auch als Link `ablage://document/<id>`).
- Einstellungen → Bibliothek zeigt den belegten Speicher, gleicht sofort ab oder löscht die Kopie.

## Protokoll

Fehler landen im macOS-Log:

```sh
log stream --predicate 'subsystem == "de.max-venz.ablage"' --level info
```
