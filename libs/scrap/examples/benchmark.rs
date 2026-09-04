use docopt::Docopt;
use hbb_common::{
    anyhow::{bail, Context},
    env_logger::{init_from_env, Env, DEFAULT_FILTER_ENV},
    log, serde_json, ResultType,
};
use scrap::{
    aom::{AomDecoder, AomEncoder, AomEncoderConfig},
    codec::{EncoderApi, EncoderCfg},
    Capturer, Display, TraitCapturer, VpxDecoder, VpxDecoderConfig, VpxEncoder, VpxEncoderConfig,
    VpxVideoCodecId::{self, *},
    STRIDE_ALIGN,
};
use std::{
    fs::File,
    io::{ErrorKind, Write},
    path::Path,
    time::{Duration, Instant},
};

// cargo run --package scrap --example benchmark --release --features hwcodec

const NO_PROGRESS_TIMEOUT: Duration = Duration::from_secs(10);

const USAGE: &str = "
Codec benchmark.

Usage:
  benchmark [--count=COUNT] [--quality=QUALITY] [--i444] [--codec=CODEC] [--json=PATH]
  benchmark (-h | --help)

Options:
  -h --help             Show this screen.
  --count=COUNT         Successfully submitted frame count [default: 100].
  --quality=QUALITY     Video quality [default: 1.0].
  --i444                I444.
  --codec=CODEC         Codec: vp8, vp9, av1, h264, h265, or all [default: all].
  --json=PATH           Write a machine-readable JSON report.
";

#[derive(Debug, serde::Deserialize, Clone)]
struct Args {
    flag_count: usize,
    flag_quality: f32,
    flag_i444: bool,
    flag_codec: String,
    flag_json: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CodecSelection {
    Vp8,
    Vp9,
    Av1,
    H264,
    H265,
    All,
}

impl CodecSelection {
    fn parse(value: &str) -> ResultType<Self> {
        match value.to_ascii_lowercase().as_str() {
            "vp8" => Ok(Self::Vp8),
            "vp9" => Ok(Self::Vp9),
            "av1" => Ok(Self::Av1),
            "h264" => Ok(Self::H264),
            "h265" => Ok(Self::H265),
            "all" => Ok(Self::All),
            _ => bail!("unsupported codec '{value}'; expected vp8, vp9, av1, h264, h265, or all"),
        }
    }

