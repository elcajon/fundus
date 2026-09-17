# Fundus

Eine native Mac-App für Paperless-ngx, inspiriert von [Papers](https://papersapp.info). Sie funktioniert mit einer normalen Paperless-Anmeldung und kommt zusätzlich an Instanzen heran, die hinter **Pangolin** (badger + SSO) stehen.

Der Bundle-Identifier bleibt aus Gründen der Kompatibilität `de.max-venz.ablage`; daran hängen Schlüsselbund-Freigabe, Einstellungen, Anmeldeobjekt und der Cache-Ordner. Das URL-Schema `ablage://` funktioniert weiterhin, `fundus://` ebenso.

## Bauen und testen

Voraussetzung ist macOS 15. Xcode ist nicht nötig, die Command Line Tools reichen:

```sh
./test.sh
./build.sh
open build/Fundus.app
```

- `build.sh` baut gegen das neueste macOS-26-SDK, weil im 27er-SDK `@State` ein Macro ist, dessen Plugin nur mit Xcode ausgeliefert wird (die Liquid-Glass-APIs sind in beiden SDKs identisch). Danach trägt es mit `vtool` die echte SDK-Version ins Binary ein: SwiftPM schreibt dort sonst die Mindestversion 15.0 hinein, und macOS zeigt die App dann im alten Design ohne Liquid Glass.
- Das Icon (hell und dunkel) und das Menüleisten-Symbol rendert `scripts/make-icon.swift` bei jedem Build. Eine `.icns`-Datei kennt keine Hell-/Dunkel-Varianten, das kann nur Apples Icon Composer. Fundus tauscht deshalb zur Laufzeit sein Dock-Symbol, wenn das System dunkel ist; im Finder und im DMG erscheint die helle Fassung.
- Signiert wird mit Hardened Runtime und einem selbst erzeugten Zertifikat aus einem eigenen Schlüsselbund unter `.signing/` (nicht im Repo). Der Login-Schlüsselbund bleibt unberührt. Ohne Apple-Entwicklerzertifikat bindet macOS „Immer erlauben“ beim Schlüsselbund-Zugriff trotzdem an den einzelnen Build: Nach jedem Neubau fragt es einmal nach dem Passwort.
- `test.sh` führt die Tests (Swift Testing) aus und gibt den Pfad zum Macro-Plugin mit, den die Command Line Tools sonst nicht finden.
- Beide Skripte prüfen über `scripts/make-strings.py`, dass jeder sichtbare Text eine englische Übersetzung hat (`scripts/translations_en.py`). Deutsch ist die Entwicklungssprache.

Zum Installieren nach `/Applications` ziehen (nötig für „Beim Anmelden starten“).

## Wie die App durch Pangolin kommt

Pangolin beantwortet `/api/*` ohne Session mit `401 Unauthorized` (text/plain), bevor Paperless die Anfrage überhaupt sieht.

1. **SSO-Login im App-Fenster.** Beim Verbinden öffnet sich ein WebView mit dem Pangolin-Login. Nach der Anmeldung liegt das Resource-Cookie `p_session_token` im persistenten WebKit-Speicher. Die App kopiert es in ihre URLSession und nutzt es nach jedem Neustart wieder.
   - **Passkeys aus dem Schlüsselbund funktionieren in diesem Fenster nicht.** macOS erlaubt WebAuthn in eingebetteten WebViews nur signierten Browsern mit Entitlement. In Pocket-ID deshalb *Alternative Anmeldemöglichkeiten → Mit einem anderen Gerät anmelden* (QR-Code mit dem iPhone) oder *Logincode* nehmen. Das Banner im Login-Fenster hat dafür einen Direktknopf.
2. **Ohne SSO:** Bei einer normalen Paperless-Instanz führt derselbe Weg zur Paperless-Anmeldeseite. Alternativ nimmt Einstellungen → Verbindung Benutzername und Passwort entgegen und holt darüber einen API-Token (`/api/token/`); gespeichert wird nur der Token.
3. **Paperless-Auth.** Nach dem SSO-Login liest die App `/api/profile/`. Hat das Profil einen API-Token, wird er in den Schlüsselbund übernommen, sonst reicht das Paperless-Session-Cookie zum Lesen. Importe und Bearbeiten brauchen den Token (Paperless prüft ihn vor der Session, also ohne CSRF).

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
| ⌘I | Informationen: Titel, Datum, Korrespondent, Typ, Tags und benutzerdefinierte Felder bearbeiten (⌘S sichert) |
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

**Schnellsuche.** ⌥⌘A öffnet aus jeder App ein schwebendes Suchfeld (wie Quick Access bei 1Password). Es sucht in der lokalen Kopie, versteht dieselben Filter wie das Suchfeld (`#Tag`, `@Absender`, `typ:`) und zeigt Treffer im Titel zuerst. ↑/↓ wählt, ↩ öffnet das Dokument in Fundus, Esc oder ein Klick daneben schließt. Abschaltbar unter Einstellungen → Allgemein.

**Benutzerdefinierte Felder.** Die Informationen zeigen zugewiesene Felder mit passendem Eingabeelement (Text, Zahl, Betrag mit Währung, Datum, Ja/Nein, Auswahl, Dokument-Verknüpfung). „Feld hinzufügen“ weist weitere Felder zu, der Minus-Knopf entfernt eines. Paperless ersetzt beim Sichern die komplette Feldliste, deshalb sendet die App sie nur, wenn sich daran etwas geändert hat und die Felder des Dokuments vollständig geladen sind. Neue Felder selbst legt man in Paperless an.

**Importe.** Nach dem Hochladen verfolgt die App den Paperless-Task. In der Toolbar zeigt ein Knopf laufende und fehlgeschlagene Importe, samt Meldung von Paperless (z. B. Duplikat). Dateien werden gestreamt, nicht komplett in den Speicher geladen.

## Mitteilungen

- **Auf dem Mac:** Fundus fragt Paperless regelmäßig (Standard: alle 2 Minuten) nach neuen Dokumenten und meldet sie mit Vorschaubild. Ein Klick öffnet das Dokument. Selbst importierte Dokumente meldet der Import, nicht der Watcher.
- **Menüleiste:** Das Symbol zeigt die neuesten Dokumente und schnelle Aktionen. Solange es aktiv ist, schließt ⌘Q nur die Fenster und blendet das Dock-Symbol aus; Fundus läuft in der Menüleiste weiter und meldet neue Dokumente. Beendet wird die App über „Fundus beenden“ im Menüleisten-Menü, „Fundus → Fundus vollständig beenden“, beim Abmelden oder über „Beenden“ im Dock. Das Fenster (und mit ihm das Dock-Symbol) kommt über das Symbol, einen Spotlight-Treffer, eine Mitteilung oder erneutes Öffnen der App zurück. Beim Anmelden startet eine kleine Hilfs-App im Paket (`Contents/Library/LoginItems/FundusLauncher.app`) Fundus still mit `--silent`: ohne Fenster und ohne Dock-Symbol, wie bei 1Password. Auf Wunsch läuft Fundus ganz ohne Dock-Symbol und startet ohne Fenster („Nur in der Menüleiste“).

## Offline und Spotlight

Fundus gleicht alle 15 Minuten (und nach neuen Dokumenten) eine lokale Kopie ab: Titel, Text (bis 50 000 Zeichen je Dokument) und Vorschaubilder aller Dokumente, dazu die 150 zuletzt geöffneten Vorschauen. Einmal täglich ein vollständiger Abgleich, der auch Gelöschtes entfernt. Liegt unter `~/Library/Caches/de.max-venz.ablage/<host>/`.

- Ohne Verbindung zeigt die App die lokale Kopie, sucht darin und öffnet bereits geöffnete Dokumente.
- Die Dokumente werden an Spotlight gemeldet (Einstellungen → Bibliothek zeigt, wie viele Spotlight kennt). Ein Treffer öffnet sie in Fundus (auch als Link `ablage://document/<id>`).
- Einstellungen → Bibliothek zeigt den belegten Speicher, gleicht sofort ab oder löscht die Kopie.

## Wie das hier entstanden ist

Fundus ist **vibe gecodet**: Geschrieben hat es praktisch vollständig ein KI-Agent (Claude Code) nach Zuruf, während ich gesteuert, jeden Build an meiner eigenen Paperless-Instanz ausprobiert und entschieden habe, was bleibt. Eine zeilenweise Durchsicht aller Änderungen durch einen Menschen gab es nicht.

Die App läuft hier täglich, die Tests sind grün und die heiklen Stellen habe ich von Hand geprüft. Trotzdem gilt: erst den Code lesen, bevor du sie auf ein Archiv loslässt, an dem dir etwas liegt, Sicherungen behalten und die eine oder andere Ecke erwarten.

## Protokoll

Fehler landen im macOS-Log:

```sh
log stream --predicate 'subsystem == "de.max-venz.ablage"' --level info
```
