# scheelite LAN access — design space

**Status:** Active (deferred — implementation picks up when a domain is chosen)
**Started:** 2026-05-04
**Owner:** djacu
**Related:** `scheelite-homelab-services.md` (the services this is fronting); `scheelite-external-access-options.md` (separate, for off-LAN reach)

## Problem

`scheelite` runs the homelab services (Prowlarr, Sonarr/Radarr/Whisparr,
Jellyfin, qBittorrent, etc.). Each binds to `127.0.0.1`. Caddy on
scheelite reverse-proxies them under `*.${theonecfg.networking.lanDomain}`
(currently `literallyhell`) on port 443. The Caddy config uses
`local_certs` — Caddy's internal CA — so every TLS cert is signed by a
CA that no device trusts by default.

To use the services, today, requires SSH-tunneling
`localhost:<port>` from argentite. That works for the maintainer but
is unusable for phones, TVs, or guests on the WiFi.

The goal is **browser-based access from any LAN device** —
`https://<service>.<domain>` works straight away, no per-device setup —
so the services are usable beyond a NixOS desktop.

## Three TLS paths

The hard part is making devices trust Caddy's certs without per-device
fiddling. Three real options exist; each has honest trade-offs.

### Path A — per-device CA install

Keep `local_certs`. Extract Caddy's local-CA root cert from
`/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt`,
commit it to the repo, install on each device.

| Device | Trust install | Reality |
|---|---|---|
| argentite (NixOS) | `security.pki.certificateFiles = [ ./root.pem ];` | Trivial. Firefox needs `policies.ImportEnterpriseRoots = true` to see system trust. |
| Other NixOS hosts | Same as argentite | Trivial. |
| Android phone | Settings → Security → Encryption & credentials → Install from storage | Manual, persistent "your network may be monitored" warning, many apps with cert-pinning ignore user-added CAs. |
| iOS phone | AirDrop the .crt → Install Profile → Settings → General → About → Certificate Trust Settings → enable | Two-step manual install per phone. |
| Smart TVs | Usually no system UI for custom CAs | Often impossible; some Android TV yes, most no. |
| Guests | Install your CA on their device | Bad UX *and* a security ask — guest is now blindly trusting you to MITM their traffic until they remove it. |

**Cost:** $0. **Privacy:** fully private (no public DNS, no public certs).
**Caveat:** if Caddy regenerates its CA (e.g., wiping `/var/lib/caddy`),
the committed cert goes stale and trust breaks across all devices.

Path A is the right answer if the homelab is genuinely
NixOS-hosts-only with no phones, TVs, or guests in scope.

### Path B — real domain + Let's Encrypt DNS-01

Switch `services.caddy.globalConfig` from `local_certs` to ACME with
the DNS-01 challenge against a real, publicly-registered domain. Let's
Encrypt then issues publicly-trusted certs, automatically. Every
device's default trust store includes Let's Encrypt — phones, TVs,
guests, browsers all accept the cert with no setup.

The catch is what's exposed:

- Certificate Transparency logs. Every cert LE issues is published to
  CT logs (crt.sh and similar). Anyone who searches `*.<domain>` sees
  every subdomain that's been certed (`jellyfin.<domain>`, etc.). They
  can't *reach* the service (no public IP exposure happens here), but
  they know it exists.
- Public DNS records. *Only* the ACME challenge `_acme-challenge.<…>`
  TXT records — set transiently by Caddy via the DNS provider's API,
  then removed. We do **not** create public A records pointing at
  scheelite. So an external attacker doing `nslookup
  jellyfin.<domain>` from outside the LAN gets nothing — the domain
  doesn't resolve to anything reachable on the public internet.
- WHOIS records. Domain registration carries owner contact info. Some
  TLDs allow WHOIS-privacy proxies, others don't (see TLD section
  below).

**Cost:** $5–15/yr per domain. **Privacy:** subdomain names in CT
logs; WHOIS varies by TLD.

Path B is the right answer when phones/TVs/guests are in scope, which
is the typical homelab.

