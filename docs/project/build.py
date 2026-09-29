"""Сборка комплекта проектной документации Think Faster в PDF: по файлу на документ.

    python docs/project/build.py

Исходники — docs/project/0N-*.md (Markdown читается в GitHub как есть). В PDF ссылки на соседние
документы и на docs/system/SYSTEM.md ведут на их PDF. Отрисовка схем и печать — теми же функциями,
что docs/system/build.py (нужны пакет `markdown`, Chrome/Edge и доступ к cdn.jsdelivr.net).
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'system'))
import build as system  # noqa: E402

LOCAL_MD = re.compile(r'\]\(((?:\.\./system/)?[\w.-]+)\.md(#[^)]*)?\)')


def for_pdf(md_text: str) -> str:
    """Ссылки на .md соседних документов → .pdf."""
    return LOCAL_MD.sub(lambda m: f']({m.group(1)}.pdf{m.group(2) or ""})', md_text)


def build_one(md_path: Path, exe: str) -> tuple[str, int]:
    text = md_path.read_text(encoding='utf-8')
    title = next((line[2:].strip() for line in text.splitlines() if line.startswith('# ')), md_path.stem)
    dynamic = md_path.with_suffix('.render.html')
    static = md_path.with_suffix('.html')
    pdf = md_path.with_suffix('.pdf')
    dynamic.write_text(system.to_html(for_pdf(text), f'Think Faster — {title}'), encoding='utf-8')
    try:
        dom = system.run_browser(exe, '--virtual-time-budget=60000', '--run-all-compositor-stages-before-draw',
                                 '--dump-dom', dynamic.as_uri()).stdout
        status = re.search(r'name="mermaid-status" content="done (\d+) failed (\d+)"', dom)
        if not status:
            return 'схемы не отрисованы', 1
        static.write_text('<!DOCTYPE html>\n' + dom, encoding='utf-8')
        system.run_browser(exe, '--no-pdf-header-footer', '--print-to-pdf-no-header', f'--print-to-pdf={pdf}',
                           static.as_uri())
        failed = int(status.group(2))
        return f'схем {status.group(1)}, ошибок {failed}, PDF {pdf.stat().st_size // 1024} КБ', failed
    finally:
        dynamic.unlink(missing_ok=True)
        static.unlink(missing_ok=True)


def main() -> int:
    exe = system.browser()
    if not exe:
        print('нет Chrome/Edge — PDF не собраны')
        return 1
    errors = 0
    for md_path in sorted(HERE.glob('[0-9][0-9]-*.md')):
        result, failed = build_one(md_path, exe)
        errors += failed
        print(f'{md_path.name}: {result}')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
