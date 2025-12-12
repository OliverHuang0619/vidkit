#!/usr/bin/env python3

import json
import sys
import argparse
import os
import subprocess
import tempfile
import math
import warnings


def transcribe_audio(audio_file, output_file, model_name, language=None, output_format='txt'):
    """
    Transcribe audio file using Whisper model.
    
    Args:
        audio_file: Path to audio file
        output_file: Path to output file
        model_name: Whisper model name (tiny, base, small, medium, large)
        language: Language code (None for auto-detection)
        output_format: Output format (txt, srt, vtt, json)
    """
    try:
        import whisper
    except ImportError:
        print("Error: Whisper not found. Please install: pip install openai-whisper", file=sys.stderr)
        sys.exit(1)
    
    try:
        model = whisper.load_model(model_name)
        result = model.transcribe(audio_file, language=language)
        
        if output_format == 'txt':
            with open(output_file, 'w', encoding='utf-8') as f:
                f.write(result['text'])
        elif output_format == 'srt':
            with open(output_file, 'w', encoding='utf-8') as f:
                for i, segment in enumerate(result['segments'], 1):
                    start = segment['start']
                    end = segment['end']
                    text = segment['text'].strip()
                    f.write(f"{i}\n")
                    f.write(f"{int(start//3600):02d}:{int((start%3600)//60):02d}:{int(start%60):02d},{int((start%1)*1000):03d} --> {int(end//3600):02d}:{int((end%3600)//60):02d}:{int(end%60):02d},{int((end%1)*1000):03d}\n")
                    f.write(f"{text}\n\n")
        elif output_format == 'vtt':
            with open(output_file, 'w', encoding='utf-8') as f:
                f.write("WEBVTT\n\n")
                for segment in result['segments']:
                    start = segment['start']
                    end = segment['end']
                    text = segment['text'].strip()
                    f.write(f"{int(start//3600):02d}:{int((start%3600)//60):02d}:{int(start%60):02d}.{int((start%1)*1000):03d} --> {int(end//3600):02d}:{int((end%3600)//60):02d}:{int(end%60):02d}.{int((end%1)*1000):03d}\n")
                    f.write(f"{text}\n\n")
        elif output_format == 'json':
            with open(output_file, 'w', encoding='utf-8') as f:
                json.dump(result, f, ensure_ascii=False, indent=2)
        
        print(f"Transcription saved to: {output_file}")
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


