#!/usr/bin/env python3

import json
import sys
import argparse
import os
import subprocess
import tempfile


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


def detect_watermark(video_file, num_frames=5, region=None, min_confidence=0.5):
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
    try:
        import cv2
    except ImportError:
        print("Error: OpenCV not found. Please install: pip install opencv-python", file=sys.stderr)
        sys.exit(1)
    
    ocr_engine = None
    reader = None
    pytesseract_module = None
    
    try:
        import easyocr
        reader = easyocr.Reader(['en', 'ch_sim'], gpu=False)
        ocr_engine = 'easyocr'
    except ImportError:
        pass
    except Exception as e:
        print(f"Warning: EasyOCR initialization failed: {e}", file=sys.stderr)
    
    if ocr_engine is None:
        try:
            import pytesseract
            pytesseract_module = pytesseract
            try:
                pytesseract.get_tesseract_version()
                ocr_engine = 'tesseract'
            except Exception:
                print("Warning: pytesseract found but tesseract executable not available", file=sys.stderr)
                print("Trying to use EasyOCR instead...", file=sys.stderr)
                if reader is None:
                    print("Error: No working OCR engine found.", file=sys.stderr)
                    print("Please install one of:", file=sys.stderr)
                    print("  1. EasyOCR: pip install easyocr", file=sys.stderr)
                    print("  2. Tesseract: Install tesseract-ocr system package, then pip install pytesseract", file=sys.stderr)
                    sys.exit(1)
                else:
                    ocr_engine = 'easyocr'
        except ImportError:
            if reader is None:
                print("Error: OCR library not found. Please install one of:", file=sys.stderr)
                print("  pip install easyocr", file=sys.stderr)
                print("  pip install pytesseract (requires tesseract-ocr system package)", file=sys.stderr)
                sys.exit(1)
            else:
                ocr_engine = 'easyocr'
    
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
    
    for frame_idx in frame_indices:
        cap.set(cv2.CAP_PROP_POS_FRAMES, frame_idx)
        ret, frame = cap.read()
        if not ret:
            continue
        
        if region:
            x, y, w, h = region
            frame = frame[y:y+h, x:x+w]
        
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        
        if ocr_engine == 'tesseract' and pytesseract_module is not None:
            try:
                data = pytesseract_module.image_to_data(gray, output_type=pytesseract_module.Output.DICT, lang='eng+chi_sim')
                for i, text in enumerate(data['text']):
                    if text.strip() and float(data['conf'][i]) > min_confidence * 100:
                        detected_texts.append({
                            'text': text.strip(),
                            'confidence': float(data['conf'][i]) / 100,
                            'frame': frame_idx,
                            'bbox': (data['left'][i], data['top'][i], data['width'][i], data['height'][i])
                        })
            except Exception as e:
                print(f"Warning: Tesseract OCR error: {e}", file=sys.stderr)
        elif ocr_engine == 'easyocr' and reader is not None:
            try:
                results = reader.readtext(gray)
                for (bbox, text, confidence) in results:
                    if confidence >= min_confidence:
                        detected_texts.append({
                            'text': text.strip(),
                            'confidence': confidence,
                            'frame': frame_idx,
                            'bbox': bbox
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
    
    text_frequency = {}
    for item in detected_texts:
        text = item['text']
        if text not in text_frequency:
            text_frequency[text] = {
                'count': 0,
                'total_confidence': 0,
                'frames': [],
                'bboxes': []
            }
        text_frequency[text]['count'] += 1
        text_frequency[text]['total_confidence'] += item['confidence']
        text_frequency[text]['frames'].append(item['frame'])
        text_frequency[text]['bboxes'].append(item['bbox'])
    
    watermarks = []
    for text, info in text_frequency.items():
        if info['count'] >= 2:
            avg_confidence = info['total_confidence'] / info['count']
            watermarks.append({
                'text': text,
                'frequency': info['count'],
                'confidence': avg_confidence,
                'frames': sorted(set(info['frames'])),
                'appears_consistently': info['count'] >= num_frames * 0.6
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
        
        result = detect_watermark(args.video_file, args.frames, region, args.confidence)
        
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
                    print("")
            else:
                print("No watermark detected in video.")
                print(result.get('message', ''))
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == '__main__':
    main()

