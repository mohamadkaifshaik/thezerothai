# Shared profile text fixture (ADR-0024 D2, W3-22 L-2 and L-3)

Accepted and rejected vectors for the four free-text profile fields. The Go validators
(`backend/internal/identity/validate.go`, runner `profile_text_fixture_test.go`) and the Dart client rules
(`app/lib/features/profile/domain/profile_extras_rules.dart`, `app/lib/shared/format/profile_website.dart`) must give the
same answer on every row. Change a rule on one side and these files fail on the other, as `post_text_grammar.json` does
for post text. Backend-developer owns the Go side, frontend-developer the Dart side; edit the rules and the rows in the
same PR, and review changes like proto changes.

## Files

| File | Field | Rows |
|---|---|---|
| `location.json` | `Profile.location` | 11 accept, 17 reject |
| `website.json` | `Profile.website` | 30 accept, 80 reject |
| `display_name.json` | `Profile.display_name` | 9 accept, 16 reject |
| `bio.json` | `Profile.bio` | 11 accept, 13 reject |
| `single_line_text.json` | the shared one-line rules (display name, location, list name and description); Go only, Dart follow-up W5-48 | 9 accept, 25 reject |

## Schema

Every file is one JSON object. Every code point outside printable ASCII is written as a JSON backslash-u escape (a
non-BMP code point as a surrogate pair), so no invisible or right-to-left character is ever present in the file itself.
Do not write one raw when you add a row.

```
{
 "_comment": "free text, ignored",
 "field":    "location" | "website" | "display_name" | "bio",
 "accept":   [ { "name": "...", "raw": "...", "stored": "...", "host": "..." } ],
 "reject":   [ { "name": "...", "raw": "...", "why": "..." } ]
}
```

- `name`: what the row shows. Free text, for failure messages.
- `raw`: the text exactly as the user typed or pasted it, before any trimming.
- `accept[].stored`: the value the server persists (and returns) for that `raw`: trimmed, NFC-normalized (the website is
  not normalized), and for a website only the scheme lower-cased. `""` is a clear.
- `accept[].host` (`website.json` only): the lower-case ASCII host the client displays and opens (no port, no trailing
  dot, non-ASCII labels as `xn--` punycode); `""` for a clear.
- `reject[].why`: the rule that must refuse the row. Documentation only; runners do not compare it.

A runner passes when, for every `accept` row, the field is valid and its normalised form equals `stored` (and its host
equals `host`), and for every `reject` row the field is invalid. It must also fail when it ran fewer rows than the file
holds: count the `"raw":` keys in the file text and compare with the decoded rows, as the Go runner does. Keep invalid
UTF-8 and lone surrogates out of these files (Go and Dart decode them differently); Go-only unit tests cover them.

## Rules

Common to all four fields:

- **Trim** first: remove Unicode `White_Space` plus U+FEFF from both ends (Dart `String.trim`; Go
  `unicode.IsSpace` plus U+FEFF). A trailing U+2028 is therefore trimmed, not refused; an interior one is refused.
- **NFC** second (location, display name, bio; not the website).
- **Count code points** (Dart `runes`, Go runes), after trim and NFC. An emoji counts once.
- **Control** means category Cc: U+0000-U+001F and U+007F-U+009F (a newline included, U+0085 included).
- **Bidi formatting controls** are U+202A-U+202E and U+2066-U+2069 (the post text rules, ADR-0010 D9).
- **Line separators** are U+2028 and U+2029 (categories Zl and Zp).
- The rules apply to a value being written. Nothing validates a stored value on read and nothing migrates one.

| Field | Valid when |
|---|---|
| `display_name` | 1 to 50 code points; no control, line separator or bidi formatting control |
| `bio` | 0 to 160 code points; no control other than U+000A (LF), no line separator, no bidi formatting control. CR is refused, not folded |
| `location` | 0 to 30 code points; no control (so one line), no line separator, no bidi formatting control |
| `website` | see below; empty is a clear |

### Website

After trim, the text must satisfy all of:

1. At most 100 code points. No whitespace (`\s`, which includes U+FEFF, U+00A0, U+2028, U+3000), no control, and none of
   U+061C, U+200E, U+200F, U+202A-U+202E, U+2066-U+2069, anywhere in the text.
2. It starts with `http://` or `https://`, scheme in any case. Only the scheme is lower-cased in the stored value.
3. The authority is everything after `://` up to the first `/`, `?` or `#`. It contains no `@` (no userinfo) and no `[`
   (no IPv6 literal). Path, query and fragment are not inspected further (a `%`, `\`, `@`, `[` or `:` is allowed there).
4. An optional port follows the LAST `:` of the authority: ASCII digits only, value 1 to 65535, leading zeros allowed.
   An empty port (`host:`) is allowed. `+80` and `0x50` are refused (Dart `int.tryParse` would accept them).
5. The host (the rest of the authority) is lower-cased, then ONE trailing dot is dropped. Every label must be non-empty.
   A label with a non-ASCII code point is encoded as `xn--` + RFC 3492 punycode of the label as typed (no NFC, no NFKC
   mapping). Every encoded label is at most 63 characters of `[a-z0-9_-]`. A `%`, `\` or any other character in the host
   fails this.
6. W3-22 L-3, new on both sides: the host has at least two labels; its last label is TLD-shaped, `[a-z]{2,63}` or
   `xn--[a-z0-9-]+`; and the host is not `localhost`, `local`, `internal` or `home.arpa` nor a subdomain of one. A
   TLD-shaped last label is also what refuses IPv4 literals in dotted, decimal and hex forms.

The Dart runner is `app/test/features/profile/domain/profile_text_fixture_test.dart`: it runs every row through the
functions the Edit profile screen uses (`websiteIssue`, `locationIssue`, `displayNameIssue`, `bioIssue`) and compares the
stored form and the host. `parseProfileWebsite` implements rules 1 to 6 and has no length limit on purpose (it also
shows websites stored before the limit existed); `websiteIssue` adds the 100 code point limit for a value being written.
