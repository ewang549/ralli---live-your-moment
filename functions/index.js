const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const { getAuth } = require("firebase-admin/auth");
const { getMessaging } = require("firebase-admin/messaging");
const { StreamChat } = require("stream-chat");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getStorage } = require("firebase-admin/storage");
const { randomInt, createHash } = require("crypto");

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
    viewerCount: data.viewerCount || 0,
    followerCount: data.followerCount || 0,
    avatarURL: data.avatarURL || "",
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

  // A blocked account should be indistinguishable from one that isn't there.
  const [iBlockedThem, theyBlockedMe] = await Promise.all([
    blockedRef(uid, targetUid).get(),
    blockedRef(targetUid, uid).get(),
  ]);
  if (iBlockedThem.exists || theyBlockedMe.exists) {
    throw new HttpsError("not-found", "No one found with that ID.");
  }

  // Ship the relationship with the profile so the result card's button can
  // render Add / Requested / Friends immediately instead of flashing "Add"
  // for someone you already added.
  return {
    profile: publicProfile(target.data()),
    status: await relationship(uid, targetUid),
  };
});

// ---------------------------------------------------------------------------
// Discovery (Phase 6)
//
// lookupUser above is the exact-match path: one handle or one code, one answer.
// Search is the fuzzy path — you half-remember a name — and needs a different
// shape (a list) and different guards (it can't be allowed to walk the
// directory, so the query has a floor and the page has a ceiling).
// ---------------------------------------------------------------------------

// Firestore prefix range: everything sorting between `term` and `term` plus a
// code point above any character a handle or name can contain.
const PREFIX_END = "\uf8ff";

/**
 * Attaches relationship + block state to a batch of candidate profiles, and
 * drops the ones the caller must not see.
 *
 * Blocks are filtered in both directions: someone I blocked, and someone who
 * blocked me, are equally absent — a search result is exactly the kind of
 * surface a blocked person would use to check whether they've been blocked.
 *
 * The caller's own edge sets are read once here rather than per candidate;
 * per-candidate `relationship()` calls would turn a 15-result search into
 * ninety document reads.
 */
async function decorateCandidates(uid, docs, limit) {
  const seen = new Set();
  const candidates = [];
  for (const doc of docs) {
    if (doc.id === uid || seen.has(doc.id)) continue;
    seen.add(doc.id);
    candidates.push(doc);
  }
  if (!candidates.length) return [];

  const [friends, outgoing, incoming, blocked] = await Promise.all([
    edgeUids(uid, "friends"),
    edgeUids(uid, "outgoingRequests"),
    edgeUids(uid, "incomingRequests"),
    edgeUids(uid, "blocked"),
  ]);
  const friendSet = new Set(friends);
  const outgoingSet = new Set(outgoing);
  const incomingSet = new Set(incoming);
  const blockedSet = new Set(blocked);

  // Trimmed before the reverse-block reads so an over-long candidate list
  // can't fan out into an unbounded number of gets.
  const visible = candidates.filter((doc) => !blockedSet.has(doc.id)).slice(0, limit * 2);

  // Only the reverse direction needs a per-candidate read; our own blocks are
  // already in the set above.
  const blockedMe = await Promise.all(
    visible.map((doc) => blockedRef(doc.id, uid).get().then((snap) => snap.exists))
  );

  return visible
    .filter((_, index) => !blockedMe[index])
    .slice(0, limit)
    .map((doc) => ({
      profile: publicProfile(doc.data()),
      status: friendSet.has(doc.id) ? "friends"
        : outgoingSet.has(doc.id) ? "requested"
          : incomingSet.has(doc.id) ? "incoming"
            : "none",
    }));
}

/**
 * Callable: searchUsers({ query, limit }) -> { results: [{ profile, status }] }
 *
 * Prefix search over handle and name. Two queries rather than one because
 * Firestore has no OR across fields; the union is deduped below.
 *
 * The two-character floor matters: a one-character prefix returns a slice of
 * the whole directory, which is enumeration with extra steps. Combined with the
 * shared lookupUser rate limiter, that keeps this from becoming a scraping
 * endpoint.
 */
exports.searchUsers = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};

  const raw = typeof data.query === "string" ? data.query.trim().replace(/^@/, "") : "";
  const term = raw.toLowerCase();
  if (term.length < 2) return { results: [] };

  const limit = Math.min(Math.max(Number(data.limit) || 15, 1), 25);

  const limiter = await enforceRateLimit(uid, "lookupUser", {
    maxAttempts: 20,
    windowMs: 5 * 60 * 1000,
    maxFailures: 25,
    lockoutMs: 30 * 60 * 1000,
  });

  const [byHandle, byName] = await Promise.all([
    db.collection("users")
      .orderBy("handle")
      .startAt(term).endAt(term + PREFIX_END)
      .limit(limit)
      .get(),
    db.collection("users")
      .orderBy("nameLower")
      .startAt(term).endAt(term + PREFIX_END)
      .limit(limit)
      .get(),
  ]);

  // Handle matches first: an exact-ish handle is the strongest signal of who
  // the searcher meant.
  const results = await decorateCandidates(uid, [...byHandle.docs, ...byName.docs], limit);
  await limiter.record(results.length > 0);

  return { results };
});

/**
 * Callable: suggestedFriends({ limit }) -> { suggestions: [{ profile, status, mutuals }] }
 *
 * "People you may know", from two cheap signals: friends-of-friends (ranked by
 * how many mutuals) and same city. Mutuals win — a shared friend is a much
 * stronger hint than a shared metro area.
 *
 * Everything already in the graph is excluded, so the list is only ever people
 * the caller could actually act on.
 */
exports.suggestedFriends = onCall(async (request) => {
  const uid = requireAuth(request);
  const limit = Math.min(Math.max(Number((request.data || {}).limit) || 10, 1), 20);

  const [friendUids, incomingUids, outgoingUids, blockedUids, me] = await Promise.all([
    edgeUids(uid, "friends"),
    edgeUids(uid, "incomingRequests"),
    edgeUids(uid, "outgoingRequests"),
    edgeUids(uid, "blocked"),
    db.doc(`users/${uid}`).get(),
  ]);

  // Anyone already connected to, pending with, or blocked by the caller.
  const excluded = new Set([uid, ...friendUids, ...incomingUids, ...outgoingUids, ...blockedUids]);

  // Friends-of-friends. Capped at 20 friends so a well-connected account
  // doesn't turn one tap into hundreds of subcollection reads.
  const mutuals = new Map();
  const sampled = friendUids.slice(0, 20);
  await Promise.all(sampled.map(async (friendUid) => {
    const theirs = await edgeUids(friendUid, "friends", 100);
    for (const candidate of theirs) {
      if (excluded.has(candidate)) continue;
      mutuals.set(candidate, (mutuals.get(candidate) || 0) + 1);
    }
  }));

  // Same city, for accounts with no friends yet — otherwise a brand new user
  // sees an empty suggestion list forever.
  const city = me.exists ? (me.data().city || "") : "";
  const cityDocs = [];
  if (city) {
    const snap = await db.collection("users")
      .where("city", "==", city)
      .limit(30)
      .get();
    cityDocs.push(...snap.docs.filter((doc) => !excluded.has(doc.id) && !mutuals.has(doc.id)));
  }

  const ranked = [...mutuals.entries()].sort((a, b) => b[1] - a[1]).slice(0, limit);
  const mutualDocs = ranked.length
    ? (await db.getAll(...ranked.map(([id]) => db.doc(`users/${id}`)))).filter((doc) => doc.exists)
    : [];

  const decorated = await decorateCandidates(uid, [...mutualDocs, ...cityDocs], limit);

  return {
    suggestions: decorated.map((entry) => ({
      ...entry,
      mutuals: mutuals.get(entry.profile.uid) || 0,
    })),
  };
});

/**
 * Callable: publicProfileFor({ uid }) -> { profile, status, mutuals }
 *
 * Backs the profile sheet opened from a search result or an avatar. Goes
 * through a function rather than a direct read so the block check and the
 * mutual count happen server-side — a blocked account must 404 here exactly as
 * it does in search.
 */
