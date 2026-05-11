# Paperless OIDC users land without permissions

**Status:** Deferred
**Started:** 2026-05-07
**Owner:** djacu

## Context

Paperless-ngx is configured with native OIDC against Kanidm (via
django-allauth, see `nixos-modules/services/paperless/module.nix`).
First time you sign in via Kanidm, django-allauth auto-creates a
Django user matching your Kanidm identity (e.g. `djacu`) — but with
**zero permissions**. The Paperless web UI then immediately throws:

```json
{
  "status": 403,
  "url": "https://paperless.scheelite.dev/api/ui_settings/",
  "error": {
    "detail": "You do not have permission to perform this action."
  }
}
```

The user IS authenticated; they just can't read or write anything
because the auto-created Django account is not a superuser, not in any
group, and has no per-document permissions.

A separate `admin` user exists, created from
`sops.secrets."paperless/admin-password"` via the upstream module's
`passwordFile` mechanism. That account *does* have superuser. The
two accounts are not linked.

## Manual unblock (verified 2026-05-07)

1. Decrypt the admin password:

   ```fish
   sops -d secrets/scheelite.yaml | grep -A1 '^paperless:' | grep admin-password
   ```

2. Open `https://paperless.scheelite.dev/accounts/login/` in an
   incognito window (so the existing OIDC session doesn't auto-redirect).

3. Log in with username `admin` and the password from step 1.

4. Navigate to **Settings → Users & Groups** (or `/admin/` for the
   Django admin UI). Click the OIDC-created user (e.g. `djacu`),
   check both **Staff status** and **Superuser status**, save.

5. Close incognito. In your normal browser, log out + sign back in
   via Kanidm. The 403 on `/api/ui_settings/` is gone; full UI loads.

This is a one-time fix per user. The promotion persists in Paperless's
Postgres database. Survives reboots and `nixos-rebuild` runs because
Paperless's DB lives in `theonecfg.services.postgres.instances.paperless`,
which is on `/persist`.

If you wipe Paperless's DB (postgres reset, fresh install,
nixos-anywhere), you have to re-do the promotion.

## Why it happens

django-allauth's default behavior on social-auth signup:

- Create a new Django `User` row.
- Mark `is_active = True` so they can log in.
- Leave `is_staff = False` and `is_superuser = False`.
- Don't add to any group.

Paperless's REST API permission classes require either superuser status
or explicit group/user permissions on the resource. The
`/api/ui_settings/` endpoint requires a permission the freshly-created
user doesn't have, hence 403.

Neither django-allauth nor Paperless ship a built-in "first OIDC user
becomes superuser" or "all OIDC users get group X" toggle. Has to be
configured.

## Options for a declarative fix (deferred)

Three real paths. Trade-offs differ on simplicity, reuse, and how
identity is presented in the UI.

### Option 1 — Post-bootstrap one-shot that promotes the user

Add a systemd oneshot to `paperless/module.nix` that runs after
Paperless starts and is idempotent:

```nix
systemd.services.paperless-promote-oidc-user = {
  description = "Promote the OIDC user to superuser in Paperless";
  after = [ "paperless-web.service" ];
  requires = [ "paperless-web.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    User = "paperless";
    Group = "paperless";
  };
  script = ''
    ${pkgs.paperless-ngx}/bin/paperless-ngx-manage shell -c \
      "from django.contrib.auth import get_user_model; \
       User = get_user_model(); \
       User.objects.filter(username='djacu').update(is_superuser=True, is_staff=True)"
  '';
};
```

The username (`djacu`) would either be hardcoded against
`theonecfg.knownUsers.djacu.username`, or the helper could iterate
all configured `theonecfg.knownUsers` entries that should have
admin access.

**Pros**: surgical, clear intent, runs only when Paperless is up,
doesn't touch django-allauth internals.

**Cons**: depends on the OIDC user existing in Paperless's DB at the
time the oneshot runs — it doesn't exist until the user signs in for
the first time. So the unit does nothing on a fresh deploy until the
user has already triggered the OIDC flow once. Then on the *next*
activation, the unit promotes.

Workaround: re-run with `systemctl restart paperless-promote-oidc-user`
once after first OIDC login. Or accept the two-step.

### Option 2 — Match by email, auto-link OIDC to existing admin

django-allauth respects `SOCIALACCOUNT_EMAIL_AUTHENTICATION = True` (or
the older `SOCIALACCOUNT_EMAIL_VERIFICATION` + matching email): when
an OIDC login arrives whose email matches an existing Django user,
the OIDC identity gets linked to that user instead of creating a new
one.

Setup:

- Set the `admin` user's email at creation time to match djacu's
  Kanidm email (`theonecfg.knownUsers.djacu.email`).
- Add `"EMAIL_AUTHENTICATION": true` (or equivalent) to the
  `PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON in the sops template.

Result: OIDC login as djacu → email matches `admin` → OIDC identity
attached to the existing `admin` account, which already has
superuser. No new Django user gets created.

**Pros**: pure config, no Python, no oneshot, works on first OIDC
login (no two-step). Closest to declarative.

**Cons**: UI shows the logged-in user as `admin`, not `djacu`. For a
single-admin homelab that's irrelevant; for multi-user it would
break.

Need to check whether the upstream paperless module supports setting
the admin user's email (it has `passwordFile` but emails are usually
defaulted). May need a small upstream-module-level workaround.

### Option 3 — Custom social account adapter

Subclass `allauth.socialaccount.adapter.DefaultSocialAccountAdapter`
in a Python file shipped via `services.paperless.extraConfig` (or
similar), overriding `populate_user` or `save_user` to set
`is_superuser = True` and `is_staff = True` on signup.

**Pros**: most flexible. Could promote based on Kanidm group
membership, attribute presence, etc.

**Cons**: Python code shipped via Nix; more moving parts; needs to
be kept in sync with django-allauth API (subclass interface has
changed across versions). Overkill for a single-user homelab.

## Recommendation when revisited

**Option 2** (email match → auto-link to admin) for a single-user
homelab. Simplest, no Python, no two-step deploy. The UI-shows-as-admin
quirk is fine when there's one human.

**Option 1** (post-bootstrap oneshot) when adding a second human user
becomes a real concern. It scales to N users naturally.

**Option 3** is reserved for needing role-based promotion (e.g.
"users in Kanidm group `paperless-admins` get superuser; everyone
else gets read-only"). Not on the horizon yet.

## Out of scope

- Per-document or group-based permissions in Paperless. The
  superuser bypass is fine for a homelab; revisit if multiple
  humans actually share the instance.
- Cleaning up the duplicated user accounts created during the
  manual fix. Currently both `admin` and `djacu` exist as
  superusers; either can be removed via the Django admin once the
  declarative fix lands.
