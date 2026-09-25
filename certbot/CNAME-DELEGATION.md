# ACME DNS-01 Challenge Delegation via CNAME

This document describes a technique for automating ACME DNS-01 certificate issuance with a
public CA for domains whose authoritative DNS zone cannot be directly automated — by delegating
the challenge validation to a separate, API-accessible DNS zone using a permanent CNAME record.

---

## The Problem: Automating DNS-01 Across Zone Boundaries

The ACME DNS-01 challenge requires placing a temporary TXT record at `_acme-challenge.www.example.com`
to prove domain ownership. This is straightforward when the authoritative DNS zone supports a
programmable API.

But what if the domain's primary DNS zone is managed by a provider that:

- offers no automation-friendly API,
- is controlled by a third party (registrar, enterprise DNS team),
- must not receive broad write access for security or compliance reasons, or
- belongs to a completely separate organization?

In these cases the standard approach — "let certbot write directly to the DNS zone" — is not
possible or not acceptable. The CNAME delegation technique solves this without requiring any
changes to the primary zone after initial setup.

---

## The Solution: CNAME Delegation

The ACME validator follows CNAME chains. If `_acme-challenge.example.com` is a CNAME pointing
to another name, the validator resolves the chain and looks for the TXT record at the final
target.

This means you can:

1. Add a **one-time, static CNAME** in the primary zone (done once by whoever controls it).
2. Let an **automated hook** create and delete TXT records in a dedicated, API-accessible challenge zone.
3. Renew certificates indefinitely **without ever touching the primary zone again**.

### DNS Setup (One-Time, Manual)

In the **primary zone** (the zone that is authoritative for your domain), add a CNAME:

```
_acme-challenge.www.example.com.  IN  CNAME  _acme-challenge.www.example.com.challenge-service.com.
```

The CNAME target encodes the full subject name as a label prefix within the challenge zone.
This record is static and permanent. The primary zone owner only needs to do this once, ever.
All subsequent automation runs entirely against the challenge zone.

---

## How It Works During Certificate Issuance

```
┌──────────────────────────────────────────────────────────────────────────┐
│  ACME Server (public CA)                                                 │
│    1. Issues challenge: "prove ownership of www.example.com"             │
└─────────────────────────────────┬────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  Certbot (local machine)                                                 │
│    2. Calls auth-hook → creates TXT record in challenge zone:            │
│         name:  _acme-challenge.www.example.com.challenge-service.com.    │
│         type:  TXT                                                       │
│         value: <validation token>                                        │
│    3. Waits for DNS propagation, then signals certbot to proceed         │
└─────────────────────────────────┬────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  ACME Server queries _acme-challenge.www.example.com                     │
│    → primary zone returns CNAME                                          │
│      → _acme-challenge.www.example.com.challenge-service.com.            │
│    → challenge zone returns TXT → validation token found ✓               │
│    → certificate is issued                                               │
└─────────────────────────────────┬────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  Certbot calls cleanup-hook → deletes TXT record from challenge zone     │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Why Two DNS Zones?

| Zone      | Role                                       | Who controls it                        | API access required? |
|-----------|--------------------------------------------|----------------------------------------|----------------------|
| Primary   | Authoritative for your domain              | Domain owner / registrar / third party | No — set-and-forget  |
| Challenge | Hosts `_acme-challenge` TXT records only   | You                                    | Yes — full write     |

The primary zone is only ever touched to add the one-time CNAME. Everything else happens in
the challenge zone, which exists solely to serve `_acme-challenge` records.

---

## Implementation

The hooks implement certbot's `--manual-auth-hook` / `--manual-cleanup-hook` contract.
Certbot passes context via environment variables:

| Variable                       | Value                                             |
|--------------------------------|---------------------------------------------------|
| `CERTBOT_DOMAIN`               | Domain being validated, e.g. `www.example.com`    |
| `CERTBOT_VALIDATION`           | Token the ACME server expects to find             |
| `CERTBOT_REMAINING_CHALLENGES` | Challenges still pending (0 = last one)           |

### Auth Hook — creates the TXT record

Creates the following record in the challenge zone:

```
_acme-challenge.www.example.com.challenge-service.com.  IN  TXT  "<CERTBOT_VALIDATION>"
```

### Cleanup Hook — removes the TXT record

Deletes the following record from the challenge zone:

```
_acme-challenge.www.example.com.challenge-service.com.  IN  TXT  "<CERTBOT_VALIDATION>"
```

### Certbot Invocation

```bash
certbot certonly \
  --manual \
  --preferred-challenges dns \
  --manual-auth-hook   ./auth-hook.sh \
  --manual-cleanup-hook ./cleanup-hook.sh \
  -d www.example.com
```

---

## Key Benefits

**No permanent write access to the primary zone required.**
The CNAME is configured once; after that, the primary zone is never touched during renewals.
This is especially valuable when the primary zone is managed by a third party or by a team
with its own change-management process.

**Works with any primary DNS provider.**
Every DNS implementation supports CNAME records. The technique is completely agnostic to the
primary zone's provider, control panel, or API capabilities.

**Minimal blast radius.**
Automation credentials only have write access to the challenge zone — a purpose-built zone
whose sole function is hosting transient `_acme-challenge` records. Compromised credentials
cannot affect any real DNS records.

**Fully automated renewals.**
Once the CNAME is in place, `certbot renew` runs unattended, indefinitely. No human
intervention is required for subsequent renewals.

**Enables wildcard certificates.**
DNS-01 is the only ACME challenge type that supports wildcard certificates (`*.example.com`).
This delegation technique makes DNS-01 automation viable even when direct API access to the
primary zone is unavailable, unlocking wildcard issuance for otherwise inaccessible zones.
Note that a wildcard certificate requires its own CNAME in the primary zone:
`_acme-challenge.example.com. IN CNAME _acme-challenge.example.com.challenge-service.com.`
