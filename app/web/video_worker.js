// @ffmpeg/core 0.12.10, single-threaded UMD distribution. Loaded only on a video pick.
importScripts('ffmpeg/ffmpeg-core.js');

self.onmessage = async ({data}) => {
  try {
    const core = await createFFmpegCore({
      wasmBinary: await (await fetch('ffmpeg/ffmpeg-core.wasm')).arrayBuffer(),
    });
    core.FS.writeFile('input', new Uint8Array(await (await fetch(data.url)).arrayBuffer()));
    if (core.exec(...data.encode) !== 0) throw new Error('encode');
    core.reset();
    // The 0.12.10 probe can leave ret at -1 after writing a successful report.
    // Each pick has a fresh filesystem, so read the newly produced report.
    core.ffprobe(...data.probe);
    const metadata = core.FS.readFile('metadata.json', {encoding: 'utf8'});
    if (!JSON.parse(metadata).streams?.length) throw new Error('metadata');
    core.reset();
    if (core.exec(...data.poster) !== 0) throw new Error('poster');
    const video = core.FS.readFile('post.mp4');
    const poster = core.FS.readFile('poster.jpg');
    self.postMessage({metadata, video, poster}, [video.buffer, poster.buffer]);
  } catch (_) {
    self.postMessage({error: true});
  }
};
