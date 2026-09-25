# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Operational scripts for certificate lifecycle management with DigiCert ONE Trust Lifecycle Manager (TLM): issuing certificates via ACME and EST, delivering them through the DigiCert ONE agent, and inspecting the result. Everything is shell, PowerShell, batch and static HTML. There is no build system, no test suite and no package manager.

## Rules for this repository

- **It is meant to be public.** No secrets, no identifiers such as GUIDs (TLM account, profile, agent or script IDs), no personal data (email addresses, user names, absolute home paths) in any file. Not even in comments or examples.
- **Parameters and secrets live in a git-ignored `.env`**, written by an interactive generator next to the scripts (`certbot/setup.sh`, `yubikey/config-mac.sh`, `yubikey/config-linux.sh`). Scripts source `.env` and fail with a clear message when a value is missing. Follow this pattern for anything new.
- **Comments, prompts and output are English.**
- **Bash scripts stay compatible with bash 3.2** (macOS) unless the script is Linux only and says so.

## Repository structure

| Directory | Purpose | Docs |
|-----------|---------|------|
| `agent/` | Admin web requests (AWR) with the DigiCert ONE agent: API trigger (`awr-api-trigger-comfort.sh/.ps1`), post-delivery scripts (`awr-post-*`: IIS bindings, Docker nginx, FortiWeb, config example) and a local simulator (`awr-simulator.sh/.ps1`) | `agent/SCRIPTS.md` (script contract and usage), `agent/README.md` (PowerShell execution policy on the agent VM) |
| `analyse/` | `check-public-cert` inspects a TLS endpoint's certificate; `reset-pwd-pkcs12` re-encrypts a PKCS#12 file with a new password | `analyse/README.md` |
| `certbot/` | Certificates from TLM via ACME with plain `certbot`, DNS-01 by hand and EAB credentials from `.env` | `certbot/README.md`, `certbot/CNAME-DELEGATION.md` (automating DNS-01 for zones without API access) |
| `homepage/` | Self-contained demo landing pages (`index-*-v1.html`), served behind a TLS endpoint as a visual target for certificate demos | none |
| `yubikey/` | Enrolls a TLM certificate into a YubiKey PIV slot via EST; key generated on the key, CSR signed through PKCS#11 | `yubikey/README.md` |

## Key contracts

**Agent post-delivery scripts** (`agent/awr-post-*`) receive `DC1_POST_SCRIPT_DATA`, a base64-encoded JSON with `args`, `certfolder`, `files` and `password`. They must write nothing to stdout or stderr (any output fails the delivery in TLM), log to a file instead and report only through the exit code: `0` success, `10` to `14` for the failure classes listed in `agent/SCRIPTS.md`. `awr-simulator.*` runs such a script locally with a self-signed certificate before it is registered in TLM.

**ACME with EAB** (`certbot/run-tlm.sh`) binds the certbot account to a TLM enrollment profile with `--eab-kid` and `--eab-hmac-key` from `.env`.

**EST enrollment** (`yubikey/*-est-enroll*.sh`) posts a CSR to `<EST_BASE_URL>/<profile id>/simpleenroll` with the enrollment code as HTTP Basic credential and imports the returned PKCS#7 into the PIV slot. The scripts reset the PIV application first.

## Conventions when editing

- Keep one script per platform where the tooling differs (`mac-*`/`linux-*`, `.sh`/`.ps1`) and keep the pairs in sync.
- Every directory has a short `README.md` (or `SCRIPTS.md`): two-sentence abstract, prerequisites, usage, notes. Update it when a script changes.
- Do not commit `.env`, `*.conf` with credentials, agent logs or customer data. Check `git status` for files another session may have created before committing.