exports.publicProfileFor = onCall(async (request) => {
  const uid = requireAuth(request);
  const targetUid = requireUidArg((request.data || {}).uid, "uid");

  if (targetUid === uid) {
    const me = await db.doc(`users/${uid}`).get();
    if (!me.exists) throw new HttpsError("not-found", "Profile not found.");
    return { profile: publicProfile(me.data()), status: "none", mutuals: 0, following: false };
  }

  const [target, iBlockedThem, theyBlockedMe] = await Promise.all([
    db.doc(`users/${targetUid}`).get(),
    blockedRef(uid, targetUid).get(),
    blockedRef(targetUid, uid).get(),
  ]);

  if (!target.exists || theyBlockedMe.exists) {
    throw new HttpsError("not-found", "That account isn't available.");
  }

  // My own block doesn't hide them from me — I need to see the profile to
  // unblock. It's their block on me that makes them disappear.
  if (iBlockedThem.exists) {
    return { profile: publicProfile(target.data()), status: "blocked", mutuals: 0, following: false };
  }

  // Every other-person view bumps their public "total viewers" counter.
  // Fire-and-forget: a slow write here must never hold up opening a profile.
  db.doc(`users/${targetUid}`).update({ viewerCount: FieldValue.increment(1) }).catch(() => {});

  // The follow edge rides along here so the sheet can render the right button
  // state on first paint rather than after a second round trip.
  const [status, mine, theirs, followEdge] = await Promise.all([
    relationship(uid, targetUid),
    edgeUids(uid, "friends"),
    edgeUids(targetUid, "friends"),
    followingRef(uid, targetUid).get(),
  ]);
  const theirSet = new Set(theirs);
  const mutuals = mine.filter((id) => theirSet.has(id)).length;

  // The increment above is fire-and-forget, so reflect it in this response
  // immediately rather than re-reading — the viewer shouldn't have to refresh
  // to see their own view counted.
  const targetData = target.data();
  const profile = { ...publicProfile(targetData), viewerCount: (targetData.viewerCount || 0) + 1 };

  return { profile, status, mutuals, following: followEdge.exists };
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
      // Folded copy of `name` purely so searchUsers can run a prefix range on
      // it — Firestore has no case-insensitive query. The rules keep this in
      // step with `name` on client-side edits.
      nameLower: name.toLowerCase(),
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

// ---------------------------------------------------------------------------
// Friend graph
//
// Shape (all written by these functions only — clients read, never write):
//   users/{uid}/friends/{friendUid}         { since }
//   users/{uid}/incomingRequests/{fromUid}  { at }
//   users/{uid}/outgoingRequests/{toUid}    { at }
//   users/{uid}/blocked/{blockedUid}        { at }   (Phase 4 writes it; we honour it now)
//
// Every edge is stored on both sides. That doubles the writes but makes the
// only query the client ever needs — "who are my friends?" — a single
// subcollection read with no index and no fan-out.
// ---------------------------------------------------------------------------

const friendRef = (uid, otherUid) => db.doc(`users/${uid}/friends/${otherUid}`);
const incomingRef = (uid, fromUid) => db.doc(`users/${uid}/incomingRequests/${fromUid}`);
const outgoingRef = (uid, toUid) => db.doc(`users/${uid}/outgoingRequests/${toUid}`);
const blockedRef = (uid, otherUid) => db.doc(`users/${uid}/blocked/${otherUid}`);

/** Validates a uid argument and returns it, or throws invalid-argument. */
function requireUidArg(raw, field) {
  if (typeof raw !== "string" || !raw.trim() || raw.length > 128) {
    throw new HttpsError("invalid-argument", `${field} is required.`);
  }
  return raw.trim();
}

/**
 * Throws if either side has blocked the other.
 *
 * Deliberately symmetric and deliberately vague in its message: telling the
 * caller "they blocked you" leaks the block itself, which is exactly the thing
 * a blocked person should not be able to probe for.
 */
async function assertNotBlocked(uid, otherUid) {
  const [iBlockedThem, theyBlockedMe] = await Promise.all([
    blockedRef(uid, otherUid).get(),
    blockedRef(otherUid, uid).get(),
  ]);
  if (iBlockedThem.exists || theyBlockedMe.exists) {
    throw new HttpsError("permission-denied", "That account isn't available.");
  }
}

/**
 * Deterministic DM channel id for two real accounts.
 *
 * Keyed on sorted Firebase uids, which is what a real account's Stream user id
 * actually is (see getStreamToken). The client's older name-slug ids stay for
 * demo rows; anything involving a real friendship resolves through here so both
 * sides compute the same channel.
 */
function dmChannelId(a, b) {
  return `dm-${[a, b].sort().join("-")}`;
}

/** Creates (or backfills membership on) the DM channel for two users. */
async function ensureDmChannel(a, b) {
  const serverClient = StreamChat.getInstance(STREAM_API_KEY, streamApiSecret.value());
  const channel = serverClient.channel("messaging", dmChannelId(a, b), {
    created_by_id: a,
    members: [a, b],
  });
  await channel.create();
  // Covers the case where the channel already existed without one of them.
  await channel.addMembers([a, b]);
}

/** Reads a page of uids out of one of the edge subcollections. */
async function edgeUids(uid, collection, limit = 500) {
  const snap = await db.collection(`users/${uid}/${collection}`).limit(limit).get();
  return snap.docs.map((doc) => doc.id);
}

/** Batch-loads public profiles for a list of uids, skipping any that vanished. */
async function profilesFor(uids) {
  if (!uids.length) return [];
  const refs = uids.map((id) => db.doc(`users/${id}`));
  const snaps = await db.getAll(...refs);
  return snaps.filter((snap) => snap.exists).map((snap) => publicProfile(snap.data()));
}

/**
 * Relationship between the caller and another user, as the UI's button states:
 * "friends" | "requested" (I asked them) | "incoming" (they asked me) | "none".
 */
async function relationship(uid, otherUid) {
  const [friend, outgoing, incoming] = await Promise.all([
    friendRef(uid, otherUid).get(),
    outgoingRef(uid, otherUid).get(),
    incomingRef(uid, otherUid).get(),
  ]);
  if (friend.exists) return "friends";
  if (outgoing.exists) return "requested";
  if (incoming.exists) return "incoming";
  return "none";
}

/**
 * Writes both halves of a friendship and clears any pending requests between
 * the pair. Caller supplies the transaction so this composes with state checks.
 *
 * `accepter` is whoever acted; `requester` is who had asked. Only the
 * requester's copy of the edge is flagged, because they're the one who doesn't
 * know yet — the accepter just tapped the button. The flag has to live on the
 * doc: the request docs are deleted in this same transaction, so a trigger
 * firing afterwards has no other way to tell the two sides apart.
 */
function commitFriendship(tx, accepter, requester) {
  const since = FieldValue.serverTimestamp();
  tx.set(friendRef(accepter, requester), { uid: requester, since });
  tx.set(friendRef(requester, accepter), { uid: accepter, since, notifyAccepted: true });
  tx.delete(incomingRef(accepter, requester));
  tx.delete(incomingRef(requester, accepter));
  tx.delete(outgoingRef(accepter, requester));
  tx.delete(outgoingRef(requester, accepter));
}

/**
 * Callable: sendFriendRequest({ toUid }) -> { status }
 *
 * `status` is the resulting relationship, so the button can settle without a
 * second round trip. Idempotent: re-sending an existing request is a no-op that
 * reports "requested" rather than an error.
 *
 * If they had already requested *us*, this accepts instead of queueing a second
 * request — two people tapping Add on each other should end up friends, not
 * staring at inboxes waiting for the other to move.
 */
exports.sendFriendRequest = onCall({ secrets: [streamApiSecret] }, async (request) => {
  const uid = requireAuth(request);
  const toUid = requireUidArg((request.data || {}).toUid, "toUid");

  if (toUid === uid) {
    throw new HttpsError("invalid-argument", "You can't add yourself.");
  }

  const target = await db.doc(`users/${toUid}`).get();
  if (!target.exists) {
    throw new HttpsError("not-found", "That account no longer exists.");
  }

  await assertNotBlocked(uid, toUid);

  // Outbound requests are the spammable direction, so they get their own
  // budget: enough for a real person adding a group of friends, far short of
  // what a script would want.
  const limiter = await enforceRateLimit(uid, "sendFriendRequest", {
    maxAttempts: 30,
    windowMs: 60 * 60 * 1000,   // 30 requests per hour
    maxFailures: 1000,          // failure lockout is meaningless here
    lockoutMs: 60 * 60 * 1000,
  });
  await limiter.record(true);

  const status = await db.runTransaction(async (tx) => {
    const [friend, outgoing, incoming] = await Promise.all([
      tx.get(friendRef(uid, toUid)),
      tx.get(outgoingRef(uid, toUid)),
      tx.get(incomingRef(uid, toUid)),
    ]);

    if (friend.exists) return "friends";
    if (outgoing.exists) return "requested";

    if (incoming.exists) {
      // They asked first — treat this tap as the accept.
      commitFriendship(tx, uid, toUid);
      return "friends";
    }

    const at = FieldValue.serverTimestamp();
    tx.set(outgoingRef(uid, toUid), { uid: toUid, at });
    tx.set(incomingRef(toUid, uid), { uid, at });
    return "requested";
  });

  if (status === "friends") {
    await ensureDmChannel(uid, toUid);
  }
  return { status };
});

/**
 * Callable: acceptFriendRequest({ fromUid }) -> { status }
 *
 * Creates both edges and clears the request docs in one transaction, then makes
 * sure the DM channel exists so the per-row message button works the instant
 * the friendship appears.
 */
exports.acceptFriendRequest = onCall({ secrets: [streamApiSecret] }, async (request) => {
  const uid = requireAuth(request);
  const fromUid = requireUidArg((request.data || {}).fromUid, "fromUid");

  if (fromUid === uid) {
    throw new HttpsError("invalid-argument", "You can't add yourself.");
  }
  await assertNotBlocked(uid, fromUid);

  await db.runTransaction(async (tx) => {
    const [friend, incoming] = await Promise.all([
      tx.get(friendRef(uid, fromUid)),
      tx.get(incomingRef(uid, fromUid)),
    ]);
    if (friend.exists) return;            // already accepted (double tap)
    if (!incoming.exists) {
      throw new HttpsError("failed-precondition", "That request is no longer pending.");
    }
    commitFriendship(tx, uid, fromUid);
  });

  await ensureDmChannel(uid, fromUid);
  return { status: "friends" };
});

/** Callable: declineFriendRequest({ fromUid }) — drops their request to us. */
exports.declineFriendRequest = onCall(async (request) => {
  const uid = requireAuth(request);
  const fromUid = requireUidArg((request.data || {}).fromUid, "fromUid");

  const batch = db.batch();
  batch.delete(incomingRef(uid, fromUid));
  batch.delete(outgoingRef(fromUid, uid));
  await batch.commit();

  return { status: "none" };
});

/** Callable: cancelFriendRequest({ toUid }) — withdraws our request to them. */
exports.cancelFriendRequest = onCall(async (request) => {
  const uid = requireAuth(request);
  const toUid = requireUidArg((request.data || {}).toUid, "toUid");

  const batch = db.batch();
  batch.delete(outgoingRef(uid, toUid));
  batch.delete(incomingRef(toUid, uid));
  await batch.commit();

  return { status: "none" };
});

/**
 * Callable: removeFriend({ friendUid })
 *
 * Drops both edges. The Stream channel is deliberately left alone — removing a
 * friend shouldn't destroy the message history either side already has.
 */
exports.removeFriend = onCall(async (request) => {
  const uid = requireAuth(request);
  const friendUid = requireUidArg((request.data || {}).friendUid, "friendUid");

  const batch = db.batch();
  batch.delete(friendRef(uid, friendUid));
  batch.delete(friendRef(friendUid, uid));
  await batch.commit();

  return { status: "none" };
});

/**
 * Callable: listFriends() -> { friends: [profile] }
 *
 * Goes through a function rather than a client read so the response is public
 * profiles, not raw edge docs the client would then have to resolve one by one.
 */
exports.listFriends = onCall(async (request) => {
  const uid = requireAuth(request);
  const uids = await edgeUids(uid, "friends");
  return { friends: await profilesFor(uids) };
});

/**
 * Callable: listRequests() -> { incoming: [profile], outgoing: [profile] }
 *
 * Backs the requests inbox. Both directions in one call — the inbox shows them
 * together and a single round trip keeps the badge and the list consistent.
 */
exports.listRequests = onCall(async (request) => {
  const uid = requireAuth(request);
  const [incomingUids, outgoingUids] = await Promise.all([
    edgeUids(uid, "incomingRequests"),
    edgeUids(uid, "outgoingRequests"),
  ]);
  const [incoming, outgoing] = await Promise.all([
    profilesFor(incomingUids),
    profilesFor(outgoingUids),
  ]);
  return { incoming, outgoing };
});

// ---------------------------------------------------------------------------
// Follow graph (lightweight, one-directional)
//
//   users/{uid}/following/{followingUid}  { uid, since }
//   users/{uid}/followers/{followerUid}   { uid, since }
//   users/{uid}.followerCount / .followingCount
//
// Deliberately *not* the friend graph. A follow needs no acceptance, carries no
// DM channel, and grants no access to private details — it only says "put their
// highlights in my feed". Both halves are written for the same reason the friend
// edges are: "who follows me?" and "who do I follow?" each stay a single
// subcollection read.
//
// The counts are denormalised onto the profile doc and maintained inside the
// same transaction as the edges. A client read-count-and-write would lose
// increments whenever two people followed the same person at once.
// ---------------------------------------------------------------------------

const followingRef = (uid, otherUid) => db.doc(`users/${uid}/following/${otherUid}`);
const followerRef = (uid, followerUid) => db.doc(`users/${uid}/followers/${followerUid}`);

/**
 * Callable: followUser({ uid }) -> { following, followerCount }
 *
 * Idempotent: following someone you already follow reports the current state
 * rather than double-counting. Blocked either direction is refused with the
 * same vague message every other graph write uses.
 */
exports.followUser = onCall(async (request) => {
  const uid = requireAuth(request);
  const targetUid = requireUidArg((request.data || {}).uid, "uid");

  if (targetUid === uid) {
    throw new HttpsError("invalid-argument", "You can't follow yourself.");
  }
  await assertNotBlocked(uid, targetUid);

  const targetRef = db.doc(`users/${targetUid}`);
  const selfRef = db.doc(`users/${uid}`);

  const followerCount = await db.runTransaction(async (tx) => {
    // Every read first — Firestore transactions reject a read after a write.
    const [edge, target, self] = await Promise.all([
      tx.get(followingRef(uid, targetUid)),
      tx.get(targetRef),
      tx.get(selfRef),
    ]);

    if (!target.exists) {
      throw new HttpsError("not-found", "That account isn't available.");
    }
    const current = target.data().followerCount || 0;
    if (edge.exists) return current;

    const since = FieldValue.serverTimestamp();
    tx.set(followingRef(uid, targetUid), { uid: targetUid, since });
    tx.set(followerRef(targetUid, uid), { uid, since });
    tx.update(targetRef, { followerCount: FieldValue.increment(1) });
    // Guarded: a caller who is authed but hasn't finished onboarding has no
    // profile doc yet, and `update` on a missing document throws.
    if (self.exists) tx.update(selfRef, { followingCount: FieldValue.increment(1) });
    return current + 1;
  });

  return { following: true, followerCount };
});

/**
 * Callable: unfollowUser({ uid }) -> { following, followerCount }
 *
 * Also idempotent, and clamped at zero so a double-unfollow (or an edge that
 * outlived its counter) can't drive the count negative.
 */
exports.unfollowUser = onCall(async (request) => {
  const uid = requireAuth(request);
  const targetUid = requireUidArg((request.data || {}).uid, "uid");

  const targetRef = db.doc(`users/${targetUid}`);
  const selfRef = db.doc(`users/${uid}`);

  const followerCount = await db.runTransaction(async (tx) => {
    const [edge, target, self] = await Promise.all([
      tx.get(followingRef(uid, targetUid)),
      tx.get(targetRef),
      tx.get(selfRef),
    ]);

    const current = target.exists ? target.data().followerCount || 0 : 0;
    if (!edge.exists) return current;

    tx.delete(followingRef(uid, targetUid));
    tx.delete(followerRef(targetUid, uid));
    if (target.exists && current > 0) {
      tx.update(targetRef, { followerCount: FieldValue.increment(-1) });
    }
    if (self.exists && (self.data().followingCount || 0) > 0) {
      tx.update(selfRef, { followingCount: FieldValue.increment(-1) });
    }
    return Math.max(0, current - 1);
  });

  return { following: false, followerCount };
});

/**
 * Callable: listFollowing() -> { following: [profile] }
 *
 * Backs the Following tab under Places, which composes a feed out of the
 * highlights of everyone here.
 */
exports.listFollowing = onCall(async (request) => {
  const uid = requireAuth(request);
  const uids = await edgeUids(uid, "following");
  return { following: await profilesFor(uids) };
});

// ---------------------------------------------------------------------------
// Safety: block & report (Phase 4)
//
//   users/{uid}/blocked/{blockedUid}  { uid, at }
//   reports/{reportId}                { reporterUid, targetUid, targetType, ... }
//
// The block doc is the authority. Every read path that could surface a person
// or their content already consults it (lookupUser, listFriendLogs, the message
// webhook, assertNotBlocked on the request callables) — this section is what
// finally writes it, plus the Stream-side enforcement that stops a blocked
// account from reaching an existing DM channel.
//
// Blocking is deliberately one-sided in storage and two-sided in effect: only
// the blocker's doc is written, and every check looks at both directions. That
// way the blocked party never gains a document they could observe.
// ---------------------------------------------------------------------------

/**
 * Applies (or lifts) the Stream half of a block on the pair's DM channel.
 *
 * Best-effort by design. The Firestore doc is what every server path enforces,
 * so a Stream outage must not fail the block — it would leave the user staring
 * at an error having decided they want someone gone. Failures are logged and
 * the channel-level ban can be re-applied by toggling the block.
 *
 * Two mechanisms, because they cover different directions: the channel ban
 * stops them sending to us, the mute stops their existing messages rendering
 * for us.
 */
async function applyStreamBlock(uid, otherUid, blocking) {
  const serverClient = StreamChat.getInstance(STREAM_API_KEY, streamApiSecret.value());
  const channel = serverClient.channel("messaging", dmChannelId(uid, otherUid));

  try {
    if (blocking) {
      await channel.banUser(otherUid, {
        banned_by_id: uid,
        reason: "Blocked by the other member.",
      });
      await serverClient.muteUser(otherUid, uid);
    } else {
      await channel.unbanUser(otherUid);
      await serverClient.unmuteUser(otherUid, uid);
    }
  } catch (error) {
    // No channel between them yet is the common, uninteresting case.
    console.warn(`stream block ${blocking ? "apply" : "lift"} failed`, {
      uid, otherUid, message: error && error.message,
    });
  }
}

/**
 * Callable: blockUser({ uid }) -> { status }
 *
 * Severs everything in one transaction: the friendship (both edges) and any
 * pending request in either direction. Leaving a request behind would let it
 * reappear in an inbox after the block, and leaving the friend edge behind
 * would keep them in the roster.
 */
exports.blockUser = onCall({ secrets: [streamApiSecret] }, async (request) => {
  const uid = requireAuth(request);
  const targetUid = requireUidArg((request.data || {}).uid, "uid");

  if (targetUid === uid) {
    throw new HttpsError("invalid-argument", "You can't block yourself.");
  }

  // Generous — blocking is a legitimate burst action when someone is being
  // harassed — but not unbounded.
  const limiter = await enforceRateLimit(uid, "blockUser", {
    maxAttempts: 60,
    windowMs: 60 * 60 * 1000,
    maxFailures: 10000,
    lockoutMs: 60 * 60 * 1000,
  });
  await limiter.record(true);

  const batch = db.batch();
  batch.set(blockedRef(uid, targetUid), {
    uid: targetUid,
    at: FieldValue.serverTimestamp(),
  });
  batch.delete(friendRef(uid, targetUid));
  batch.delete(friendRef(targetUid, uid));
  batch.delete(incomingRef(uid, targetUid));
  batch.delete(incomingRef(targetUid, uid));
  batch.delete(outgoingRef(uid, targetUid));
  batch.delete(outgoingRef(targetUid, uid));
  await batch.commit();

  await applyStreamBlock(uid, targetUid, true);

  return { status: "blocked" };
});

/**
 * Callable: unblockUser({ uid }) -> { status }
 *
 * Lifts the block only. The friendship is *not* restored — un-blocking says
 * "I'll see them again", not "we're friends again"; re-adding is a separate,
 * deliberate act.
 */
exports.unblockUser = onCall({ secrets: [streamApiSecret] }, async (request) => {
  const uid = requireAuth(request);
  const targetUid = requireUidArg((request.data || {}).uid, "uid");

  await blockedRef(uid, targetUid).delete();
  await applyStreamBlock(uid, targetUid, false);

  return { status: "none" };
});

/**
 * Callable: listBlocked() -> { blocked: [profile] }
 *
 * Backs the "Blocked accounts" list in Profile, which is the only place an
 * unblock can be reached — once someone is blocked they're gone from search,
 * feeds and chat by design, so there is nowhere else to tap them.
 */
exports.listBlocked = onCall(async (request) => {
  const uid = requireAuth(request);
  const uids = await edgeUids(uid, "blocked");
  return { blocked: await profilesFor(uids) };
});

// What a reporter can pick. Free text goes in `details`; the reason itself is
// constrained so the review queue is filterable and can't be stuffed.
const REPORT_REASONS = new Set([
  "spam", "harassment", "nudity", "violence", "hate", "impersonation",
  "self_harm", "other",
]);

const REPORT_TARGET_TYPES = new Set(["user", "log", "message"]);

/**
 * Writes one report doc. Clients never touch `reports` directly — the rules
 * deny it outright — so this is the only way in, and it's the only place that
 * decides what a report contains.
 */
async function fileReport(uid, { targetUid, targetType, targetId, reason, details }) {
  if (targetUid === uid) {
    throw new HttpsError("invalid-argument", "You can't report yourself.");
  }
  if (!REPORT_REASONS.has(reason)) {
    throw new HttpsError("invalid-argument", "Pick a reason.");
  }

  // Reports are a moderation queue, not a firehose. A real person files a
  // handful; a script filing hundreds is the abuse case this guards.
  const limiter = await enforceRateLimit(uid, "report", {
    maxAttempts: 20,
    windowMs: 60 * 60 * 1000,
    maxFailures: 10000,
    lockoutMs: 60 * 60 * 1000,
  });
  await limiter.record(true);

  const ref = db.collection("reports").doc();
  await ref.set({
    id: ref.id,
    reporterUid: uid,
    targetUid,
    targetType,
    targetId,
    reason,
    details: cleanText(details, 1000),
    status: "open",
    createdAt: FieldValue.serverTimestamp(),
  });

  return { id: ref.id };
}

/**
 * Callable: reportUser({ targetUid, reason, details?, block? }) -> { id }
 *
 * `block` is offered because reporting someone almost always means you also
 * want them gone; doing both in one call saves the user a second decision at
 * the worst possible moment.
 */
exports.reportUser = onCall({ secrets: [streamApiSecret] }, async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const targetUid = requireUidArg(data.targetUid, "targetUid");

  const result = await fileReport(uid, {
    targetUid,
    targetType: "user",
    targetId: targetUid,
    reason: cleanText(data.reason, 40),
    details: data.details,
  });

  if (data.block === true) {
    const batch = db.batch();
    batch.set(blockedRef(uid, targetUid), {
      uid: targetUid,
      at: FieldValue.serverTimestamp(),
    });
    batch.delete(friendRef(uid, targetUid));
    batch.delete(friendRef(targetUid, uid));
    batch.delete(incomingRef(uid, targetUid));
    batch.delete(incomingRef(targetUid, uid));
    batch.delete(outgoingRef(uid, targetUid));
    batch.delete(outgoingRef(targetUid, uid));
    await batch.commit();
    await applyStreamBlock(uid, targetUid, true);
  }

  return { ...result, blocked: data.block === true };
});

/**
 * Callable: reportContent({ targetId, targetType, targetUid?, reason, details? })
 *
 * For a specific log or message rather than the account as a whole. The author
 * is resolved server-side for logs so a report can't be misattributed to
 * whoever the client claims made it.
 */
exports.reportContent = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const targetId = requireUidArg(data.targetId, "targetId");

  const targetType = REPORT_TARGET_TYPES.has(data.targetType) && data.targetType !== "user"
    ? data.targetType
    : "log";

  let targetUid = typeof data.targetUid === "string" ? data.targetUid.trim() : "";
  if (targetType === "log") {
    // Authorship comes from the doc, never from the caller.
    const snap = await db.doc(`logs/${targetId}`).get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "That post is no longer available.");
    }
    targetUid = snap.data().authorUid;
  }
  if (!targetUid) {
    throw new HttpsError("invalid-argument", "targetUid is required.");
  }

  return await fileReport(uid, {
    targetUid,
    targetType,
    targetId,
    reason: cleanText(data.reason, 40),
    details: data.details,
  });
});

