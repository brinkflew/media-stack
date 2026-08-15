/* eslint-disable no-param-reassign */
// ============================================================================
// Media Stack stream policy: one ffmpeg pass, HEVC + Opus, VO/EN/FR preserved
// ----------------------------------------------------------------------------
// This replaces the community "5 steps" flow chain, which took ~5 full reads of
// every file and, because its audio node used `-c:a:0` with no `-map`, kept
// exactly ONE audio track. Which one survived depended on the stream reorder,
// so it destroyed the French dub on the Harry Potter films and the Latvian VO
// on Flow (2024). Every decision below is made in a single ffmpeg invocation.
//
// WHY A CLASSIC PLUGIN AND NOT A FLOW PLUGIN. A flow plugin has to live at
// Plugins/Local/FlowPlugins/<cat>/<name>/1.0.0/index.js and the community ones
// reach FlowHelpers with relative `require`s that do NOT resolve from Local/.
// A classic plugin is one file in Plugins/Local/, its single `require` path is
// correct there, and it returns the raw ffmpeg argument string - which is
// exactly what we want, since the whole point is one hand-verified command.
//
// This file is TRACKED IN GIT at apps/tdarr/plugins/ and copied into the server's
// Plugins/Local/ by an ExecStartPre= on tdarr-server.container. Do not edit the
// copy on the server; it is overwritten on every start.
// ============================================================================

const details = () => ({
  id: 'Tdarr_Plugin_avs1_MediaStackStreamPolicy',
  Stage: 'Pre-processing',
  Name: 'Media Stack stream policy (HEVC + Opus, VO/EN/FR)',
  Type: 'Video',
  Operation: 'Transcode',
  Description:
    'One pass: HEVC 10-bit via NVENC, Opus only for codecs that do not direct-play, '
    + 'an AC3 companion per language, original+EN+FR audio, EN/FR subtitles copied.',
  Version: '1.0',
  Tags: 'pre-processing,ffmpeg,nvenc,h265,configurable',
  Inputs: [
    {
      name: 'audioLanguages',
      type: 'string',
      defaultValue: 'eng,fra,fre,und',
      inputUI: { type: 'text' },
      tooltip:
        'Comma-separated ISO-639-2 audio languages to keep. Untagged tracks count as "und" and '
        + 'are kept by default - dropping them is how VO tracks go missing.',
    },
    {
      name: 'originalLanguage',
      type: 'string',
      defaultValue: '',
      inputUI: { type: 'text' },
      tooltip:
        'Optional. The film\'s original language, if it is not in the list above (e.g. "lav" for '
        + 'Flow). A track in this language is ALWAYS kept. Leave empty for the common case.',
    },
    {
      name: 'subtitleLanguages',
      type: 'string',
      defaultValue: 'eng,fra,fre',
      inputUI: { type: 'text' },
      tooltip: 'Comma-separated subtitle languages to keep. Copied, never re-encoded.',
    },
    {
      name: 'cq',
      type: 'string',
      defaultValue: '26',
      inputUI: { type: 'text' },
      tooltip:
        'NVENC constant-quality target. Lower is bigger. Calibrated on this host against a 20 Mbps '
        + 'VC-1 remux (60s, preset p6, SSIM vs source): CQ 20 = 9631 kbps / 0.98817, '
        + 'CQ 22 = 8618 / 0.98771, CQ 24 = 6354 / 0.98584, CQ 26 = 4541 / 0.98379, '
        + 'CQ 28 = 3179 / 0.98164. The curve is FLAT - 0.0065 SSIM across a 3x bitrate range - so '
        + 'there is no quality cliff to find, and 26 was chosen as the point that still exceeds '
        + 'the ~3.9 Mbps files already in the library. 18 (the old value) is near-lossless and is '
        + 'why the previous flow made files LARGER than their sources.',
    },
    {
      name: 'nvencPreset',
      type: 'string',
      defaultValue: 'p6',
      inputUI: { type: 'text' },
      tooltip: 'p1 (fastest) .. p7 (slowest). p6 measured 162 fps on 1080p; p7 buys little.',
    },
    {
      name: 'keyframeSeconds',
      type: 'string',
      defaultValue: '6',
      inputUI: { type: 'text' },
      tooltip:
        'Seconds between keyframes. MUST NOT be below Jellyfin\'s HLS segment length (6s), or '
        + 'browser playback drifts: on its stream-copy path Jellyfin advertises one segment per '
        + 'keyframe but tells ffmpeg -hls_time 6, so ffmpeg MERGES shorter GOPs and segment N '
        + 'stops being segment N. Measured on Backrooms (2026): +3.8s after one segment, +22.4s '
        + 'after twenty-five. Set 0 to leave keyframe placement to NVENC (the old behaviour).',
    },
    {
      name: 'skipIfHevcBelowBitrate',
      type: 'string',
      defaultValue: '8000000',
      inputUI: { type: 'text' },
      tooltip:
        'Bits/s. A file that is ALREADY HEVC and below this is left alone - re-encoding it is '
        + 'generation loss for no saving. Set 0 to always re-encode.',
    },
    {
      name: 'opusBitrateStereo', type: 'string', defaultValue: '128k', inputUI: { type: 'text' }, tooltip: 'Opus bitrate for 1-2 channel tracks.',
    },
    {
      name: 'opusBitrate51', type: 'string', defaultValue: '256k', inputUI: { type: 'text' }, tooltip: 'Opus bitrate for 3-6 channel tracks. TOTAL, not per channel.',
    },
    {
      name: 'opusBitrate71', type: 'string', defaultValue: '450k', inputUI: { type: 'text' }, tooltip: 'Opus bitrate for 7+ channel tracks. TOTAL, not per channel.',
    },
    {
      name: 'ac3Bitrate', type: 'string', defaultValue: '640k', inputUI: { type: 'text' }, tooltip: 'Bitrate of the AC3 direct-play companion track.',
    },
    {
      name: 'addCompanionAc3',
      type: 'boolean',
      defaultValue: 'true',
      inputUI: { type: 'dropdown', options: ['true', 'false'] },
      tooltip:
        'When a track is converted to Opus and no AC3/E-AC3 survives IN THAT SAME LANGUAGE, add '
        + 'an AC3 companion. Per-language matters: a French AC3 does not make the English VO '
        + 'direct-playable.',
    },
  ],
});