    fn includes(self, codec: Self) -> bool {
        self == Self::All || self == codec
    }
}

#[derive(Debug, serde::Serialize)]
struct BenchmarkSuite {
    width: usize,
    height: usize,
    quality: f32,
    i444: bool,
    requested_count: usize,
    results: Vec<CodecReport>,
    skipped: Vec<SkippedCodec>,
}

#[derive(Debug, serde::Serialize)]
struct SkippedCodec {
    codec: String,
    reason: String,
}

#[derive(Debug, serde::Serialize)]
struct CodecReport {
    codec: String,
    implementation: String,
    submitted_frames: usize,
    encoded_packets: usize,
    decoded_frames: usize,
    decode_flush_frames: usize,
    bytes: usize,
    average_bytes_per_frame: f64,
    megabits_per_second: f64,
    keyframes: usize,
    submitted_fps: f64,
    packet_fps: f64,
    pipeline_elapsed_ms: f64,
    capture_timeouts: usize,
    capture: TimingStats,
    capture_wait: TimingStats,
    convert: TimingStats,
    encode: TimingStats,
    decode: TimingStats,
    decode_flush: Option<TimingStats>,
}

#[derive(Debug, serde::Serialize)]
struct TimingStats {
    count: usize,
    total_ms: f64,
    avg_ms: f64,
    p50_ms: f64,
    p95_ms: f64,
    p99_ms: f64,
    max_ms: f64,
}

impl TimingStats {
    fn from_samples(samples: &[Duration]) -> Self {
        if samples.is_empty() {
            return Self {
                count: 0,
                total_ms: 0.0,
                avg_ms: 0.0,
                p50_ms: 0.0,
                p95_ms: 0.0,
                p99_ms: 0.0,
                max_ms: 0.0,
            };
        }

        let mut sorted = samples.to_vec();
        sorted.sort_unstable();
        let total = samples.iter().copied().sum::<Duration>();
        Self {
            count: samples.len(),
            total_ms: duration_ms(total),
            avg_ms: duration_ms(total) / samples.len() as f64,
            p50_ms: duration_ms(percentile(&sorted, 50)),
            p95_ms: duration_ms(percentile(&sorted, 95)),
            p99_ms: duration_ms(percentile(&sorted, 99)),
            max_ms: duration_ms(*sorted.last().unwrap_or(&Duration::ZERO)),
        }
    }
}

#[derive(Default)]
struct TimingSamples {
    capture: Vec<Duration>,
    capture_wait: Vec<Duration>,
    convert: Vec<Duration>,
    encode: Vec<Duration>,
    decode: Vec<Duration>,
    decode_flush: Option<Duration>,
}

struct EncodedPacket {
    data: Vec<u8>,
    key: bool,
}

fn main() -> ResultType<()> {
    init_from_env(Env::default().filter_or(DEFAULT_FILTER_ENV, "info"));
    let args: Args = Docopt::new(USAGE)
        .and_then(|d| d.deserialize())
        .unwrap_or_else(|e| e.exit());
    if args.flag_count == 0 {
        bail!("--count must be greater than zero");
    }
    let selection = CodecSelection::parse(&args.flag_codec)?;

    let mut displays = Display::all().context("failed to enumerate displays")?;
    if displays.is_empty() {
        bail!("no displays available");
    }
    let index = displays.iter().position(Display::is_primary).unwrap_or(0);
    let display = displays.remove(index);
    let mut capturer = Capturer::new(display).context("failed to create screen capturer")?;
    let width = capturer.width();
    let height = capturer.height();

    println!(
        "benchmark {}x{} quality:{:?}, i444:{:?}, codec:{}",
        width, height, args.flag_quality, args.flag_i444, args.flag_codec
    );

    let mut suite = BenchmarkSuite {
        width,
        height,
        quality: args.flag_quality,
        i444: args.flag_i444,
        requested_count: args.flag_count,
        results: Vec::new(),
        skipped: Vec::new(),
    };

    if selection.includes(CodecSelection::Vp8) {
        let result = test_vpx(
            &mut capturer,
            VP8,
            width,
            height,
            args.flag_quality,
            args.flag_count,
            false,
        )?;
        print_report(&result);
        suite.results.push(result);
    }
    if selection.includes(CodecSelection::Vp9) {
        let result = test_vpx(
            &mut capturer,
            VP9,
            width,
            height,
            args.flag_quality,
            args.flag_count,
            args.flag_i444,
        )?;
        print_report(&result);
        suite.results.push(result);
    }
    if selection.includes(CodecSelection::Av1) {
        let result = test_av1(
            &mut capturer,
            width,
            height,
            args.flag_quality,
            args.flag_count,
            args.flag_i444,
        )?;
        print_report(&result);
        suite.results.push(result);
    }

    run_hwcodec(
        selection,
        &mut capturer,
        width,
        height,
        args.flag_quality,
        args.flag_count,
        &mut suite,
    )?;

    if let Some(path) = args.flag_json {
        write_json_report(Path::new(&path), &suite)?;
        println!("JSON report written to {path}");
    }

    Ok(())
}

fn test_vpx(
    capturer: &mut Capturer,
    codec_id: VpxVideoCodecId,
    width: usize,
    height: usize,
    quality: f32,
    requested_count: usize,
    i444: bool,
) -> ResultType<CodecReport> {
    let config = EncoderCfg::VPX(VpxEncoderConfig {
        width: width as _,
        height: height as _,
        quality,
        codec: codec_id,
        keyframe_interval: None,
    });
    let mut encoder = VpxEncoder::new(config, i444)
        .with_context(|| format!("failed to create {codec_id:?} encoder"))?;
    let mut packets = Vec::with_capacity(requested_count);
    let mut timings = TimingSamples::default();
    let mut yuv = Vec::new();
    let mut mid_data = Vec::new();
    let pipeline_start = Instant::now();
    let mut last_progress = pipeline_start;
    let mut submitted_frames = 0;

    while submitted_frames < requested_count {
        let capture_start = Instant::now();
        match capturer.frame(Duration::from_millis(30)) {
            Ok(frame) => {
                timings.capture.push(capture_start.elapsed());

                let convert_start = Instant::now();
                let converted = frame
                    .to(encoder.yuvfmt(), &mut yuv, &mut mid_data)
                    .with_context(|| format!("failed to convert frame for {codec_id:?}"))?;
                let yuv = converted
                    .yuv()
                    .with_context(|| format!("{codec_id:?} requires a YUV frame"))?;
                timings.convert.push(convert_start.elapsed());

                let encode_start = Instant::now();
                for frame in encoder
                    .encode(pipeline_start.elapsed().as_millis() as _, yuv, STRIDE_ALIGN)
                    .with_context(|| format!("failed to encode {codec_id:?} frame"))?
                {
                    push_packet(&mut packets, frame.data.to_vec(), frame.key);
                }
                for frame in encoder
                    .flush()
                    .with_context(|| format!("failed to flush {codec_id:?} encoder"))?
                {
                    push_packet(&mut packets, frame.data.to_vec(), frame.key);
                }
                timings.encode.push(encode_start.elapsed());
                submitted_frames += 1;
                last_progress = Instant::now();
                print_progress(&format!("{codec_id:?}"), submitted_frames, requested_count);
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                timings.capture_wait.push(capture_start.elapsed());
                if last_progress.elapsed() >= NO_PROGRESS_TIMEOUT {
                    bail!(
                        "{codec_id:?} made no capture progress for {} seconds after {} timeouts",
                        NO_PROGRESS_TIMEOUT.as_secs(),
                        timings.capture_wait.len()
                    );
                }
            }
            Err(error) => bail!("failed to capture frame for {codec_id:?}: {error}"),
        }
    }
    println!();
    let pipeline_elapsed = pipeline_start.elapsed();

    let mut decoder = VpxDecoder::new(VpxDecoderConfig { codec: codec_id })
        .with_context(|| format!("failed to create {codec_id:?} decoder"))?;
    let mut decoded_frames = 0;
    for packet in &packets {
        let decode_start = Instant::now();
        decoded_frames += decoder
            .decode(&packet.data)
            .with_context(|| format!("failed to decode {codec_id:?} frame"))?
            .count();
        timings.decode.push(decode_start.elapsed());
    }
    let flush_start = Instant::now();
    let decode_flush_frames = decoder
        .flush()
        .with_context(|| format!("failed to flush {codec_id:?} decoder"))?
        .count();
    timings.decode_flush = Some(flush_start.elapsed());
    decoded_frames += decode_flush_frames;
    if decoded_frames == 0 {
        bail!("{codec_id:?} decoder produced no frames");
    }

    Ok(build_report(
        &format!("{codec_id:?}").to_ascii_lowercase(),
        "libvpx",
        &packets,
        submitted_frames,
        decoded_frames,
        decode_flush_frames,
        pipeline_elapsed,
        timings,
    ))
}

fn test_av1(
    capturer: &mut Capturer,
    width: usize,
    height: usize,
    quality: f32,
    requested_count: usize,
    i444: bool,
) -> ResultType<CodecReport> {
    let config = EncoderCfg::AOM(AomEncoderConfig {
        width: width as _,
        height: height as _,
        quality,
        keyframe_interval: None,
    });
    let mut encoder = AomEncoder::new(config, i444).context("failed to create AV1 encoder")?;
    let mut packets = Vec::with_capacity(requested_count);
    let mut timings = TimingSamples::default();
    let mut yuv = Vec::new();
    let mut mid_data = Vec::new();
    let pipeline_start = Instant::now();
    let mut last_progress = pipeline_start;
    let mut submitted_frames = 0;

    while submitted_frames < requested_count {
        let capture_start = Instant::now();
        match capturer.frame(Duration::from_millis(30)) {
            Ok(frame) => {
                timings.capture.push(capture_start.elapsed());

                let convert_start = Instant::now();
                let converted = frame
                    .to(encoder.yuvfmt(), &mut yuv, &mut mid_data)
                    .context("failed to convert frame for AV1")?;
                let yuv = converted.yuv().context("AV1 requires a YUV frame")?;
                timings.convert.push(convert_start.elapsed());

                let encode_start = Instant::now();
                for frame in encoder
                    .encode(pipeline_start.elapsed().as_millis() as _, yuv, STRIDE_ALIGN)
                    .context("failed to encode AV1 frame")?
                {
                    push_packet(&mut packets, frame.data.to_vec(), frame.key);
                }
                timings.encode.push(encode_start.elapsed());
                submitted_frames += 1;
                last_progress = Instant::now();
                print_progress("AV1", submitted_frames, requested_count);
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                timings.capture_wait.push(capture_start.elapsed());
                if last_progress.elapsed() >= NO_PROGRESS_TIMEOUT {
                    bail!(
                        "AV1 made no capture progress for {} seconds after {} timeouts",
                        NO_PROGRESS_TIMEOUT.as_secs(),
                        timings.capture_wait.len()
                    );
                }
            }
            Err(error) => bail!("failed to capture frame for AV1: {error}"),
        }
    }
    println!();
    let pipeline_elapsed = pipeline_start.elapsed();

    let mut decoder = AomDecoder::new().context("failed to create AV1 decoder")?;
    let mut decoded_frames = 0;
    for packet in &packets {
        let decode_start = Instant::now();
        decoded_frames += decoder
            .decode(&packet.data)
            .context("failed to decode AV1 frame")?
            .count();
        timings.decode.push(decode_start.elapsed());
    }
    let flush_start = Instant::now();
    let decode_flush_frames = decoder
        .flush()
        .context("failed to flush AV1 decoder")?
        .count();
    timings.decode_flush = Some(flush_start.elapsed());
    decoded_frames += decode_flush_frames;
    if decoded_frames == 0 {
        bail!("AV1 decoder produced no frames");
    }

    Ok(build_report(
        "av1",
        "libaom",
        &packets,
        submitted_frames,
        decoded_frames,
        decode_flush_frames,
        pipeline_elapsed,
        timings,
    ))
}

fn build_report(
    codec: &str,
    implementation: &str,
    packets: &[EncodedPacket],
    submitted_frames: usize,
    decoded_frames: usize,
    decode_flush_frames: usize,
    pipeline_elapsed: Duration,
    timings: TimingSamples,
) -> CodecReport {
    let encoded_packets = packets.len();
    let bytes = packets
        .iter()
        .map(|packet| packet.data.len())
        .sum::<usize>();
    let elapsed_seconds = pipeline_elapsed.as_secs_f64();
    CodecReport {
        codec: codec.to_owned(),
        implementation: implementation.to_owned(),
        submitted_frames,
        encoded_packets,
        decoded_frames,
        decode_flush_frames,
        bytes,
        average_bytes_per_frame: if submitted_frames > 0 {
            bytes as f64 / submitted_frames as f64
        } else {
            0.0
        },
        megabits_per_second: if elapsed_seconds > 0.0 {
            bytes as f64 * 8.0 / elapsed_seconds / 1_000_000.0
        } else {
            0.0
        },
        keyframes: packets.iter().filter(|packet| packet.key).count(),
        submitted_fps: if elapsed_seconds > 0.0 {
            submitted_frames as f64 / elapsed_seconds
        } else {
            0.0
        },
        packet_fps: if elapsed_seconds > 0.0 {
            encoded_packets as f64 / elapsed_seconds
        } else {
            0.0
        },
        pipeline_elapsed_ms: duration_ms(pipeline_elapsed),
        capture_timeouts: timings.capture_wait.len(),
        capture: TimingStats::from_samples(&timings.capture),
        capture_wait: TimingStats::from_samples(&timings.capture_wait),
        convert: TimingStats::from_samples(&timings.convert),
        encode: TimingStats::from_samples(&timings.encode),
        decode: TimingStats::from_samples(&timings.decode),
        decode_flush: timings
            .decode_flush
            .map(|duration| TimingStats::from_samples(&[duration])),
    }
}

fn print_report(report: &CodecReport) {
    println!(
        "{} ({}) submitted_frames={} encoded_packets={} decoded_frames={} decode_flush_frames={} bytes={} average_bytes_per_frame={:.2} megabits_per_second={:.3} submitted_fps={:.2} packet_fps={:.2} keyframes={} capture_timeouts={}",
        report.codec.to_ascii_uppercase(),
        report.implementation,
        report.submitted_frames,
        report.encoded_packets,
        report.decoded_frames,
        report.decode_flush_frames,
        report.bytes,
        report.average_bytes_per_frame,
        report.megabits_per_second,
        report.submitted_fps,
        report.packet_fps,
        report.keyframes,
        report.capture_timeouts
    );
    print_timing("capture", &report.capture);
    print_timing("wait", &report.capture_wait);
    print_timing("convert", &report.convert);
    print_timing("encode", &report.encode);
    print_timing("decode", &report.decode);
    if let Some(stats) = &report.decode_flush {
        print_timing("decflush", stats);
    }
}

fn print_timing(name: &str, stats: &TimingStats) {
    println!(
        "  {name:<7} count={} avg={:.3}ms P50={:.3}ms P95={:.3}ms P99={:.3}ms max={:.3}ms",
        stats.count, stats.avg_ms, stats.p50_ms, stats.p95_ms, stats.p99_ms, stats.max_ms
    );
}

fn print_progress(codec: &str, count: usize, requested_count: usize) {
    print!("\r{codec} {count}/{requested_count}");
    if let Err(error) = std::io::stdout().flush() {
        log::warn!("failed to flush benchmark progress: {error}");
    }
}

fn push_packet(packets: &mut Vec<EncodedPacket>, data: Vec<u8>, key: bool) {
    packets.push(EncodedPacket { data, key });
}

fn percentile(sorted: &[Duration], percent: usize) -> Duration {
    let rank = ((percent as f64 / 100.0) * sorted.len() as f64).ceil() as usize;
    sorted[rank.saturating_sub(1).min(sorted.len() - 1)]
}

fn duration_ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1_000.0
}

