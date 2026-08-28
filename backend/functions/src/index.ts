import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import express from "express";
import cors from "cors";

admin.initializeApp();

const app = express();
app.use(cors({ origin: true }));
app.use(express.json());

const db = admin.firestore();

function detectSource(url: string): "spotify" | "soundcloud" | null {
  const lowered = url.toLowerCase();
  if (lowered.includes("spotify.com")) return "spotify";
  if (lowered.includes("soundcloud.com")) return "soundcloud";
  return null;
}

app.post("/playlist/import", async (req, res) => {
  const { userId, url } = req.body ?? {};
  if (!userId || !url) {
    res.status(400).json({ error: "userId and url are required" });
    return;
  }

  const source = detectSource(url);
  if (!source) {
    res.status(400).json({ error: "Unsupported provider" });
    return;
  }

  const payload = {
    userId,
    source,
    url,
    title: source === "spotify" ? "Spotify Playlist" : "SoundCloud Set",
    description: `Imported from ${source}`,
    artworkUrl: null,
    trackCount: 0,
    importedAt: admin.firestore.FieldValue.serverTimestamp()
  };

  const doc = await db.collection("playlistLinks").add(payload);
  res.status(200).json({ id: doc.id, ...payload });
});

app.post("/ratings/toggle", async (req, res) => {
  const { userId, targetType, targetId, value } = req.body ?? {};
  if (!userId || !targetType || !targetId || !value) {
    res.status(400).json({ error: "Missing required fields" });
    return;
  }

  const key = `${userId}_${targetType}_${targetId}`;
  const ref = db.collection("ratings").doc(key);
  const payload = {
    userId,
    targetType,
    targetId,
    value,
    createdAt: admin.firestore.FieldValue.serverTimestamp()
  };

  await ref.set(payload, { merge: true });
  res.status(200).json({ id: key, ...payload });
});

app.post("/art/report", async (req, res) => {
  const { userId, artPostId, reason } = req.body ?? {};
  if (!userId || !artPostId || !reason) {
    res.status(400).json({ error: "Missing required fields" });
    return;
  }

  const report = {
    userId,
    artPostId,
    reason,
    createdAt: admin.firestore.FieldValue.serverTimestamp()
  };

  const reportRef = await db.collection("reports").add(report);
  const moderationCase = {
    artPostId,
    status: "pending",
    notes: "Created from user report",
    reviewedBy: null,
    updatedAt: admin.firestore.FieldValue.serverTimestamp()
  };
  const caseRef = await db.collection("moderationCases").add(moderationCase);

  res.status(200).json({ reportId: reportRef.id, caseId: caseRef.id });
});

app.post("/moderation/review", async (req, res) => {
  const { caseId, status, notes, reviewerId } = req.body ?? {};
  if (!caseId || !status || !reviewerId) {
    res.status(400).json({ error: "caseId, status, reviewerId required" });
    return;
  }

  const updates = {
    status,
    notes: notes ?? "",
    reviewedBy: reviewerId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp()
  };

  await db.collection("moderationCases").doc(caseId).set(updates, { merge: true });
  res.status(200).json({ caseId, ...updates });
});

app.post("/dj/preset/save", async (req, res) => {
  const { id, userId, name, crossfader, eqLow, eqMid, eqHigh, fxMode, bpmHint } = req.body ?? {};
  if (!userId || !name) {
    res.status(400).json({ error: "userId and name are required" });
    return;
  }

  const presetId = id ?? db.collection("djPresets").doc().id;
  const payload = {
    userId,
    name,
    crossfader: crossfader ?? 0.5,
    eqLow: eqLow ?? 0,
    eqMid: eqMid ?? 0,
    eqHigh: eqHigh ?? 0,
    fxMode: fxMode ?? "Clean",
    bpmHint: bpmHint ?? 120,
    updatedAt: admin.firestore.FieldValue.serverTimestamp()
  };

  await db.collection("djPresets").doc(presetId).set(payload, { merge: true });
  res.status(200).json({ id: presetId, ...payload });
});

app.post("/dj/preset/apply", async (req, res) => {
  const { presetId } = req.body ?? {};
  if (!presetId) {
    res.status(400).json({ error: "presetId is required" });
    return;
  }

  const doc = await db.collection("djPresets").doc(presetId).get();
  if (!doc.exists) {
    res.status(404).json({ error: "Preset not found" });
    return;
  }

  res.status(200).json({ id: doc.id, ...doc.data() });
});

exports.api = functions.https.onRequest(app);
