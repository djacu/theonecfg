# scheelite external access — options

**Status:** Postponed (no decision)
**Started:** 2026-04-26
**Owner:** djacu
**Related:** `scheelite-homelab-services.md` (Phase 6 is gated on the choice captured here)

## Context

The scheelite homelab plan covers LAN service access but leaves remote access
deliberately out of scope for the first iteration. This document captures the
options that were evaluated, what each offers, what each costs to operate, and
how each would slot into the existing plan. **No option is selected.** Pick this
back up when ready.

The "external access" question is: how does Daniel reach Jellyfin / Nextcloud /
Grafana / etc. when not on the home LAN? Options range from "skip remote access"
to "fully public URLs," and there are several middle paths.

The locked plan already builds:

- Caddy on scheelite as reverse proxy (LAN vhosts on `*.scheelite.lan`)
- Kanidm + oauth2-proxy for identity (LAN-only this iteration)
- AdGuard Home for LAN DNS

Most external-access options layer on top of these without rebuilding them. The
delta is the *edge* — what listens on a public IP, how traffic reaches scheelite.

## Options evaluated

### 1. Tailscale (managed mesh VPN)

**What it offers**

- Reach scheelite from anywhere — phone on cellular, hotel laptop, coffee-shop network.
- WireGuard tunnel under the hood, modern and audited.
- "MagicDNS" makes service names resolve the same on/off LAN for tailnet members.
- Auto-issued TLS certs via Tailscale's CA, or `tailscale funnel` for real public certs.
- Free up to 100 devices for personal use.
- Polished mobile apps + a CLI.
- ACLs in the admin UI scope who reaches what (overkill for a single user; available if needed).

**Costs**

- $0.
- One Tailscale account.
- Annual SSO refresh per device (configurable up to 180 days).

**Maintenance**

- Install agent on each consuming device (phone, laptop). Smart TVs / Chromecasts can't.
- Tailscale (a US company) sees connection metadata — *which* device connected to *which*
  node, not content. Treat as a third-party trust decision.
- If Tailscale's coordination server is down, *new* connections fail; established ones
  keep working.

**How it slots into the plan**

Add `theonecfg.services.tailscale.enable = true` (a thin wrapper over
`services.tailscale`). Caddy on scheelite would listen on both LAN and tailnet IPs
simultaneously — same vhost, two interfaces. An off-tailnet device on the LAN uses
the LAN IP; a remote phone uses the tailnet IP; both hit the same vhost.

**Implementation sketch**

```nix
services.tailscale = {
  enable = true;
  useRoutingFeatures = "server";
  authKeyFile = config.sops.secrets."tailscale/auth-key".path;
};
networking.firewall.checkReversePath = "loose";
networking.firewall.trustedInterfaces = [ "tailscale0" ];
```

**Pros**

- Lowest setup cost, lowest ongoing maintenance.
- No router config, no exposed ports.
- Works from anywhere a tailnet member is online.
- Encryption + ACLs + certs all built-in.

**Cons**

- Tailscale-as-third-party (metadata, ToS could change).
- Smart TVs / cast targets / guest devices that can't run Tailscale lose access entirely.
- Free tier capped at 100 devices.

### 2. Headscale (self-hosted Tailscale control plane)

**What it offers**

- Same UX as Tailscale — same Tailscale clients, same WireGuard data plane.
- Self-hosted coordination server replaces Tailscale Inc.'s.
- Open source (BSD-3-Clause).
- No third-party trust for connection metadata.

**Costs**

- $3-5/month for a small public-IP VPS to run the headscale daemon (it needs a public
  IP for coordination), or use any existing always-on machine with a public IP.
- One domain (cheap, can be a subdomain of an existing domain).

**Maintenance**

- Maintain the headscale instance: update the daemon, manage its sqlite DB, monitor.
- ACLs are managed via headscale's CLI rather than the polished Tailscale admin UI.
- Tailscale clients (especially on iOS) need a config tweak to point at the headscale
  server — straightforward but slightly less smooth than vanilla Tailscale.
- Same SSO/key rotation requirements as Tailscale.

**How it slots into the plan**

Two pieces:

1. New nixosConfiguration for the VPS (headscale runs there). Joins the existing
   `nixos-configurations/` pattern.
1. New `theonecfg.services.headscale.enable` module on the VPS;
   `theonecfg.services.tailscale.enable` on scheelite, configured to use the
   self-hosted control plane.

**Pros**