// ---------------------------------------------------------------------------
// Logs (Phase 2: content sync)
//
// `logs/{logId}`: { authorUid, mediaURL, storagePath, kind, caption, emoji,
//                   hueA, hueB, capturedAt, hour, audience }
//
// Media itself goes straight to Storage from the client (it's a big upload and
// has no business passing through a function); this only records the metadata,
// which is what needs validating. Reads go through listFriendLogs so friendship
// and blocks are enforced server-side and clients never query the collection.
// ---------------------------------------------------------------------------

const LOG_KINDS = new Set(["video", "photo", "vibe"]);
const LOG_AUDIENCES = new Set(["friends", "public"]);

/** Clamped, trimmed string or "" — captions are user text going to other users. */
function cleanText(raw, max) {
  return typeof raw === "string" ? raw.trim().slice(0, max) : "";
}

function cleanHue(raw) {
  const value = typeof raw === "number" && Number.isFinite(raw) ? raw : 0;
  // Wrap rather than clamp: hues are cyclic, and a wrapped value still renders.
  return ((value % 1) + 1) % 1;
}

/**
 * Callable: publishLog({...}) -> { id, capturedAt }
 *
 * Records a captured log so the author's friends can see it. Storage path is
 * verified to live under the caller's own prefix — without that check a client
 * could point a log doc at somebody else's media.
 */
