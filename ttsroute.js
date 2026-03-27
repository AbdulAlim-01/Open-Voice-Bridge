/**
 * Open-Source TTS API Route
 * Engines: Kokoro-ONNX | Piper
 *
 * POST /tts
 *   Body: { "chunk": "Hello world", "voice": "af_heart", "engine": "kokoro" }
 *   Returns: audio/wav
 *
 * GET  /tts?chunk=Hello+world&voice=af_heart&engine=kokoro
 *   Returns: audio/wav (browser test)
 *
 * GET  /tts/voices
 *   Returns: { "piper": [...], "kokoro": [...] }
 */

import { spawn }           from "child_process";
import { readdirSync }     from "fs";
import { fileURLToPath }   from "url";
import { dirname, join }   from "path";
import dotenv              from "dotenv";
import os                  from "os";

dotenv.config();

const __dirname = dirname(fileURLToPath(import.meta.url));

// ── Platform detection ─────────────────────────────────────────────────────────
const IS_WINDOWS = os.platform() === "win32";

// ── Piper ──────────────────────────────────────────────────────────────────────
// Default piper binary name differs per platform
const PIPER_DEFAULT = IS_WINDOWS ? "piper.exe" : "piper";
const PIPER_PATH    = process.env.PIPER_PATH   || join(__dirname, "engines", "piper", PIPER_DEFAULT);
const PIPER_VOICES  = process.env.PIPER_VOICES || join(__dirname, "engines", "piper", "voices");
const PIPER_SR      = parseInt(process.env.PIPER_SAMPLE_RATE || "22050");

// ── Kokoro-ONNX ────────────────────────────────────────────────────────────────
// On Windows python3 may not exist; try "python" as fallback via env
const KOKORO_PYTHON  = process.env.PYTHON_PATH    || (IS_WINDOWS ? "python" : "python3");
const KOKORO_SCRIPT  = process.env.KOKORO_SCRIPT  || join(__dirname, "engines", "kokoro", "kokoro_tts.py");
const KOKORO_VOICE   = process.env.KOKORO_VOICE   || "af_heart";
const KOKORO_SR      = parseInt(process.env.KOKORO_SAMPLE_RATE || "24000");

// ── Default engine ─────────────────────────────────────────────────────────────
const DEFAULT_TTS = (process.env.TTS_ENGINE || "kokoro").toLowerCase();

// ─── WAV header builder ────────────────────────────────────────────────────────
function buildWav(pcmBuf, sampleRate, numChannels = 1, bitsPerSample = 16) {
  const dataSize   = pcmBuf.length;
  const byteRate   = sampleRate * numChannels * (bitsPerSample / 8);
  const blockAlign = numChannels * (bitsPerSample / 8);
  const header     = Buffer.alloc(44);
  header.write("RIFF",                 0);
  header.writeUInt32LE(36 + dataSize,  4);
  header.write("WAVE",                 8);
  header.write("fmt ",                12);
  header.writeUInt32LE(16,            16);
  header.writeUInt16LE(1,             20);
  header.writeUInt16LE(numChannels,   22);
  header.writeUInt32LE(sampleRate,    24);
  header.writeUInt32LE(byteRate,      28);
  header.writeUInt16LE(blockAlign,    32);
  header.writeUInt16LE(bitsPerSample, 34);
  header.write("data",                36);
  header.writeUInt32LE(dataSize,      40);
  return Buffer.concat([header, pcmBuf]);
}