- Independence from Tailscale Inc. (privacy, ToS, vendor lock-in).
- Same client UX as Tailscale.
- WireGuard data plane is unchanged.

**Cons**

- Costs $3-5/month + a domain.
- More moving parts than vanilla Tailscale.
- ACL UX worse than the Tailscale admin UI.
- iOS Tailscale client config friction (a one-time setup).

### 3. Tailscale Funnel

**What it offers**

- Public URLs (`https://service.<machine>.<tailnet>.ts.net`) reachable by anyone — no
  Tailscale on the visitor's device.
- Tailscale runs an edge proxy on their servers; traffic flows through Tailscale to your
  tailnet node.
- Auto-TLS via Tailscale's CA.
- Free for personal use.

**Costs**

- $0.
- Already a Tailscale user.

**Maintenance**

- Funnel adds a per-service ACL to the tailnet config.
- Tailscale sees plaintext at their edge (TLS terminates there). Same trust posture as
  Cloudflare Tunnel — third-party-mediated.

**How it slots into the plan**

Run scheelite as a Tailscale node (option 1). Then enable Funnel on a per-service
basis: `tailscale funnel 443 on` for each vhost or use the API.

**Pros**

- Zero infrastructure. Public URLs without ports.
- No DDNS, no ACME, no Authelia replacement needed (Funnel + Kanidm OIDC works).

**Cons**