// Codecs that already direct-play on essentially every client. Re-encoding
// these is generation loss for no compatibility gain, so they are copied.
const KEEP_AS_IS = ['aac', 'ac3', 'eac3', 'mp3', 'opus'];

// Codecs converted to Opus. Note plain `dts` is here despite being lossy: it is
// poorly supported and runs 768-1536 kb/s, so it loses on both counts.
const NEEDS_OPUS = ['truehd', 'dts', 'dca', 'flac', 'mlp', 'pcm_s16le', 'pcm_s24le',
  'pcm_s32le', 'pcm_f32le', 'pcm_bluray', 'pcm_dvd'];

const langOf = (stream) => {
  const tags = stream.tags || {};
  const lang = (tags.language || tags.LANGUAGE || '').toLowerCase().trim();
  return lang === '' ? 'und' : lang;
};

// fre and fra are the same language in two ISO-639-2 flavours. Treating them as
// distinct is how a "keep French" rule silently drops French.
const normLang = (lang) => (lang === 'fra' ? 'fre' : lang);

// ffprobe reports frame rate as a RATIONAL STRING, "24000/1001", not a number.
// parseFloat() on that yields 24000, which would put the keyframe interval out by
// a factor of a thousand - so parse the fraction. r_frame_rate first: avg_frame_rate
// is total frames over duration, which a variable-rate source skews.
const frameRateOf = (stream) => {
  const candidates = [stream.r_frame_rate, stream.avg_frame_rate];
  for (let i = 0; i < candidates.length; i += 1) {
    const parts = String(candidates[i] || '').split('/');
    const num = parseFloat(parts[0]);
    const den = parts.length > 1 ? parseFloat(parts[1]) : 1;
    if (num > 0 && den > 0) return num / den;
  }
  return 0;
};

