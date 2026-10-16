-- Esempio di sola lettura: esegue soltanto status.
-- I comandi che modificano la libreria sono commentati.
tell application "SuperSnippetto"
    status
    -- disable
    -- enable
    -- expand ";firma"
    -- import {"/percorso/primo.json", "/percorso/secondo.csv"}
    -- delete "UUID-DEL-FRAMMENTO"
end tell
