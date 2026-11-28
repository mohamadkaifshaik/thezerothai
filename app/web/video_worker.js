// @ffmpeg/core 0.12.10, single-threaded UMD distribution. Loaded only on a video pick.
importScripts('ffmpeg/ffmpeg-core.js');

self.onmessage = async ({data}) => {
  try {
    const core = await createFFmpegCore({
      wasmBinary: await (await fetch('ffmpeg/ffmpeg-core.wasm')).arrayBuffer(),
    });
    core.FS.writeFile('input', new Uint8Array(await (await fetch(data.url)).arrayBuffer()));
    if (data.captionCommands) {
      const captionAudio = [];
      for (const segment of data.captionCommands) {
        core.reset();
        if (core.exec(...segment.args) !== 0) throw new Error('audio extraction');
        captionAudio.push(core.FS.readFile(segment.output));
      }
      self.postMessage({captionAudio}, captionAudio.map(chunk => chunk.buffer));
      return;
    }
    for (const item of data.artwork ?? []) {
      core.FS.writeFile(item.path, item.png);
    }
    if (core.exec(...data.encode) !== 0) throw new Error('encode');
    core.reset();
    // The 0.12.10 probe can leave ret at -1 after writing a successful report.
    // Each pick has a fresh filesystem, so read the newly produced report.
    core.ffprobe(...data.probe);
    const metadata = core.FS.readFile('metadata.json', {encoding: 'utf8'});
    if (!JSON.parse(metadata).streams?.length) throw new Error('metadata');
    let poster;
    const candidates = Array.isArray(data.poster[0]) ? data.poster : [data.poster];
    for (const args of candidates) {
      core.reset();
      const success = core.exec(...args) === 0;
      if (core.FS.analyzePath('poster.jpg').exists) {
        const candidate = core.FS.readFile('poster.jpg');
        if (success && candidate.length > 0) {
          poster = candidate;
          break;
        }
        core.FS.unlink('poster.jpg');
      }
    }
    if (!poster) throw new Error('poster');
    const video = core.FS.readFile('post.mp4');
    // Hash the encoded container bytes, including its headers, in the worker.
    core.reset();
    if (core.exec('-f', 'data', '-i', 'post.mp4', '-map', '0:0', '-c', 'copy',
                  '-f', 'md5', 'digest.txt') !== 0) throw new Error('digest');
    const digest = /^MD5=([0-9a-f]{32})$/i.exec(core.FS.readFile('digest.txt', {encoding: 'utf8'}).trim());
    if (!digest) throw new Error('digest');
    const fullMd5 = btoa(String.fromCharCode(...digest[1].match(/../g).map(pair => parseInt(pair, 16))));
    self.postMessage({metadata, video, poster, fullMd5}, [video.buffer, poster.buffer]);
  } catch (_) {
    self.postMessage({error: true});
  }
};