exports.publishLog = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};

  const kind = typeof data.kind === "string" && LOG_KINDS.has(data.kind) ? data.kind : null;
  if (!kind) {
    throw new HttpsError("invalid-argument", "Unknown log kind.");
  }

  const storagePath = cleanText(data.storagePath, 512);
  const mediaURL = cleanText(data.mediaURL, 2048);

  // A vibe clip is generated art with no upload; everything else must carry
  // media, and that media must be the caller's own.
  if (kind === "vibe") {
    if (storagePath || mediaURL) {
      throw new HttpsError("invalid-argument", "Vibe logs carry no media.");
    }
  } else {
    if (!storagePath || !mediaURL) {
      throw new HttpsError("invalid-argument", "Media is required.");
    }
    if (!storagePath.startsWith(`logs/${uid}/`)) {
      throw new HttpsError("permission-denied", "That media isn't yours.");
    }
  }

  // Posting is cheap but not free — cap it well above the hourly cadence so a
  // normal user never notices, while a runaway client does.
  const limiter = await enforceRateLimit(uid, "publishLog", {
    maxAttempts: 60,
    windowMs: 60 * 60 * 1000,
    maxFailures: 10000,
    lockoutMs: 60 * 60 * 1000,
  });
  await limiter.record(true);

  // Trust the client's capture time only within reason: it drives feed order,
  // so a bad clock (or a client trying to pin itself to the top) gets pulled
  // back to now.
  const now = Date.now();
  const claimed = typeof data.capturedAt === "number" ? data.capturedAt : now;
  const capturedMs = Math.min(Math.max(claimed, now - 24 * 3600 * 1000), now);
  const capturedAt = new Date(capturedMs);

  // Friends stays the default, so a client that predates the audience field
  // keeps behaving exactly as it did.
  const audience = LOG_AUDIENCES.has(data.audience) ? data.audience : "friends";

  // A public log has to say where it was taken — the public feed is organised
  // by place, and an unplaced public post has nowhere to appear.
  let spotId = null;
  let spot = null;
  if (audience === "public") {
    spotId = requireUidArg(data.spotId, "spotId");
    const spotSnap = await db.doc(`spots/${spotId}`).get();
    if (!spotSnap.exists) {
      throw new HttpsError("not-found", "That place no longer exists.");
    }
    spot = spotSnap.data();
  }

  // Author identity is denormalised onto public logs: the Places feed renders
  // attribution for people the viewer has no relationship with, and resolving
  // a profile per clip would be a fan-out on every scroll. `authorUid` is still
  // the real identity — this is only what's needed to draw the row.
  let author = null;
  if (audience === "public") {
    const me = await db.doc(`users/${uid}`).get();
    author = me.exists ? me.data() : null;
  }

  const ref = db.collection("logs").doc();
  await ref.set({
    id: ref.id,
    authorUid: uid,
    kind,
    storagePath: storagePath || null,
    mediaURL: mediaURL || null,
    caption: cleanText(data.caption, 140),
    emoji: cleanText(data.emoji, 8) || "✨",
    hueA: cleanHue(data.hueA),
    hueB: cleanHue(data.hueB),
    capturedAt,
    // Bucket for the hourly model, so a feed can group by the hour it belongs
    // to without every reader re-deriving it.
    hour: new Date(capturedMs).toISOString().slice(0, 13),
    audience,
    spotId,
    spotName: spot ? spot.name : null,
    authorName: author ? author.name || "" : null,
    authorHandle: author ? author.handleDisplay || author.handle || "" : null,
    authorAvatarEmoji: author ? author.avatarEmoji || "🙂" : null,
    authorAvatarURL: author ? author.avatarURL || "" : null,
    createdAt: FieldValue.serverTimestamp(),
  });

  if (spotId) {
    await db.doc(`spots/${spotId}`).update({
      clipCount: FieldValue.increment(1),
      lastPostedAt: FieldValue.serverTimestamp(),
    });
  }

  return { id: ref.id, capturedAt: capturedMs, audience, spotId };
});

