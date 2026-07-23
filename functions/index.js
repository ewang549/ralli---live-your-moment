const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { StreamChat } = require("stream-chat");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { randomInt } = require("crypto");

initializeApp();
const db = getFirestore();

// Server-side only. Set once with:
//   firebase functions:secrets:set STREAM_API_SECRET
const streamApiSecret = defineSecret("STREAM_API_SECRET");
const STREAM_API_KEY = "msdyxmxmqf53";

// ---------------------------------------------------------------------------
// Phase 1: user directory + handles
// ---------------------------------------------------------------------------

const HANDLE_PATTERN = /^[a-z0-9_]{3,20}$/;

// Names we don't want anyone claiming.
const RESERVED_HANDLES = new Set([
  "explog", "admin", "administrator", "support", "help", "root", "system",
  "moderator", "mod", "staff", "team", "official", "security", "about",
  "settings", "login", "signup", "me", "you", "null", "undefined",
]);

// Unambiguous alphabet: no 0/O/1/I/L to keep codes readable out loud.
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 6;

// Friend codes are a lookup key for "add me" — a predictable sequence would let
// someone walk the directory, so they come from the CSPRNG, not Math.random.
// Keyspace is 31^6 ≈ 8.9e8; the code alone must never be treated as proof of
// anything, and resolveFriendCode (Phase 2) needs per-caller rate limiting.
function generateFriendCode() {
  let code = "";
  for (let i = 0; i < CODE_LENGTH; i += 1) {
    code += CODE_ALPHABET[randomInt(0, CODE_ALPHABET.length)];
  }
  return code;
}

/** Throws unless the caller is signed in; returns the uid. */
function requireAuth(request) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }
  return request.auth.uid;
}

/** Normalizes and validates a handle, or throws invalid-argument. */
function normalizeHandle(raw) {
  if (typeof raw !== "string") {
    throw new HttpsError("invalid-argument", "Handle is required.");
  }
  const handle = raw.trim().toLowerCase().replace(/^@/, "");
  if (!HANDLE_PATTERN.test(handle)) {
    throw new HttpsError(
      "invalid-argument",
      "Handles are 3–20 characters: lowercase letters, numbers, underscores."
    );
  }
  if (RESERVED_HANDLES.has(handle)) {
    throw new HttpsError("invalid-argument", "That handle is reserved.");
  }
  return handle;
}

/** Public projection of a profile — everything here is safe for other users. */
function publicProfile(data) {
  return {
    uid: data.uid,
    handle: data.handle,
    handleDisplay: data.handleDisplay || data.handle,
    name: data.name || "",
    avatarEmoji: data.avatarEmoji || "🙂",
    city: data.city || "",
    bio: data.bio || "",
    isPrivate: data.isPrivate === true,
  };
}

// ---------------------------------------------------------------------------
// Rate limiting
// ---------------------------------------------------------------------------

/**
 * Fixed-window rate limiter with a failure-triggered lockout, stored at
 * `rateLimits/{uid}__{action}`.
 *
 * Friend codes are only ~8.9e8 possibilities, so an unthrottled lookup endpoint
 * is a directory-enumeration oracle: guess codes until one resolves and harvest
 * profiles. Two layers guard it — a per-window cap on *all* calls, and a
 * lockout once too many calls in a row come back empty, which is the signature
 * of guessing rather than of a real person typing a code off a friend's screen.
 *
 * The whole read-modify-write runs in a transaction so parallel calls from the
 * same uid can't race past the cap.
 */
async function enforceRateLimit(uid, action, options) {
  const {
    maxAttempts,      // calls allowed per window
    windowMs,
    maxFailures,      // consecutive misses before lockout
    lockoutMs,
  } = options;

  const ref = db.doc(`rateLimits/${uid}__${action}`);
  const now = Date.now();

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? snap.data() : {};

    if (typeof data.lockedUntil === "number" && data.lockedUntil > now) {
      const minutes = Math.ceil((data.lockedUntil - now) / 60000);
      throw new HttpsError(
        "resource-exhausted",
        `Too many lookups. Try again in ${minutes} minute${minutes === 1 ? "" : "s"}.`
      );
    }

    const windowStart = typeof data.windowStart === "number" ? data.windowStart : 0;
    const freshWindow = now - windowStart >= windowMs;
    const attempts = freshWindow ? 0 : (data.attempts || 0);

    if (attempts >= maxAttempts) {
      throw new HttpsError(
        "resource-exhausted",
        "Too many lookups. Slow down and try again shortly."
      );
    }

    tx.set(ref, {
      windowStart: freshWindow ? now : windowStart,
      attempts: attempts + 1,
      // Consecutive failures survive window resets; only a hit clears them.
      failures: data.failures || 0,
      lockedUntil: data.lockedUntil || 0,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });

  return {
    /// Call after the lookup so the limiter learns hit vs miss.
    async record(hit) {
      if (hit) {
        await ref.set({ failures: 0 }, { merge: true });
        return;
      }
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        const failures = ((snap.exists ? snap.data().failures : 0) || 0) + 1;
        const update = { failures };
        if (failures >= maxFailures) {
          // Lock out and reset the counter so the next offence starts clean.
          update.lockedUntil = Date.now() + lockoutMs;
          update.failures = 0;
        }
        tx.set(ref, update, { merge: true });
      });
    },
  };
}

