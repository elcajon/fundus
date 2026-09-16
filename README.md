# Ablage

Eine native Mac-App für Paperless-ngx, inspiriert von [Papers](https://papersapp.info). Anders als Papers kommt sie auch an Paperless heran, wenn es hinter **Pangolin** (badger + SSO) veröffentlicht ist.

## Bauen

Xcode ist nicht nötig, die Command Line Tools reichen:

```sh
./build.sh
open build/Ablage.app
```

`build.sh` baut gegen das neueste macOS-26-SDK, weil im 27er-SDK `@State` ein Macro ist, dessen Plugin nur mit Xcode ausgeliefert wird. Das Ergebnis ist ad-hoc signiert. Zum Installieren nach `/Applications` ziehen.

## Wie die App durch Pangolin kommt

Pangolin beantwortet `/api/*` ohne Session mit `401 Unauthorized` (text/plain), bevor Paperless die Anfrage überhaupt sieht. Die App regelt das so (Stand 0.1.0: bis zum Login-Fenster getestet, der Weg danach noch nicht end-to-end):

1. **SSO-Login im App-Fenster.** Beim Verbinden öffnet sich ein WebView mit dem Pangolin-Login. Nach der Anmeldung liegt das Resource-Cookie `p_session_token` im persistenten WebKit-Speicher. Die App kopiert es in ihre URLSession und nutzt es nach jedem Neustart wieder.
   - **Passkeys aus dem Schlüsselbund funktionieren in diesem Fenster nicht.** macOS erlaubt WebAuthn in eingebetteten WebViews nur signierten Browsern mit Entitlement. In Pocket-ID deshalb *Alternative Anmeldemöglichkeiten → Mit einem anderen Gerät anmelden* (QR-Code mit dem iPhone) oder *Logincode* nehmen. Das Banner im Login-Fenster hat dafür einen Direktknopf.
2. **Paperless-Auth.** Nach dem SSO-Login liest die App `/api/profile/`. Hat das Profil einen API-Token, wird er in den Schlüsselbund übernommen, sonst reicht das Paperless-Session-Cookie zum Lesen. Uploads brauchen den Token.
3. **Alternative ohne Browser:** In den Einstellungen lässt sich ein Pangolin Access Token (Resource → Share Link) eintragen. Die App schickt ihn als `P-Access-Token-Id`/`P-Access-Token`-Header mit, das sind die Standardnamen aus Pangolins `resource_access_token_headers`.

Läuft die Pangolin-Session ab, öffnet sich das Login-Fenster von selbst wieder.

## Bedienung

Bewusst minimalistisch, nach dem Vorbild von Papers: ein Fenster ohne Seitenleiste, die Dokumente in ihrem echten Seitenverhältnis.

| | |
|---|---|
| Klick | auswählen |
| Doppelklick, Leertaste, ↩ | lesen (im selben Fenster) |
| Esc | Lesemodus schließen, Auswahl aufheben |
| ← → ↑ ↓ | durchs Raster wandern, im Lesemodus ← → zum vorigen/nächsten Dokument |
| ⌘F | suchen (Volltext über Paperless, Vorschläge unter dem Feld, ↩ öffnet den ersten Treffer) |
| ⌘+ / ⌘− / ⌘0 | Dokumente größer, kleiner, Ansicht zurücksetzen |
| ⌘O, Dateien aufs Fenster ziehen | importieren |
| ⇧⌘S / ⌘E | ausgewähltes Dokument teilen / exportieren (Originaldatei) |
| ⌘R | neu laden |

In den Einstellungen (⌘,) lassen sich das Erscheinungsbild und die Infos unter den Dokumenten (Typ, Korrespondent, Tags) einstellen. Tokens liegen nur im Schlüsselbund.

Nicht enthalten (anders als Papers): Spotlight-Integration, Offline-Cache, lokaler Suchindex.