/** Shapes a stored log doc for the wire, including its denormalised author. */
function publicLogPayload(log) {
  return {
    id: log.id,
    authorUid: log.authorUid,
    authorName: log.authorName || "",
    authorHandle: log.authorHandle || "",
    authorAvatarEmoji: log.authorAvatarEmoji || "🙂",
    authorAvatarURL: log.authorAvatarURL || "",
    spotId: log.spotId || "",
    spotName: log.spotName || "",
    kind: log.kind,
    mediaURL: log.mediaURL || "",
    caption: log.caption || "",
    emoji: log.emoji || "✨",
    hueA: typeof log.hueA === "number" ? log.hueA : 0,
    hueB: typeof log.hueB === "number" ? log.hueB : 0,
    capturedAt: log.capturedAt && log.capturedAt.toMillis
      ? log.capturedAt.toMillis()
      : Date.now(),
  };
}

/**
 * Public logs, newest first, with both directions of blocking applied.
 *
 * `audience == "public"` is part of the query rather than a filter applied
 * afterwards, so friends-only content can never leak into a public feed even if
 * the rest of this function is wrong.
 *
 * Blocking is asymmetric in storage — only the blocker holds an edge — so
 * "people who blocked me" can't be read from the caller's own document. It's
 * resolved instead with one batched `getAll` over the distinct authors on this
 * page, which is a handful of point reads rather than a fan-out per clip.
 */
async function publicLogsFor(uid, { spotId = null, limit = 60 } = {}) {
  let query = db.collection("logs").where("audience", "==", "public");
  if (spotId) query = query.where("spotId", "==", spotId);

  // Over-fetch: some of this page will be dropped by the block filter below,
  // and a short page is better than a second round trip.
  const snap = await query.orderBy("capturedAt", "desc").limit(limit * 2).get();
  const rows = snap.docs.map((doc) => doc.data());
  if (!rows.length) return [];

  const authors = [...new Set(rows.map((log) => log.authorUid).filter(Boolean))];
  const [blockedUids, reverse] = await Promise.all([
    edgeUids(uid, "blocked"),
    authors.length
      ? db.getAll(...authors.map((author) => blockedRef(author, uid)))
      : Promise.resolve([]),
  ]);

  const hidden = new Set(blockedUids);
  reverse.forEach((snapshot, index) => {
    if (snapshot.exists) hidden.add(authors[index]);
  });

  return rows
    .filter((log) => !hidden.has(log.authorUid))
    .map(publicLogPayload)
    .slice(0, limit);
}

/**
 * Callable: listPublicLogs({ limit, spotId }) -> { logs: [...] }
 *
 * The Places feed. `spotId` narrows it to a single place's clips.
 */
exports.listPublicLogs = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const spotId = typeof data.spotId === "string" && data.spotId.trim()
    ? data.spotId.trim()
    : null;
  const logs = await publicLogsFor(uid, {
    spotId,
    limit: Math.min(Math.max(Number(data.limit) || 60, 1), 200),
  });
  return { logs };
});

/**
 * Callable: listSpotLogs({ spotId, limit }) -> { logs: [...] }
 *
 * One place's public clips — what a spot detail view shows.
 */
exports.listSpotLogs = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const logs = await publicLogsFor(uid, {
    spotId: requireUidArg(data.spotId, "spotId"),
    limit: Math.min(Math.max(Number(data.limit) || 60, 1), 200),
  });
  return { logs };
});

/**
 * Callable: listFriendLogs({ limit }) -> { logs: [...] }
 *
 * Recent logs from everyone the caller is friends with. The friend set is read
 * server-side, so a client can't ask for a stranger's content, and blocked
 * accounts are dropped even if an edge somehow survived.
 */
exports.listFriendLogs = onCall(async (request) => {
  const uid = requireAuth(request);
  const limit = Math.min(Math.max(Number((request.data || {}).limit) || 60, 1), 200);

  const [friendUids, blockedUids] = await Promise.all([
    edgeUids(uid, "friends"),
    edgeUids(uid, "blocked"),
  ]);
  const blocked = new Set(blockedUids);
  const visible = friendUids.filter((id) => !blocked.has(id));
  if (!visible.length) return { logs: [] };

  // `in` tops out at 30 values, so fan out in chunks and merge. Each chunk is
  // ordered and capped server-side; the merge below re-sorts the union.
  const chunks = [];
  for (let i = 0; i < visible.length; i += 30) {
    chunks.push(visible.slice(i, i + 30));
  }

  const snaps = await Promise.all(chunks.map((chunk) =>
    db.collection("logs")
      .where("authorUid", "in", chunk)
      .orderBy("capturedAt", "desc")
      .limit(limit)
      .get()
  ));

  const logs = snaps
    .flatMap((snap) => snap.docs.map((doc) => doc.data()))
    .filter((log) => !blocked.has(log.authorUid))
    .map((log) => ({
      id: log.id,
      authorUid: log.authorUid,
      kind: log.kind,
      mediaURL: log.mediaURL || "",
      caption: log.caption || "",
      emoji: log.emoji || "✨",
      hueA: typeof log.hueA === "number" ? log.hueA : 0,
      hueB: typeof log.hueB === "number" ? log.hueB : 0,
      capturedAt: log.capturedAt && log.capturedAt.toMillis
        ? log.capturedAt.toMillis()
        : Date.now(),
    }))
    .sort((a, b) => b.capturedAt - a.capturedAt)
    .slice(0, limit);

  return { logs };
});

// ---------------------------------------------------------------------------
// Spots
//
// `spots/{spotId}`: { id, name, nameLower, category, summary, address,
//                     latitude, longitude, emoji, hueA, hueB, createdBy,
//                     clipCount, createdAt }
//
// Places come from the client's MapKit search, so this collection isn't a place
// database — it's the shared identity layer over one. Its whole job is that two
// accounts picking the same café converge on the same `spotId`, which is what
// makes a spot findable by someone who didn't create it.
// ---------------------------------------------------------------------------

/**
 * Deterministic id for a place: normalised name plus coordinates rounded to
 * ~11m. Two people selecting the same MapKit result derive the same id, so
 * "create or reuse" is a single addressed write with no query, no transaction,
 * and no chance of two racing clients producing duplicate spots.
 */
function spotIdFor(name, latitude, longitude) {
  const key = [
    name.trim().toLowerCase().replace(/\s+/g, " "),
    latitude.toFixed(4),
    longitude.toFixed(4),
  ].join("@");
  return createHash("sha1").update(key).digest("hex").slice(0, 20);
}

function cleanCoordinate(raw, limit) {
  const value = Number(raw);
  if (!Number.isFinite(value) || Math.abs(value) > limit) {
    throw new HttpsError("invalid-argument", "That location isn't valid.");
  }
  return value;
}

function spotPayload(data) {
  return {
    id: data.id,
    name: data.name || "",
    category: data.category || "",
    summary: data.summary || "",
    address: data.address || "",
    latitude: typeof data.latitude === "number" ? data.latitude : 0,
    longitude: typeof data.longitude === "number" ? data.longitude : 0,
    emoji: data.emoji || "📍",
    hueA: typeof data.hueA === "number" ? data.hueA : 0,
    hueB: typeof data.hueB === "number" ? data.hueB : 0,
    clipCount: typeof data.clipCount === "number" ? data.clipCount : 0,
  };
}

