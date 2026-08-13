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
// This file is TRACKED IN GIT at tdarr/plugins/ and copied into the server's
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

  const inputArgs = hevcIsFine ? '' : '-hwaccel cuda -hwaccel_output_format cuda';
  response.preset = `${inputArgs},${maps.join(' ')} ${out.join(' ')}`
    + ' -map_metadata 0 -map_chapters 0 -max_muxing_queue_size 9999';
  response.processFile = true;
  response.infoLog += `Keeping ${keptAudio.length}/${audios.length} audio and `
    + `${keptSubs.length}/${subs.length} subtitle streams; ${oa} audio streams out.\n`;

  return response;
};

module.exports.details = details;
module.exports.plugin = plugin;
