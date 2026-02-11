import fs from "node:fs/promises";
import process from "node:process";
import admin from "firebase-admin";

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var: ${name}`);
  return value;
}

function toStringValue(value) {
  if (value === null || value === undefined) return "";
  if (typeof value === "string") return value;
  if (typeof value === "number") return String(value);
  return JSON.stringify(value);
}

async function main() {
  const manifestPath = process.env.MANIFEST_PATH ?? "updates/manifest.json";
  const topic = process.env.TOPIC ?? "cellmaster-db-updates";
  const saPath = requiredEnv("FIREBASE_ADMIN_SA_JSON");

  const [manifestRaw, saRaw] = await Promise.all([
    fs.readFile(manifestPath, "utf8"),
    fs.readFile(saPath, "utf8"),
  ]);

  const manifest = JSON.parse(manifestRaw);
  const serviceAccount = JSON.parse(saRaw);

  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
  });

  const version = toStringValue(manifest.version);
  if (!version) throw new Error("Manifest missing .version");

  const message = {
    topic,
    notification: {
      title: "CellMaster update",
      body: `New tower database available: ${version}. Tap to update.`,
    },
    data: {
      event: "db_update",
      version,
      manifestUrl: "https://goldstandardsolutions.github.io/updates/manifest.json",
      releaseUrl: toStringValue(manifest.url),
      sha256: toStringValue(manifest.sha256),
      sizeBytes: toStringValue(manifest.sizeBytes),
      releasedAt: toStringValue(manifest.releasedAt),
      minAppVersion: toStringValue(manifest.minAppVersion),
    },
    apns: {
      headers: {
        "apns-priority": "10",
      },
      payload: {
        aps: {
          sound: "default",
        },
      },
    },
  };

  const messageId = await admin.messaging().send(message);
  console.log(`Sent message: ${messageId}`);
}

main().catch((err) => {
  console.error(err?.stack || String(err));
  process.exit(1);
});