/**
 * Callable: upsertSpot({ name, latitude, longitude, ... }) -> { spot }
 *
 * Create-or-reuse for a place the caller picked out of location search.
 * Idempotent by construction: the id is derived from the place itself, so
 * calling this twice for the same café returns the same spot rather than a
 * second copy of it.
 */
exports.upsertSpot = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};

  const name = cleanText(data.name, 120);
  if (!name) throw new HttpsError("invalid-argument", "A place needs a name.");

  const latitude = cleanCoordinate(data.latitude, 90);
  const longitude = cleanCoordinate(data.longitude, 180);

  const limiter = await enforceRateLimit(uid, "upsertSpot", {
    maxAttempts: 60,
    windowMs: 60 * 60 * 1000,
    maxFailures: 10000,
    lockoutMs: 60 * 60 * 1000,
  });
  await limiter.record(true);

  const id = spotIdFor(name, latitude, longitude);
  const ref = db.doc(`spots/${id}`);
  const existing = await ref.get();

  if (existing.exists) {
    // Someone already created this place. Its details belong to whoever got
    // there first — a later caller supplying a thinner MapKit result must not
    // overwrite a richer record.
    return { spot: spotPayload(existing.data()) };
  }

  const record = {
    id,
    name,
    nameLower: name.toLowerCase(),
    category: cleanText(data.category, 60),
    summary: cleanText(data.summary, 280),
    address: cleanText(data.address, 240),
    latitude,
    longitude,
    emoji: cleanText(data.emoji, 8) || "📍",
    hueA: cleanHue(data.hueA),
    hueB: cleanHue(data.hueB),
    createdBy: uid,
    clipCount: 0,
    createdAt: FieldValue.serverTimestamp(),
  };
  await ref.set(record);

  return { spot: spotPayload(record) };
});

/**
 * Callable: searchSpots({ query, limit }) -> { spots: [...] }
 *
 * Prefix search over spots other people have already created — the path by
 * which a second account finds a place without re-deriving it from MapKit.
 */
exports.searchSpots = onCall(async (request) => {
  requireAuth(request);
  const data = request.data || {};
  const term = cleanText(data.query, 80).toLowerCase();
  if (!term) return { spots: [] };

  const limit = Math.min(Math.max(Number(data.limit) || 15, 1), 50);

  // Same prefix-range trick `searchUsers` uses: PREFIX_END sorts above any
  // character that can follow the term.
  const snap = await db.collection("spots")
    .orderBy("nameLower")
    .startAt(term)
    .endAt(term + PREFIX_END)
    .limit(limit)
    .get();

  return { spots: snap.docs.map((doc) => spotPayload(doc.data())) };
});

/**
 * Callable: deleteLog({ id })
 *
 * Removes the doc and its media. Authors only — checked against the stored
 * `authorUid`, never against anything the caller supplies.
 */
exports.deleteLog = onCall(async (request) => {
  const uid = requireAuth(request);
  const id = requireUidArg((request.data || {}).id, "id");

  const ref = db.doc(`logs/${id}`);
  const snap = await ref.get();
  if (!snap.exists) return { ok: true };
  if (snap.data().authorUid !== uid) {
    throw new HttpsError("permission-denied", "That log isn't yours.");
  }

  const storagePath = snap.data().storagePath;
  if (storagePath) {
    await getStorage().bucket().file(storagePath).delete().catch(() => {});
  }
  await ref.delete();
  return { ok: true };
});

// ---------------------------------------------------------------------------
// Beacons
//
// `beacons/{beaconId}`: { id, hostUid, host* (denormalised), spotId, spot*,
//                         note, startsAt, capacity, isPublic, joinedUids[],
//                         createdAt }
//
// Same shape as logs: clients never query the collection, they call
// listFriendBeacons / listPublicBeacons, so friendship, blocking, capacity and
// the public-profile rule are all decided server-side. A beacon carries no
// media, so unlike a log there's nothing to upload first — the callable is the
// whole write.
//
// Host and spot identity are denormalised onto the doc for the same reason
// public logs denormalise their author: the public feed renders beacons hosted
// by people the viewer has no relationship with, and resolving a profile and a
// place per card would be a fan-out on every scroll.
// ---------------------------------------------------------------------------

const BEACON_MIN_CAPACITY = 2;
const BEACON_MAX_CAPACITY = 50;
/** How long past its start time a beacon keeps appearing in the feeds. */
const BEACON_LIFETIME_MS = 6 * 60 * 60 * 1000;
/** How far ahead one may be scheduled. */
const BEACON_MAX_LEAD_MS = 30 * 24 * 60 * 60 * 1000;

/** Shapes a stored beacon doc for the wire. */
function beaconPayload(beacon) {
  return {
    id: beacon.id,
    hostUid: beacon.hostUid || "",
    hostName: beacon.hostName || "",
    hostHandle: beacon.hostHandle || "",
    hostAvatarEmoji: beacon.hostAvatarEmoji || "🙂",
    hostAvatarURL: beacon.hostAvatarURL || "",
    spotId: beacon.spotId || "",
    spotName: beacon.spotName || "",
    spotCategory: beacon.spotCategory || "",
    spotAddress: beacon.spotAddress || "",
    spotEmoji: beacon.spotEmoji || "📍",
    spotHueA: typeof beacon.spotHueA === "number" ? beacon.spotHueA : 0,
    spotHueB: typeof beacon.spotHueB === "number" ? beacon.spotHueB : 0,
    note: beacon.note || "",
    startsAt: beacon.startsAt && beacon.startsAt.toMillis
      ? beacon.startsAt.toMillis()
      : Date.now(),
    capacity: typeof beacon.capacity === "number" ? beacon.capacity : BEACON_MIN_CAPACITY,
    isPublic: beacon.isPublic === true,
    joinedUids: Array.isArray(beacon.joinedUids) ? beacon.joinedUids : [],
  };
}

/** False once a beacon has aged out — it stays visible a while after starting. */
function beaconIsLive(beacon, now) {
  const startsAt = beacon.startsAt && beacon.startsAt.toMillis ? beacon.startsAt.toMillis() : 0;
  return startsAt + BEACON_LIFETIME_MS > now;
}

/**
 * The caller's profile.
 *
 * Hosting and joining both depend on `isPrivate`, and an account with no
 * profile doc has no answer to that question — better to say so than to guess
 * "public" for someone who never chose it.
 */
async function requireProfile(uid) {
  const snap = await db.doc(`users/${uid}`).get();
  if (!snap.exists) {
    throw new HttpsError("failed-precondition", "Finish setting up your profile first.");
  }
  return snap.data();
}

/**
 * Callable: createBeacon({ spotId, note, startsAt, capacity, isPublic })
 *   -> { beacon }
 *
 * `spotId` is optional — a beacon needn't be pinned to a place — but when one is
 * given it has to be a real spot, so a card can't claim a venue that doesn't
 * exist.
 */
exports.createBeacon = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};

  const note = cleanText(data.note, 280);
  const capacity = Math.min(
    Math.max(Math.round(Number(data.capacity) || BEACON_MIN_CAPACITY), BEACON_MIN_CAPACITY),
    BEACON_MAX_CAPACITY
  );
  const isPublic = data.isPublic === true;

  const profile = await requireProfile(uid);
  // The public-profile rule, enforced where it counts. The client checks it too,
  // but a client check only shapes the UI — it is not the rule.
  if (isPublic && profile.isPrivate === true) {
    throw new HttpsError("failed-precondition",
      "Set your profile to public to host a community activity.");
  }

  // Same treatment as a log's capture time: trusted only within reason, since
  // it drives feed order and how long the beacon lives.
  const now = Date.now();
  const claimed = typeof data.startsAt === "number" && Number.isFinite(data.startsAt)
    ? data.startsAt
    : now;
  const startsMs = Math.min(Math.max(claimed, now - 60 * 60 * 1000), now + BEACON_MAX_LEAD_MS);

  let spotId = null;
  let spot = null;
  if (typeof data.spotId === "string" && data.spotId.trim()) {
    spotId = data.spotId.trim();
    const spotSnap = await db.doc(`spots/${spotId}`).get();
    if (!spotSnap.exists) {
      throw new HttpsError("not-found", "That place no longer exists.");
    }
    spot = spotSnap.data();
  }

  const limiter = await enforceRateLimit(uid, "createBeacon", {
    maxAttempts: 30,
    windowMs: 60 * 60 * 1000,
    maxFailures: 10000,
    lockoutMs: 60 * 60 * 1000,
  });
  await limiter.record(true);

  const ref = db.collection("beacons").doc();
  const record = {
    id: ref.id,
    hostUid: uid,
    hostName: profile.name || "",
    hostHandle: profile.handleDisplay || profile.handle || "",
    hostAvatarEmoji: profile.avatarEmoji || "🙂",
    hostAvatarURL: profile.avatarURL || "",
    spotId,
    spotName: spot ? spot.name || "" : "",
    spotCategory: spot ? spot.category || "" : "",
    spotAddress: spot ? spot.address || "" : "",
    spotEmoji: spot ? spot.emoji || "📍" : "📍",
    spotHueA: spot && typeof spot.hueA === "number" ? spot.hueA : 0,
    spotHueB: spot && typeof spot.hueB === "number" ? spot.hueB : 0,
    note,
    startsAt: new Date(startsMs),
    capacity,
    isPublic,
    joinedUids: [],
    createdAt: FieldValue.serverTimestamp(),
  };
  await ref.set(record);

  // `record.startsAt` is a plain Date here, not the Timestamp a read would
  // return, so the millis go on explicitly rather than through beaconPayload.
  return { beacon: { ...beaconPayload(record), startsAt: startsMs } };
});