### Path C — plain HTTP

Drop TLS. No cert trust, no install dance. Many apps refuse to send
credentials over HTTP (Jellyfin's mobile clients have historically
required HTTPS; some browser features are HTTPS-only). LAN attackers
can sniff session cookies and admin passwords cleartext. Also: any
service we'd expose externally later would need a separate TLS
deployment.

Not viable for a multi-device homelab. Documented for completeness.

## DNS routing

### LAN device → "10.0.10.111"

The address is intercepted by AdGuard Home running on scheelite.
AdGuard:
- listens on `0.0.0.0:53` (TCP+UDP), with the firewall already open
  per the AdGuard module;
- rewrites `*.${cfg.lanDomain}` and `${cfg.lanDomain}` to scheelite's
  LAN IP (`10.0.10.111`);
- forwards everything else to upstream resolvers (`1.1.1.1`,
  `1.0.0.1`).

Side benefit: LAN-wide ad-blocking via AdGuard.

### Making argentite (and everyone else) talk to AdGuard

The user runs **pfSense** as the LAN router. The natural path:

> **Services → DHCP Server → LAN → DNS Servers** → set the first entry
> to `10.0.10.111`. Save → Apply. Renew DHCP on argentite.

That makes pfSense advertise scheelite's address as the LAN's primary
DNS via DHCP option 6. Every DHCP client on the LAN — argentite,
phones, smart TVs, guest devices on the WiFi — picks it up
automatically.

Alternative considered and rejected: pfSense Unbound's *Domain
Override* feature, which forwards only `<lan-domain>` queries to
scheelite while pfSense remains the primary DNS for everything else.
This is split-horizon DNS. Cleaner separation but loses the LAN-wide
AdGuard ad-blocking and adds a moving part. Recommended approach is
the simple "scheelite is LAN DNS, AdGuard handles everything"
configuration.

## URL structure

Two viable shapes:

- **Single-level: `<service>.<domain>`** — current
  (`prowlarr.literallyhell`). Shorter URLs. Implies `<domain>` is the
  homelab namespace.
- **Per-host two-level: `<service>.<host>.<domain>`** — would be
  `prowlarr.scheelite.<domain>`. Future-proofs for services on other
  hosts (`<service>.argentite.<domain>`). Longer to type. Bookmarks
  more verbose. Caddy and AdGuard wildcards handle either depth
  identically.

**Recommendation:** stick with single-level until multi-host services
materialize. Migration later is a sed across module defaults +
AdGuard rewrite + bookmark refresh.

## CT-log privacy considerations

