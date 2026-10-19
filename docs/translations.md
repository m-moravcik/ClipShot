# Translations

ClipShot ships in English, Slovak, Czech, German, Spanish and French. Every string lives in
`ClipShot/Resources/Localizable.xcstrings` (the English text is the key, defined in
`ClipShot/UI/Copy.swift`). The folder access prompts live in
`ClipShot/Resources/InfoPlist.xcstrings`.

## Review status

| Language | Status |
| --- | --- |
| en | Source |
| sk, cs, de | Written for the app; the author reviews them before release |
| es, fr | Machine-assisted; awaiting review by a native reader |

Until a native reader has checked Spanish and French, treat their wording as a draft. Name
the reviewer and the date here when that happens.

## Conventions

- Natural, concise UI copy rather than a literal translation. Informal address in sk, cs, de
  and es (as in the sibling apps); `vous` in fr.
- Product names (ClipShot, Finder, Homebrew) and keyboard symbols (⇧⌘4, ⌘V) stay as they are.
- macOS terms aim to match the system's own wording (check against macOS when reviewing): Trash is Kôš / Koš / Papierkorb / Papelera /
  Corbeille; the floating thumbnail is miniatúra / miniatura / Miniatur / miniatura / vignette.
- The retention feature reads as "cleanup" in every translation (Upratovanie, Úklid,
  Aufräumen, Limpieza, Nettoyage), which is how people talk about it.
- Counts use plural variations with every CLDR category of the language: one, few, many and
  other in sk and cs; one and other in de; one, many and other in es and fr. Where a verb has
  to agree with the count too, the string uses a second substitution on the same argument
  (for example `Do Koša by teraz %#@verb@ %#@count@`).
- Relative times, dates and sizes come from formatters (`Text(date, style: .relative)`,
  `ByteCountFormatStyle`), never from strings.
- Slovak and Czech keep a no-break space after a number and after one-letter words, so no
  line ends on them. French uses a no-break space before `:` `?` `!` and inside « ».
- No em dash anywhere.

## Checks

`make l10n` builds the app and fails when a language misses a key, when a plural (top level or
in any substitution) misses a category, when a value uses an undefined `%#@name@`, or when the
code uses a string the catalog lacks. It first runs a self-test on the broken catalogs in
`ClipShotTests/Fixtures/l10n/`, and `make test` runs the same fixtures through the script.
