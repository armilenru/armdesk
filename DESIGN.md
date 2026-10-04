# ArmDesk design rules

How the client is supposed to look, and how that is checked. The client and
www.armilen.ru belong to one business and share one visual language; where
the site has a rule, the client follows it at desktop density.

This file covers what the fork decides. Everything it does not mention is
upstream RustDesk as is.

## How a change is judged

- **Numbers, not impressions.** A layout is drawn on the stand
  (`flutter/test/stand/`) with the fonts of the platform it is for, and the
  positions of its parts are read off the render tree or off the picture.
  "Looks aligned" is not a result; "all three fields run from 64.0 to 556.0"
  is.
- **One place.** Colors, text sizes, button and field shapes live in
  `MyTheme` (`flutter/lib/common.dart`). A screen does not carry its own
  numbers for them.
- **The smallest diff.** Every upstream file the fork rewrites is a merge
  conflict at the next RustDesk release. The theme and shared widgets come
  first; a single screen is edited only for a real defect.

## Color

| Token | Value | Use |
|---|---|---|
| `MyTheme.accent` | `#047857` | primary buttons, focus, links (the site's green-700) |
| `MyTheme.accentBright` | `#10B981` | the ID, small accents (green-500) |
| `MyTheme.grayBg` | `#EFEFF2` | field and secondary button fill, light theme |
| `#24252B` | | the same fills, dark theme |
| `MyTheme.border` | `#CCCCCC` | hairlines |

## Text

The font is the platform's own: Segoe UI on Windows, Roboto on Linux and
Android, the system font on macOS. Sizes come from the theme's text styles,
light and dark alike:

| Style | Size | Line height | Use |
|---|---|---|---|
| `titleLarge` | 19 | font's own | dialog titles |
| `labelLarge` | 16 | font's own | button labels |
| `bodyMedium` | 14 | 1.25 | body text |
| `titleSmall` | 14 | font's own | small titles |
| `bodySmall` | 12 | 1.25 | captions, counters |

Letter spacing is the font's own everywhere.

## Dialogs

- Corner radius 18, a 1 px border, padding 24 on every side
  (`MyTheme.dialogPadding`).
- Buttons stand at the bottom right, the secondary one first, 12 apart.

## Forms

Decided 2026-10-04: **the label lives inside the field.**

- A field takes the full width of its dialog. Fields of one form begin and end
  on the same lines in every language.
- No label column. A column `minWidth` wide is a minimum, not a width: a longer
  label pushed its own field to the right, and a character counter under a
  field pulled that field's label off its center line.
- **The label rises inside the field, never onto its frame.** Empty, the field
  shows the label where the text will go; with text or the focus, the label
  sits small at the top of the field, as `.field-float` does on the site. The
  desktop theme frames fields with an outline, and on an outline a label
  climbs onto the frame, so every labeled field of the desktop takes
  `border: MyTheme.insideLabelBorder` and
  `contentPadding: MyTheme.insideLabelPadding`. On a phone both are null: its
  underlined fields already keep the label inside.
- A labeled field is 53 high, a field without a label 45; both keep the same
  frame and radius. A field without a label is not touched.
- A required field marks its label with a red asterisk.
- A hint is an icon with a tooltip inside the field on the desktop and a line
  under the field on a phone.
- Use `FormTextField` (`flutter/lib/common/widgets/form_text_field.dart`), or
  upstream's `DialogTextField` where the field never needs to be disabled.
- Fields are 8 apart.

## Buttons

- Desktop height 28, corner radius 8: the site's ratio of radius to height,
  about 0.30.
- **A label is centered on its capitals, not on its line box.** Segoe UI sets
  capitals 0.88 px low, so on Windows a button has two pixels more padding
  below than above (`MyTheme.buttonPadding`); the capitals end up 0.12 px from
  the center. Roboto is within a quarter of a pixel and gets nothing. macOS has
  not been measured.

## Not decided yet

- Field radius: fields keep 8, while the site's scale gives a 45 px control 12
  and a 53 px one 16. Changing it touches every field of the client.
- Motion: durations and curves have not been audited.
- Icons: sizes and weights have not been audited.
- macOS: the exact look can only be checked on a built client.

## The stand

```sh
cd flutter
ARMDESK_STAND_OUT=/some/dir flutter test --update-goldens test/stand/proxy_dialog_stand.dart
ARMDESK_STAND_OUT=/some/dir flutter test --update-goldens test/stand/buttons_stand.dart
ARMDESK_STAND_PLATFORM=linux ARMDESK_STAND_OUT=/some/dir flutter test --update-goldens test/stand/buttons_stand.dart
```

It needs Segoe UI: `ARMDESK_STAND_FONTS` points at the folder, under WSL that
is `/mnt/c/Windows/Fonts` by default. Without the fonts it is skipped. The
tests in `flutter/test/` that guard these rules need no fonts.