/**
 * Callable: resolveFriendCode({ code }) -> { profile }
 *
 * Add-by-code / QR entry point (Phase 2). Rate limited and lockout-guarded —
 * see enforceRateLimit for why this endpoint specifically needs it.
 */
exports.resolveFriendCode = onCall(async (request) => {
  const uid = requireAuth(request);

  const raw = (request.data || {}).code;
  if (typeof raw !== "string") {
    throw new HttpsError("invalid-argument", "A friend code is required.");
  }
  // Normalize the way people actually type codes: case and spacing are noise.
  const code = raw.trim().toUpperCase().replace(/[\s-]/g, "");
  if (!/^[A-Z0-9]{4,12}$/.test(code)) {
    throw new HttpsError("invalid-argument", "That doesn't look like a friend code.");
  }

  const limiter = await enforceRateLimit(uid, "resolveFriendCode", {
    maxAttempts: 15,
    windowMs: 5 * 60 * 1000,   // 15 lookups per 5 minutes
    maxFailures: 20,           // 20 misses in a row
    lockoutMs: 30 * 60 * 1000, // 30 minute lockout
  });

  const claim = await db.doc(`friendCodes/${code}`).get();
  if (!claim.exists) {
    await limiter.record(false);
    throw new HttpsError("not-found", "No one found with that code.");
  }

  const target = await db.doc(`users/${claim.data().uid}`).get();
  if (!target.exists) {
    await limiter.record(false);
    throw new HttpsError("not-found", "No one found with that code.");
  }

  await limiter.record(true);
  return { profile: publicProfile(target.data()) };
});

/**
 * Callable: lookupUser({ query }) -> { profile }
 *
 * "Add friend by User ID". Accepts either a handle or a friend code, because
 * people don't reliably know which one they were given. Rate limited on the
 * same limiter as resolveFriendCode — both are directory lookups keyed on a
 * short, guessable string.
 */
exports.lookupUser = onCall(async (request) => {
  const uid = requireAuth(request);

  const raw = (request.data || {}).query;
  if (typeof raw !== "string" || !raw.trim()) {
    throw new HttpsError("invalid-argument", "Enter a User ID.");
  }
  const value = raw.trim().replace(/^@/, "");

  const limiter = await enforceRateLimit(uid, "lookupUser", {
    maxAttempts: 20,
    windowMs: 5 * 60 * 1000,
    maxFailures: 25,
    lockoutMs: 30 * 60 * 1000,
  });

  // Try the handle first, then fall back to treating it as a friend code.
  let targetUid = null;

  const handle = value.toLowerCase();
  if (HANDLE_PATTERN.test(handle)) {
    const handleSnap = await db.doc(`handles/${handle}`).get();
    if (handleSnap.exists) targetUid = handleSnap.data().uid;
  }

  if (!targetUid) {
    const code = value.toUpperCase().replace(/[\s-]/g, "");
    if (/^[A-Z0-9]{4,12}$/.test(code)) {
      const codeSnap = await db.doc(`friendCodes/${code}`).get();
      if (codeSnap.exists) targetUid = codeSnap.data().uid;
    }
  }

  if (!targetUid) {
    await limiter.record(false);
    throw new HttpsError("not-found", "No one found with that ID.");
  }

  if (targetUid === uid) {
    await limiter.record(true);
    throw new HttpsError("invalid-argument", "That's you.");
  }

  const target = await db.doc(`users/${targetUid}`).get();
  if (!target.exists) {
    await limiter.record(false);
    throw new HttpsError("not-found", "No one found with that ID.");
  }

  await limiter.record(true);
  return { profile: publicProfile(target.data()) };
});

/**
 * Callable: checkHandleAvailable({ handle }) -> { available, reason? }
 *
 * Live validation while the user types during onboarding. Cheap read of the
 * claim doc; the real guarantee is the transaction in createProfile.
 */
exports.checkHandleAvailable = onCall(async (request) => {
  requireAuth(request);

  let handle;
  try {
    handle = normalizeHandle((request.data || {}).handle);
  } catch (error) {
    // A malformed handle isn't an error to the UI — it's just unavailable.
    return { available: false, reason: error.message };
  }

  const snap = await db.doc(`handles/${handle}`).get();
  if (snap.exists && snap.data().uid !== request.auth.uid) {
    return { available: false, reason: "That handle is taken." };
  }
  return { available: true, handle };
});

