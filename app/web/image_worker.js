// Dzeroth image worker: decodes, crops, resizes and JPEG-encodes picked photos off the UI thread
// (lib/features/media/data/worker_raster_codec_web.dart). It makes no size decisions: Dart sends the exact
// crop rectangle and output size for every step (image_size_plan.dart), and checks every JPEG's SOF.
// One worker per image; Dart terminates it when the image is done or cancelled.
// Re-encoding through a canvas drops all metadata (EXIF/GPS/ICC); the canvas is filled white first,
// so transparency flattens like the package:image path.
'use strict';

const PROTOCOL = 1;

let bitmap = null;

const supported =
  typeof createImageBitmap === 'function' &&
  typeof OffscreenCanvas === 'function' &&
  typeof OffscreenCanvas.prototype.convertToBlob === 'function';

self.postMessage({ seq: 0, op: 'ready', protocol: PROTOCOL, ok: supported });

function draw(req) {
  if (!bitmap) throw new Error('nothing decoded');
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
  const seq = req.seq;
  try {
    switch (req.op) {
      case 'decode': {
        if (bitmap) {
          bitmap.close();
          bitmap = null;
        }
        try {
          bitmap = await createImageBitmap(new Blob([req.bytes]), { imageOrientation: 'from-image' });
        } catch (e) {
          self.postMessage({ seq, ok: false, kind: 'decode', error: String(e) });
          return;
        }
        self.postMessage({ seq, ok: true, width: bitmap.width, height: bitmap.height });
        return;
      }
      case 'jpeg': {
        const { canvas } = draw(req);
        const blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: req.quality / 100 });
        if (blob.type !== 'image/jpeg') throw new Error('no JPEG encoder: ' + blob.type);
        const buffer = await blob.arrayBuffer();
        self.postMessage({ seq, ok: true, bytes: buffer }, [buffer]);
        return;
      }
      case 'rgba': {
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