fn write_json_report(path: &Path, suite: &BenchmarkSuite) -> ResultType<()> {
    let mut file = File::create(path)
        .with_context(|| format!("failed to create JSON report at {}", path.display()))?;
    serde_json::to_writer_pretty(&mut file, suite)
        .with_context(|| format!("failed to write JSON report at {}", path.display()))?;
    writeln!(file)
        .with_context(|| format!("failed to finish JSON report at {}", path.display()))?;
    Ok(())
}

#[cfg(feature = "hwcodec")]
fn run_hwcodec(
    selection: CodecSelection,
    capturer: &mut Capturer,
    width: usize,
    height: usize,
    quality: f32,
    requested_count: usize,
    suite: &mut BenchmarkSuite,
) -> ResultType<()> {
    use scrap::CodecFormat;

    for (selected, format, name) in [
        (CodecSelection::H264, CodecFormat::H264, "h264"),
        (CodecSelection::H265, CodecFormat::H265, "h265"),
    ] {
        if !selection.includes(selected) {
            continue;
        }
        let outcome = hw::test_codec(
            capturer,
            width,
            height,
            quality,
            requested_count,
            format,
            name,
        );
        match outcome {
            Ok(Some(result)) => {
                print_report(&result);
                suite.results.push(result);
            }
            Ok(None) if selection == CodecSelection::All => suite.skipped.push(SkippedCodec {
                codec: name.to_owned(),
                reason: "no compatible encoder found".to_owned(),
            }),
            Ok(None) => bail!("no compatible {name} encoder found"),
            Err(error) if selection == CodecSelection::All => {
                suite.skipped.push(SkippedCodec {
                    codec: name.to_owned(),
                    reason: format!("benchmark unavailable: {error:#}"),
                });
            }
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

#[cfg(not(feature = "hwcodec"))]
fn run_hwcodec(
    selection: CodecSelection,
    _capturer: &mut Capturer,
    _width: usize,
    _height: usize,
    _quality: f32,
    _requested_count: usize,
    suite: &mut BenchmarkSuite,
) -> ResultType<()> {
    for (selected, name) in [
        (CodecSelection::H264, "h264"),
        (CodecSelection::H265, "h265"),
    ] {
        if !selection.includes(selected) {
            continue;
        }
        if selection == CodecSelection::All {
            suite.skipped.push(SkippedCodec {
                codec: name.to_owned(),
                reason: "build without the hwcodec feature".to_owned(),
            });
        } else {
            bail!("{name} requires building the benchmark with --features hwcodec");
        }
    }
    Ok(())
}

#[cfg(feature = "hwcodec")]
mod hw {
    use hwcodec::ffmpeg_ram::CodecInfo;
    use scrap::{
        hwcodec::{HwRamDecoder, HwRamEncoder, HwRamEncoderConfig},
        CodecFormat,
    };

    use super::*;

    pub fn test_codec(
        capturer: &mut Capturer,
        width: usize,
        height: usize,
        quality: f32,
        requested_count: usize,
        format: CodecFormat,
        codec_name: &str,
    ) -> ResultType<Option<CodecReport>> {
        let Some(info) = HwRamEncoder::try_get(format) else {
            return Ok(None);
        };
        let report = test_encoder(
            width,
            height,
            quality,
            info,
            capturer,
            requested_count,
            format,
            codec_name,
        )?;
        Ok(Some(report))
    }

    fn test_encoder(
        width: usize,
        height: usize,
        quality: f32,
        info: CodecInfo,
        capturer: &mut Capturer,
        requested_count: usize,
        format: CodecFormat,
        codec_name: &str,
    ) -> ResultType<CodecReport> {
        let mut encoder = HwRamEncoder::new(
            EncoderCfg::HWRAM(HwRamEncoderConfig {
                name: info.name.clone(),
                mc_name: None,
                width,
                height,
                quality,
                keyframe_interval: None,
            }),
            false,
        )
        .with_context(|| format!("failed to create {} encoder", info.name))?;
        let mut packets = Vec::with_capacity(requested_count);
        let mut timings = TimingSamples::default();
        let mut yuv = Vec::new();
        let mut mid_data = Vec::new();
        let pipeline_start = Instant::now();
        let mut last_progress = pipeline_start;
        let mut submitted_frames = 0;

        while submitted_frames < requested_count {
            let capture_start = Instant::now();
            match capturer.frame(Duration::from_millis(30)) {
                Ok(frame) => {
                    timings.capture.push(capture_start.elapsed());

                    let convert_start = Instant::now();
                    let converted = frame
                        .to(encoder.yuvfmt(), &mut yuv, &mut mid_data)
                        .with_context(|| format!("failed to convert frame for {}", info.name))?;
                    let yuv = converted
                        .yuv()
                        .with_context(|| format!("{} requires a YUV frame", info.name))?;
                    timings.convert.push(convert_start.elapsed());

                    let encode_start = Instant::now();
                    for frame in encoder
                        .encode(yuv, pipeline_start.elapsed().as_millis() as _)
                        .with_context(|| format!("failed to encode {} frame", info.name))?
                    {
                        push_packet(&mut packets, frame.data, frame.key == 1);
                    }
                    timings.encode.push(encode_start.elapsed());
                    submitted_frames += 1;
                    last_progress = Instant::now();
                    print_progress(&info.name, submitted_frames, requested_count);
                }
                Err(error) if error.kind() == ErrorKind::WouldBlock => {
                    timings.capture_wait.push(capture_start.elapsed());
                    if last_progress.elapsed() >= NO_PROGRESS_TIMEOUT {
                        bail!(
                            "{} made no capture progress for {} seconds after {} timeouts",
                            info.name,
                            NO_PROGRESS_TIMEOUT.as_secs(),
                            timings.capture_wait.len()
                        );
                    }
                }
                Err(error) => bail!("failed to capture frame for {}: {error}", info.name),
            }
        }
        println!();
        let pipeline_elapsed = pipeline_start.elapsed();

        let mut decoder = HwRamDecoder::new(format)
            .with_context(|| format!("failed to create {codec_name} decoder"))?;
        let mut decoded_frames = 0;
        for packet in &packets {
            let decode_start = Instant::now();
            let frames = decoder
                .decode(&packet.data)
                .with_context(|| format!("failed to decode {codec_name} frame"))?;
            decoded_frames += frames.len();
            drop(frames);
            timings.decode.push(decode_start.elapsed());
        }
        if decoded_frames == 0 {
            bail!("{codec_name} decoder produced no frames");
        }
        let decoder_name = decoder.info.name.clone();
        let decoder_device = format!("{:?}", decoder.info.hwdevice).to_ascii_lowercase();
        let implementation = format!(
            "encoder={}, decoder={}/{}",
            info.name,
            decoder_name,
            decoder_device.rsplit('_').next().unwrap_or(&decoder_device)
        );

        Ok(build_report(
            codec_name,
            &implementation,
            &packets,
            submitted_frames,
            decoded_frames,
            0,
            pipeline_elapsed,
            timings,
        ))
    }
}
