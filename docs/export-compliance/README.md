# U.S. Export Compliance (App Store)

SnapSiphon encrypts user photo backups client-side using its own implementation
of the age format (X25519, ChaCha20-Poly1305, HKDF-SHA256 — all standard IETF
algorithms, built on Apple CryptoKit). Under the U.S. Export Administration
Regulations this is **mass-market encryption software, self-classified as
ECCN 5D992.c** — no export license is required, but an annual self-classification
report must be emailed to the U.S. government.

Distributing through the App Store counts as an export from the U.S. (Apple's
servers), so this applies even though the developer is in Canada.

## What's in this folder

- `self-classification-report.csv` — the report in the format required by
  Supplement No. 8 to Part 742 of the EAR. Fill in the phone number and mailing
  address placeholders before sending.

## Annual filing (once per year, by February 1)

Covers any calendar year in which the app was distributed. Send **one email**
with the CSV attached:

- **To:** crypt@bis.doc.gov
- **Cc:** enc@nsa.gov
- **Subject:** `Self-classification report — Stray Bits / Jeff Clement — [YEAR]`
- **Body:**

  > Please find attached the annual self-classification report for encryption
  > items, submitted pursuant to Sections 740.17(e)(3) and 742.15(c) of the
  > Export Administration Regulations (Supplement No. 8 to Part 742).
  >
  > Submitter: Jeff Clement (Stray Bits)
  > Reporting period: calendar year [YEAR]
  >
  > Product: SnapSiphon (iOS app, ca.straybits.snapsiphon), self-classified
  > ECCN 5D992.c, mass market. The app performs client-side encryption of user
  > photo backups using standard published algorithms (X25519, ChaCha20-Poly1305,
  > HKDF-SHA256) via Apple CryptoKit.

No confirmation is required from BIS; keep a copy of the sent email as your
record. The report is only needed for years in which the classification list
changed or the app was newly distributed — in practice, just send it every
January.

## App Store Connect questionnaire answers

App Store Connect → your app → App Information → App Encryption Documentation
(or when prompted at build submission):

1. **Is your app designed to use cryptography or does it contain or incorporate
   cryptography?** — **Yes** (age encryption of backups, plus TLS).
2. **Does your app qualify for any of the exemptions provided in Category 5,
   Part 2 of the U.S. Export Administration Regulations?** — **No.**
   (Encrypting user data for confidentiality is not one of the listed exempt
   uses like authentication-only or medical.)
3. **Does your app implement any encryption algorithms that are proprietary or
   not accepted as standards?** — **No.** All algorithms are IETF standards
   (RFC 7748, RFC 8439, RFC 5869).
4. When asked about compliance obligations, confirm you submit the annual
   self-classification report (this folder).

`ITSAppUsesNonExemptEncryption` is set to `true` in Info.plist, which matches
these answers; once the questionnaire is saved in App Information, uploads
won't be blocked on the compliance question.

## EU / DSA / France — decision (July 2026): not distributing in the EU

To avoid the DSA "trader" requirements (publicly displayed address + phone on
the EU product page) and the France/ANSSI encryption declaration, SnapSiphon
is not distributed in EU countries.

In App Store Connect:

1. Business (or the app's Distribution section) → Digital Services Act →
   select **"I'm not a trader under the DSA or I don't plan to distribute in
   the EU."**
2. App → Pricing and Availability → edit country/region availability →
   deselect all EU member states. (UK, Switzerland, and Norway are not EU and
   can stay selected.)

This is fully reversible: to sell in the EU later, get a displayable business
address (virtual mailbox, ~CA$10/month, e.g. PostScan Mail Calgary), switch to
trader status, re-add the EU territories, and file the ANSSI declaration for
France.