// ─── Strip markdown symbols before sending to TTS ─────────────────────────────
function cleanForTTS(text) {
  return text
    .replace(/[*#`~|>_$%]/g, "")
    .replace(/^[\-—]+\s*/gm, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

// ─── Piper TTS ─────────────────────────────────────────────────────────────────
function piperTTS(text, voice) {
  const modelPath = join(PIPER_VOICES, `${voice}.onnx`);
  return new Promise((resolve, reject) => {
    const p = spawn(PIPER_PATH, ["--model", modelPath, "--output-raw"]);
    const chunks = [], errs = [];
    p.stdout.on("data", c => chunks.push(c));
    p.stderr.on("data", d => errs.push(d.toString().trim()));
    p.on("close", code => {
      if (code === 0) resolve(Buffer.concat(chunks));
      else reject(new Error(`Piper: ${errs.join(" ") || `exit ${code}`}`));
    });
    p.on("error", err =>
      reject(err.code === "ENOENT"
        ? new Error(`Piper binary not found at "${PIPER_PATH}". Run setup.sh to install.`)
        : err)
    );
    p.stdin.write(text + "\n");
    p.stdin.end();
  });
}

// ─── Kokoro TTS ────────────────────────────────────────────────────────────────
function kokoroTTS(text, voice = KOKORO_VOICE) {
  return new Promise((resolve, reject) => {
    const p = spawn(KOKORO_PYTHON, [KOKORO_SCRIPT], {
      env: { ...process.env, KOKORO_VOICE: voice, PYTHONUNBUFFERED: "1" },
    });
    const chunks = [], errs = [];
    p.stdout.on("data", c => chunks.push(c));
    p.stderr.on("data", d => errs.push(d.toString().trim()));
    p.on("close", code => {
      errs.forEach(l => process.stdout.write(`[Kokoro] ${l}\n`));
      if (code === 0) resolve(Buffer.concat(chunks));
      else reject(new Error(`Kokoro: ${errs.filter(l => l.startsWith("[Kokoro] ERROR")).join(" ") || `exit ${code}`}`));
    });
    p.on("error", err =>
      reject(err.code === "ENOENT"
        ? new Error(`Python not found at "${KOKORO_PYTHON}". Set PYTHON_PATH in .env or install Python.`)
        : err)
    );
    p.stdin.write(text + "\n");
    p.stdin.end();
  });
}

// ─── Concurrency queue ─────────────────────────────────────────────────────────
class PromiseQueue {
  constructor(concurrency = 5) {
    this.concurrency = concurrency;
    this.running = 0;
    this.queue = [];
  }
  add(task) {
    return new Promise((resolve, reject) => {
      this.queue.push(async () => {
        try   { resolve(await task()); }
        catch (err) { reject(err); }
        finally { this.running--; this._next(); }
      });
      this._next();
    });
  }
  _next() {
    if (this.running < this.concurrency && this.queue.length > 0) {
      this.running++;
      this.queue.shift()();
    }
  }
}

const ttsQueue = new PromiseQueue(parseInt(process.env.TTS_CONCURRENCY || "5"));

function textToAudio(text, engine, voice) {
  return ttsQueue.add(() =>
    engine === "piper" ? piperTTS(text, voice) : kokoroTTS(text, voice)
  );
}

function getSampleRate(engine) { return engine === "piper" ? PIPER_SR : KOKORO_SR; }

// ─── Exported init ─────────────────────────────────────────────────────────────
export function initTTS(app) {

  // ── POST /tts ──────────────────────────────────────────────────────────────
  // Primary endpoint: accepts a text chunk and returns WAV audio.
  // Body (JSON): { "chunk": "Hello world", "voice": "af_heart", "engine": "kokoro" }
  // Also accepts the legacy "text" field for compatibility.
  app.post("/tts", async (req, res) => {
    try {
      const { text, chunk, voice = KOKORO_VOICE, engine = DEFAULT_TTS } = req.body;
      const content = chunk || text;

      if (!content || typeof content !== "string" || !content.trim()) {
        return res.status(400).json({ error: 'Missing or empty "chunk" field' });
      }

      const reqId = Math.random().toString(36).substring(2, 9);
      console.log(`[POST /tts ${reqId}] engine=${engine} voice=${voice} chunk="${content.slice(0, 60)}"`);

      const pcm       = await textToAudio(cleanForTTS(content.trim()), engine, voice);
      const sr        = getSampleRate(engine);
      const wavBuffer = buildWav(pcm, sr);

      res.set({
        "Content-Type":   "audio/wav",
        "Content-Length": wavBuffer.length,
        "X-TTS-Engine":   engine,
        "X-TTS-Voice":    voice,
        "X-Sample-Rate":  sr,
        "X-Request-Id":   reqId,
        // Allow any client / device to use this API
        "Access-Control-Allow-Origin":  "*",
        "Access-Control-Expose-Headers": "X-TTS-Engine,X-TTS-Voice,X-Sample-Rate,X-Request-Id",
      });
      res.send(wavBuffer);
    } catch (err) {
      console.error("[POST /tts error]", err.message);
      res.status(500).json({ error: err.message });
    }
  });

  // ── GET /tts ───────────────────────────────────────────────────────────────
  // Browser-friendly test. Open in address bar to hear audio.
  // ?chunk=Hello+world&voice=af_heart&engine=kokoro
  app.get("/tts", async (req, res) => {
    const content = req.query.chunk || req.query.text || "Hello from the open source TTS API!";
    const voice   = req.query.voice  || KOKORO_VOICE;
    const engine  = req.query.engine || DEFAULT_TTS;
    const reqId   = Math.random().toString(36).substring(2, 9);

    console.log(`[GET /tts ${reqId}] engine=${engine} voice=${voice} chunk="${content.slice(0, 60)}"`);

    try {
      const pcm       = await textToAudio(cleanForTTS(content.trim()), engine, voice);
      const sr        = getSampleRate(engine);
      const wavBuffer = buildWav(pcm, sr);

      res.set({
        "Content-Type":   "audio/wav",
        "Content-Length": wavBuffer.length,
        "X-Request-Id":   reqId,
        "Access-Control-Allow-Origin": "*",
      });
      res.send(wavBuffer);
    } catch (err) {
      console.error("[GET /tts error]", err.message);
      res.status(500).json({ error: err.message });
    }
  });

  // ── GET /tts/voices ────────────────────────────────────────────────────────
  // Lists available voices for both engines.
  app.get("/tts/voices", (req, res) => {
    const result = { piper: [], kokoro: [] };

    try {
      result.piper = readdirSync(PIPER_VOICES)
        .filter(f => f.endsWith(".onnx"))
        .map(f => f.replace(".onnx", ""));
    } catch {
      // voices directory may not exist yet
    }

    // Kokoro voices are baked into the model; list the well-known set.
    result.kokoro = [
      "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky",
      "am_adam", "am_michael",
      "bf_emma", "bf_isabella", "bm_george", "bm_lewis",
    ];

    res.set("Access-Control-Allow-Origin", "*");
    res.json(result);
  });

  // ── OPTIONS /tts (preflight for CORS) ─────────────────────────────────────
  app.options("/tts", (req, res) => {
    res.set({
      "Access-Control-Allow-Origin":  "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    });
    res.sendStatus(204);
  });

  console.log(`\n🔊 TTS API ready`);
  console.log(`   POST /tts          → convert chunk to audio/wav`);
  console.log(`   GET  /tts          → browser test`);
  console.log(`   GET  /tts/voices   → list available voices`);
  console.log(`   Engine default     → ${DEFAULT_TTS}\n`);
}