Every Let's Encrypt cert issuance is logged to public Certificate
Transparency logs (crt.sh, Google's Transparency Report, etc.). For a
domain `<your-domain>`, anyone can search `*.<your-domain>` and see
every subdomain that's ever been certed.

Implications for domain choice:

- **Identifiable domain** (`firstnamelast.com`,
  `your-employer-side-project.net`) — CT log entries
  (`jellyfin.firstnamelast.com`, etc.) tie your name and homelab
  contents together publicly.
- **Generic domain** (`coolproject2024.com`,
  `random-mineral-name.org`) — CT log shows
  `jellyfin.coolproject2024.com` exists. Not directly linkable to you
  unless someone separately knows the domain is yours.

Mitigation: if Path B is chosen, pick a domain whose name doesn't
encode your identity. CT logs are global and forever — once a cert is
issued, the (subdomain, date) pair is on the public record.

## WHOIS privacy by TLD on Porkbun

Porkbun offers free WHOIS privacy via its "Private By Design, LLC"
proxy on most TLDs, but registry policies prevent it on a specific
list. **Verified against Porkbun's KB**:

- **Privacy supported**: `.com`, `.net`, `.org`, `.xyz`, `.dev`,
  `.app`, `.io`, `.me`, and most other gTLDs.
- **Privacy NOT supported (registry restriction, not Porkbun-specific)**:
  `.us`, `.uk` / `.co.uk` / `.org.uk` / `.me.uk`, `.de`, `.ca`,
  `.au` / `.com.au`, `.in` and friends, `.eu`, `.nl`, `.mx`, and
  several others.

`.us` is particularly relevant here because it's a US-resident
nexus-required TLD; the registry policy prohibits proxy WHOIS. Any
domain registered on `.us` has the registrant's real name + address
publicly searchable via `whois`.

**HSTS-preloaded TLDs** (`.dev`, `.app`, `.bank`, a few others) — these
have a TLD-level HSTS preload list entry, meaning every modern browser
*forces* HTTPS for any domain under them and refuses HTTP entirely. No
practical issue for our setup since Caddy serves HTTPS only. Worth
knowing if a future workflow ever wants HTTP locally for testing — won't
work on these TLDs without bypass flags.

## Domain candidates considered

The user has Porkbun as registrar (and existing Squarespace domains
they could transfer to Porkbun). Candidates discussed:

| Candidate | TLD | Cost | WHOIS privacy | Notes |
|---|---|---|---|---|
| `fiscontinuo.us` (transfer from Squarespace) | `.us` | ~free (transfer extends a year) | No (`.us` policy) | Existing domain. Distinctive name (Italian musical term — basso continuo). 5-7 day transfer window. WHOIS already public via Squarespace. |
| `scheelite.us` | `.us` | ~$5–15/yr | No (`.us` policy) | Cohesive with host name. Available immediately. |
| `scheelite.xyz` | `.xyz` | ~$1 first year / ~$12/yr renewal | Yes | Cheapest first year. `.xyz` has a mild email-deliverability stigma (some spam filters score `.xyz` senders higher) — irrelevant unless we add SMTP relay later. |
| `wolframite.{com,net,org}` | gTLD | ~$10–12/yr | Yes | Tungsten ore, fits theme; future hosts could be other tungsten ores (`huebnerite`, `ferberite`). |
| `pegmatite.{com,net,org}` | gTLD | ~$10–12/yr | Yes | Coarse-grained crystal-bearing rock; less specific to tungsten. |
| `feldspar.{com,net,org}` | gTLD | ~$10–12/yr | Yes | Common rock-forming mineral. |
| `schist.{com,net,org}` | gTLD | ~$10–12/yr | Yes | 6-letter metamorphic rock; mild homophone-humor. |

`scheelite.{com,net,org}` are all unavailable; thus the mineral-themed
alternates above.

## Implementation outline (Path B)

When a domain is picked and Path B is chosen, here's what changes:

1. **User-side prerequisites** (out-of-Nix):
   - Register/transfer the chosen domain to Porkbun.
   - In Porkbun's UI: Domain Management → Details → API Access → enable.
     Then Account → API → generate API Key + Secret.
   - Confirm domain uses Porkbun's nameservers (default for
     Porkbun-registered domains). Required for DNS-01 challenge.
   - Add the API credentials to sops:
     ```yaml
     porkbun:
         api-key: <Porkbun API key>
         api-secret: <Porkbun secret API key>
     ```

2. **`theonecfg.networking.lanDomain`** — change from `"literallyhell"`
   to the chosen domain in `nixos-configurations/scheelite/default.nix`.
   AdGuard rewrites and all Caddy vhost defaults
   (`<service>.${lanDomain}`) cascade automatically.