/**
 * Callable: createProfile({ handle, name, avatarEmoji, city })
 *
 * Called immediately after Firebase sign-up. Atomically claims
 * `handles/{handle}` and writes `users/{uid}` in one transaction, so two people
 * racing for the same handle can't both win. Idempotent: calling again with an
 * existing profile returns it untouched rather than failing.
 */
exports.createProfile = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};

  const userRef = db.doc(`users/${uid}`);

  // Fast path: profile already exists (re-install, retry, double-tap).
  const existing = await userRef.get();
  if (existing.exists) {
    return { profile: { ...publicProfile(existing.data()), friendCode: existing.data().friendCode } };
  }

  const handle = normalizeHandle(data.handle);
  const name = typeof data.name === "string" ? data.name.trim().slice(0, 40) : "";
  if (!name) {
    throw new HttpsError("invalid-argument", "Name is required.");
  }
  const avatarEmoji = typeof data.avatarEmoji === "string" && data.avatarEmoji.length <= 8
    ? data.avatarEmoji
    : "🙂";
  const city = typeof data.city === "string" ? data.city.trim().slice(0, 60) : "";
  const referredBy = typeof data.referredBy === "string" ? data.referredBy.slice(0, 64) : null;

  const profile = await db.runTransaction(async (tx) => {
    // ---- reads first (Firestore transactions require it) ----
    const userSnap = await tx.get(userRef);
    if (userSnap.exists) {
      return userSnap.data(); // won the race against another call from us
    }

    const handleRef = db.doc(`handles/${handle}`);
    const handleSnap = await tx.get(handleRef);
    if (handleSnap.exists && handleSnap.data().uid !== uid) {
      throw new HttpsError("already-exists", "That handle is taken.");
    }

    // Pick the first free friend code out of a handful of candidates. Claim
    // docs make the code unique the same way handles are unique.
    const candidates = Array.from({ length: 5 }, generateFriendCode);
    const codeSnaps = await Promise.all(
      candidates.map((code) => tx.get(db.doc(`friendCodes/${code}`)))
    );
    const freeIndex = codeSnaps.findIndex((snap) => !snap.exists);
    if (freeIndex === -1) {
      throw new HttpsError("resource-exhausted", "Could not allocate a friend code. Try again.");
    }
    const friendCode = candidates[freeIndex];

    // ---- writes ----
    const record = {
      uid,
      handle,
      handleDisplay: (typeof data.handle === "string" ? data.handle.trim().replace(/^@/, "") : handle),
      name,
      avatarEmoji,
      city,
      bio: "",
      friendCode,
      isPrivate: false,
      createdAt: FieldValue.serverTimestamp(),
      ...(referredBy ? { referredBy } : {}),
    };

    tx.set(handleRef, { uid, at: FieldValue.serverTimestamp() });
    tx.set(db.doc(`friendCodes/${friendCode}`), { uid, at: FieldValue.serverTimestamp() });
    tx.set(userRef, record);

    return record;
  });

  return { profile: { ...publicProfile(profile), friendCode: profile.friendCode } };
});

/**
 * Callable: getStreamToken
 *
 * The app calls this right after Firebase sign-in/sign-up. Behind the scenes
 * it upserts a matching Stream user (id = Firebase uid) and returns a token.
 * The user never sees Stream — chat just works.
 */
exports.getStreamToken = onCall({ secrets: [streamApiSecret] }, async (request) => {
  const auth = request.auth;
  if (!auth) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }

  const serverClient = StreamChat.getInstance(STREAM_API_KEY, streamApiSecret.value());

  // Quietly create/update the matching Stream user.
  await serverClient.upsertUser({
    id: auth.uid,
    name: auth.token.name || auth.token.email || "Explog user",
    image: auth.token.picture || undefined,
  });

  return {
    apiKey: STREAM_API_KEY,
    userId: auth.uid,
    token: serverClient.createToken(auth.uid),
  };
});

/**
 * Callable: joinStreamChannel
 *
 * Client-side channel creation can't grant membership on a channel that
 * already exists without the caller in it — adding yourself to a channel
 * requires already being a member. This runs with the admin-privileged
 * server secret so it always works, whether the channel is brand new or
 * was created earlier (e.g. by a different test account) without this user.
 */
exports.joinStreamChannel = onCall({ secrets: [streamApiSecret] }, async (request) => {
  const auth = request.auth;
  if (!auth) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }

  const { channelId, members, name } = request.data || {};
  if (typeof channelId !== "string" || !channelId) {
    throw new HttpsError("invalid-argument", "channelId is required.");
  }
  const otherMembers = Array.isArray(members) ? members.filter((id) => typeof id === "string") : [];

  const serverClient = StreamChat.getInstance(STREAM_API_KEY, streamApiSecret.value());
  const channel = serverClient.channel("messaging", channelId, {
    created_by_id: auth.uid,
    members: [...otherMembers, auth.uid],
    ...(name ? { name } : {}),
  });
  await channel.create();
  // Guarantees membership even if the channel pre-existed without this user.
  await channel.addMembers([auth.uid]);

  return { ok: true };
});
