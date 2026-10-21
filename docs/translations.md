# Translations

ClipShot ships in English, Slovak, Czech, German, Spanish and French. Every string lives in
`ClipShot/Resources/Localizable.xcstrings` (the English text is the key, defined in
`ClipShot/UI/Copy.swift`, or for the Shortcuts actions' titles in `ClipShot/Intents/`). The
folder access prompts live in `ClipShot/Resources/InfoPlist.xcstrings`, the Siri and
Spotlight phrases in `ClipShot/Resources/AppShortcuts.xcstrings`.

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
  Corbeille; the floating thumbnail is miniatúra / miniatura / Miniatur / miniatura / vignette;
  the menu bar is lišta / řádek nabídek / Menüleiste / barra de menús / barre des menus, as
  macOS writes it ("Zobraziť v lište", "Přidat do řádku nabídek"), never "lišta menu" in sk
  or "lišta" in cs.
  Markup is Anotácie / Anotace in sk and cs, as Preview names it there ("Zobraziť panel
  anotácií", "Zobrazit anotační nástroje"), so "Upraviť v anotáciách" / "Upravit v anotacích";
  Markierungen / Marcación / Annoter in de, es, fr.
- Focus is režim Môjho času / režim soustředění / Fokus / modo de concentración / mode de
  concentration, as System Settings writes it ("keď je zapnutý režim Môjho času", "wenn ein
  Fokus aktiviert ist"). Shortcuts action titles follow the Shortcuts app's verbs: Získať,
  Načíst, abrufen, Obtener, Obtenir (as in "Get Latest Screenshots").
- Siri phrases (AppShortcuts.xcstrings) keep `${applicationName}` and use plain spaces.
  Imperative, informal in sk, cs, de and es; the infinitive in fr, which avoids both tu and
  vous. Slovak and Czech name the app as "v aplikácii ClipShot" / "v aplikaci ClipShot", so
  it is never declined.
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
- Quotation marks around a folder name follow the language as macOS writes it: “ ” in
  en and es, „ “ in sk, cs and de, « » with no-break spaces in fr. No spaces inside the
  marks except in French.
- Commands and paths (`clipshot`, `clipshot latest`, `/usr/local/bin`, a path argument) are
  Markdown code spans in the strings, drawn in the monospaced font: keep the backticks
  around them wherever the sentence puts them.
- No em dash anywhere.

## Checks

`make l10n` builds the app and fails when a language misses a key, when a plural (top level or
in any substitution) misses a category, when a value uses an undefined `%#@name@`, when any
value or variant is empty or not in state `translated`, or when the code uses a string the
catalog lacks. It first runs a self-test on the broken catalogs in
`ClipShotTests/Fixtures/l10n/`, and `make test` runs the same fixtures through the script.