def detect_watermark(video_file, num_frames=5, region=None, min_confidence=0.5, engine='auto', padding=0.08):
    """
    Detect watermark text in video frames using OCR.
    
    Args:
        video_file: Path to video file
        num_frames: Number of frames to extract for detection (default: 5)
        region: Region to search (x,y,width,height) or None for full frame
        min_confidence: Minimum confidence threshold for OCR (0-1)
        
    Returns:
        Dictionary with detected watermark information
    """
    warnings.filterwarnings(
        "ignore",
        message=r"Signature .* for <class 'numpy\.longdouble'> does not match any known type.*",
        category=UserWarning,
    )

    try:
        import cv2
    except ImportError:
        print("Error: OpenCV not found. Please install: pip install opencv-python", file=sys.stderr)
        sys.exit(1)

    engine = (engine or "auto").strip().lower()
    if engine not in ("auto", "easyocr", "tesseract"):
        print("Error: Invalid OCR engine. Use: auto, easyocr, or tesseract", file=sys.stderr)
        sys.exit(1)

    ocr_engine = None
    reader = None
    pytesseract_module = None
    easyocr_error = None
    tesseract_error = None

    def try_init_easyocr():
        nonlocal reader, easyocr_error
        try:
            import easyocr
            reader = easyocr.Reader(['en', 'ch_sim'], gpu=False)
            return True
        except ImportError as e:
            easyocr_error = e
            return False
        except Exception as e:
            easyocr_error = e
            return False

    def try_init_tesseract():
        nonlocal pytesseract_module, tesseract_error
        try:
            import pytesseract
            pytesseract_module = pytesseract
            pytesseract.get_tesseract_version()
            return True
        except ImportError as e:
            tesseract_error = e
            return False
        except Exception as e:
            tesseract_error = e
            return False

    if engine in ("auto", "easyocr") and try_init_easyocr():
        ocr_engine = "easyocr"
    elif engine in ("auto", "tesseract") and try_init_tesseract():
        ocr_engine = "tesseract"
    elif engine == "easyocr":
        print(f"Error: EasyOCR initialization failed: {easyocr_error}", file=sys.stderr)
        print("Hint: EasyOCR may need to download models on first run. If your network is restricted,", file=sys.stderr)
        print("      pre-download models to ~/.EasyOCR/ or try engine 'tesseract'.", file=sys.stderr)
        sys.exit(1)
    elif engine == "tesseract":
        print(f"Error: Tesseract initialization failed: {tesseract_error}", file=sys.stderr)
        print("Hint: Install the system tesseract-ocr package and then 'pip install pytesseract'.", file=sys.stderr)
        sys.exit(1)
    else:
        print("Error: No working OCR engine found.", file=sys.stderr)
        print(f"  EasyOCR error: {easyocr_error}", file=sys.stderr)
        print(f"  Tesseract error: {tesseract_error}", file=sys.stderr)
        print("Please install one of:", file=sys.stderr)
        print("  1) EasyOCR: pip install easyocr", file=sys.stderr)
        print("  2) Tesseract: install tesseract-ocr (system), then pip install pytesseract", file=sys.stderr)
        sys.exit(1)
    
    if not os.path.exists(video_file):
        print(f"Error: Video file not found: {video_file}", file=sys.stderr)
        sys.exit(1)
    
    cap = cv2.VideoCapture(video_file)
    if not cap.isOpened():
        print(f"Error: Cannot open video file: {video_file}", file=sys.stderr)
        sys.exit(1)
    
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    fps = cap.get(cv2.CAP_PROP_FPS)
    duration = total_frames / fps if fps > 0 else 0
    
    frame_indices = []
    if total_frames > 0:
        step = max(1, total_frames // (num_frames + 1))
        for i in range(1, num_frames + 1):
            frame_indices.append(i * step)
    else:
        frame_indices = [0]
    
    detected_texts = []
    offset_x = 0
    offset_y = 0
    
    for frame_idx in frame_indices:
        cap.set(cv2.CAP_PROP_POS_FRAMES, frame_idx)
        ret, frame = cap.read()
        if not ret:
            continue
        
        if region:
            x, y, w, h = region
            offset_x = int(x)
            offset_y = int(y)
            frame = frame[y:y+h, x:x+w]
        
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        
        if ocr_engine == 'tesseract' and pytesseract_module is not None:
            try:
                try:
                    data = pytesseract_module.image_to_data(
                        gray,
                        output_type=pytesseract_module.Output.DICT,
                        lang='eng+chi_sim',
                    )
                except Exception:
                    data = pytesseract_module.image_to_data(
                        gray,
                        output_type=pytesseract_module.Output.DICT,
                        lang='eng',
                    )

                for i, text in enumerate(data.get('text', [])):
                    try:
                        conf_val = float(data['conf'][i])
                    except Exception:
                        conf_val = -1.0
                    if text and text.strip() and conf_val > min_confidence * 100:
                        left = int(data['left'][i]) + offset_x
                        top = int(data['top'][i]) + offset_y
                        width = int(data['width'][i])
                        height = int(data['height'][i])
                        detected_texts.append({
                            'text': text.strip(),
                            'confidence': conf_val / 100.0,
                            'frame': frame_idx,
                            'bbox': (left, top, width, height),
                            'bbox_xywh': (left, top, width, height),
                        })
            except Exception as e:
                print(f"Warning: Tesseract OCR error: {e}", file=sys.stderr)
        elif ocr_engine == 'easyocr' and reader is not None:
            try:
                results = reader.readtext(gray)
                for (bbox, text, confidence) in results:
                    if confidence >= min_confidence:
                        try:
                            xs = [p[0] for p in bbox]
                            ys = [p[1] for p in bbox]
                            min_x = int(min(xs)) + offset_x
                            min_y = int(min(ys)) + offset_y
                            max_x = int(max(xs)) + offset_x
                            max_y = int(max(ys)) + offset_y
                            xywh = (min_x, min_y, max(1, max_x - min_x), max(1, max_y - min_y))
                        except Exception:
                            xywh = None
                        detected_texts.append({
                            'text': text.strip(),
                            'confidence': confidence,
                            'frame': frame_idx,
                            'bbox': bbox,
                            'bbox_xywh': xywh,
                        })
            except Exception as e:
                print(f"Warning: EasyOCR error: {e}", file=sys.stderr)
    
    cap.release()
    
    if not detected_texts:
        return {
            'watermark_found': False,
            'watermarks': [],
            'message': 'No watermark text detected'
        }
    
    def normalize_text(s: str) -> str:
        return (s or "").strip()

    text_stats = {}
    for item in detected_texts:
        text = normalize_text(item.get('text', ''))
        if not text:
            continue
        frame_no = item.get('frame')
        confidence = float(item.get('confidence', 0.0) or 0.0)
        bbox_xywh = item.get('bbox_xywh')
        stats = text_stats.setdefault(text, {"occurrences": 0, "frame_conf": {}, "frame_bbox": {}})
        stats["occurrences"] += 1
        if frame_no is not None:
            prev = stats["frame_conf"].get(frame_no, 0.0)
            if confidence > prev:
                stats["frame_conf"][frame_no] = confidence
            if bbox_xywh is not None:
                stats["frame_bbox"][frame_no] = bbox_xywh

    watermarks = []
    consistency_threshold = int(math.ceil(num_frames * 0.6)) if num_frames and num_frames > 0 else 0
    for text, info in text_stats.items():
        frames = sorted(info["frame_conf"].keys())
        frame_frequency = len(frames)
        if frame_frequency < 2:
            continue
        avg_confidence = sum(info["frame_conf"].values()) / max(1, frame_frequency)
        bboxes = [info["frame_bbox"].get(f) for f in frames if info["frame_bbox"].get(f) is not None]
        suggested_region = None
        if bboxes:
            xs = [b[0] for b in bboxes]
            ys = [b[1] for b in bboxes]
            ws = [b[2] for b in bboxes]
            hs = [b[3] for b in bboxes]
            mx = int(sorted(xs)[len(xs)//2])
            my = int(sorted(ys)[len(ys)//2])
            mw = int(sorted(ws)[len(ws)//2])
            mh = int(sorted(hs)[len(hs)//2])
            pad = max(0.0, float(padding or 0.0))
            px = int(mw * pad)
            py = int(mh * pad)
            suggested_region = (max(0, mx - px), max(0, my - py), mw + 2 * px, mh + 2 * py)

        watermarks.append({
            'text': text,
            'frequency': frame_frequency,
            'confidence': avg_confidence,
            'frames': frames,
            'appears_consistently': frame_frequency >= max(2, consistency_threshold),
            'occurrences': info["occurrences"],
            'region': suggested_region,
        })
    
    watermarks.sort(key=lambda x: (x['appears_consistently'], x['frequency'], x['confidence']), reverse=True)
    
    return {
        'watermark_found': len(watermarks) > 0,
        'watermarks': watermarks,
        'total_frames_analyzed': len(frame_indices),
        'video_duration': duration
    }


def parse_metadata_json(json_input):
    """
    Parse ffprobe JSON output and format it for display.
    
    Args:
        json_input: JSON string from ffprobe
        
    Returns:
        Formatted string with metadata information
    """
    try:
        data = json.loads(json_input)
        format_info = data.get('format', {})
        
        output_lines = []
        output_lines.append(f"Format name: {format_info.get('format_name', 'N/A')}")
        output_lines.append(f"Format long name: {format_info.get('format_long_name', 'N/A')}")
        output_lines.append(f"Duration: {format_info.get('duration', 'N/A')} seconds")
        output_lines.append(f"Size: {format_info.get('size', 'N/A')} bytes")
        output_lines.append(f"Bitrate: {format_info.get('bit_rate', 'N/A')} bps")
        output_lines.append("")
        
        tags = format_info.get('tags', {})
        if tags:
            output_lines.append('--- Metadata Tags ---')
            for key, value in sorted(tags.items()):
                output_lines.append(f"{key}: {value}")
            output_lines.append("")
        
        streams = data.get('streams', [])
        if streams:
            output_lines.append('--- Stream Information ---')
            for i, stream in enumerate(streams):
                codec_type = stream.get('codec_type', 'unknown')
                codec_name = stream.get('codec_name', 'N/A')
                output_lines.append(f"Stream #{i} ({codec_type}):")
                output_lines.append(f"  Codec: {codec_name} ({stream.get('codec_long_name', 'N/A')})")
                if codec_type == 'video':
                    output_lines.append(f"  Resolution: {stream.get('width', 'N/A')}x{stream.get('height', 'N/A')}")
                    output_lines.append(f"  Frame rate: {stream.get('r_frame_rate', 'N/A')}")
                    output_lines.append(f"  Bitrate: {stream.get('bit_rate', 'N/A')} bps")
                elif codec_type == 'audio':
                    output_lines.append(f"  Sample rate: {stream.get('sample_rate', 'N/A')} Hz")
                    output_lines.append(f"  Channels: {stream.get('channels', 'N/A')}")
                    output_lines.append(f"  Bitrate: {stream.get('bit_rate', 'N/A')} bps")
                output_lines.append("")
        
        return '\n'.join(output_lines)
    except Exception as e:
        print(f"Error parsing JSON: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description='Video tools Python utilities')
    subparsers = parser.add_subparsers(dest='command', help='Command to execute')
    
    transcribe_parser = subparsers.add_parser('transcribe', help='Transcribe audio using Whisper')
    transcribe_parser.add_argument('audio_file', help='Path to audio file')
    transcribe_parser.add_argument('output_file', help='Path to output file')
    transcribe_parser.add_argument('--model', default='base', help='Whisper model name')
    transcribe_parser.add_argument('--language', default=None, help='Language code (None for auto)')
    transcribe_parser.add_argument('--format', default='txt', choices=['txt', 'srt', 'vtt', 'json'], help='Output format')
    
    parse_parser = subparsers.add_parser('parse-metadata', help='Parse ffprobe JSON metadata')
    parse_parser.add_argument('json_file', nargs='?', help='Path to JSON file (or read from stdin)')
    
    watermark_parser = subparsers.add_parser('detect-watermark', help='Detect watermark in video')
    watermark_parser.add_argument('video_file', help='Path to video file')
    watermark_parser.add_argument('--frames', type=int, default=5, help='Number of frames to analyze (default: 5)')
    watermark_parser.add_argument('--region', help='Region to search (x,y,width,height)')
    watermark_parser.add_argument('--confidence', type=float, default=0.5, help='Minimum confidence (0-1, default: 0.5)')
    watermark_parser.add_argument('--engine', default='auto', choices=['auto', 'easyocr', 'tesseract'], help='OCR engine (auto, easyocr, tesseract)')
    watermark_parser.add_argument('--padding', type=float, default=0.08, help='Suggested region padding ratio (default: 0.08)')
    watermark_parser.add_argument('--format', default='text', choices=['text', 'json'], help='Output format')
    
    args = parser.parse_args()
    
    if args.command == 'transcribe':
        language = args.language if args.language and args.language != 'auto' else None
        transcribe_audio(args.audio_file, args.output_file, args.model, language, args.format)
    elif args.command == 'parse-metadata':
        if args.json_file:
            with open(args.json_file, 'r', encoding='utf-8') as f:
                json_input = f.read()
        else:
            json_input = sys.stdin.read()
        result = parse_metadata_json(json_input)
        print(result)
    elif args.command == 'detect-watermark':
        region = None
        if args.region:
            try:
                coords = [int(x) for x in args.region.split(',')]
                if len(coords) == 4:
                    region = tuple(coords)
            except ValueError:
                print("Error: Invalid region format. Use: x,y,width,height", file=sys.stderr)
                sys.exit(1)
        
        result = detect_watermark(args.video_file, args.frames, region, args.confidence, args.engine, args.padding)
        
        if args.format == 'json':
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            if result['watermark_found']:
                print("=== Watermark Detection Results ===")
                print(f"Video duration: {result.get('video_duration', 0):.2f} seconds")
                print(f"Frames analyzed: {result.get('total_frames_analyzed', 0)}")
                print("")
                print("Detected watermarks:")
                for i, wm in enumerate(result['watermarks'], 1):
                    print(f"  {i}. Text: {wm['text']}")
                    print(f"     Frequency: {wm['frequency']} frames")
                    print(f"     Confidence: {wm['confidence']:.2%}")
                    print(f"     Consistent: {'Yes' if wm['appears_consistently'] else 'No'}")
                    print(f"     Frames: {wm['frames']}")
                    if wm.get('region'):
                        x, y, w, h = wm['region']
                        print(f"     Suggested region: {x},{y},{w},{h}")
                    print("")
            else:
                print("No watermark detected in video.")
                print(result.get('message', ''))
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == '__main__':
    main()

