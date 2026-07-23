# Runbook: Rotate the Stream API secret

**Status: URGENT — do this now.**

## Why

`StreamConfig.userToken` shipped a long-lived Stream user JWT for user `ethan`
in the app source, and that source was committed to git. The token has no `exp`
claim, so it never expires on its own.

A Stream user token is a bearer credential. Anyone who has (or had) a copy of
that string can connect to Stream **as that user** — read their channels, send
messages as them — and will keep being able to until the signing secret changes.

Deleting the token from the source does **not** revoke it. Only rotating
`STREAM_API_SECRET` invalidates it, because that secret is what signed it.

- App: `explog (development)`
- API key: `msdyxmxmqf53` (public, safe to ship — this is not the secret)
- Leaked token subject: user `ethan`

## Blast radius of rotating

Rotating invalidates **every token signed with the old secret**, not just the
leaked one. In practice this is nearly free for Explog:

- The app mints a fresh token on every launch/sign-in via `getStreamToken`, so
  clients recover on their next launch.
- There is a gap between rotating in the Stream dashboard and redeploying the
  Cloud Function. During that window `getStreamToken` signs with the old secret
  and clients fail to connect. Keep steps 1–3 back to back; the gap is ~2 min.
- The Stream CLI's local `.stream/creds.yaml` will hold the old secret and stop
  working until you re-run `getstream login`.

## Steps

### 1. Mint the new secret (you — dashboard only)

The Stream CLI has no rotation command, so this step cannot be automated.

```bash
getstream open          # opens this project's app in the Stream dashboard
```

In the dashboard: **App Settings → Access Keys** (sometimes "API Keys") for
`explog (development)` → rotate / regenerate the secret for key `msdyxmxmqf53`.

Copy the new secret. Do not paste it into a file, a commit, or a chat message.

### 2. Update the Cloud Functions secret

`STREAM_API_SECRET` lives in Google Secret Manager and is read by
`getStreamToken` / `joinStreamChannel`. Adding a new version is safe and
reversible — the old version stays until you disable it.

```bash
cd /Users/ethan/explog
npx firebase-tools functions:secrets:set STREAM_API_SECRET --project explog-723b7
# paste the new secret at the prompt, press enter
```

### 3. Redeploy the functions that read it

A new secret version does not reach running functions until they redeploy.

```bash
npx firebase-tools deploy --only functions:getStreamToken,functions:joinStreamChannel \
  --project explog-723b7 --non-interactive
```

### 4. Verify

```bash
# Should print the new ENABLED version (and the old one)
npx firebase-tools functions:secrets:describe STREAM_API_SECRET --project explog-723b7
```

Then in the simulator: launch the app signed in and open a chat surface. If
messages load, `getStreamToken` is signing with the new secret and clients are
connecting.

```bash
DEV=/Applications/Xcode.app/Contents/Developer
SIM=45543A32-4A2C-4436-8DA8-E36C35B9CC00
$DEV/usr/bin/simctl terminate $SIM com.ej.explog
SIMCTL_CHILD_EXPLOG_AUTO_OPEN=chat $DEV/usr/bin/simctl launch $SIM com.ej.explog
```

Confirm the leaked token is dead: it should now fail to connect. (Optional —
only if you kept a copy; there is no need to go find one.)

### 5. Re-authenticate the local CLI

```bash
getstream login          # refreshes .stream/creds.yaml with the new secret
```

### 6. Clean up the old secret version

Once step 4 passes, disable the superseded version so it can't be rolled back to:

```bash
npx firebase-tools functions:secrets:prune --project explog-723b7
```

## After rotating

- [ ] New secret set in Secret Manager (step 2)
- [ ] Functions redeployed (step 3)
- [ ] App connects to chat (step 4)
- [ ] Stream CLI re-authenticated (step 5)
- [ ] Old secret version pruned (step 6)
- [ ] Git history scrubbed (separate — see below)

## Preventing a repeat

`StreamConfig.userToken` is now `""` and must stay that way. To develop
signed-out, put a short-lived token in a gitignored xcconfig
(`Secrets.xcconfig` is already in `.gitignore`), never in a tracked source file.

Real credentials belong in exactly two places in this project:

1. Google Secret Manager, read by Cloud Functions (`STREAM_API_SECRET`).
2. `.stream/creds.yaml`, gitignored, for local CLI use.

`GoogleService-Info.plist` and the Stream **API key** are client identifiers,
not secrets, and are fine to commit.
