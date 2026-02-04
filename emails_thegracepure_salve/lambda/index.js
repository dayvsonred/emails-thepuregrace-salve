const { S3Client, GetObjectCommand, PutObjectCommand } = require("@aws-sdk/client-s3");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");

const s3 = new S3Client({});
const ses = new SESClient({});

function pad(n, width) {
  const s = String(n);
  return s.length >= width ? s : "0".repeat(width - s.length) + s;
}

function extractEmails(value) {
  if (!value) return [];
  const matches = String(value).match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi);
  return matches ? matches.map(v => v.toLowerCase()) : [];
}

function parseHeaders(raw) {
  const text = raw.toString("utf8");
  const headerEnd = text.indexOf("\r\n\r\n");
  const headerText = headerEnd >= 0 ? text.slice(0, headerEnd) : text;

  const lines = headerText.split("\r\n");
  const unfolded = [];
  for (const line of lines) {
    if (/^[ \t]/.test(line) && unfolded.length > 0) {
      unfolded[unfolded.length - 1] += " " + line.trim();
    } else {
      unfolded.push(line);
    }
  }

  const headers = {};
  for (const line of unfolded) {
    const idx = line.indexOf(":");
    if (idx <= 0) continue;
    const name = line.slice(0, idx).trim().toLowerCase();
    const value = line.slice(idx + 1).trim();
    if (!headers[name]) headers[name] = [];
    headers[name].push(value);
  }

  return { headers, text };
}

function pickAllowed(recipients, allowed) {
  for (const r of recipients) {
    if (allowed.includes(r)) return r;
  }
  return null;
}

function getMessageId(headers, fallback) {
  const msg = (headers["message-id"] && headers["message-id"][0]) || "";
  const cleaned = msg.replace(/[<>]/g, "").trim();
  return cleaned || fallback;
}

function getSubject(headers) {
  return (headers["subject"] && headers["subject"][0]) || "(sem assunto)";
}

function getRecipients(headers) {
  const list = [];
  for (const h of ["to", "cc", "delivered-to", "x-original-to", "x-ses-original-recipients"]) {
    if (headers[h]) {
      for (const v of headers[h]) {
        list.push(...extractEmails(v));
      }
    }
  }
  return Array.from(new Set(list));
}

async function streamToBuffer(stream) {
  if (Buffer.isBuffer(stream)) return stream;
  return new Promise((resolve, reject) => {
    const chunks = [];
    stream.on("data", (chunk) => chunks.push(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolve(Buffer.concat(chunks)));
  });
}

exports.handler = async (event) => {
  const allowed = (process.env.ALLOWED_RECIPIENTS || "").split(",").map(s => s.trim().toLowerCase()).filter(Boolean);
  const bucket = process.env.BUCKET;
  const incomingPrefix = process.env.INCOMING_PREFIX || "incoming/";
  const forwardTo = (process.env.FORWARD_TO || "").trim().toLowerCase();
  const forwardFrom = (process.env.FORWARD_FROM || "").trim();
  const skipTo = (process.env.SKIP_TO || "").trim().toLowerCase();

  for (const record of event.Records || []) {
    const s3rec = record.s3;
    if (!s3rec) continue;

    const key = decodeURIComponent(s3rec.object.key.replace(/\+/g, " "));
    if (!key.startsWith(incomingPrefix)) continue;

    const obj = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    const raw = await streamToBuffer(obj.Body);

    const { headers, text } = parseHeaders(raw);
    const recipients = getRecipients(headers);

    const chosen = pickAllowed(recipients, allowed) || "unknown";
    const localPart = chosen.includes("@") ? chosen.split("@")[0] : chosen;

    const eventTime = record.eventTime ? new Date(record.eventTime) : (obj.LastModified ? new Date(obj.LastModified) : new Date());
    const yyyy = eventTime.getUTCFullYear();
    const mm = pad(eventTime.getUTCMonth() + 1, 2);
    const dd = pad(eventTime.getUTCDate(), 2);
    const hh = pad(eventTime.getUTCHours(), 2);
    const mi = pad(eventTime.getUTCMinutes(), 2);
    const ss = pad(eventTime.getUTCSeconds(), 2);
    const ms = pad(eventTime.getUTCMilliseconds(), 3);

    const fallbackId = key.split("/").pop();
    const messageId = getMessageId(headers, fallbackId);

    const destKey = `${localPart}/${yyyy}/${mm}/${dd}/${yyyy}${mm}${dd}T${hh}${mi}${ss}.${ms}Z-${messageId}.eml`;

    await s3.send(new PutObjectCommand({
      Bucket: bucket,
      Key: destKey,
      Body: raw,
      ContentType: "message/rfc822"
    }));

    if (forwardTo && forwardFrom) {
      const shouldSkip = skipTo && recipients.includes(skipTo);
      if (!shouldSkip) {
        const subject = `Fwd: ${getSubject(headers)}`;
        const maxLen = 200000;
        const bodyText = text.length > maxLen
          ? text.slice(0, maxLen) + "\n\n[truncado]"
          : text;

        await ses.send(new SendEmailCommand({
          Source: forwardFrom,
          Destination: { ToAddresses: [forwardTo] },
          Message: {
            Subject: { Data: subject },
            Body: { Text: { Data: bodyText } }
          }
        }));
      }
    }
  }

  return { ok: true };
};
