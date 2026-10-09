# ComponentVault: pubblicazione su App Store

Un'unica app universale: lo stesso bundle `it.michelebigi.ComponentVault` per iPad (iPadOS 17+) e Mac (macOS 14+). Su App Store Connect va creata come app **iPadOS + macOS**.

## Già pronto nel progetto

| Voce | Stato |
|------|-------|
| Versione | `MARKETING_VERSION 1.0.0`, build `CURRENT_PROJECT_VERSION 1` |
| Sandbox Mac | solo `user-selected.read-write`, `bookmarks.app-scope` e rete in uscita. Rimossa l'eccezione su `/Users/michelebigi/LCSC/`, che l'App Store non accetta |
| Cartella | una sola, scelta con il selettore di sistema e ricordata con un bookmark security-scoped |
| Privacy manifest | `ComponentVault/PrivacyInfo.xcprivacy`: nessun tracciamento né dato raccolto; API: UserDefaults `CA92.1`, timestamp file `C617.1` e `3B52.1` |
| Fotocamera | `NSCameraUsageDescription` in italiano e inglese (`InfoPlist.xcstrings`) |
| Lingue | italiano (sorgente) e inglese (`Localizable.xcstrings`, 560 stringhe). Le altre lingue usano l'inglese |
| File iPad | `UIFileSharingEnabled` e `LSSupportsOpeningDocumentsInPlace`: la cartella locale `LCSC` è visibile nell'app File |
| Icona | 1024×1024 senza trasparenza, set Mac completo |
| iPad | tutte le orientazioni (multitasking e Stage Manager) |
| Server | eliminato: niente backend da tenere online per la revisione |
| Archive | `xcodebuild archive` Release riuscito per iOS e macOS |
| Crittografia | solo HTTPS del sistema, `ITSAppUsesNonExemptEncryption = NO` |
| Servizi di terzi | solo API ufficiali (Mouser, DigiKey, Nexar) con chiavi dell'utente nel Portachiavi; niente scraping né immagini da siti senza autorizzazione |

## Da fare (decisioni tue)

1. **Crittografia (export compliance): risolta.** L'app usa solo HTTPS del sistema. Ho rimosso SM2 e la ricerca live sull'API web di LCSC. `ITSAppUsesNonExemptEncryption = NO` è impostato: niente documenti da allegare.
2. **Email di supporto.** Sostituisci `SUPPORT_EMAIL` in `Web/privacy.html` e `Web/support.html`.
3. **Pubblica le pagine statiche** di `Web/` su un sito HTTPS (GitHub Pages, michelebigi.it…). Su App Store Connect servono:
   - Privacy Policy URL → `privacy.html`
   - Support URL → `support.html`
4. **Categoria.** Ora è `public.app-category.utilities`. In alternativa: Developer Tools o Productivity.
5. **Screenshot.**
   - iPad 13" (2064×2752 o 2752×2064)
   - Mac (2880×1800 o 1280×800)
   - in italiano e inglese: inventario, scheda componente, progetto a checklist, carico da etichetta, libreria KiCad.
6. **Privacy "nutrition label"** su App Store Connect: *Data Not Collected*.
7. **Età**: 4+. **Prezzo**: a scelta.

## Note per la revisione (App Review)

> ComponentVault is an inventory for electronic components. It needs no account or server.
> To try it: Inventory → Import CSV (sample CSV attached) or Inventory → Load from Label and type an LCSC code such as C25804, then tap "Use" and "Add to Inventory" (part details come from lcsc.com).
> Settings → Folder lets the user pick any folder (e.g. iCloud Drive) to share configuration and data between their own devices. The KiCad requests in that folder are handled by an optional script on the user's Mac.
> The camera is used only on the "Load from Label" screen to read barcodes on component bags.

Allega un CSV di prova, ad esempio:

```
Codice (LCSC);MPN;Descrizione;Footprint;Quantità
C25804;0603WAF1002T5E;10kΩ 0603 resistor;0603;100
C14663;CL10B104KB8NNNC;100nF 0603 capacitor;0603;200
```

## Pubblicazione

Pubblicazione da Xcode: Product → Archive → Distribute App → App Store Connect, una volta con destinazione "Any iOS Device" e una con "My Mac". In alternativa da terminale:

```bash
xcodebuild archive -project ComponentVault.xcodeproj -scheme ComponentVault \
  -destination 'generic/platform=iOS' -archivePath build/ComponentVault-iOS.xcarchive
xcodebuild -exportArchive -archivePath build/ComponentVault-iOS.xcarchive \
  -exportOptionsPlist AppStore/ExportOptions.plist -exportPath build/export-ios
```

I testi della scheda sono in [`metadata-it.md`](metadata-it.md) e [`metadata-en.md`](metadata-en.md).
