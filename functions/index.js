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
