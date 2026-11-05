import contextlib
import base64
import json
import os
import shutil
import sys
import tempfile

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.environ.get(
    "WINDOW_KEYWORD_OCR_CACHE",
    os.path.join(tempfile.gettempdir(), "window_keyword_ocr_cache"),
)
HOME_DIR = os.path.join(CACHE_DIR, "home")


def configure_environment() -> None:
    os.makedirs(CACHE_DIR, exist_ok=True)
    os.makedirs(HOME_DIR, exist_ok=True)
    os.environ["PADDLE_PDX_CACHE_HOME"] = CACHE_DIR
    os.environ["AISTUDIO_CACHE_HOME"] = os.path.join(CACHE_DIR, "aistudio")
    os.environ["XDG_CACHE_HOME"] = os.path.join(CACHE_DIR, "xdg")
    os.environ["HOME"] = HOME_DIR
    os.environ["USERPROFILE"] = HOME_DIR
    os.environ["HOMEDRIVE"] = os.path.splitdrive(HOME_DIR)[0] or "C:"
    os.environ["HOMEPATH"] = HOME_DIR
    os.environ["PADDLE_HOME"] = os.path.join(CACHE_DIR, "paddle")
    os.environ["PADDLEOCR_HOME"] = os.path.join(CACHE_DIR, "paddleocr")
    os.environ["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
    os.environ["PADDLE_PDX_MODEL_SOURCE"] = "bos"
    os.environ["PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT"] = "False"
    os.environ["FLAGS_use_mkldnn"] = "0"
    os.environ["FLAGS_enable_pir_api"] = "0"


def create_ocr():
    configure_environment()
    with contextlib.redirect_stdout(sys.stderr):
        detection_model = os.environ.get(
            "WINDOW_KEYWORD_OCR_DET_MODEL", "PP-OCRv5_mobile_det"
        )
        recognition_model = os.environ.get(
            "WINDOW_KEYWORD_OCR_REC_MODEL", "PP-OCRv5_server_rec"
        )

        from paddleocr import PaddleOCR

        try:
            return PaddleOCR(
                use_doc_orientation_classify=False,
                use_doc_unwarping=False,
                use_textline_orientation=False,
                text_detection_model_name=detection_model,
                text_recognition_model_name=recognition_model,
                text_det_limit_type="min",
                text_det_limit_side_len=1280,
                device="cpu",
                enable_mkldnn=False,
                enable_hpi=False,
                enable_cinn=False,
                lang="ch",
            )
        except Exception as primary_error:
            print(
                f"PP-OCRv5 initialization failed, falling back to PP-OCRv4: {primary_error}",
                file=sys.stderr,
            )
            return PaddleOCR(
                use_doc_orientation_classify=False,
                use_doc_unwarping=False,
                use_textline_orientation=False,
                text_detection_model_name="PP-OCRv4_mobile_det",
                text_recognition_model_name="PP-OCRv4_mobile_rec",
                device="cpu",
                enable_mkldnn=False,
                enable_hpi=False,
                enable_cinn=False,
                lang="ch",
            )


def ascii_working_image_path(image_path: str) -> str:
    configure_environment()
    image_path = os.path.abspath(image_path)
    ascii_dir = os.path.join(CACHE_DIR, "input")
    os.makedirs(ascii_dir, exist_ok=True)

    suffix = os.path.splitext(image_path)[1] or ".png"
    target_path = os.path.join(ascii_dir, f"ocr_input_{os.getpid()}{suffix}")
    shutil.copyfile(image_path, target_path)
    return target_path


def recognize(ocr, image_path: str) -> str:
    image_path = ascii_working_image_path(image_path)
    try:
        return recognize_working_image(ocr, image_path)
    finally:
        # Only remove the copy created above, never the user's source image.
        try:
            os.remove(image_path)
        except FileNotFoundError:
            pass


def recognize_working_image(ocr, image_path: str) -> str:
    with contextlib.redirect_stdout(sys.stderr):
        try:
            result = ocr.ocr(image_path, cls=True)
        except TypeError:
            result = ocr.ocr(image_path)

    lines = []

    def add_text(value):
        if value is None:
            return
        if isinstance(value, str):
            text = value.strip()
            if text:
                lines.append(text)
            return
        if isinstance(value, (list, tuple)):
            for part in value:
                add_text(part)
            return

    def extract_new_result(page):
        if isinstance(page, dict):
            if "rec_texts" in page:
                add_text(page.get("rec_texts"))
                return True
            if "text" in page:
                add_text(page.get("text"))
                return True
            if "res" in page:
                return extract_new_result(page.get("res"))

        if hasattr(page, "get"):
            try:
                rec_texts = page.get("rec_texts")
            except Exception:
                rec_texts = None
            if rec_texts:
                add_text(rec_texts)
                return True

        return False

    for page in result or []:
        if extract_new_result(page):
            continue
        for item in page or []:
            if not item or len(item) < 2:
                continue
            text_info = item[1]
            if isinstance(text_info, (list, tuple)) and text_info:
                text = text_info[0]
            else:
                text = text_info
            if text:
                lines.append(str(text))

    return "\n".join(lines)


def run_server() -> int:
    protocol_out = sys.stdout

    try:
        ocr = create_ocr()
    except Exception as exc:
        protocol_out.write(json.dumps({"ready": False, "error": str(exc)}, ensure_ascii=False) + "\n")
        protocol_out.flush()
        return 3

    protocol_out.write(json.dumps({"ready": True}, ensure_ascii=False) + "\n")
    protocol_out.flush()

    for raw_line in sys.stdin:
        image_path = raw_line.strip()
        if not image_path:
            continue
        if image_path == "__quit__":
            break

        try:
            text = recognize(ocr, image_path)
            payload = {
                "ok": True,
                "text_b64": base64.b64encode(text.encode("utf-8", errors="replace")).decode("ascii"),
            }
        except Exception as exc:
            payload = {"ok": False, "error": str(exc)}

        protocol_out.write(json.dumps(payload, ensure_ascii=False) + "\n")
        protocol_out.flush()

    return 0


def main() -> int:
    if len(sys.argv) >= 2 and sys.argv[1] == "--server":
        return run_server()

    if len(sys.argv) < 2:
        print("usage: paddle_ocr_runner.py IMAGE_PATH", file=sys.stderr)
        return 2

    image_path = sys.argv[1]

    try:
        ocr = create_ocr()
    except Exception as exc:
        print(f"PaddleOCR import failed: {exc}", file=sys.stderr)
        return 3

    sys.stdout.write(recognize(ocr, image_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
