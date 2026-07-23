// Smoke test for the Stream messaging layer (no Firebase, no app needed).
// Run from the functions/ dir:  node test-stream.js
// Reads the secret from ../.stream/creds.yaml so nothing is hard-coded here.
const fs = require("fs");
const path = require("path");
const { StreamChat } = require("stream-chat");

const creds = fs.readFileSync(path.join(__dirname, "..", ".stream", "creds.yaml"), "utf8");
const KEY = creds.match(/^key:\s*(\S+)/m)[1];
const SECRET = creds.match(/^secret:\s*(\S+)/m)[1];

(async () => {
  const server = StreamChat.getInstance(KEY, SECRET);
  const CH = "explog-smoketest";
  try {
    await server.upsertUsers([{ id: "test_alice", name: "Alice" }, { id: "test_bob", name: "Bob" }]);
    console.log("✓ upserted users");

    const ch = server.channel("messaging", CH, {
      created_by_id: "test_alice",
      members: ["test_alice", "test_bob"],
    });
    await ch.create();
    console.log("✓ channel created with both members");

    const sent = await ch.sendMessage({ text: "smoke test @ " + new Date().toISOString(), user_id: "test_alice" });
    console.log("✓ message sent:", sent.message.id);

    const state = await ch.query({ messages: { limit: 3 } });
    console.log("✓ read back", state.messages.length, "msg(s). latest:", state.messages.at(-1).text);

    console.log("✓ client token for bob:", server.createToken("test_bob").slice(0, 24) + "...");

    await server.deleteChannels(["messaging:" + CH], { hard_delete: true });
    console.log("✓ cleaned up. Stream messaging works.");
  } catch (e) {
    console.error("✗ FAILED:", e.message);
    process.exit(1);
  }
})();