const opusBitrateFor = (channels, inputs) => {
  if (channels >= 7) return String(inputs.opusBitrate71);
  if (channels >= 3) return String(inputs.opusBitrate51);
  return String(inputs.opusBitrateStereo);
};

const plugin = (file, librarySettings, inputs, otherArguments) => {
  const lib = require('../methods/lib')(); // eslint-disable-line global-require
  inputs = lib.loadDefaultValues(inputs, details);

  const response = {
    processFile: false,
    preset: '',
    container: '.mkv',
    handBrakeMode: false,
    FFmpegMode: true,
    reQueueAfter: true,
    infoLog: '',
  };

  const streams = (file.ffProbeData && file.ffProbeData.streams) || [];
  if (streams.length === 0) {
    response.infoLog += 'No streams found in ffProbeData - skipping.\n';
    return response;
  }

  const wantAudio = String(inputs.audioLanguages).toLowerCase().split(',')
    .map((s) => normLang(s.trim())).filter((s) => s.length > 0);
  const origLang = normLang(String(inputs.originalLanguage).toLowerCase().trim());
  if (origLang && wantAudio.indexOf(origLang) === -1) wantAudio.push(origLang);
  const wantSubs = String(inputs.subtitleLanguages).toLowerCase().split(',')
    .map((s) => normLang(s.trim())).filter((s) => s.length > 0);

  // Cover art is carried as a video stream. It is not the picture.
  const videos = streams.filter((s) => s.codec_type === 'video'
    && !(s.disposition && s.disposition.attached_pic));
  const audios = streams.filter((s) => s.codec_type === 'audio');
  const subs = streams.filter((s) => s.codec_type === 'subtitle');

  if (videos.length === 0) {
    response.infoLog += 'No video stream - skipping.\n';
    return response;
  }
  const video = videos[0];

  // ---- Should we touch the video at all? -----------------------------------
  const skipBelow = parseInt(String(inputs.skipIfHevcBelowBitrate), 10) || 0;
  const overallBitrate = parseInt(
    (file.ffProbeData.format && file.ffProbeData.format.bit_rate) || file.bit_rate || 0, 10,
  ) || 0;
  const alreadyHevc = video.codec_name === 'hevc';
  const hevcIsFine = alreadyHevc && skipBelow > 0 && overallBitrate > 0
    && overallBitrate < skipBelow;

  // ---- Audio selection -----------------------------------------------------
  // Language first, and channel count NEVER as a selection criterion: filtering
  // by "highest channel count" is precisely the bug that deleted VO tracks.
  let keptAudio = audios.filter((s) => wantAudio.indexOf(normLang(langOf(s))) !== -1);

  // Never end up with a silent file. If the whitelist matched nothing, the
  // whitelist is wrong for this file - keep everything rather than lose it.
  if (keptAudio.length === 0 && audios.length > 0) {
    keptAudio = audios.slice();
    response.infoLog += 'No audio matched the language list; keeping all audio rather than '
      + 'producing a silent file.\n';
  }

  // Drop same-language duplicates: releases routinely ship VFF and VFQ French
  // AC3 5.1. Keep the first of each (language, codec, channels).
  const seen = {};
  keptAudio = keptAudio.filter((s) => {
    const key = `${normLang(langOf(s))}|${s.codec_name}|${s.channels}`;
    if (seen[key]) return false;
    seen[key] = true;
    return true;
  });

  // Which languages already have a direct-playable track, so no companion is
  // needed for them.
  const hasDirectPlay = {};
  keptAudio.forEach((s) => {
    if (['ac3', 'eac3'].indexOf(s.codec_name) !== -1) hasDirectPlay[normLang(langOf(s))] = true;
  });

  const keptSubs = subs.filter((s) => wantSubs.indexOf(normLang(langOf(s))) !== -1);

  // ---- Build the command ---------------------------------------------------
  const maps = [];
  const out = [];

  maps.push(`-map 0:${video.index}`);
  if (hevcIsFine) {
    out.push('-c:v copy');
    response.infoLog += `Video is already HEVC at ${overallBitrate} bps (< ${skipBelow}) - copying.\n`;
  } else {
    // scale_cuda, NOT -pix_fmt. With -hwaccel_output_format cuda the frames stay
    // in GPU memory, and -pix_fmt p010le fails with "Impossible to convert
    // between the formats supported by the filter". Verified on this host.
    out.push('-vf scale_cuda=format=p010le');
    out.push(`-c:v hevc_nvenc -preset ${inputs.nvencPreset} -tune hq -rc vbr`
      + ` -cq ${inputs.cq} -b:v 0 -profile:v main10`
      + ' -bf 4 -b_ref_mode middle -rc-lookahead 32'
      + ' -spatial-aq 1 -temporal-aq 1 -aq-strength 8');

    // A REGULAR KEYFRAME INTERVAL, AND IT IS NOT A TUNING KNOB. Left to itself
    // NVENC places keyframes on scene cuts, which on Backrooms (2026) put them
    // 0.375s to 10.427s apart. Jellyfin's HLS STREAM-COPY path cannot segment
    // that consistently: it advertises one segment per keyframe (from its own
    // KeyframeData index) but passes ffmpeg -hls_time 6, and ffmpeg - unable to
    // cut anywhere but a keyframe - MERGES consecutive short GOPs until it has
    // 6s. So from the second segment of every session, ffmpeg's file N holds
    // different media than playlist entry N, and the error accumulates: +3.838s
    // after one segment, +22.397s after twenty-five. The picture jumps forward,
    // and text subtitles - which Jellyfin strips from the stream (-map -0:s) and
    // times against the player's currentTime - detach and stay detached until
    // the page is reloaded. Keyframes at or above hls_time make ffmpeg's cuts
    // and Jellyfin's playlist the same list.
    //
    // AND IT IS NOT A TRADE. The same 90s clip at CQ 26 / p6 came out 19,989,619
    // bytes without these and 18,997,172 with them - about 5% SMALLER - because
    // an I-frame costs far more than the P and B frames it displaces, so dropping
    // the adaptive ones more than pays for having none exactly on a cut.
    const kfSeconds = parseFloat(String(inputs.keyframeSeconds)) || 0;
    const fps = frameRateOf(video);
    if (kfSeconds > 0 && fps > 0) {
      // +1 frame so the interval lands just ABOVE hls_time rather than exactly on
      // it: at 6.000s the muxer's ">= 6" test can round either way and merge two
      // GOPs after all, which is the whole failure again at half the amplitude.
      const gop = Math.round(fps * kfSeconds) + 1;
      // -no-scenecut is the load-bearing half. Without it NVENC keeps inserting
      // adaptive I-frames at cuts, gaps fall back below hls_time, and the merging
      // returns. It needs lookahead, which -rc-lookahead 32 above already gives.
      out.push(`-g ${gop} -keyint_min ${gop} -no-scenecut 1`);
      response.infoLog += `Keyframes every ${gop} frames = ${(gop / fps).toFixed(3)}s `
        + `at ${fps.toFixed(3)} fps (>= ${kfSeconds}s, so Jellyfin can stream-copy it).\n`;
    } else if (kfSeconds > 0) {
      response.infoLog += 'Could not read a frame rate, so keyframe placement is left to NVENC. '
        + 'Browser playback of this file may drift - see keyframeSeconds.\n';
    }
  }

  let oa = 0;
  keptAudio.forEach((s) => {
    const lang = normLang(langOf(s));
    const channels = parseInt(s.channels, 10) || 2;
    const toOpus = NEEDS_OPUS.indexOf(s.codec_name) !== -1;

    maps.push(`-map 0:${s.index}`);
    if (toOpus) {
      out.push(`-c:a:${oa} libopus -b:a:${oa} ${opusBitrateFor(channels, inputs)}`
        + ` -mapping_family:a:${oa} 1`);
    } else {
      if (KEEP_AS_IS.indexOf(s.codec_name) === -1) {
        response.infoLog += `Unrecognised audio codec ${s.codec_name} - copying it unchanged.\n`;
      }
      out.push(`-c:a:${oa} copy`);
    }
    oa += 1;

    if (toOpus && String(inputs.addCompanionAc3) === 'true' && !hasDirectPlay[lang]) {
      // Same source stream mapped a second time. Verified working on this host.
      maps.push(`-map 0:${s.index}`);
      out.push(`-c:a:${oa} ac3 -b:a:${oa} ${inputs.ac3Bitrate} -ac:a:${oa} ${Math.min(channels, 6)}`);
      oa += 1;
      hasDirectPlay[lang] = true;
      response.infoLog += `Added an AC3 companion for ${lang} (its only track became Opus).\n`;
    }
  });

  keptSubs.forEach((s) => maps.push(`-map 0:${s.index}`));
  if (keptSubs.length > 0) out.push('-c:s copy');

  // ---- Is there anything to do? -------------------------------------------
  const droppingStreams = (keptAudio.length !== audios.length) || (keptSubs.length !== subs.length)
    || (videos.length !== streams.filter((s) => s.codec_type === 'video').length);
  const reencodingAudio = out.some((a) => a.indexOf('libopus') !== -1 || a.indexOf(' ac3 ') !== -1);
  if (hevcIsFine && !droppingStreams && !reencodingAudio) {
    response.infoLog += 'Already compliant - nothing to do.\n';
    return response;
  }

  // STRIP THE SOURCE'S STATISTICS TAGS. mkvmerge writes BPS / NUMBER_OF_BYTES /
  // DURATION / _STATISTICS_* per track, and ffmpeg carries them across with the
  // stream - so a 4.5 GB output inherited the 23 GB source's numbers and
  // Jellyfin displayed them verbatim: "Bitrate 9.0 Mbps", "Opus 3.6 Mbps", and
  // a video track claiming NUMBER_OF_BYTES=18,987,321,520 inside a 4.5 GB file.
  // Nothing was actually wrong with the encode; the metadata was lying.
  //
  // `-metadata:s KEY=` with no stream specifier clears KEY on every stream.
  // The flow then runs mkvpropedit on the OUTPUT to recompute them correctly -
  // which is cheap, because at that point the file is a few GB on the NVMe
  // cache. Running mkvpropedit on the 23 GB SOURCE off the spindle, as the
  // community flow did, is the part that was pure waste.
  const stripStats = ['BPS', 'DURATION', 'NUMBER_OF_FRAMES', 'NUMBER_OF_BYTES',
    '_STATISTICS_WRITING_APP', '_STATISTICS_WRITING_DATE_UTC', '_STATISTICS_TAGS']
    .map((tag) => `-metadata:s ${tag}=`).join(' ');

  const inputArgs = hevcIsFine ? '' : '-hwaccel cuda -hwaccel_output_format cuda';
  response.preset = `${inputArgs},${maps.join(' ')} ${out.join(' ')} ${stripStats}`
    + ' -map_metadata 0 -map_chapters 0 -max_muxing_queue_size 9999';
  response.processFile = true;
  response.infoLog += `Keeping ${keptAudio.length}/${audios.length} audio and `
    + `${keptSubs.length}/${subs.length} subtitle streams; ${oa} audio streams out.\n`;

  return response;
};

module.exports.details = details;
module.exports.plugin = plugin;
