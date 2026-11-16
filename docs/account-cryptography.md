# Account cryptography, explained simply

[Documentation](readme.md) · [Project overview](../README.md)

The three crypto settings under `[account]` in [etc/config.ini](../etc/config.ini)
work together like **a locked box, a secret stamp, and a site-specific ingredient**.
The site passes them to `web-user`, which manages accounts and sessions.

## `aead_keyset`: the key to a locked box

It encrypts information the application needs to read later: email addresses,
names, and MFA secrets. It also encrypts the stored bcrypt password hashes; the
original passwords are never stored.

Think: "Lock Alice's email away, and unlock it when we need to send her mail."

[AEAD](https://developers.google.com/tink/aead), or authenticated encryption with
associated data, also detects tampering. The account code attaches context, such
as the site, account ID, and field, so copying Alice's encrypted value into Bob's
record will not successfully decrypt there. This project generates an
**AES-256-GCM** keyset.

## `mac_keyset`: a secret stamp for checking things

It produces a small authentication tag from a value. The application can check
that tag later using its secret key. A [MAC](https://developers.google.com/tink/mac),
or message authentication code, does **not encrypt the value**, and there is no
"decrypt this tag" operation.

Think: "Keep a secret fingerprint of this login token, so we can recognize it
when it comes back."

The account code uses it for session tokens, verification/reset codes, CSRF
protection, and email lookup identifiers. It includes the site and purpose in
the calculation, keeping those uses separate. This project generates an
**HMAC-SHA256** keyset.

## `email_hash_salt`: an extra ingredient in email fingerprints

The application needs to find Alice's account when she types her email, even
though the stored email is encrypted.

It trims and lowercases the submitted address, combines it with this salt, and
uses `mac_keyset` to calculate a repeatable lookup identifier. The database
searches for that identifier.

Think: "Alice's address always produces the same filing label for this site."

This salt is **one persistent random value per site**, shared across its accounts
and workers. It is separate from bcrypt's per-password salts. It adds
site-specific variation; the MAC key supplies the secret-key protection. The
[account key generator](../bin/generate-account-keys.tcl) uses 32 random bytes,
encoded as hex.

The email therefore has **two stored representations**: an encrypted address for
reading and sending, and a MAC-derived label for searching.

## Keep all three values persistent

Both `*_keyset` settings contain Tink keyset JSON, including secret key material.
Keep all three values in private configuration, outside the repository, and reuse
them across workers and restarts.

Losing the AEAD keys makes existing encrypted data unreadable. Changing the MAC
key or email salt breaks existing email lookups unless you migrate them. The MAC
key also affects existing sessions and codes. Preserve these values when
restoring the account database.
