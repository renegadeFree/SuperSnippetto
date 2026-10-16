# SuperSnippetto

<img src="Resources/AppIcon.png" width="160" alt="Icona SuperSnippetto: frammento di testo con fulmine">

Espansore di testo nativo per macOS, scritto in Swift con SwiftUI e AppKit. Implementazione indipendente in sviluppo: la parità completa con l'app di riferimento non è ancora raggiunta.

## Compilazione

Richiede un Mac Apple Silicon con macOS 13 o successivo e i Command Line Tools Apple.

```sh
./build.sh
open SuperSnippetto.app
```

La build usa una firma ad hoc locale. L'icona macOS è già inclusa; per rigenerarla dal PNG originale:

```sh
./make-icon.sh
```

La prima volta concedi personalmente Accessibilità e Monitoraggio input dalle Impostazioni di Sistema. Questi permessi servono per l'espansione nelle altre app. L'anteprima locale dei campi non li richiede.

## Funzioni disponibili

- Libreria di frammenti e raccolte, ricerca, alias, menu e scorciatoie.
- Ricerca rapida con scorciatoia globale modificabile nelle impostazioni, chiusura con clic esterno o Esc.
- Testo, rich text, HTML, immagini locali e script con abilitazione esplicita.
- Campi, menu di scelta, checkbox, date, condizioni e trasformazioni.
- Backup, cestino recuperabile e sincronizzazione tramite cartella.
- Import/export JSON e CSV, import TextExpander testuale e import `.atext` parziale (LZ4 e vecchi archivi Apple NSKeyedArchiver).
- Dizionario AppleScript; esempio di sola lettura in `Automazione.applescript`.

Le esportazioni `aTextData.json` con gruppi a chiavi numeriche sono riconosciute automaticamente. Le variabili data legacy `【date:full locale:it】` e gli stili full/long/medium/short vengono convertiti. Gli archivi Apple sono letti come dati, senza istanziare le classi archiviate.

Gli elementi `.atext` importati usano l'attivazione manuale. Script, regole o macro non convertibili restano disattivati con avvisi e metadati originali conservati. Nessuna gestione di archivi protetti o rimozione di licenze/protezioni. Nessun codice, asset o archivio dell'app analizzata è incluso nella repository.

## Dati esistenti

Il nome visualizzato e il bundle sono **SuperSnippetto** (`it.local.SuperSnippetto`). Per conservare la libreria già creata prima della rinomina, la cartella dati resta:

```text
~/Library/Application Support/EspansoLocale/library.json
```

Restano compatibili anche gli identificatori interni dei documenti e il file di sincronizzazione `EspansoLocale.sync.json`. Non occorre spostare manualmente i dati. Prima di modificare la libreria, esportane una copia JSON. Tutti i Mac sincronizzati devono usare una versione che conservi alias e metadati (0.3 o successiva).

## Verifiche

```sh
./test.sh
```

586 controlli locali su libreria, modelli, script, automazione, sincronizzazione, decoder LZ4 e importazione/conversione aText. I test usano dati sintetici e temporanei. `NSFileCoordinator` richiede l'accesso al servizio macOS e può non funzionare dentro sandbox di esecuzione esterni.

La scorciatoia predefinita della ricerca è ⌃⌥Spazio: cambiala da Impostazioni > Ricerca rapida > Modifica, oppure usa Ripristina. Le combinazioni già assegnate ai frammenti o occupate nel sistema vengono segnalate; la preferenza resta locale al Mac. La ricerca usa la registrazione nativa delle scorciatoie e non richiede i permessi per l’espansione.

Build, firma e interfaccia sono verificate sul Mac locale. L'espansione globale e le scorciatoie nelle altre app richiedono ancora collaudo dopo i consensi macOS dell'utente; la sincronizzazione non è ancora collaudata fra due Mac fisici con un provider cloud reale.

L'icona è originale, generata con il tool image_gen integrato; prompt e procedura sono in `Resources/AppIcon.prompt.txt`. La repository contiene sorgenti, test, icona ed esempi originali. Build compilate, dati personali e intermedi di analisi restano esclusi da Git.

Vedi `LEGGIMI.txt` per sintassi e uso, e `Collaudo.txt` per il dettaglio delle verifiche.