- Tailscale-mediated; their edge sees plaintext.
- Limited bandwidth on free tier (uploads stream through Tailscale's network).
- Tied to the Tailscale ecosystem — switching costs.
- URL aesthetic (`*.ts.net`) — not your domain.

### 4. Reverse proxy + DDNS + ACME (with Authelia or Kanidm + oauth2-proxy)

**What it offers**

- Real public URLs: `https://jellyfin.example.com`. Anyone with the URL + auth credentials
  can access.
- SSO across all services (Authelia or Kanidm).
- Real TLS certs (browsers + apps universally happy).
- Easy to share specific URLs with friends/family without onboarding to a VPN.

**Costs**

- Domain (~$12/year) at a registrar with DNS API (Cloudflare, Porkbun, Namecheap).
- $0 in infrastructure beyond what scheelite already is.

**Maintenance**

- Router port forwards 80 + 443 → scheelite IP.
- DDNS daemon (`ddclient`) keeps DNS pointed at your home IP — secret needed.
- ACME via Caddy DNS-01 (avoids needing port 80 publicly) — registrar API token in sops.
- Authelia or Kanidm + oauth2-proxy + Caddy `forward_auth` per public vhost.
- Watch attack logs; consider fail2ban + crowdsec.
- Every public service is now an internet-scale attack surface — patch promptly when CVEs land.
- Real ongoing operational burden compared to Tailscale.

**How it slots into the plan**

Two new modules + extensions to existing ones:

- `theonecfg.services.ddns` — `ddclient` with Cloudflare provider.
- Extend Caddy module: support a `publicDomain` per vhost; ACME DNS-01 wiring; per-vhost
  forward-auth registration.
- Extend each per-service module: opt-in `publicDomain` option that triggers the public
  vhost + auth gate.

**Pros**

- Real public URLs; widest device compatibility.
- No third-party in the data path (you control TLS termination).
- Works for any visitor (smart TVs, guests, anyone with the URL).

**Cons**

- Highest ongoing maintenance.
- Highest attack surface.
- Home IP exposed in DNS — port-scanning, DDoS, and ISP-level surveillance can target your
  home connection.
- Requires DDNS unless ISP gives you a static IP.

### 5. Cloudflare Tunnel

**What it offers**

- Public URLs without opening any router port. `cloudflared` makes an outbound connection
  to Cloudflare; Cloudflare proxies inbound traffic to your services.
- Cloudflare's CDN + DDoS protection in front.
- Cloudflare Access offers SSO via Google / GitHub / email magic-link without you running
  auth.
- Free for personal use.

**Costs**

- $0.
- Domain on Cloudflare DNS (free or transfer NS).

**Maintenance**

- `cloudflared` daemon, declarative ingress rules in NixOS.
- Cloudflare account; trust them with your traffic — they terminate TLS so they see plaintext.
- Free-tier caveats: 100MB request body limit (problematic for Nextcloud / Immich uploads
  out of the box; can be worked around with raw TCP tunneling).
- Cloudflare's free tier ToS could change.
- Some non-HTTP protocols need extra config.
- Lock-in: switching off Cloudflare requires re-setting up ports + DDNS + ACME from scratch.

**How it slots into the plan**

New `theonecfg.services.cloudflared` module. Public DNS records auto-created by Cloudflare
when you add ingress rules. No router changes. ACME and DDNS are not needed.

**Implementation sketch**

```nix
services.cloudflared = {
  enable = true;
  tunnels."<tunnel-uuid>" = {
    credentialsFile = config.sops.secrets."cloudflared/credentials".path;
    default = "http_status:404";
    ingress = {
      "jellyfin.example.com" = "http://localhost:8096";
      "grafana.example.com"  = "http://localhost:3000";
    };
  };
};
```

**Pros**

- Easiest path to "internet-reachable" if you trust Cloudflare.
- No port forwarding, no DDNS, no ACME.
- DDoS absorbed by Cloudflare's edge.

**Cons**

- Cloudflare sees plaintext (their threat model, not yours).
- 100MB body limit on free tier hurts large-file services.
- Cloudflare-as-third-party with ToS-change risk.
- Service quirks (websockets, raw TCP) need extra plumbing.

### 6. Nebula + small VPS edge

**What it offers**

- Public URLs without opening any router port — but the edge is a *box you own*, not Cloudflare.
- Nebula (open source, by Slack) is a peer-to-peer mesh VPN. Self-hosted "lighthouse"
  for peer discovery.
- VPS with public IP runs Caddy + Nebula. Scheelite runs Nebula. Caddy on the VPS
  reverse-proxies through the Nebula tunnel back to scheelite's services.
- Home network never exposes anything to the open internet.

**Costs**

- $3-5/month for a small LXC-tier VPS (Hetzner CX11, BuyVM, RackNerd, Ramnode, etc).
- Domain (~$12/year).

**Maintenance**

- Two NixOS hosts now (scheelite + VPS).
- Nebula CA: generate once, sign per-host certs, rotate yearly.
- Two Caddy installs (LAN on scheelite, public on VPS).
- ACME on the VPS (DNS-01 still recommended; needs registrar API token).
- VPS provider becomes a single point of failure for *external* access. LAN access unchanged.
- VPS bandwidth quota (most providers include 1-10TB/month — Jellyfin streaming from
  outside the home eats this).

**How it slots into the plan**

- New nixosConfiguration for the VPS (joins existing `nixos-configurations/` pattern).
- New `theonecfg.services.nebula` module with two roles — `lighthouse` (runs on VPS;
  has public IP) and `peer` (joins mesh; gets a private Nebula IP).
- VPS host enables `nebula.lighthouse` + Caddy public vhosts that `reverse_proxy` to
  scheelite's Nebula IP.
- Scheelite enables `nebula.peer`.
- Kanidm stays on scheelite. The VPS Caddy uses `forward_auth` against
  `oauth2-proxy.<scheelite-nebula-ip>` over the tunnel.
- ACME runs on the VPS Caddy with Cloudflare DNS-01.

**Pros**

- Home IP not in DNS — meaningfully harder to target your home directly.
- Two layers of firewall before reaching scheelite (VPS + scheelite).
- No Cloudflare dependency, no upload-size cap.
- ISP can't block you — they only see outgoing Nebula UDP.
- DDoS reflects on the VPS, not your home connection.

**Cons**

- $3-5/month, ongoing.
- Another NixOS host to keep updated.
- Two-hop latency (visitor → VPS → home → service). Negligible for HTTP, more visible
  for video streams.
- VPS bandwidth limits affect heavy streaming.
- More moving parts: Nebula CA, second NixOS config, second Caddy.

### 7. WireGuard + small VPS edge

Same architecture as option 6 but with WireGuard instead of Nebula. Functionally
near-identical.

**Differences from Nebula**

- WireGuard has no built-in peer discovery — each peer pair needs explicit config.
  For a tiny mesh (VPS + scheelite + 1-2 personal devices) this is fine; for more
  peers, Nebula's lighthouse model is friendlier.
- WireGuard's NixOS module is more mature than Nebula's. `services.wg-quick` and
  `networking.wireguard.interfaces` are well-trodden.
- No CA-style identity. Each peer-pair is a public-key trust.

**Pros**

- Most mature WireGuard tooling in NixOS.
- Same privacy benefits as Nebula.

**Cons**

- Adding more peers later is friction (no lighthouse).
- No identity/CA story.

## Comparison

| | Public URL | Cost / month | Home IP exposed | Open router ports | Third-party trust | Setup | Ongoing | Risk surface |
|---|---|---|---|---|---|---|---|---|
| Tailscale | tailnet only | $0 | no | no | Tailscale Inc. | minimal | annual re-auth | very low |
| Headscale | tailnet only | ~$3-5 | no | no | self | medium | low | very low |
| Tailscale Funnel | yes | $0 | no | no | Tailscale Inc. | minimal | low | low |
| Reverse proxy + DDNS | yes | $1 (domain) | yes | yes | self | high | high | high |
| Cloudflare Tunnel | yes | $1 (domain) | no | no | Cloudflare | medium | medium | medium |
| Nebula + VPS | yes | ~$4-6 | no | no | self | high | medium | medium |
| WireGuard + VPS | yes | ~$4-6 | no | no | self | high | medium | medium |
| Defer | no | $0 | no | no | n/a | none | none | none |

## How to think about this

The decision splits along three axes:

1. **Do you need public URLs (browser-to-anyone), or is "any device I own" enough?**

   - "Devices I own" → Tailscale, Headscale.
   - "Browser-to-anyone" → the rest.

1. **Are you willing to put your home IP in DNS?**

   - No → Cloudflare Tunnel, Nebula+VPS, WireGuard+VPS, Tailscale Funnel.
   - Yes → reverse proxy + DDNS.

1. **Are you willing to run a tiny extra always-on machine?**

   - No → Tailscale, Tailscale Funnel, Cloudflare Tunnel.
   - Yes → Headscale, Nebula+VPS, WireGuard+VPS.

## Where we left off

User wanted to take more time to evaluate these options before committing. The
following points came up during the discussion and remain open:

- A friend uses **Headscale** — this hadn't been evaluated when the original
  options list was presented; included here for completeness when revisiting.
- Another friend recommended **Nebula + small VPS edge** specifically as an
  alternative to Cloudflare Tunnel for users who want to avoid both opening home
  ports and depending on Cloudflare.
- The locked plan was originally going to include "reverse proxy + DDNS + ACME +
  Authelia" but Kanidm replaced Authelia. The reverse-proxy + DDNS path is still
  on the table; it's just not built yet.

The non-decision-blocking work proceeds without external access. Phase 6 of
`scheelite-homelab-services.md` is the placeholder for whatever option is chosen
here. Modules are written so any of these can be added cleanly later — the swap
points are isolated (a new module, plus `publicDomain` options on existing
service modules).

## Open questions to resolve when revisiting

- How important is exposing services to non-personal devices (smart TVs, guests'
  phones, friends/family on their own networks)?
- How comfortable are you with home-IP exposure / port forwarding?
- Are you willing to maintain a second always-on host (VPS or otherwise)?
- Is Cloudflare an acceptable third-party in the data path?
- Would you prefer to skip remote access entirely for the foreseeable future?

## Caddy TLS implications when revisiting

The current scheelite Caddy is configured with `services.caddy.globalConfig = "local_certs"`, which forces Caddy to use its internal CA for every
vhost. This is correct for the all-private homelab on `*.literallyhell`
because Caddy's auto-HTTPS only treats `localhost`, `.localhost`, `.local`,
`.internal`, `.home.arpa` (and internal IPs) as "private" — non-public
TLDs like `literallyhell` would otherwise fall through to ACME, fail,
and TLS handshakes return alert 80.

Whether this needs to change per option chosen here:

- **Tailscale / Tailscale Funnel / Cloudflare Tunnel**: no change.
  Public TLS terminates upstream (Tailscale's `*.ts.net` cert,
  Cloudflare's edge cert); scheelite's Caddy keeps serving internal-CA
  certs to the tunnel client over loopback. The internal CA never
  faces a browser.
- **WireGuard / Headscale subnet routing (private mesh only)**: no
  change. Mesh peers can be told to trust the internal CA.
- **Reverse-proxy + DDNS + ACME** (option 4): change required.
  Drop `local_certs` from the global config and instead apply
  `tls internal` per-vhost to private domains. Public vhosts then
  fall through to default automatic HTTPS (Let's Encrypt). The edit
  scope is small — one line per service module that adds a vhost,
  plus dropping the global directive in `caddy/module.nix`.
- **Nebula + small VPS edge** (option 6): same as Cloudflare Tunnel
  — public TLS terminates on the VPS edge. No change to scheelite.
- **WireGuard + small VPS edge** (option 7): same.

So the global `local_certs` is robust for any tunnel-based or
mesh-based access strategy. Only the direct-port-forward + public-
ACME strategy requires migrating Caddy's TLS config.