3. **Caddy with the Porkbun DNS plugin** —
   `nixos-modules/services/caddy/module.nix`:

   ```nix
   services.caddy = {
     package = pkgs.caddy.withPlugins {
       plugins = [ "github.com/caddy-dns/porkbun@v0.3.1" ];
       hash = lib.fakeHash;  # build once, replace with real hash from error
     };
     globalConfig = ''
       email ${theonecfg.knownUsers.djacu.email}
       acme_dns porkbun {
         api_key {env.PORKBUN_API_KEY}
         api_secret_key {env.PORKBUN_API_SECRET}
       }
     '';
   };
   ```

   The `withPlugins` helper requires a vendor hash; standard pattern is
   `lib.fakeHash` first build → take the real hash from the error →
   substitute. `email` populates the LE account contact from the
   user's existing `theonecfg.knownUsers` data. The `acme_dns porkbun
   { … }` directive replaces `local_certs`; every cert Caddy provisions
   from then on uses Porkbun DNS-01.

4. **Sops template + EnvironmentFile** — same pattern other services use:

   ```nix
   sops.templates."caddy.env" = {
     content = ''
       PORKBUN_API_KEY=${config.sops.placeholder."porkbun/api-key"}
       PORKBUN_API_SECRET=${config.sops.placeholder."porkbun/api-secret"}
     '';
     owner = "caddy";
   };
   sops.secrets."porkbun/api-key".owner = "caddy";
   sops.secrets."porkbun/api-secret".owner = "caddy";
   systemd.services.caddy.serviceConfig.EnvironmentFile =
     config.sops.templates."caddy.env".path;
   ```

5. **pfSense DHCP** — Services → DHCP Server → LAN → DNS Servers →
   `10.0.10.111` (primary). Save → Apply. DHCP clients on the LAN pick
   up the new DNS on lease renewal.

6. **Verification**:
   - From scheelite, `journalctl -u caddy` shows the ACME issuance
     succeeding.
   - From argentite, `nslookup jellyfin.<domain>` → `10.0.10.111`.
   - `curl -v https://jellyfin.<domain>/` → 200/302, cert chain shows
     issuer "Let's Encrypt" (no warning).
   - Browser visits `https://jellyfin.<domain>` etc. — green padlock.
   - Phone on the same WiFi — same URL works without setup.

### Per-vhost vs wildcard certs

Caddy's default with the configuration above is **one cert per vhost** —
each `<service>.<domain>` gets its own LE issuance. With ~7 services in
phase 3a alone, that's 7 ACME challenges on first deploy and 7
renewals every ~60 days. Caddy automates all of it; the user-visible
overhead is zero, but the CT log entries scale linearly with
service count, and on first deploy LE rate-limits could matter if
something forces re-issuance in a tight loop.

A **wildcard cert** (`*.<domain>`) covers every subdomain with a single
issuance + renewal. Switching is a small Caddyfile change — declare a
single wildcard cert config block and disable per-vhost auto-issuance.
DNS-01 challenges already work for wildcards (HTTP-01 doesn't), so
nothing else changes mechanically. Trade-offs: one cert covers the
entire domain (less granular if you ever revoke), and CT log entries
show fewer subdomains directly (the wildcard hides them, but
subdomains can still leak via passive DNS, browser preconnect, etc.).

Default in this plan: per-vhost. Wildcard is the upgrade if cert
churn becomes annoying or rate limits bite.

## Open decisions

- **Path A vs B vs C.** Driven by who needs to access the services.
  Path B if phones/TVs/guests matter; Path A if NixOS-only is fine.
- **If Path B: which domain.** Driven by WHOIS privacy stance, cost
  tolerance, and how identifiable the chosen name is.
- **WHOIS privacy stance.** Do we care about the registrant identity
  being publicly searchable? `.us` rules it out; `.com`/`.net`/`.org`/
  `.xyz`/`.dev`/`.app` allow it.
- **URL depth.** Single-level (current `literallyhell`) vs per-host
  (`<service>.scheelite.<domain>`). Default to single-level until a
  reason to migrate appears.

## Revisit triggers

- A new device type joins the homelab workflow (phone, TV) and needs
  to access services without per-device CA install.
- A guest needs to access a service on the LAN (Jellyfin most likely).
- The SSH-tunnel friction stops being acceptable as the daily-driver
  path.
- We add SMTP relay (then `.xyz`'s deliverability stigma might matter
  enough to swap to a `.com`).

## Out of scope

- **Implementation** — deferred until the path / domain decisions are
  made.
- **External / WAN access** — separate concern; tracked in
  `scheelite-external-access-options.md`. Path B's publicly-trusted
  cert doesn't imply external reachability; it just means the cert is
  trusted regardless of where the IP behind the domain points.
- **Removing AdGuard** — orthogonal. The rewrites stay either way.
