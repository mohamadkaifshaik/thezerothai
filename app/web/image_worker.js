// Dzeroth image worker: decodes, crops, resizes and JPEG-encodes picked photos off the UI thread
// (lib/features/media/data/worker_raster_codec_web.dart). It makes no size decisions: Dart sends the exact
// crop rectangle and output size for every step (image_size_plan.dart), and checks every JPEG's SOF.
// One worker per image; Dart terminates it when the image is done, times out or is cancelled.
// Re-encoding through a canvas drops all metadata (EXIF/GPS/ICC); the canvas is filled white first,
// so transparency flattens like the package:image path.
'use strict';

const PROTOCOL = 1;

// Largest output side Dart ever asks for (posts 1600, banners 1500); anything else is malformed.
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

// A draw request: integer output size within 1..MAX_OUTPUT_EDGE, an integer crop inside the decoded
// bitmap, and (for JPEG) an integer quality 1..100.
function checkDraw(req, needsQuality) {
  if (!bitmap) throw new Error('nothing decoded');
  if (!isInt(req.w, 1, MAX_OUTPUT_EDGE) || !isInt(req.h, 1, MAX_OUTPUT_EDGE)) throw new Error('bad output size');
  if (
    !isInt(req.sx, 0, bitmap.width - 1) ||
    !isInt(req.sy, 0, bitmap.height - 1) ||
    !isInt(req.sw, 1, bitmap.width - req.sx) ||
    !isInt(req.sh, 1, bitmap.height - req.sy)
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
  ctx.drawImage(bitmap, req.sx, req.sy, req.sw, req.sh, 0, 0, req.w, req.h);
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