/**
 * Callable: joinBeacon({ beaconId }) -> { joinedUids }
 *
 * Transactional because capacity is the point: two clients racing for the last
 * spot must not both get it, which a read-then-write outside a transaction
 * cannot promise.
 */
exports.joinBeacon = onCall(async (request) => {
  const uid = requireAuth(request);
  const beaconId = requireUidArg((request.data || {}).beaconId, "beaconId");
  const profile = await requireProfile(uid);
  const ref = db.doc(`beacons/${beaconId}`);

  const joinedUids = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new HttpsError("not-found", "That beacon is gone.");
    }
    const beacon = snap.data();

    if (!beaconIsLive(beacon, Date.now())) {
      throw new HttpsError("failed-precondition", "That beacon has already ended.");
    }

    const current = Array.isArray(beacon.joinedUids) ? beacon.joinedUids : [];
    // The host is attending by definition; there's nothing to add.
    if (beacon.hostUid === uid) return current;

    if (beacon.isPublic) {
      if (profile.isPrivate === true) {
        throw new HttpsError("failed-precondition",
          "Set your profile to public to join a community activity.");
      }
    } else {
      // Friends-only. The guest list is the host's friend list, so it's read off
      // the edge rather than taken from whoever called.
      const edge = await tx.get(friendRef(uid, beacon.hostUid));
      if (!edge.exists) {
        throw new HttpsError("permission-denied", "That beacon is for the host's friends.");
      }
    }

    // Idempotent: joining twice is a no-op, not an error, so a retried request
    // can't consume a second spot.
    if (current.includes(uid)) return current;
    if (current.length >= beacon.capacity) {
      throw new HttpsError("resource-exhausted", "That beacon is full.");
    }

    const next = [...current, uid];
    tx.update(ref, { joinedUids: next });
    return next;
  });

  return { joinedUids };
});

/**
 * Callable: leaveBeacon({ beaconId }) -> { joinedUids }
 *
 * Unconditional and idempotent — dropping an RSVP needs no permission check,
 * and a beacon that's already gone is a successful leave.
 */
exports.leaveBeacon = onCall(async (request) => {
  const uid = requireAuth(request);
  const beaconId = requireUidArg((request.data || {}).beaconId, "beaconId");
  const ref = db.doc(`beacons/${beaconId}`);

  const joinedUids = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return [];
    const current = Array.isArray(snap.data().joinedUids) ? snap.data().joinedUids : [];
    const next = current.filter((id) => id !== uid);
    if (next.length !== current.length) tx.update(ref, { joinedUids: next });
    return next;
  });

  return { joinedUids };
});

/**
 * Callable: listFriendBeacons({ limit }) -> { beacons: [...] }
 *
 * Friends-only beacons hosted by the caller's friends, plus the caller's own —
 * so a host sees what they created on every device they sign in on. Same
 * chunked `in` fan-out as listFriendLogs, since `in` tops out at 30 values.
 */
exports.listFriendBeacons = onCall(async (request) => {
  const uid = requireAuth(request);
  const limit = Math.min(Math.max(Number((request.data || {}).limit) || 60, 1), 200);

  const [friendUids, blockedUids] = await Promise.all([
    edgeUids(uid, "friends"),
    edgeUids(uid, "blocked"),
  ]);
  const blocked = new Set(blockedUids);
  const visible = [uid, ...friendUids.filter((id) => !blocked.has(id))];

  const cutoff = new Date(Date.now() - BEACON_LIFETIME_MS);
  const chunks = [];
  for (let i = 0; i < visible.length; i += 30) {
    chunks.push(visible.slice(i, i + 30));
  }

  const snaps = await Promise.all(chunks.map((chunk) =>
    db.collection("beacons")
      .where("hostUid", "in", chunk)
      .where("startsAt", ">=", cutoff)
      .orderBy("startsAt", "asc")
      .limit(limit)
      .get()
  ));

  // `isPublic` is filtered here rather than in the query: adding a third
  // constraint would need another composite index to buy nothing, since the
  // page is already bounded by the two above.
  const beacons = snaps
    .flatMap((snap) => snap.docs.map((doc) => doc.data()))
    .filter((beacon) => beacon.isPublic !== true)
    .map(beaconPayload)
    .sort((a, b) => a.startsAt - b.startsAt)
    .slice(0, limit);

  return { beacons };
});

/**
 * Callable: listPublicBeacons({ limit }) -> { beacons: [...] }
 *
 * The community feed. No relationship required, so blocking is the only filter
 * — resolved in both directions the same way publicLogsFor does it, with one
 * batched getAll over the distinct hosts on this page.
 */
exports.listPublicBeacons = onCall(async (request) => {
  const uid = requireAuth(request);
  const limit = Math.min(Math.max(Number((request.data || {}).limit) || 60, 1), 200);
  const cutoff = new Date(Date.now() - BEACON_LIFETIME_MS);

  const snap = await db.collection("beacons")
    .where("isPublic", "==", true)
    .where("startsAt", ">=", cutoff)
    .orderBy("startsAt", "asc")
    // Over-fetch: some of this page will be dropped by the block filter below.
    .limit(limit * 2)
    .get();

  const rows = snap.docs.map((doc) => doc.data());
  if (!rows.length) return { beacons: [] };

  const hosts = [...new Set(rows.map((beacon) => beacon.hostUid).filter(Boolean))];
  const [blockedUids, reverse] = await Promise.all([
    edgeUids(uid, "blocked"),
    hosts.length
      ? db.getAll(...hosts.map((host) => blockedRef(host, uid)))
      : Promise.resolve([]),
  ]);

  const hidden = new Set(blockedUids);
  reverse.forEach((snapshot, index) => {
    if (snapshot.exists) hidden.add(hosts[index]);
  });

  const beacons = rows
    .filter((beacon) => !hidden.has(beacon.hostUid))
    .map(beaconPayload)
    .slice(0, limit);

  return { beacons };
});

/**
 * Callable: deleteBeacon({ beaconId })
 *
 * Hosts only, checked against the stored `hostUid` — same rule as deleteLog.
 */
exports.deleteBeacon = onCall(async (request) => {
  const uid = requireAuth(request);
  const beaconId = requireUidArg((request.data || {}).beaconId, "beaconId");

  const ref = db.doc(`beacons/${beaconId}`);
  const snap = await ref.get();
  if (!snap.exists) return { ok: true };
  if (snap.data().hostUid !== uid) {
    throw new HttpsError("permission-denied", "That beacon isn't yours.");
  }
  await ref.delete();
  return { ok: true };
});

// ---------------------------------------------------------------------------
// Push notifications (Phase 3)
//
// Device tokens live at `users/{uid}/devices/{token}`, written by the client.
// Everything below fans a message out to every token an account has registered,
// and prunes tokens the FCM service reports as dead — a stale token otherwise
// accumulates forever and slows every later send.
// ---------------------------------------------------------------------------

/**
 * Sends one notification to every device registered to `uid`.
 *
 * `data` travels alongside the alert and is what the client's `PushDestination`
 * decodes to decide where a tap should land.
 */
async function notify(uid, { title, body, data = {} }) {
  const devices = await db.collection(`users/${uid}/devices`).get();
  const tokens = devices.docs.map((doc) => doc.id).filter(Boolean);
  if (!tokens.length) return;

  const response = await getMessaging().sendEachForMulticast({
    tokens,
    notification: { title, body },
    // FCM requires every data value to be a string.
    data: Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)])),
    apns: {
      payload: { aps: { sound: "default", badge: 1 } },
    },
  });

  // Drop tokens the service says are gone (app deleted, token rotated).
  const dead = [];
  response.responses.forEach((result, index) => {
    const code = result.error && result.error.code;
    if (code === "messaging/registration-token-not-registered"
        || code === "messaging/invalid-registration-token") {
      dead.push(tokens[index]);
    }
  });
  await Promise.all(dead.map((token) =>
    db.doc(`users/${uid}/devices/${token}`).delete().catch(() => {})
  ));
}

/** Display name for a uid, for notification copy. */
async function displayName(uid) {
  const snap = await db.doc(`users/${uid}`).get();
  if (!snap.exists) return "Someone";
  const data = snap.data();
  return data.name || `@${data.handle}` || "Someone";
}

/**
 * Trigger: someone received a friend request.
 *
 * Fires on the *target's* incoming doc, which is written by sendFriendRequest,
 * so there is exactly one notification per request regardless of retries.
 */
exports.onFriendRequest = onDocumentCreated(
  "users/{uid}/incomingRequests/{fromUid}",
  async (event) => {
    const { uid, fromUid } = event.params;
    const name = await displayName(fromUid);
    await notify(uid, {
      title: "New friend request",
      body: `${name} wants to be friends on Ralli.`,
      data: { type: "friend_request", fromUid },
    });
  }
);

