// Dzeroth image worker: decodes, crops, resizes and JPEG-encodes picked photos off the UI thread
// (lib/features/media/data/worker_raster_codec_web.dart). It makes no size decisions: Dart sends the exact
// crop rectangle and output size for every step (image_size_plan.dart), and checks every JPEG's SOF.
// One worker per image; Dart terminates it when the image is done, times out or is cancelled.
// Re-encoding through a canvas drops all metadata (EXIF/GPS/ICC); the canvas is filled white first,
// so transparency flattens like the package:image path.
'use strict';

const PROTOCOL = 2;

// Largest output side Dart ever asks for (posts 1600); anything else is malformed.
const MAX_OUTPUT_EDGE = 4096;

let bitmap = null;

const supported =
  typeof createImageBitmap === 'function' &&
  typeof OffscreenCanvas === 'function' &&
  typeof OffscreenCanvas.prototype.convertToBlob === 'function';

self.postMessage({ seq: 0, op: 'ready', protocol: PROTOCOL, ok: supported });

function isInt(v, min, max) {
  return typeof v === 'number' && Number.isInteger(v) && v >= min && v <= max;
}

// Clockwise quarter turns of a draw request (0 when absent): the crop is then a rectangle of the ROTATED
// bitmap, so the user's rotation is applied before the crop, like the package:image path.
function turnsOf(req) {
  return req.turns === undefined ? 0 : req.turns;
}

// A draw request: integer output size within 1..MAX_OUTPUT_EDGE, an integer crop inside the decoded
// (and rotated) bitmap, and (for JPEG) an integer quality 1..100.
function checkDraw(req, needsQuality) {
  if (!bitmap) throw new Error('nothing decoded');
  if (!isInt(req.w, 1, MAX_OUTPUT_EDGE) || !isInt(req.h, 1, MAX_OUTPUT_EDGE)) throw new Error('bad output size');
  if (!isInt(turnsOf(req), 0, 3)) throw new Error('bad turns');
  const odd = turnsOf(req) % 2 === 1;
  const rw = odd ? bitmap.height : bitmap.width;
  const rh = odd ? bitmap.width : bitmap.height;
  if (
    !isInt(req.sx, 0, rw - 1) ||
    !isInt(req.sy, 0, rh - 1) ||
    !isInt(req.sw, 1, rw - req.sx) ||
    !isInt(req.sh, 1, rh - req.sy)
  ) {
    throw new Error('bad crop');
  }
  if (needsQuality && !isInt(req.quality, 1, 100)) throw new Error('bad quality');
}

function draw(req) {
  const canvas = new OffscreenCanvas(req.w, req.h);
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('no 2d context');
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, req.w, req.h);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  const turns = turnsOf(req);
  if (turns === 0) {
    ctx.drawImage(bitmap, req.sx, req.sy, req.sw, req.sh, 0, 0, req.w, req.h);
  } else {
    // Map the rotated-frame crop onto the canvas, then draw the bitmap rotated clockwise.
    const bw = bitmap.width;
    const bh = bitmap.height;
    ctx.scale(req.w / req.sw, req.h / req.sh);
    ctx.translate(-req.sx, -req.sy);
    if (turns === 1) ctx.transform(0, 1, -1, 0, bh, 0);
    else if (turns === 2) ctx.transform(-1, 0, 0, -1, bw, bh);
    else ctx.transform(0, -1, 1, 0, 0, bw);
    ctx.drawImage(bitmap, 0, 0);
  }
  return { canvas, ctx };
}

self.onmessage = async (event) => {
  const req = event.data;
  if (!req || typeof req !== 'object' || !isInt(req.seq, 1, Number.MAX_SAFE_INTEGER)) return;
  const seq = req.seq;
  try {
    switch (req.op) {
      case 'decode': {
        if (!(req.bytes instanceof Uint8Array)) throw new Error('bad bytes');
        if (bitmap) {
          bitmap.close();
          bitmap = null;
        }
        try {
          bitmap = await createImageBitmap(new Blob([req.bytes]), { imageOrientation: 'from-image' });
        } catch (e) {
          // A TypeError is this engine refusing the call (an option it does not know), not a bad file:
          // report it as a capability failure so Dart falls back to package:image.
          if (e instanceof TypeError) {
            self.postMessage({ seq, ok: false, kind: 'env', capability: true, error: String(e) });
          } else {
            self.postMessage({ seq, ok: false, kind: 'decode', error: String(e) });
          }
          return;
        }
        self.postMessage({ seq, ok: true, width: bitmap.width, height: bitmap.height });
        return;
      }
      case 'jpeg': {
        checkDraw(req, true);
        const { canvas } = draw(req);
        const blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: req.quality / 100 });
        if (blob.type !== 'image/jpeg') {
          self.postMessage({ seq, ok: false, kind: 'env', capability: true, error: 'no JPEG encoder: ' + blob.type });
          return;
        }
        const buffer = await blob.arrayBuffer();
        self.postMessage({ seq, ok: true, bytes: buffer }, [buffer]);
        return;
      }
      case 'rgba': {
        checkDraw(req, false);
        const { ctx } = draw(req);
        const buffer = ctx.getImageData(0, 0, req.w, req.h).data.buffer;
        self.postMessage({ seq, ok: true, bytes: buffer }, [buffer]);
        return;
      }
      default:
        throw new Error('unknown op ' + req.op);
    }
  } catch (e) {
    self.postMessage({ seq, ok: false, kind: 'env', error: String(e) });
  }
};