/**
 * Trigger: a friend request was accepted.
 *
 * Notifies only the person who *sent* the request — the accepter already knows,
 * they just tapped the button. `since` is written by commitFriendship on both
 * sides, so this fires for each; the guard below keeps it to the right one.
 */
exports.onFriendAccepted = onDocumentCreated(
  "users/{uid}/friends/{friendUid}",
  async (event) => {
    const { uid, friendUid } = event.params;

    // Both edges are written together, so this trigger fires twice. Only the
    // requester's copy carries `notifyAccepted` — see commitFriendship.
    const edge = event.data && event.data.data();
    if (!edge || edge.notifyAccepted !== true) return;

    const name = await displayName(friendUid);
    await notify(uid, {
      title: "You're now friends",
      body: `${name} accepted your friend request.`,
      data: { type: "friend_accepted", friendUid },
    });
  }
);

/**
 * HTTP: Stream message webhook.
 *
 * Point Stream's "before/after message" webhook at this URL. Stream signs each
 * request with the app secret; the signature is verified before anything is
 * sent, otherwise this endpoint would let anyone push arbitrary notifications
 * to any user.
 */
exports.streamMessageWebhook = onRequest(
  { secrets: [streamApiSecret] },
  async (request, response) => {
    if (request.method !== "POST") {
      response.status(405).send("Method not allowed");
      return;
    }

    const serverClient = StreamChat.getInstance(STREAM_API_KEY, streamApiSecret.value());
    const signature = request.get("x-signature");
    const rawBody = request.rawBody ? request.rawBody.toString() : JSON.stringify(request.body);

    if (!signature || !serverClient.verifyWebhook(rawBody, signature)) {
      response.status(401).send("Bad signature");
      return;
    }

    const event = request.body || {};
    if (event.type !== "message.new") {
      response.status(200).send("ignored");
      return;
    }

    const senderId = event.user && event.user.id;
    const members = Array.isArray(event.members) ? event.members : [];
    const text = (event.message && event.message.text) || "sent you something";
    const channelId = event.channel_id || "";

    const recipients = members
      .map((member) => member.user_id || (member.user && member.user.id))
      .filter((id) => id && id !== senderId);

    const name = senderId ? await displayName(senderId) : "Someone";

    await Promise.all(recipients.map(async (uid) => {
      // Respect blocks: a blocked sender shouldn't be able to buzz a phone.
      const blocked = await blockedRef(uid, senderId).get().catch(() => ({ exists: false }));
      if (blocked.exists) return;
      await notify(uid, {
        title: name,
        body: text.slice(0, 140),
        data: { type: "message", channelId, fromUid: senderId || "" },
      });
    }));

    response.status(200).send("ok");
  }
);

/**
 * Scheduled: nudge people whose streak is about to lapse.
 *
 * Runs in the evening. A streak here means "logged on consecutive days", so the
 * thing worth warning about is having a live streak and nothing logged today.
 */
exports.streakReminder = onSchedule(
  { schedule: "0 20 * * *", timeZone: "America/Los_Angeles" },
  async () => {
    const dayStart = new Date();
    dayStart.setHours(0, 0, 0, 0);

    // Everyone who posted today is safe; everyone else with a recent streak
    // gets one nudge.
    const todaysLogs = await db.collection("logs")
      .where("capturedAt", ">=", dayStart)
      .get();
    const postedToday = new Set(todaysLogs.docs.map((doc) => doc.data().authorUid));

    // "Has a streak" = logged yesterday but not today.
    const yesterdayStart = new Date(dayStart.getTime() - 24 * 3600 * 1000);
    const yesterdaysLogs = await db.collection("logs")
      .where("capturedAt", ">=", yesterdayStart)
      .where("capturedAt", "<", dayStart)
      .get();

    const atRisk = new Set(
      yesterdaysLogs.docs
        .map((doc) => doc.data().authorUid)
        .filter((uid) => !postedToday.has(uid))
    );

    await Promise.all([...atRisk].map((uid) => notify(uid, {
      title: "Your streak is about to break",
      body: "Post a log before midnight to keep it alive.",
      data: { type: "streak" },
    }).catch(() => {})));
  }
);

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

// ---------------------------------------------------------------------------
// Account deletion (Phase 5 — App Store Guideline 5.1.1(v))
//
// "Delete my account" has to mean it: the directory record, the handle and
// friend-code claims, every edge pointing back at this account, the published
// logs and their media, the Stream identity, and finally the Firebase Auth
// user itself.
// ---------------------------------------------------------------------------

// Every action enforceRateLimit is called with. Listed explicitly because the
// limiter docs are keyed `{uid}__{action}` and there is no prefix query for
// them; missing one leaves an inert counter behind, not a leak.
const RATE_LIMIT_ACTIONS = [
  "lookupUser", "resolveFriendCode", "sendFriendRequest", "publishLog",
  "blockUser", "report",
];

/**
 * Deletes the edges *other* accounts hold pointing back at `uid`.
 *
 * The account's own subcollections go with the recursive delete below; these
 * are the mirrored halves, which live under other users' documents and would
 * otherwise linger as rows referencing an account that no longer exists.
 */
async function deleteReciprocalEdges(uid) {
  const [friends, incoming, outgoing, following, followers] = await Promise.all([
    edgeUids(uid, "friends", 1000),
    edgeUids(uid, "incomingRequests", 1000),
    edgeUids(uid, "outgoingRequests", 1000),
    edgeUids(uid, "following", 1000),
    edgeUids(uid, "followers", 1000),
  ]);

  const writer = db.bulkWriter();
  // They have us as a friend.
  friends.forEach((other) => writer.delete(friendRef(other, uid)));
  // They asked us — their outgoing copy.
  incoming.forEach((other) => writer.delete(outgoingRef(other, uid)));
  // We asked them — their incoming copy.
  outgoing.forEach((other) => writer.delete(incomingRef(other, uid)));
  // Follow edges, both halves, plus the counters they were feeding — a stale
  // "1 follower" pointing at a deleted account is a visible wrong number.
  following.forEach((other) => {
    writer.delete(followerRef(other, uid));
    writer.update(db.doc(`users/${other}`), { followerCount: FieldValue.increment(-1) })
      .catch(() => {});
  });
  followers.forEach((other) => {
    writer.delete(followingRef(other, uid));
    writer.update(db.doc(`users/${other}`), { followingCount: FieldValue.increment(-1) })
      .catch(() => {});
  });
  await writer.close();

  // Deliberately not touched: `users/{other}/blocked/{uid}` for people who
  // blocked us. Finding those needs a collection-group query, and the docs are
  // inert once the account is gone — they name a uid that can never be
  // reissued, so nothing about the deleted account survives in them.
}

/** Deletes every log this account published, plus its media. */
async function deleteAuthoredLogs(uid) {
  const snap = await db.collection("logs").where("authorUid", "==", uid).get();
  if (snap.empty) return;

  const writer = db.bulkWriter();
  snap.docs.forEach((doc) => writer.delete(doc.ref));
  await writer.close();
}

/**
 * Callable: deleteAccount() -> { ok }
 *
 * Ordered so that a failure part-way through leaves the account recoverable
 * rather than orphaned: everything the user owns goes first, and the Firebase
 * Auth record — the thing that lets them sign back in and retry — goes last.
 */
exports.deleteAccount = onCall({ secrets: [streamApiSecret] }, async (request) => {
  const uid = requireAuth(request);

  const profileRef = db.doc(`users/${uid}`);
  const profileSnap = await profileRef.get();
  const profile = profileSnap.exists ? profileSnap.data() : {};

  // 1. Other people's copies of our edges, and our published content.
  await Promise.all([
    deleteReciprocalEdges(uid),
    deleteAuthoredLogs(uid),
  ]);

  // 2. Media. One prefix sweep rather than per-log deletes, so files whose log
  //    doc was already lost still go.
  await getStorage().bucket().deleteFiles({ prefix: `logs/${uid}/` }).catch((error) => {
    console.warn("storage sweep failed", { uid, message: error && error.message });
  });

  // 3. Uniqueness claims, so the handle and code become available again.
  const claims = db.batch();
  if (profile.handle) claims.delete(db.doc(`handles/${profile.handle}`));
  if (profile.friendCode) claims.delete(db.doc(`friendCodes/${profile.friendCode}`));
  RATE_LIMIT_ACTIONS.forEach((action) => claims.delete(db.doc(`rateLimits/${uid}__${action}`)));
  await claims.commit();

  // 4. The directory record and every subcollection under it (friends,
  //    requests, blocked, devices).
  await db.recursiveDelete(profileRef);

  // 5. Stream identity and their side of every conversation.
  try {
    const serverClient = StreamChat.getInstance(STREAM_API_KEY, streamApiSecret.value());
    await serverClient.deleteUser(uid, {
      mark_messages_deleted: true,
      hard_delete: true,
      delete_conversation_channels: true,
    });
  } catch (error) {
    console.warn("stream user delete failed", { uid, message: error && error.message });
  }

  // 6. The auth record itself. Last, so every step above ran while the caller
  //    still had a valid token — and so a retry is possible if one didn't.
  await getAuth().deleteUser(uid);

  return { ok: true };
});
